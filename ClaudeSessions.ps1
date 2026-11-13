# Claude Code collector. Dot-sourced by Watch-OpencodeSessions.ps1, which
# provides Get-Field, Limit-Text, Get-ToolSummary, Get-SessionName,
# Get-DirectoryKey, Get-StateRank, Sort-SessionJson and Receive-Request.
#
# Claude Code has no API to poll, so everything comes from its files:
#   ~/.claude/sessions/<pid>.json                     running processes, busy / idle
#   ~/.claude/projects/<dir>/<session>.jsonl          one transcript per session
#   ~/.claude/projects/<dir>/<session>/subagents/agent-<id>.jsonl (+ .meta.json)
#
# Transcripts can be megabytes, so each file is read once and then only the
# bytes appended since the last tick are parsed.

$script:ClaudeRoot = Join-Path $env:USERPROFILE '.claude'

$script:CC = @{
    Files      = @{}   # transcript path -> parsed state
    Since      = @{}   # node id -> @{ state; since }
    Day        = ''
    LastScan   = [long]0
    Roots      = @()
    Tick       = 0
    LastResult = $null
}

function ConvertTo-UnixMs {
    param($Value)

    if ($null -eq $Value) { return [long]0 }
    if ($Value -is [datetime]) { return ([DateTimeOffset]$Value).ToUnixTimeMilliseconds() }

    $text = [string]$Value
    if (-not $text) { return [long]0 }

    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.ToUnixTimeMilliseconds()
    }
    return [long]0
}

function New-TokenSet {
    return @{ input = [long]0; output = [long]0; reasoning = [long]0; cacheRead = [long]0; cacheWrite = [long]0 }
}

function New-ClaudeTranscript {
    param([string]$Path)

    return @{
        Path        = $Path
        Offset      = [long]0
        SessionId   = ''
        Cwd         = ''
        Prompt      = ''
        Model       = ''
        Agent       = ''
        Tokens      = (New-TokenSet)
        Today       = (New-TokenSet)
        Steps       = 0
        TodaySteps  = 0
        MsgUsage    = @{}       # message id -> last counted usage (streamed lines repeat it)
        Pending     = [ordered]@{}   # tool_use id -> call still waiting for its result
        AgentCalls  = New-Object 'System.Collections.Generic.HashSet[string]'
        Created     = [long]0
        Updated     = [long]0
        TurnOpen    = $false
        Interrupted = $false
        Cost        = [double]0
        Used        = 0
    }
}

