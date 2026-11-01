#Requires -Version 5.1
<#
.SYNOPSIS
    Live bubble dashboard for OpenCode sessions.

.DESCRIPTION
    Polls the local OpenCode background service once per second, writes
    sessions.json, serves a static D3 page from a loopback HTTP server, and
    opens that page in the browser.

    The HTTP server lives inside this PowerShell process. When the script stops
    (Ctrl+C or closing the window), the listener is closed with it.

    Data sources, all verified against OpenCode 2.1.3:
      GET /api/session                  all sessions, including parentID
      GET /api/session/active           sessions currently executing
      GET /api/session/{id}/message     last assistant message (running tool)
      GET /api/permission/request       sessions waiting for approval
      GET /api/experimental/session/stats   today's token totals

    Session names are taken from the first user prompt (fetched via the API).

    Token totals are refreshed every 10 seconds; the graph itself every second.

.PARAMETER IntervalMs
    Snapshot cadence in milliseconds. Default 1000.

.PARAMETER TokenIntervalMs
    How often daily token totals are refreshed. Default 10000.

.PARAMETER Limit
    Maximum number of sessions to read. Default 200.

.PARAMETER Port
    First loopback port to try. Default 8787. If busy, the next ports are tried.

.PARAMETER NoBrowser
    Do not open the dashboard in the default browser.

.PARAMETER Once
    Collect one snapshot, write sessions.json, and exit. No server.

.EXAMPLE
    .\Watch-OpencodeSessions.ps1

.EXAMPLE
    .\Watch-OpencodeSessions.ps1 -IntervalMs 2000 -NoBrowser
#>

[CmdletBinding()]
param(
    [ValidateRange(250, 60000)]
    [int]$IntervalMs = 1000,

    [ValidateRange(1000, 600000)]
    [int]$TokenIntervalMs = 10000,

    [ValidateRange(1, 200)]
    [int]$Limit = 200,

    [ValidateRange(1, 65535)]
    [int]$Port = 8787,

    [switch]$NoBrowser,

    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Net.Http

# ------------------------------------------------------------- constants ----
$script:Root         = $PSScriptRoot
$script:DataPath     = Join-Path $script:Root 'sessions.json'
$script:StatePath    = Join-Path $script:Root '.monitor-state.json'
$script:IndexPath    = Join-Path $script:Root 'index.html'
$script:SmileyPath   = Join-Path $script:Root 'smiley-prototype.html'
$script:ServicePath  = Join-Path $env:USERPROFILE '.local\state\opencode\service.json'
$script:Utf8         = New-Object System.Text.UTF8Encoding($false)
$script:StartedAt    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:Tick         = 0
$script:LastSlow     = 0
$script:LastSnapshot = $null
$script:LastError    = $null
$script:Service      = $null
$script:AuthToken    = ''
$script:Server       = $null
$script:LastStats    = 0

$script:Today = @{
    date      = (Get-Date).ToString('yyyy-MM-dd')
    tokens    = @{ input = 0; output = 0; reasoning = 0; cacheRead = 0; cacheWrite = 0 }
    cost      = 0
    steps     = 0
    sessions  = 0
    prompts   = 0
    updatedAt = 0
}

$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(4)

# --------------------------------------------------------------- helpers ----

function Get-Field {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function ConvertTo-Hashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $result[$p.Name] = ConvertTo-Hashtable $p.Value
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) { $items += ,(ConvertTo-Hashtable $item) }
        return ,$items
    }

    return $InputObject
}

function Write-Utf8File {
    param([string]$Path, [string]$Text)

    $temp = "$Path.tmp"
    [System.IO.File]::WriteAllText($temp, $Text, $script:Utf8)

    for ($i = 0; $i -lt 5; $i++) {
        try {
            Move-Item -LiteralPath $temp -Destination $Path -Force
            return
        }
        catch {
            Start-Sleep -Milliseconds 20
        }
    }

    throw "Could not replace $Path (still locked)."
}

function Write-Log {
    param([string]$Message, [string]$Level = 'info')

    $color = switch ($Level) {
        'warn'  { 'Yellow' }
        'error' { 'Red' }
        'ok'    { 'Green' }
        default { 'DarkGray' }
    }

    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $color
}

# ------------------------------------------------------------ opencode I/O --

function Connect-Service {
    if (-not (Test-Path -LiteralPath $script:ServicePath)) {
        throw "OpenCode service file not found: $script:ServicePath"
    }

    $raw = Get-Content -LiteralPath $script:ServicePath -Raw -Encoding UTF8
    $info = $raw | ConvertFrom-Json

    $url = [string](Get-Field $info 'url' '')
    $password = [string](Get-Field $info 'password' '')

    if ([string]::IsNullOrWhiteSpace($url)) { throw 'OpenCode service file has no url.' }
    if ([string]::IsNullOrWhiteSpace($password)) { throw 'OpenCode service file has no password.' }

    $script:Service = @{
        Url       = $url.TrimEnd('/')
        Password  = $password
        Version   = [string](Get-Field $info 'version' '')
        ServerPid = [int](Get-Field $info 'pid' 0)
    }

    $script:AuthToken = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes("opencode:$password")
    )
}