function Read-ClaudeLines {
    # New complete lines since the last read. Reset = the file shrank (rewritten).
    param($T)

    $stream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($T.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $length = $stream.Length

        if ($length -lt $T.Offset) { return @{ Reset = $true; Lines = @() } }
        if ($length -eq $T.Offset) { return @{ Reset = $false; Lines = @() } }

        [void]$stream.Seek($T.Offset, [IO.SeekOrigin]::Begin)
        $count = [int]($length - $T.Offset)
        $buffer = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $n = $stream.Read($buffer, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -le 0) { return @{ Reset = $false; Lines = @() } }

        # Only consume up to the last newline; a half-written line waits for the next tick.
        $last = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
        if ($last -lt 0) { return @{ Reset = $false; Lines = @() } }

        $text = $script:Utf8.GetString($buffer, 0, $last)
        $T.Offset += $last + 1
        return @{ Reset = $false; Lines = ($text -split "`n") }
    }
    catch {
        return @{ Reset = $false; Lines = @() }
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Add-ClaudeUsage {
    param($T, [string]$MessageId, $Usage, [bool]$IsToday)

    $output = [long](Get-Field $Usage 'output_tokens' 0)
    $thinking = [long](Get-Field (Get-Field $Usage 'output_tokens_details') 'thinking_tokens' 0)
    if ($thinking -gt $output) { $thinking = 0 }

    $now = @{
        input      = [long](Get-Field $Usage 'input_tokens' 0)
        output     = $output - $thinking
        reasoning  = $thinking
        cacheRead  = [long](Get-Field $Usage 'cache_read_input_tokens' 0)
        cacheWrite = [long](Get-Field $Usage 'cache_creation_input_tokens' 0)
    }

    # A streamed message is written once per content block; count only its latest usage.
    $previous = $T.MsgUsage[$MessageId]
    if (-not $previous) {
        $T.Steps++
        if ($IsToday) { $T.TodaySteps++ }
    }

    foreach ($key in @($now.Keys)) {
        $delta = $now[$key]
        if ($previous) { $delta -= $previous.Values[$key] }
        $T.Tokens[$key] += $delta
        if ($IsToday) { $T.Today[$key] += $delta }
    }

    $T.MsgUsage[$MessageId] = @{ Values = $now }
}

function Add-ClaudeUser {
    param($T, $Entry)

    $message = Get-Field $Entry 'message'
    $content = Get-Field $message 'content'

    $texts = New-Object System.Collections.ArrayList
    if ($content -is [string]) {
        [void]$texts.Add($content)
    }
    else {
        foreach ($block in @($content)) {
            $blockType = [string](Get-Field $block 'type' '')
            if ($blockType -eq 'tool_result') {
                $id = [string](Get-Field $block 'tool_use_id' '')
                if ($id -and $T.Pending.Contains($id)) { $T.Pending.Remove($id) }
            }
            elseif ($blockType -eq 'text') {
                [void]$texts.Add([string](Get-Field $block 'text' ''))
            }
        }
    }

    if ($texts.Count -eq 0) { return }
    $text = ($texts -join ' ').Trim()

    if ($text.StartsWith('[Request interrupted')) {
        $T.Interrupted = $true
        $T.TurnOpen = $false
        $T.Pending.Clear()
        return
    }

    if (Get-Field $Entry 'isMeta' $false) { return }
    $kind = [string](Get-Field (Get-Field $Entry 'origin') 'kind' 'human')
    if ($kind -ne 'human') { return }
    if ($text.StartsWith('<')) { return }   # slash commands and injected reminders

    $T.TurnOpen = $true
    $T.Interrupted = $false
    if (-not $T.Prompt) { $T.Prompt = Limit-Text $text 160 }
}

function Add-ClaudeAssistant {
    param($T, $Entry, [long]$Ts, [long]$DayStart)

    $message = Get-Field $Entry 'message'
    $model = [string](Get-Field $message 'model' '')
    if ($model -and $model -ne '<synthetic>') { $T.Model = $model }
    $T.TurnOpen = $true

    $messageId = [string](Get-Field $message 'id' '')
    $usage = Get-Field $message 'usage'
    if ($usage -and $messageId) {
        Add-ClaudeUsage -T $T -MessageId $messageId -Usage $usage -IsToday ($Ts -ge $DayStart)
    }

    $hasTool = $false
    foreach ($block in @(Get-Field $message 'content' @())) {
        if ((Get-Field $block 'type') -ne 'tool_use') { continue }
        $hasTool = $true
        $id = [string](Get-Field $block 'id' '')
        if (-not $id) { continue }
        $name = [string](Get-Field $block 'name' 'tool')
        $T.Pending[$id] = @{ name = $name; input = (Get-Field $block 'input'); at = $Ts }
        if ($name -eq 'Agent' -or $name -eq 'Task') { [void]$T.AgentCalls.Add($id) }
    }

    if (-not $hasTool -and (Get-Field $message 'stop_reason') -eq 'end_turn') { $T.TurnOpen = $false }
}

function Add-ClaudeEntry {
    param($T, [string]$Line, [long]$DayStart)

    if ($Line.Length -lt 20) { return }
    # Request dumps and queue records are large and carry nothing the map shows.
    if ($Line.StartsWith('{"type":"api-request') -or
        $Line.StartsWith('{"type":"file-history') -or
        $Line.StartsWith('{"type":"queue-operation')) { return }
    if ($Line -notmatch '"type":"(user|assistant|system|cost-state|agent-setting)"') { return }

    try { $entry = $Line | ConvertFrom-Json } catch { return }

    $ts = ConvertTo-UnixMs (Get-Field $entry 'timestamp')
    if ($ts -gt 0) {
        if ($T.Created -eq 0) { $T.Created = $ts }
        if ($ts -gt $T.Updated) { $T.Updated = $ts }
    }
    if (-not $T.Cwd) { $T.Cwd = [string](Get-Field $entry 'cwd' '') }
    if (-not $T.SessionId) { $T.SessionId = [string](Get-Field $entry 'sessionId' '') }

    switch ([string](Get-Field $entry 'type' '')) {
        'agent-setting' { $T.Agent = [string](Get-Field $entry 'agentSetting' '') }
        'cost-state'    { $T.Cost = [double](Get-Field $entry 'totalCostUSD' 0) }
        'system' {
            if ((Get-Field $entry 'subtype') -eq 'turn_duration') {
                $T.TurnOpen = $false
                $T.Pending.Clear()
            }
        }
        'user'      { Add-ClaudeUser -T $T -Entry $entry }
        'assistant' { Add-ClaudeAssistant -T $T -Entry $entry -Ts $ts -DayStart $DayStart }
    }
}

function Sync-ClaudeTranscript {
    param([string]$Path, [long]$DayStart)

    $T = $script:CC.Files[$Path]
    if (-not $T) {
        $T = New-ClaudeTranscript $Path
        $script:CC.Files[$Path] = $T
    }

    $chunk = Read-ClaudeLines $T
    if ($chunk.Reset) {
        $T = New-ClaudeTranscript $Path
        $script:CC.Files[$Path] = $T
        $chunk = Read-ClaudeLines $T
    }

    $i = 0
    foreach ($line in $chunk.Lines) {
        Add-ClaudeEntry -T $T -Line $line.TrimEnd("`r") -DayStart $DayStart
        $i++
        # The first read of a big transcript takes a moment; keep the page served.
        if (($i % 200) -eq 0 -and $script:Server) { Receive-Request -Server $script:Server }
    }

    $T.Used = $script:CC.Tick
    return $T
}

function Get-ClaudeLive {
    # sessionId -> registry entry, for Claude Code processes that are still alive.
    $live = @{}
    $dir = Join-Path $script:ClaudeRoot 'sessions'
    if (-not (Test-Path -LiteralPath $dir)) { return $live }

    $alive = @{}
    foreach ($process in [Diagnostics.Process]::GetProcesses()) { $alive[$process.Id] = $true }

    foreach ($file in [IO.Directory]::GetFiles($dir, '*.json')) {
        try { $info = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { continue }
        $procId = [int](Get-Field $info 'pid' 0)
        $sid = [string](Get-Field $info 'sessionId' '')
        if ($sid -and $alive.ContainsKey($procId)) { $live[$sid] = $info }
    }

    return $live
}

function Find-ClaudeTranscripts {
    param([long]$Cutoff, $Live)

    $projects = Join-Path $script:ClaudeRoot 'projects'
    $found = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $projects)) { return ,$found }

    foreach ($project in [IO.Directory]::GetDirectories($projects)) {
        foreach ($file in [IO.Directory]::GetFiles($project, '*.jsonl')) {
            $sid = [IO.Path]::GetFileNameWithoutExtension($file)
            $mtime = ([DateTimeOffset][IO.File]::GetLastWriteTimeUtc($file)).ToUnixTimeMilliseconds()
            if ($mtime -ge $Cutoff -or $Live.ContainsKey($sid)) {
                [void]$found.Add(@{ Path = $file; SessionId = $sid; Folder = $project; Mtime = $mtime; Live = $Live.ContainsKey($sid) })
            }
        }
    }

    # Live sessions first, then the most recently written, up to the limit.
    $sorted = @($found | Sort-Object -Property @{ Expression = { $_.Live }; Descending = $true }, @{ Expression = { $_.Mtime }; Descending = $true } |
        Select-Object -First $ClaudeLimit)
    return ,$sorted
}

function Get-ClaudeSubagents {
    param([string]$Folder, [string]$SessionId)

    $dir = Join-Path (Join-Path $Folder $SessionId) 'subagents'
    $result = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $dir)) { return }

    foreach ($file in [IO.Directory]::GetFiles($dir, 'agent-*.jsonl')) {
        $agentId = [IO.Path]::GetFileNameWithoutExtension($file).Substring(6)
        $metaPath = [IO.Path]::ChangeExtension($file, $null).TrimEnd('.') + '.meta.json'
        $meta = $null
        if (Test-Path -LiteralPath $metaPath) {
            try { $meta = [IO.File]::ReadAllText($metaPath) | ConvertFrom-Json } catch { }
        }
        [void]$result.Add(@{
            Path    = $file
            AgentId = $agentId
            Meta    = $meta
            Mtime   = ([DateTimeOffset][IO.File]::GetLastWriteTimeUtc($file)).ToUnixTimeMilliseconds()
        })
    }

    return $result
}