function Wait-Task {
    param($Task, [int]$SliceMs = 25)

    # While a slow HTTP call is in flight, keep the dashboard server responsive.
    while (-not $Task.IsCompleted) {
        if ($script:Server) { Receive-Request -Server $script:Server }
        try { [void]$Task.Wait($SliceMs) } catch { break }
    }

    return $Task.GetAwaiter().GetResult()
}

function Invoke-Api {
    param([string]$Path)

    $request = New-Object System.Net.Http.HttpRequestMessage(
        [System.Net.Http.HttpMethod]::Get,
        ($script:Service.Url + $Path)
    )

    try {
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
            'Basic',
            $script:AuthToken
        )
        [void]$request.Headers.Accept.ParseAdd('application/json')

        $response = Wait-Task ($script:Http.SendAsync($request))
    }
    finally {
        $request.Dispose()
    }

    try {
        $body = Wait-Task ($response.Content.ReadAsStringAsync())

        if (-not $response.IsSuccessStatusCode) {
            throw ("HTTP {0} for {1}" -f [int]$response.StatusCode, $Path)
        }

        if ([string]::IsNullOrWhiteSpace($body)) { return $null }
        return ($body | ConvertFrom-Json)
    }
    finally {
        $response.Dispose()
    }
}

function Invoke-ApiSafe {
    param([string]$Path)

    try {
        return Invoke-Api $Path
    }
    catch {
        # A timeout means the service is busy, not that its address changed.
        # Retrying immediately would only add another timeout to the same tick.
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [System.Threading.Tasks.TaskCanceledException] -or $inner -is [System.TimeoutException]) {
            throw
        }

        # Connection refused / 401: the service may have restarted with a new
        # port or password, so re-read service.json and try once more.
        Connect-Service
        return Invoke-Api $Path
    }
}