function Get-ClaudeToolSummary {
    param($Call)

    $toolInput = $Call.input
    if ($Call.name -eq 'Agent' -or $Call.name -eq 'Task') {
        $part = @{ name = 'subagent'; state = @{ input = @{
            agent       = [string](Get-Field $toolInput 'subagent_type' 'agent')
            description = [string](Get-Field $toolInput 'description' '')
            prompt      = [string](Get-Field $toolInput 'prompt' '')
        } } }
    }
    else {
        $part = @{ name = $Call.name; state = @{ input = $toolInput } }
    }

    return Get-ToolSummary $part
}

function Set-ClaudeSince {
    param([string]$Id, [string]$State, [long]$Now)

    $entry = $script:CC.Since[$Id]
    if (-not $entry -or $entry.state -ne $State) {
        $entry = @{ state = $State; since = $Now }
        $script:CC.Since[$Id] = $entry
    }
    $entry.seen = $Now
    return $entry.since
}

function New-ClaudeNode {
    param([string]$Id, [string]$ParentId, $T, [string]$State, [string]$Name, [string]$Agent, [string]$Task, $Now)

    $activity = ''
    $activityFull = ''
    $stateDetail = $null

    if ($State -eq 'running') {
        $calls = @($T.Pending.Values)
        if ($calls.Count -gt 0) {
            $summary = Get-ClaudeToolSummary $calls[0]
            $stateDetail = $calls[0].name
            $activity = $summary.short
            $activityFull = $summary.full
            if ($calls.Count -gt 1) { $activity += (' (+{0} more)' -f ($calls.Count - 1)) }
        }
        else {
            $stateDetail = 'thinking'
        }
    }

    $since = Set-ClaudeSince -Id $Id -State $State -Now $Now
    $tokens = $T.Tokens
    $total = $tokens.input + $tokens.cacheWrite + $tokens.output + $tokens.reasoning

    $shortId = $Id
    if ($shortId.Length -gt 8) { $shortId = $shortId.Substring(0, 8) }

    return @{
        id           = $Id
        shortId      = $shortId
        parentId     = $(if ($ParentId) { $ParentId } else { $null })
        depth        = 0
        source       = 'claude'
        name         = $Name
        slug         = ''
        title        = ''
        prompt       = $T.Prompt
        task         = $Task
        activity     = $activity
        activityFull = $activityFull
        delegations  = (New-Object System.Collections.ArrayList)
        agent        = $Agent
        model        = $T.Model
        state        = $State
        stateDetail  = $stateDetail
        stateSince   = $since
        runningSince = $(if ($State -eq 'running') { $since } else { $null })
        createdAt    = $T.Created
        updatedAt    = $T.Updated
        idleAt       = $null
        outcome      = $(if ($State -eq 'interrupted') { 'interrupted' } else { $null })
        cost         = $T.Cost
        tokens       = @{
            input      = $tokens.input
            output     = $tokens.output
            reasoning  = $tokens.reasoning
            cacheRead  = $tokens.cacheRead
            cacheWrite = $tokens.cacheWrite
            total      = $total
        }
        stateRank    = (Get-StateRank $State)
        children     = (New-Object System.Collections.ArrayList)
    }
}

function Get-ClaudeRootState {
    param($T, $LiveInfo, [long]$Now)

    if ($LiveInfo) {
        $status = ([string](Get-Field $LiveInfo 'status' '')).ToLowerInvariant()
        if ($status -match 'wait|permission|approv') { return 'waiting' }
        if ($status -eq 'busy' -or $status -eq 'running') { return 'running' }
        if ($status -eq 'idle') { if ($T.Interrupted) { return 'interrupted' } return 'idle' }
        if ($T.TurnOpen) { return 'running' }
        return 'idle'
    }

    # No registry entry: either the process ended, or it is a client that does not register.
    if ($T.TurnOpen -and ($Now - $T.Updated) -lt 30000) { return 'running' }
    if ($T.Interrupted -or $T.TurnOpen) { return 'interrupted' }
    return 'idle'
}

function Update-ClaudeSnapshot {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $script:CC.Tick++

    $today = Get-Date
    $dayKey = $today.ToString('yyyy-MM-dd')
    $dayStart = ([DateTimeOffset]::new($today.Date)).ToUnixTimeMilliseconds()
    if ($script:CC.Day -ne $dayKey) {
        # New day: re-read everything so "today" counts start from zero.
        $script:CC.Files = @{}
        $script:CC.Day = $dayKey
    }

    $live = Get-ClaudeLive

    $known = @{}
    foreach ($root in $script:CC.Roots) { $known[$root.SessionId] = $true }
    $missingLive = @($live.Keys | Where-Object { -not $known.ContainsKey($_) }).Count -gt 0

    if ($missingLive -or ($now - $script:CC.LastScan) -ge 5000) {
        $cutoff = $now - [long]$ClaudeHours * 3600 * 1000
        $script:CC.Roots = Find-ClaudeTranscripts -Cutoff $cutoff -Live $live
        $script:CC.LastScan = $now
    }

    $todayTokens = New-TokenSet
    $todaySteps = 0
    $todaySessions = 0
    $maxTokens = [long]0
    $nodes = @{}
    $order = New-Object System.Collections.ArrayList

    foreach ($root in $script:CC.Roots) {
        if (-not (Test-Path -LiteralPath $root.Path)) { continue }
        $T = Sync-ClaudeTranscript -Path $root.Path -DayStart $dayStart

        $sid = $root.SessionId
        $liveInfo = $null
        if ($live.ContainsKey($sid)) { $liveInfo = $live[$sid] }
        $rootState = Get-ClaudeRootState -T $T -LiveInfo $liveInfo -Now $now

        $name = Get-SessionName -SessionId $sid -Prompt $T.Prompt
        if (-not $T.Prompt -and $liveInfo) {
            $registryName = [string](Get-Field $liveInfo 'name' '')
            if ($registryName) { $name = $registryName }
        }
        if (-not $T.Cwd -and $liveInfo) { $T.Cwd = [string](Get-Field $liveInfo 'cwd' '') }

        $agent = $T.Agent
        if (-not $agent) { $agent = 'claude' }

        $rootNode = New-ClaudeNode -Id $sid -ParentId '' -T $T -State $rootState -Name $name -Agent $agent -Task '' -Now $now
        $rootNode.directoryPath = $T.Cwd
        $nodes[$sid] = $rootNode
        [void]$order.Add($rootNode)

        $sessionToday = $T.TodaySteps
        foreach ($key in @($todayTokens.Keys)) { $todayTokens[$key] += $T.Today[$key] }
        $todaySteps += $T.TodaySteps

        # Subagents: parse all of them (for tokens), show the live ones plus the latest few.
        $subs = @(Get-ClaudeSubagents -Folder $root.Folder -SessionId $sid)
        $subStates = New-Object System.Collections.ArrayList
        $cutoff = $now - [long]$ClaudeHours * 3600 * 1000

        foreach ($sub in $subs) {
            if ($sub.Mtime -lt $cutoff -and $sub.Mtime -lt $dayStart) { continue }
            $ST = Sync-ClaudeTranscript -Path $sub.Path -DayStart $dayStart
            foreach ($key in @($todayTokens.Keys)) { $todayTokens[$key] += $ST.Today[$key] }
            $todaySteps += $ST.TodaySteps
            $sessionToday += $ST.TodaySteps

            $finished = Get-Field $sub.Meta 'finished'
            $rootAlive = ($null -ne $liveInfo) -or $rootState -eq 'running'
            $state = 'idle'
            if ($finished -eq $true) {
                if ($ST.Interrupted) { $state = 'interrupted' }
            }
            elseif ($null -eq $finished) {
                # Older clients write no "finished" flag: judge by recent activity.
                if ($rootAlive -and $ST.TurnOpen -and ($now - $sub.Mtime) -lt 120000) { $state = 'running' }
                elseif ($ST.Interrupted) { $state = 'interrupted' }
            }
            elseif ($rootAlive) { $state = 'running' }
            else { $state = 'interrupted' }

            [void]$subStates.Add(@{ Sub = $sub; T = $ST; State = $state })
        }

        $shown = @($subStates | Sort-Object -Property @{ Expression = { $_.State -eq 'running' }; Descending = $true }, @{ Expression = { $_.Sub.Mtime }; Descending = $true } |
            Select-Object -First ([Math]::Max($ClaudeSubagentLimit, @($subStates | Where-Object { $_.State -eq 'running' }).Count)))

        # Which transcript launched each subagent (subagents can launch their own).
        $owners = @{}
        foreach ($item in $shown) {
            foreach ($other in $shown) {
                if ($other -eq $item) { continue }
                $toolUseId = [string](Get-Field $item.Sub.Meta 'toolUseId' '')
                if ($toolUseId -and $other.T.AgentCalls.Contains($toolUseId)) { $owners[$item.Sub.AgentId] = 'agent-' + $other.Sub.AgentId }
            }
        }

        foreach ($item in $shown) {
            $meta = $item.Sub.Meta
            $description = Limit-Text ([string](Get-Field $meta 'description' '')) 80
            $agentType = [string](Get-Field $meta 'agentType' 'subagent')
            $id = 'agent-' + $item.Sub.AgentId
            $parentId = $sid
            if ($owners.ContainsKey($item.Sub.AgentId)) { $parentId = $owners[$item.Sub.AgentId] }

            $subName = $description
            if (-not $subName) { $subName = Get-SessionName -SessionId $id -Prompt $item.T.Prompt }
            if ($subName.Length -gt 28) { $subName = $subName.Substring(0, 25).TrimEnd() + '...' }

            $node = New-ClaudeNode -Id $id -ParentId $parentId -T $item.T -State $item.State -Name $subName -Agent $agentType -Task $description -Now $now
            $nodes[$id] = $node
            [void]$order.Add($node)

            if ($item.State -eq 'running') {
                $item.Delegation = @{
                    childId     = $id
                    agent       = $agentType
                    description = $description
                    startedAt   = $item.T.Created
                }
                $item.ParentId = $parentId
            }
        }

        foreach ($item in $shown) {
            if ($item.ContainsKey('Delegation') -and $nodes.ContainsKey($item.ParentId)) {
                [void]$nodes[$item.ParentId].delegations.Add($item.Delegation)
            }
        }

        if ($sessionToday -gt 0) { $todaySessions++ }
    }

    # Build the trees and group the roots by directory.
    $directories = @{}
    foreach ($node in $order) {
        if ($node.tokens.total -gt $maxTokens) { $maxTokens = $node.tokens.total }
        if ($node.parentId -and $nodes.ContainsKey($node.parentId)) {
            [void]$nodes[$node.parentId].children.Add($node)
            continue
        }

        $path = [string]$node.directoryPath
        $key = Get-DirectoryKey $path
        if (-not $directories.ContainsKey($key)) {
            $label = '(unknown)'
            if (-not [string]::IsNullOrWhiteSpace($path)) { $label = Split-Path -Leaf $path }
            $directories[$key] = @{
                id = $key; path = $path; label = $label
                sessionCount = 0; runningCount = 0; waitingCount = 0
                sessions = (New-Object System.Collections.ArrayList)
            }
        }
        [void]$directories[$key].sessions.Add($node)
    }
    foreach ($node in $order) { if ($node.ContainsKey('directoryPath')) { $node.Remove('directoryPath') } }

    function Measure-ClaudeTree {
        param($Node, [int]$Depth, $Directory)
        $Node.depth = $Depth
        $Directory.sessionCount++
        if ($Node.state -eq 'running') { $Directory.runningCount++ }
        if ($Node.state -eq 'waiting') { $Directory.waitingCount++ }
        foreach ($child in $Node.children) { Measure-ClaudeTree -Node $child -Depth ($Depth + 1) -Directory $Directory }
    }

    $directoryList = New-Object System.Collections.ArrayList
    foreach ($directory in $directories.Values) {
        foreach ($session in $directory.sessions) { Measure-ClaudeTree -Node $session -Depth 0 -Directory $directory }
        $directory.sessions = Sort-SessionJson -Sessions $directory.sessions
        [void]$directoryList.Add($directory)
    }

    # Forget files and clocks that dropped out of view.
    foreach ($path in @($script:CC.Files.Keys)) {
        if ($script:CC.Files[$path].Used -lt $script:CC.Tick - 30) { $script:CC.Files.Remove($path) }
    }
    foreach ($id in @($script:CC.Since.Keys)) {
        if (($now - [long]$script:CC.Since[$id].seen) -gt 600000) { $script:CC.Since.Remove($id) }
    }

    $result = @{
        directories = $directoryList
        maxTokens   = $maxTokens
        live        = $live.Count
        today       = @{
            date      = $dayKey
            tokens    = $todayTokens
            steps     = $todaySteps
            sessions  = $todaySessions
            updatedAt = $now
        }
    }
    $script:CC.LastResult = $result
    return $result
}