function Update-TodayStats {
    $nowLocal = Get-Date
    $dateKey = $nowLocal.ToString('yyyy-MM-dd')

    if ($script:Today.date -ne $dateKey) {
        $script:Today = @{
            date      = $dateKey
            tokens    = @{ input = 0; output = 0; reasoning = 0; cacheRead = 0; cacheWrite = 0 }
            cost      = 0
            steps     = 0
            sessions  = 0
            prompts   = 0
            updatedAt = 0
        }
    }

    $from = ([DateTimeOffset]::new($nowLocal.Date)).ToUnixTimeMilliseconds()
    $to = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $response = Invoke-ApiSafe ("/api/experimental/session/stats?from={0}&to={1}&tools=none" -f $from, $to)
    $stats = Get-Field $response 'data'

    if (-not $stats) { return }

    $tokens = Get-Field $stats 'tokens'
    $cache = Get-Field $tokens 'cache'

    $script:Today.tokens = @{
        input      = [long](Get-Field $tokens 'input' 0)
        output     = [long](Get-Field $tokens 'output' 0)
        reasoning  = [long](Get-Field $tokens 'reasoning' 0)
        cacheRead  = [long](Get-Field $cache 'read' 0)
        cacheWrite = [long](Get-Field $cache 'write' 0)
    }
    $script:Today.cost = [double](Get-Field $stats 'cost' 0)
    $script:Today.steps = [int](Get-Field $stats 'steps' 0)
    $script:Today.sessions = [int](Get-Field $stats 'sessions' 0)
    $script:Today.prompts = [int](Get-Field $stats 'prompts' 0)
    $script:Today.updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

# Non-ASCII characters are built from code points: this file has no BOM, and
# Windows PowerShell 5.1 would read literal ones in the source as ANSI.
$script:Ellipsis = [string][char]0x2026
$script:Arrow    = [string][char]0x2192

function Limit-Text {
    param([string]$Text, [int]$Max)

    $clean = ([string]$Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $Max) { return $clean }
    return $clean.Substring(0, $Max - 1).TrimEnd() + $script:Ellipsis
}

function Get-LeafName {
    param([string]$Path)

    $parts = @(([string]$Path) -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -eq 0) { return '' }
    return $parts[$parts.Count - 1]
}

function New-Detail {
    param([string]$Detail)

    return @{
        detail       = $Detail
        activity     = ''
        activityFull = ''
        delegations  = (New-Object System.Collections.ArrayList)
    }
}

function Get-ToolSummary {
    # One tool call -> a short line for the bubble and a longer one for the panel.
    # Only the call's input is used; tool output never leaves the service.
    param($Part)

    $name  = [string](Get-Field $Part 'name' 'tool')
    $toolInput = Get-Field (Get-Field $Part 'state') 'input'

    if ($name -eq 'subagent') {
        $agent = [string](Get-Field $toolInput 'agent' 'agent')
        $description = [string](Get-Field $toolInput 'description' '')
        $prompt = [string](Get-Field $toolInput 'prompt' '')
        return @{
            short = Limit-Text ("{0} {1}: {2}" -f $script:Arrow, $agent, $description) 80
            full  = Limit-Text ("{0} {1}: {2} - {3}" -f $script:Arrow, $agent, $description, $prompt) 300
        }
    }

    $path = [string](Get-Field $toolInput 'path' (Get-Field $toolInput 'filePath' (Get-Field $toolInput 'file' '')))
    $command = [string](Get-Field $toolInput 'command' '')
    $pattern = [string](Get-Field $toolInput 'pattern' '')
    $url = [string](Get-Field $toolInput 'url' '')
    $query = [string](Get-Field $toolInput 'query' '')
    $description = [string](Get-Field $toolInput 'description' '')

    $short = ''
    $full = ''

    if ($command) {
        $short = $command
        $full = $command
    }
    elseif ($pattern) {
        $short = '"' + $pattern + '"'
        $full = $short
        if ($path) { $short += ' in ' + (Get-LeafName $path); $full += ' in ' + $path }
    }
    elseif ($path) {
        $short = Get-LeafName $path
        $full = $path
        $offset = [long](Get-Field $toolInput 'offset' 0)
        $lineCount = [long](Get-Field $toolInput 'limit' 0)
        if ($offset -gt 0 -and $lineCount -gt 0) {
            $range = ' (lines {0}-{1})' -f $offset, ($offset + $lineCount - 1)
            $short += $range
            $full += $range
        }
    }
    elseif ($url) { $short = $url; $full = $url }
    elseif ($query) { $short = '"' + $query + '"'; $full = $short }
    elseif ($description) { $short = $description; $full = $description }
    elseif ($toolInput) {
        foreach ($prop in $toolInput.PSObject.Properties) {
            if ($prop.Value -is [string] -and $prop.Value) { $short = $prop.Value; $full = $prop.Value; break }
        }
    }

    if ($description -and $command) { $full = $description + ': ' + $command }

    return @{
        short = Limit-Text $short 80
        full  = Limit-Text $full 300
    }
}

function Get-MessageDetail {
    param($Message)

    if (-not $Message) { return (New-Detail 'starting') }
    if (Get-Field $Message 'retry') { return (New-Detail 'retrying') }

    $result = New-Detail 'working'
    $running = New-Object System.Collections.ArrayList

    foreach ($part in @(Get-Field $Message 'content' @())) {
        if ((Get-Field $part 'type') -ne 'tool') { continue }

        $state = Get-Field $part 'state'
        if ((Get-Field $state 'status') -ne 'running') { continue }

        [void]$running.Add($part)

        if ((Get-Field $part 'name') -eq 'subagent') {
            $toolInput = Get-Field $state 'input'
            $time = Get-Field $part 'time'
            [void]$result.delegations.Add(@{
                childId     = [string](Get-Field (Get-Field $state 'metadata') 'sessionID' '')
                agent       = [string](Get-Field $toolInput 'agent' '')
                description = Limit-Text ([string](Get-Field $toolInput 'description' '')) 80
                startedAt   = [long](Get-Field $time 'ran' (Get-Field $time 'created' 0))
            })
        }
    }

    if ($running.Count -gt 0) {
        $first = $running[0]
        $summary = Get-ToolSummary $first
        $result.detail = [string](Get-Field $first 'name' 'tool')
        $result.activity = $summary.short
        $result.activityFull = $summary.full
        if ($running.Count -gt 1) {
            $result.activity += (' (+{0} more)' -f ($running.Count - 1))
        }
        return $result
    }

    $completed = Get-Field (Get-Field $Message 'time') 'completed'
    if (-not $completed) { $result.detail = 'thinking' }

    return $result
}

function Get-FirstPrompt {
    param([string]$SessionId)

    try {
        $response = Invoke-ApiSafe ("/api/session/{0}/message?limit=1&order=asc&type=user" -f $SessionId)
        $message = @(Get-Field $response 'data' @())[0]
        if (-not $message) { return '' }

        $text = [string](Get-Field $message 'text' '')
        $text = ($text -replace '\s+', ' ').Trim()
        if ($text.Length -gt 160) { $text = $text.Substring(0, 157) + '...' }
        return $text
    }
    catch {
        return ''
    }
}

function Get-DirectoryKey {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '(unknown)' }
    return (($Path -replace '/', '\').TrimEnd('\')).ToLowerInvariant()
}

function Get-ShortId {
    param([string]$SessionId)

    if ($SessionId.Length -gt 12) { return $SessionId.Substring(4, 8) }
    return $SessionId
}

function Get-SessionName {
    param([string]$SessionId, [string]$Prompt)

    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        if ($Prompt.Length -gt 28) { return $Prompt.Substring(0, 25).TrimEnd() + '...' }
        return $Prompt
    }

    return ('Session ' + (Get-ShortId $SessionId))
}

# ------------------------------------------------------------ snapshot -----

function Load-State {
    $state = @{ version = 1; sessions = @{} }

    if (-not (Test-Path -LiteralPath $script:StatePath)) { return $state }

    try {
        $loaded = ConvertTo-Hashtable (Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
        if ($loaded -is [System.Collections.IDictionary] -and $loaded.Contains('sessions')) {
            $state.sessions = $loaded.sessions
        }
    }
    catch {
        Write-Log "State file unreadable, starting fresh: $($_.Exception.Message)" 'warn'
    }

    return $state
}

function Save-State {
    param($State)

    $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - (24 * 60 * 60 * 1000)
    $pruned = @{}

    foreach ($id in $State.sessions.Keys) {
        $entry = $State.sessions[$id]
        if ([long](Get-Field $entry 'lastSeen' 0) -ge $cutoff) {
            $pruned[$id] = $entry
        }
    }

    $State.sessions = $pruned
    Write-Utf8File -Path $script:StatePath -Text (($State | ConvertTo-Json -Depth 8 -Compress))
}

function Sort-SessionJson {
    param($Sessions)

    $ordered = @($Sessions | Sort-Object -Property stateRank, @{ Expression = { $_.updatedAt }; Descending = $true })
    $result = New-Object System.Collections.ArrayList

    foreach ($item in $ordered) {
        [void]$item.Remove('stateRank')
        $item.children = Sort-SessionJson -Sessions $item.children
        [void]$result.Add($item)
    }

    # Return the ArrayList as one object so an empty list stays [] in JSON
    # instead of collapsing to nothing or being wrapped as [[]].
    return ,$result
}

function Get-StateRank {
    param([string]$StateName)

    switch ($StateName) {
        'waiting'     { return 0 }
        'running'     { return 1 }
        'failed'      { return 2 }
        'interrupted' { return 3 }
        'idle'        { return 4 }
        default       { return 5 }
    }
}

function Get-StaleSnapshot {
    param([string]$ErrorText, [long]$Now)

    if (-not $script:LastSnapshot) {
        return @{
            schemaVersion   = 1
            generatedAt     = $Now
            generatedAtIso  = [DateTimeOffset]::FromUnixTimeMilliseconds($Now).ToString('o')
            tick            = $script:Tick
            intervalMs      = $IntervalMs
            monitor         = @{ pid = $PID; startedAt = $script:StartedAt; stale = $true; error = $ErrorText; slowUpdatedAt = $script:LastSlow }
            server          = @{ url = ''; version = ''; pid = 0; healthy = $false; latencyMs = 0 }
            totals          = @{ directories = 0; sessions = 0; subagents = 0; running = 0; waiting = 0; idle = 0; failed = 0 }
            today           = $script:Today
            maxSessionTokens = 0
            directories     = @()
        }
    }

    $snapshot = $script:LastSnapshot.Clone()
    $snapshot.generatedAt = $Now
    $snapshot.generatedAtIso = [DateTimeOffset]::FromUnixTimeMilliseconds($Now).ToString('o')
    $snapshot.tick = $script:Tick
    $snapshot.monitor = @{ pid = $PID; startedAt = $script:StartedAt; stale = $true; error = $ErrorText; slowUpdatedAt = $script:LastSlow }
    $serverUrl = ''
    $serverVersion = ''
    $serverPid = 0
    if ($script:Service) {
        $serverUrl = $script:Service.Url
        $serverVersion = $script:Service.Version
        $serverPid = $script:Service.ServerPid
    }
    $snapshot.server = @{ url = $serverUrl; version = $serverVersion; pid = $serverPid; healthy = $false; latencyMs = 0 }
    $snapshot.today = $script:Today
    return $snapshot
}

function Update-Snapshot {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $latency = [System.Diagnostics.Stopwatch]::StartNew()
    $sessionResponse = Invoke-ApiSafe ("/api/session?limit={0}&order=desc" -f $Limit)
    $sessions = @(Get-Field $sessionResponse 'data' @())
    $latency.Stop()

    $activeMap = @{}
    $active = Get-Field (Invoke-ApiSafe '/api/session/active') 'data'
    if ($active) {
        foreach ($prop in $active.PSObject.Properties) { $activeMap[$prop.Name] = $true }
    }

    $waitingMap = @{}
    $permissions = Get-Field (Invoke-ApiSafe '/api/permission/request') 'data'
    foreach ($permission in @($permissions)) {
        $sid = [string](Get-Field $permission 'sessionID' '')
        if ([string]::IsNullOrWhiteSpace($sid)) { continue }
        $waitingMap[$sid] = [string](Get-Field $permission 'action' 'approval')
    }

    # Running detail (which tool) for active sessions only.
    $detailMap = @{}
    foreach ($id in $activeMap.Keys) {
        try {
            $messageResponse = Invoke-ApiSafe ("/api/session/{0}/message?limit=1&order=desc&type=assistant" -f $id)
            $lastMessage = @(Get-Field $messageResponse 'data' @())[0]
            $detailMap[$id] = Get-MessageDetail -Message $lastMessage
        }
        catch {
            $detailMap[$id] = New-Detail 'working'
        }
    }

    # Which child session was handed which task, from the parents' running subagent calls.
    $assignMap = @{}
    foreach ($detail in $detailMap.Values) {
        foreach ($delegation in $detail.delegations) {
            if ($delegation.childId) { $assignMap[$delegation.childId] = $delegation.description }
        }
    }

    $state = Load-State
    $nodes = @{}
    $maxTokens = [long]0
    $promptFetches = 0

    foreach ($session in $sessions) {
        $id = [string](Get-Field $session 'id' '')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $parentId = [string](Get-Field $session 'parentID' '')
        $time = Get-Field $session 'time'
        $archived = Get-Field $time 'archived'
        if ($archived) { continue }   # "current sessions" only

        $createdAt = [long](Get-Field $time 'created' 0)
        $updatedAt = [long](Get-Field $time 'updated' 0)
        $idleAt = [long](Get-Field $time 'idle' 0)
        $outcome = [string](Get-Field $session 'outcome' '')

        $entry = $null
        if ($state.sessions.ContainsKey($id)) { $entry = $state.sessions[$id] }
        $isNew = ($null -eq $entry)

        if ($isNew) {
            $entry = @{
                state         = $null
                since         = $now
                firstSeen     = $now
                lastSeen      = $now
                prompt        = ''
                promptAttempt = 0
                task          = ''
            }
            $state.sessions[$id] = $entry
        }

        $previousState = [string](Get-Field $entry 'state' '')
        $lastSeen = [long](Get-Field $entry 'lastSeen' 0)

        # If the monitor was stopped (or blocked) for a while, its "running since"
        # observation is no longer trustworthy. Start the clock again.
        if ($lastSeen -gt 0 -and ($now - $lastSeen) -gt 10000 -and $previousState -eq 'running') {
            $entry.since = $now
        }

        $stateName = 'idle'
        $stateDetail = $null

        if ($waitingMap.ContainsKey($id)) {
            $stateName = 'waiting'
            $stateDetail = $waitingMap[$id]
        }
        elseif ($activeMap.ContainsKey($id)) {
            $stateName = 'running'
            $stateDetail = $detailMap[$id].detail
        }
        elseif ($outcome -eq 'failed') {
            $stateName = 'failed'
        }
        elseif ($outcome -eq 'interrupted') {
            $stateName = 'interrupted'
        }
        elseif ($idleAt -gt 0) {
            $stateName = 'idle'
        }
        elseif (-not $activeMap.ContainsKey($id) -and $createdAt -eq $updatedAt) {
            $stateName = 'new'
        }

        if ($previousState -ne $stateName) {
            $entry.state = $stateName
            $entry.since = $now
        }

        $entry.lastSeen = $now

        $detail = $null
        if ($detailMap.ContainsKey($id)) { $detail = $detailMap[$id] }
        else { $detail = New-Detail '' }

        # Remember the task this session was handed, so it stays visible after the handoff ends.
        if ($assignMap.ContainsKey($id)) { $entry.task = $assignMap[$id] }
        $taskText = [string](Get-Field $entry 'task' '')

        # Fetch the first user prompt once per session, and retry when it starts running.
        $wantsPrompt = ($isNew -or ($stateName -eq 'running' -and $previousState -ne 'running'))
        if ($wantsPrompt -and [string]::IsNullOrEmpty([string](Get-Field $entry 'prompt' '')) -and $promptFetches -lt 5) {
            $prompt = Get-FirstPrompt -SessionId $id
            $promptFetches++
            if (-not [string]::IsNullOrWhiteSpace($prompt)) { $entry.prompt = $prompt }
        }

        $promptText = [string](Get-Field $entry 'prompt' '')

        $tokens = Get-Field $session 'tokens'
        $cache = Get-Field $tokens 'cache'
        $tokenInput = [long](Get-Field $tokens 'input' 0)
        $tokenOutput = [long](Get-Field $tokens 'output' 0)
        $tokenReasoning = [long](Get-Field $tokens 'reasoning' 0)
        $tokenCacheRead = [long](Get-Field $cache 'read' 0)
        $tokenCacheWrite = [long](Get-Field $cache 'write' 0)
        $tokenTotal = $tokenInput + $tokenOutput + $tokenReasoning
        if ($tokenTotal -gt $maxTokens) { $maxTokens = $tokenTotal }

        $model = Get-Field $session 'model'
        $modelText = ''
        if ($model) {
            $modelText = ('{0}/{1}' -f (Get-Field $model 'providerID' ''), (Get-Field $model 'id' ''))
        }

        $location = Get-Field $session 'location'
        $directoryPath = [string](Get-Field $location 'directory' '')

        $nodes[$id] = @{
            id            = $id
            parentId      = $parentId
            raw           = $session
            directoryPath = $directoryPath
            directoryKey  = Get-DirectoryKey $directoryPath
            state         = $stateName
            stateDetail   = $stateDetail
            stateSince    = [long](Get-Field $entry 'since' $now)
            createdAt     = $createdAt
            updatedAt     = $updatedAt
            idleAt        = $idleAt
            outcome       = $outcome
            name          = Get-SessionName -SessionId $id -Prompt $promptText
            slug          = ''
            title         = ''
            prompt        = $promptText
            task          = $taskText
            activity      = $detail.activity
            activityFull  = $detail.activityFull
            delegations   = $detail.delegations
            agent         = [string](Get-Field $session 'agent' '')
            model         = $modelText
            cost          = [double](Get-Field $session 'cost' 0)
            tokens        = @{
                input      = $tokenInput
                output     = $tokenOutput
                reasoning  = $tokenReasoning
                cacheRead  = $tokenCacheRead
                cacheWrite = $tokenCacheWrite
                total      = $tokenTotal
            }
            children      = New-Object System.Collections.ArrayList
        }
    }

    # Link children to parents; orphans become roots.
    $roots = New-Object System.Collections.ArrayList
    foreach ($node in $nodes.Values) {
        if ($node.parentId -and $nodes.ContainsKey($node.parentId)) {
            [void]$nodes[$node.parentId].children.Add($node)
        }
        else {
            [void]$roots.Add($node)
        }
    }

    $directoryMap = @{}

    function Convert-SessionNode {
        param($Node, [int]$Depth)

        $childJson = New-Object System.Collections.ArrayList
        $subTotal = 1
        $subRunning = 0
        $subWaiting = 0

        foreach ($child in @($Node.children)) {
            $converted = Convert-SessionNode -Node $child -Depth ($Depth + 1)
            [void]$childJson.Add($converted.Json)
            $subTotal += $converted.Total
            $subRunning += $converted.Running
            $subWaiting += $converted.Waiting
        }

        if ($Node.state -eq 'running') { $subRunning++ }
        if ($Node.state -eq 'waiting') { $subWaiting++ }

        $json = @{
            id            = $Node.id
            shortId       = (Get-ShortId $Node.id)
            parentId      = $(if ([string]::IsNullOrWhiteSpace($Node.parentId)) { $null } else { $Node.parentId })
            depth         = $Depth
            name          = $Node.name
            slug          = $Node.slug
            title         = $Node.title
            prompt        = $Node.prompt
            task          = $Node.task
            activity      = $Node.activity
            activityFull  = $Node.activityFull
            delegations   = $Node.delegations
            agent         = $Node.agent
            model         = $Node.model
            state         = $Node.state
            stateDetail   = $Node.stateDetail
            stateSince    = $Node.stateSince
            runningSince  = $(if ($Node.state -eq 'running') { $Node.stateSince } else { $null })
            createdAt     = $Node.createdAt
            updatedAt     = $Node.updatedAt
            idleAt        = $(if ($Node.idleAt -gt 0) { $Node.idleAt } else { $null })
            outcome       = $(if ([string]::IsNullOrWhiteSpace($Node.outcome)) { $null } else { $Node.outcome })
            cost          = $Node.cost
            tokens        = $Node.tokens
            stateRank     = (Get-StateRank $Node.state)
            children      = $childJson
        }

        return @{ Json = $json; Total = $subTotal; Running = $subRunning; Waiting = $subWaiting }
    }

    $directoriesJson = @()
    $totalRunning = 0
    $totalWaiting = 0

    foreach ($root in $roots) {
        $key = $root.directoryKey
        if (-not $directoryMap.ContainsKey($key)) {
            $directoryMap[$key] = @{
                id         = $key
                path       = $root.directoryPath
                label      = $(if ([string]::IsNullOrWhiteSpace($root.directoryPath)) { '(unknown)' } else { Split-Path -Leaf $root.directoryPath })
                sessions   = New-Object System.Collections.ArrayList
                sessionCount = 0
                runningCount = 0
                waitingCount = 0
            }
        }
        [void]$directoryMap[$key].sessions.Add($root)
    }

    foreach ($key in $directoryMap.Keys) {
        $directory = $directoryMap[$key]
        $sessionJson = New-Object System.Collections.ArrayList
        $count = 0
        $running = 0
        $waiting = 0

        foreach ($root in $directory.sessions) {
            $converted = Convert-SessionNode -Node $root -Depth 0
            [void]$sessionJson.Add($converted.Json)
            $count += $converted.Total
            $running += $converted.Running
            $waiting += $converted.Waiting
        }

        $sessionJson = Sort-SessionJson -Sessions $sessionJson

        $totalRunning += $running
        $totalWaiting += $waiting

        $directoriesJson += @{
            id           = $directory.id
            path         = $directory.path
            label        = $(if ([string]::IsNullOrWhiteSpace($directory.label)) { $directory.path } else { $directory.label })
            sessionCount = $count
            runningCount = $running
            waitingCount = $waiting
            sessions     = $sessionJson
        }
    }

    $directoriesJson = @($directoriesJson | Sort-Object -Property label)

    $rootCount = $roots.Count
    $allCount = $nodes.Count
    $failedCount = @($nodes.Values | Where-Object { $_.state -eq 'failed' }).Count

    $snapshot = @{
        schemaVersion    = 1
        generatedAt      = $now
        generatedAtIso   = [DateTimeOffset]::FromUnixTimeMilliseconds($now).ToString('o')
        tick             = $script:Tick
        intervalMs       = $IntervalMs
        monitor          = @{ pid = $PID; startedAt = $script:StartedAt; stale = $false; error = $null; slowUpdatedAt = $script:LastSlow }
        server           = @{ url = $script:Service.Url; version = $script:Service.Version; pid = $script:Service.ServerPid; healthy = $true; latencyMs = [int]$latency.ElapsedMilliseconds }
        totals           = @{
            directories = $directoriesJson.Count
            sessions    = $rootCount
            subagents   = ($allCount - $rootCount)
            running     = $totalRunning
            waiting     = $totalWaiting
            idle        = ($allCount - $totalRunning - $totalWaiting - $failedCount)
            failed      = $failedCount
        }
        today            = $script:Today
        maxSessionTokens = $maxTokens
        directories      = $directoriesJson
    }

    $script:LastSnapshot = $snapshot
    $script:LastError = $null
    Save-State -State $state

    return $snapshot
}

function Publish-Snapshot {
    param($Snapshot)

    $json = $Snapshot | ConvertTo-Json -Depth 20 -Compress
    Write-Utf8File -Path $script:DataPath -Text $json

    if ($script:Tick -eq 1 -or ($script:Tick % 10) -eq 0) {
        $todayTokens = $Snapshot.today.tokens
        $todayTotal = [long]$todayTokens.input + [long]$todayTokens.output + [long]$todayTokens.reasoning

        Write-Log ("{0} dirs | {1} sessions | {2} running | {3} waiting | today {4:N0} tok" -f `
            $Snapshot.totals.directories, $Snapshot.totals.sessions, $Snapshot.totals.running, `
            $Snapshot.totals.waiting, $todayTotal)
    }
}

# ----------------------------------------------------------- http server ----

function Start-MonitorServer {
    param([int]$FirstPort)

    for ($candidate = $FirstPort; $candidate -lt $FirstPort + 20; $candidate++) {
        $listener = $null
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://localhost:$candidate/")
            $listener.Start()

            return @{
                Listener = $listener
                Port     = $candidate
                Task     = $listener.GetContextAsync()
            }
        }
        catch {
            if ($listener) {
                try { $listener.Close() } catch { }
            }
        }
    }

    throw "No free loopback port between $FirstPort and $($FirstPort + 19)."
}

function Send-Bytes {
    param($Context, [int]$Status, [string]$ContentType, [byte[]]$Bytes)

    $response = $Context.Response
    $response.StatusCode = $Status
    $response.ContentType = $ContentType
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'

    if ($Bytes -and $Bytes.Length -gt 0) {
        $response.ContentLength64 = $Bytes.Length
        $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    }
    else {
        $response.ContentLength64 = 0
    }

    $response.OutputStream.Close()
}

function Receive-Request {
    param($Server)

    $task = $Server.Task
    if (-not $task.IsCompleted) { return }

    try {
        $Server.Task = $Server.Listener.GetContextAsync()
        $context = $task.Result
    }
    catch {
        return
    }

    try {
        $path = $context.Request.Url.AbsolutePath

        switch ($path) {
            '/'              { $file = $script:IndexPath; $type = 'text/html; charset=utf-8' }
            '/index.html'    { $file = $script:IndexPath; $type = 'text/html; charset=utf-8' }
            '/smiley'        { $file = $script:SmileyPath; $type = 'text/html; charset=utf-8' }
            '/smiley-prototype.html' { $file = $script:SmileyPath; $type = 'text/html; charset=utf-8' }
            '/sessions.json' { $file = $script:DataPath;  $type = 'application/json; charset=utf-8' }
            '/favicon.ico'   { Send-Bytes -Context $context -Status 204 -ContentType 'image/x-icon' -Bytes @(); return }
            default          { Send-Bytes -Context $context -Status 404 -ContentType 'text/plain; charset=utf-8' -Bytes ([Text.Encoding]::UTF8.GetBytes('not found')); return }
        }

        if (-not (Test-Path -LiteralPath $file)) {
            Send-Bytes -Context $context -Status 404 -ContentType 'text/plain; charset=utf-8' -Bytes ([Text.Encoding]::UTF8.GetBytes("missing: $file"))
            return
        }

        $bytes = [System.IO.File]::ReadAllBytes($file)
        Send-Bytes -Context $context -Status 200 -ContentType $type -Bytes $bytes
    }
    catch {
        try {
            Send-Bytes -Context $context -Status 500 -ContentType 'text/plain; charset=utf-8' -Bytes ([Text.Encoding]::UTF8.GetBytes('server error'))
        }
        catch { }
    }
    finally {
        try { $context.Response.Close() } catch { }
    }
}

# ------------------------------------------------------------------ main ----

if (-not (Test-Path -LiteralPath $script:IndexPath)) {
    throw "index.html not found next to this script: $($script:IndexPath)"
}

try {
    Connect-Service
}
catch {
    Write-Log "OpenCode service not reachable yet: $($_.Exception.Message)" 'warn'
}

# Reuse the previous day's panel value so the first frame does not flash zero.
if (Test-Path -LiteralPath $script:DataPath) {
    try {
        $previousSnapshot = Get-Content -LiteralPath $script:DataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $previousToday = ConvertTo-Hashtable (Get-Field $previousSnapshot 'today')
        $todayKey = (Get-Date).ToString('yyyy-MM-dd')
        if ($previousToday -is [System.Collections.IDictionary] -and
            $previousToday.Contains('tokens') -and
            [string](Get-Field $previousToday 'date' '') -eq $todayKey) {
            $script:Today = $previousToday
        }
    }
    catch { }
}

if ($Once) {
    try { Update-TodayStats } catch { }
    $script:LastStats = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

Write-Log ("Watching sessions (interval {0} ms, tokens {1} ms, limit {2})" -f $IntervalMs, $TokenIntervalMs, $Limit) 'ok'

$server = $null

if (-not $Once) {
    try {
        $server = Start-MonitorServer -FirstPort $Port
        $script:Server = $server
        $url = "http://localhost:$($server.Port)/"
        Write-Log "Dashboard: $url" 'ok'

        if (-not $NoBrowser) {
            Start-Process $url | Out-Null
        }
    }
    catch {
        Write-Log "HTTP server failed: $($_.Exception.Message)" 'error'
        throw
    }
}

try {
    while ($true) {
        $script:Tick++
        $tickStart = Get-Date

        try {
            if (-not $script:Service) { Connect-Service }
            $snapshot = Update-Snapshot
            Publish-Snapshot -Snapshot $snapshot

            if (-not $Once) {
                # Slow lane, after the snapshot has been published. The next tick
                # picks up the new daily totals.
                $slowNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

                if (($slowNow - $script:LastStats) -ge $TokenIntervalMs) {
                    try { Update-TodayStats } catch { }
                    $script:LastStats = $slowNow
                    $script:LastSlow = $slowNow
                }
            }
        }
        catch {
            $script:LastError = $_.Exception.Message
            # Re-read service.json so a restarted service is picked up next tick.
            try { Connect-Service } catch { }
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $stale = Get-StaleSnapshot -ErrorText $script:LastError -Now $now

            try {
                Write-Utf8File -Path $script:DataPath -Text (($stale | ConvertTo-Json -Depth 20 -Compress))
            }
            catch { }

            if ($script:Tick % 10 -eq 1) {
                Write-Log "OpenCode unreachable: $($script:LastError)" 'warn'
            }
        }

        if ($Once) { break }

        $deadline = $tickStart.AddMilliseconds($IntervalMs)
        while ((Get-Date) -lt $deadline) {
            if ($server) { Receive-Request -Server $server }
            Start-Sleep -Milliseconds 25
        }
    }
}
finally {
    if ($server) {
        try { $server.Listener.Stop() } catch { }
        try { $server.Listener.Close() } catch { }
    }
    $script:Server = $null

    try { $script:Http.Dispose() } catch { }

    if (-not $Once) { Write-Log 'Monitor stopped.' 'ok' }
}
