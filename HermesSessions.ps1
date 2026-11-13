# Hermes Agent collector. Dot-sourced by Watch-OpencodeSessions.ps1, which
# provides Get-Field, Limit-Text, Get-ToolSummary, Get-SessionName,
# Get-DirectoryKey, Get-StateRank and Sort-SessionJson.
#
# Hermes keeps every session in one SQLite database (WAL mode):
#   native Windows   %LOCALAPPDATA%\hermes\state.db
#   Linux / WSL      ~/.hermes/state.db
#   HERMES_HOME overrides both; named profiles live in <home>\profiles\<name>\state.db
#
# Native databases are read through Windows' own SQLite (winsqlite3.dll), so
# nothing has to be installed. A database inside WSL is read by
# tools\hermes-query.py, run with WSL's python3 (Hermes itself needs Python).
# Both paths run the same read-only SQL and return the same rows.
#
# Written from the Hermes docs (schema version 31); columns that an older or
# newer database lacks are simply left out of the queries.

$script:HM = @{
    Targets     = $null    # databases found: @{ Kind = 'native' | 'wsl'; Path; Profile }
    LastFind    = [long]0
    LastPoll    = [long]0
    Columns     = @{}      # target key -> @{ sessions = set; messages = set }
    Since       = @{}      # node id -> @{ state; since; seen }
    LastResult  = $null
    Ready       = $false
}

$script:HermesQueryScript = Join-Path $script:Root 'tools\hermes-query.py'

if (-not ('AgentMonitor.Sqlite' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace AgentMonitor {
    public static class Sqlite {
        const string Lib = "winsqlite3.dll";
        const int SQLITE_ROW = 100, SQLITE_DONE = 101;
        const int OPEN_READONLY = 0x01, OPEN_READWRITE = 0x02, OPEN_CREATE = 0x04, OPEN_URI = 0x40;

        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] name, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close_v2(IntPtr db);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_double(IntPtr stmt, int i, double v);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_int64(IntPtr stmt, int i, long v);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_text(IntPtr stmt, int i, byte[] v, int n, IntPtr destructor);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_name(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_type(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern long sqlite3_column_int64(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern double sqlite3_column_double(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_bytes(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg(IntPtr db);

        static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

        static string Utf8(IntPtr p, int n) {
            if (p == IntPtr.Zero) return null;
            if (n < 0) { n = 0; while (Marshal.ReadByte(p, n) != 0) n++; }
            byte[] b = new byte[n];
            Marshal.Copy(p, b, 0, n);
            return Encoding.UTF8.GetString(b);
        }

        static string Error(IntPtr db) { return Utf8(sqlite3_errmsg(db), -1); }

        // Runs each statement with its own arguments and returns one row list per statement.
        public static List<List<Hashtable>> Run(string path, bool readOnly, string[] sql, object[][] args) {
            IntPtr db;
            int flags = readOnly ? OPEN_READONLY : (OPEN_READWRITE | OPEN_CREATE);
            int rc = sqlite3_open_v2(Z(path), out db, flags, IntPtr.Zero);
            if (rc != 0) {
                string message = db == IntPtr.Zero ? "open failed" : Error(db);
                if (db != IntPtr.Zero) sqlite3_close_v2(db);
                throw new Exception("sqlite open " + rc + ": " + message);
            }

            var results = new List<List<Hashtable>>();
            try {
                sqlite3_busy_timeout(db, 1500);
                for (int q = 0; q < sql.Length; q++) {
                    byte[] text = Encoding.UTF8.GetBytes(sql[q]);
                    IntPtr stmt;
                    rc = sqlite3_prepare_v2(db, text, text.Length, out stmt, IntPtr.Zero);
                    if (rc != 0) throw new Exception("sqlite prepare: " + Error(db));
                    var rows = new List<Hashtable>();
                    try {
                        object[] a = (args != null && q < args.Length) ? args[q] : null;
                        if (a != null) {
                            for (int i = 0; i < a.Length; i++) {
                                object v = a[i];
                                if (v is string) { byte[] b = Encoding.UTF8.GetBytes((string)v); sqlite3_bind_text(stmt, i + 1, b, b.Length, new IntPtr(-1)); }
                                else if (v is int || v is long) sqlite3_bind_int64(stmt, i + 1, Convert.ToInt64(v));
                                else if (v != null) sqlite3_bind_double(stmt, i + 1, Convert.ToDouble(v));
                            }
                        }
                        int cols = sqlite3_column_count(stmt);
                        while (true) {
                            rc = sqlite3_step(stmt);
                            if (rc == SQLITE_DONE) break;
                            if (rc != SQLITE_ROW) throw new Exception("sqlite step " + rc + ": " + Error(db));
                            var row = new Hashtable();
                            for (int c = 0; c < cols; c++) {
                                string name = Utf8(sqlite3_column_name(stmt, c), -1);
                                switch (sqlite3_column_type(stmt, c)) {
                                    case 1: row[name] = sqlite3_column_int64(stmt, c); break;
                                    case 2: row[name] = sqlite3_column_double(stmt, c); break;
                                    case 3: row[name] = Utf8(sqlite3_column_text(stmt, c), sqlite3_column_bytes(stmt, c)); break;
                                    default: row[name] = null; break;
                                }
                            }
                            rows.Add(row);
                        }
                    }
                    finally { sqlite3_finalize(stmt); }
                    results.Add(rows);
                }
            }
            finally { sqlite3_close_v2(db); }
            return results;
        }
    }
}
'@
}

function Get-HermesHomes {
    # Default Hermes homes on this machine, most specific first.
    $homes = New-Object System.Collections.ArrayList
    if ($env:HERMES_HOME) { [void]$homes.Add($env:HERMES_HOME) }
    if ($env:LOCALAPPDATA) { [void]$homes.Add((Join-Path $env:LOCALAPPDATA 'hermes')) }
    [void]$homes.Add((Join-Path $env:USERPROFILE '.hermes'))
    return $homes
}

function Find-HermesTargets {
    $targets = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($home_ in Get-HermesHomes) {
        $candidates = @(@{ Path = (Join-Path $home_ 'state.db'); Profile = '' })
        $profiles = Join-Path $home_ 'profiles'
        if (Test-Path -LiteralPath $profiles) {
            foreach ($dir in [IO.Directory]::GetDirectories($profiles)) {
                $candidates += @{ Path = (Join-Path $dir 'state.db'); Profile = (Split-Path -Leaf $dir) }
            }
        }
        foreach ($c in $candidates) {
            $key = $c.Path.ToLowerInvariant()
            if ($seen.ContainsKey($key) -or -not (Test-Path -LiteralPath $c.Path)) { continue }
            $seen[$key] = $true
            [void]$targets.Add(@{ Kind = 'native'; Path = $c.Path; Profile = $c.Profile; Key = $key })
        }
    }

    # WSL: ask the default distro whether it has a Hermes database. Only when
    # WSL is installed and the helper script is present.
    if ($HermesWsl -and (Test-Path -LiteralPath $script:HermesQueryScript)) {
        $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
        if (Test-Path -LiteralPath $wsl) {
            try {
                $out = Invoke-HermesWsl -Request @{ action = 'find' }
                foreach ($db in @(Get-Field $out 'databases' @())) {
                    $path = [string](Get-Field $db 'path' '')
                    if (-not $path) { continue }
                    [void]$targets.Add(@{ Kind = 'wsl'; Path = $path; Profile = [string](Get-Field $db 'profile' ''); Key = 'wsl:' + $path })
                }
            }
            catch { }
        }
    }

    return ,$targets
}

function Invoke-HermesWsl {
    param($Request)

    # C:\x\y -> /mnt/c/x/y (WSL's default automount).
    $full = [IO.Path]::GetFullPath($script:HermesQueryScript)
    $linux = '/mnt/' + $full.Substring(0, 1).ToLowerInvariant() + ($full.Substring(2) -replace '\\', '/')

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $psi.Arguments = '-e python3 "' + $linux + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $script:Utf8

    $process = [Diagnostics.Process]::Start($psi)
    try {
        $bytes = $script:Utf8.GetBytes(($Request | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(8000)) {
            try { $process.Kill() } catch { }
            throw 'WSL query timed out'
        }
        $text = $stdout.Result
        if ($process.ExitCode -ne 0) { throw ('WSL query failed: ' + (Limit-Text $stderr.Result 200)) }
        return ($text | ConvertFrom-Json)
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-HermesQueries {
    # Runs the statements against one database and returns one row list each.
    param($Target, [string[]]$Sql, [object[]]$Arguments)

    if ($Target.Kind -eq 'native') {
        $args_ = New-Object 'object[][]' $Sql.Length
        for ($i = 0; $i -lt $Sql.Length; $i++) { $args_[$i] = [object[]]$Arguments[$i] }
        return ,([AgentMonitor.Sqlite]::Run($Target.Path, $true, $Sql, $args_))
    }

    $queries = @()
    for ($i = 0; $i -lt $Sql.Length; $i++) { $queries += ,@{ sql = $Sql[$i]; args = @($Arguments[$i]) } }
    $out = Invoke-HermesWsl -Request @{ action = 'query'; db = $Target.Path; queries = $queries }
    $results = New-Object System.Collections.ArrayList
    foreach ($rows in @(Get-Field $out 'results' @())) { [void]$results.Add(@($rows)) }
    return ,$results
}

function Get-HermesColumns {
    param($Target)

    if ($script:HM.Columns.ContainsKey($Target.Key)) { return $script:HM.Columns[$Target.Key] }

    $rows = Invoke-HermesQueries -Target $Target -Sql @(
        "SELECT name FROM pragma_table_info('sessions')",
        "SELECT name FROM pragma_table_info('messages')"
    ) -Arguments @($null, $null)

    $columns = @{ sessions = @{}; messages = @{} }
    foreach ($r in @($rows[0])) { $columns.sessions[[string](Get-Field $r 'name')] = $true }
    foreach ($r in @($rows[1])) { $columns.messages[[string](Get-Field $r 'name')] = $true }
    if ($columns.sessions.Count -eq 0) { throw "no sessions table in $($Target.Path)" }

    $script:HM.Columns[$Target.Key] = $columns
    return $columns
}

function Get-HermesSql {
    param($Columns)

    $want = @('id', 'source', 'model', 'model_config', 'parent_session_id', 'started_at', 'ended_at', 'end_reason',
        'title', 'cwd', 'display_name', 'input_tokens', 'output_tokens', 'reasoning_tokens', 'cache_read_tokens',
        'cache_write_tokens', 'estimated_cost_usd', 'actual_cost_usd', 'api_call_count', 'archived', 'profile_name')
    $sessionCols = @($want | Where-Object { $Columns.sessions.ContainsKey($_) } | ForEach-Object { 's.' + $_ })

    $msgWant = @('session_id', 'role', 'tool_calls', 'tool_name', 'finish_reason', 'timestamp')
    $msgCols = @($msgWant | Where-Object { $Columns.messages.ContainsKey($_) } | ForEach-Object { 'm.' + $_ })

    $archived = ''
    if ($Columns.sessions.ContainsKey('archived')) { $archived = ' AND COALESCE(s.archived, 0) = 0' }

    # Sessions with a message since the cutoff, or started since then.
    $sessions = @"
WITH recent AS (
  SELECT session_id, MAX(id) AS last_id, MAX(timestamp) AS last_ts
  FROM messages WHERE timestamp >= ? GROUP BY session_id
)
SELECT $($sessionCols -join ', '), r.last_id AS last_id, r.last_ts AS last_ts
FROM sessions s LEFT JOIN recent r ON r.session_id = s.id
WHERE (r.session_id IS NOT NULL OR s.started_at >= ?)$archived
ORDER BY COALESCE(r.last_ts, s.started_at) DESC
LIMIT ?
"@

    # The newest message of each of those sessions tells what it is doing.
    $last = @"
SELECT $($msgCols -join ', '), substr(m.content, 1, 300) AS content
FROM messages m
WHERE m.id IN (SELECT MAX(id) FROM messages WHERE timestamp >= ? GROUP BY session_id)
"@

    # First user prompt, used to name sessions that have no title yet.
    $first = @"
SELECT m.session_id AS session_id, substr(m.content, 1, 400) AS content
FROM messages m
WHERE m.id IN (
  SELECT MIN(id) FROM messages
  WHERE role = 'user' AND session_id IN (SELECT DISTINCT session_id FROM messages WHERE timestamp >= ?)
  GROUP BY session_id
)
"@

    $sum = { param($c) if ($Columns.sessions.ContainsKey($c)) { "COALESCE(SUM($c), 0)" } else { '0' } }
    $cost = '0'
    if ($Columns.sessions.ContainsKey('actual_cost_usd') -and $Columns.sessions.ContainsKey('estimated_cost_usd')) {
        $cost = 'COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd)), 0)'
    }
    elseif ($Columns.sessions.ContainsKey('estimated_cost_usd')) { $cost = 'COALESCE(SUM(estimated_cost_usd), 0)' }

    $today = @"
SELECT COUNT(*) AS sessions,
  $(& $sum 'input_tokens') AS input, $(& $sum 'output_tokens') AS output,
  $(& $sum 'reasoning_tokens') AS reasoning, $(& $sum 'cache_read_tokens') AS cache_read,
  $(& $sum 'cache_write_tokens') AS cache_write, $(& $sum 'api_call_count') AS steps,
  $cost AS cost
FROM sessions WHERE started_at >= ?
"@

    return @($sessions, $last, $first, $today)
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

function Get-HermesToolCalls {
    # tool_calls is an OpenAI-style JSON list: [{ id, function: { name, arguments } }]
    param($Message)

    $calls = New-Object System.Collections.ArrayList
    foreach ($call in @(ConvertFrom-JsonSafe ([string](Get-Field $Message 'tool_calls' '')))) {
        if (-not $call) { continue }
        $function = Get-Field $call 'function'
        $name = [string](Get-Field $function 'name' (Get-Field $call 'name' 'tool'))
        $arguments = Get-Field $function 'arguments' (Get-Field $call 'arguments')
        if ($arguments -is [string]) { $arguments = ConvertFrom-JsonSafe $arguments }
        [void]$calls.Add(@{ name = $name; input = $arguments; id = [string](Get-Field $call 'id' '') })
    }
    return ,$calls
}

function Get-HermesToolSummary {
    param($Call)

    $toolInput = $Call.input
    if ($Call.name -eq 'delegate_task') {
        $goal = [string](Get-Field $toolInput 'goal' (Get-Field $toolInput 'task' (Get-Field $toolInput 'description' '')))
        $part = @{ name = 'subagent'; state = @{ input = @{ agent = 'subagent'; description = $goal; prompt = [string](Get-Field $toolInput 'context' '') } } }
        return Get-ToolSummary $part
    }
    return Get-ToolSummary @{ name = $Call.name; state = @{ input = $toolInput } }
}

function Get-HermesState {
    # Hermes has no "running" flag: ended_at stays empty for crashed or
    # unfinished runs. A session counts as working while its newest message is
    # recent and is not a finished answer.
    param($Row, $Last, [long]$NowMs)

    $endedAt = Get-Field $Row 'ended_at'
    $endReason = ([string](Get-Field $Row 'end_reason' '')).ToLowerInvariant()

    if ($null -ne $endedAt) {
        if ($endReason -match 'error|fail|crash') { return 'failed' }
        if ($endReason -match 'interrupt|cancel|orphan|reap|kill|abort') { return 'interrupted' }
        return 'idle'
    }

    if (-not $Last) { return 'idle' }

    $lastMs = [long]([double](Get-Field $Last 'timestamp' 0) * 1000)
    $age = $NowMs - $lastMs
    $role = [string](Get-Field $Last 'role' '')
    $finish = ([string](Get-Field $Last 'finish_reason' '')).ToLowerInvariant()
    $hasCalls = -not [string]::IsNullOrWhiteSpace([string](Get-Field $Last 'tool_calls' ''))

    if ($role -eq 'assistant' -and $hasCalls) {
        # A tool is running; long commands get more slack.
        if ($age -lt 600000) { return 'running' }
        return 'interrupted'
    }
    if ($role -eq 'assistant' -and -not $hasCalls -and ($finish -eq '' -or $finish -match 'stop|end')) { return 'idle' }
    if ($age -lt $HermesActiveMs) { return 'running' }   # user or tool message: the model is thinking
    return 'idle'
}

function Set-HermesSince {
    param([string]$Id, [string]$State, [long]$Now)

    $entry = $script:HM.Since[$Id]
    if (-not $entry -or $entry.state -ne $State) {
        $entry = @{ state = $State; since = $Now }
        $script:HM.Since[$Id] = $entry
    }
    $entry.seen = $Now
    return $entry.since
}

function Read-HermesTarget {
    param($Target, [long]$NowMs, [double]$CutoffSec, [double]$MidnightSec)

    $columns = Get-HermesColumns -Target $Target
    $sql = Get-HermesSql -Columns $columns
    $results = Invoke-HermesQueries -Target $Target -Sql $sql -Arguments @(
        @($CutoffSec, $CutoffSec, [long]$HermesLimit),
        @($CutoffSec),
        @($CutoffSec),
        @($MidnightSec)
    )

    $lastBySession = @{}
    foreach ($m in @($results[1])) { $lastBySession[[string](Get-Field $m 'session_id')] = $m }
    $firstBySession = @{}
    foreach ($m in @($results[2])) { $firstBySession[[string](Get-Field $m 'session_id')] = [string](Get-Field $m 'content' '') }

    $nodes = New-Object System.Collections.ArrayList
    foreach ($row in @($results[0])) {
        $id = [string](Get-Field $row 'id' '')
        if (-not $id) { continue }

        $last = $lastBySession[$id]
        $state = Get-HermesState -Row $row -Last $last -NowMs $NowMs
        $source = [string](Get-Field $row 'source' '')

        $activity = ''
        $activityFull = ''
        $stateDetail = $null
        $delegateGoal = $null
        if ($state -eq 'running') {
            $calls = @()
            if ($last -and [string](Get-Field $last 'role' '') -eq 'assistant') { $calls = @(Get-HermesToolCalls $last) }
            if ($calls.Count -gt 0) {
                $summary = Get-HermesToolSummary $calls[0]
                $stateDetail = $calls[0].name
                $activity = $summary.short
                $activityFull = $summary.full
                if ($calls.Count -gt 1) { $activity += (' (+{0} more)' -f ($calls.Count - 1)) }
            }
            else {
                $stateDetail = 'thinking'
            }
        }

        # Delegated children carry their parent in model_config._delegate_from.
        $config = ConvertFrom-JsonSafe ([string](Get-Field $row 'model_config' ''))
        $delegateFrom = [string](Get-Field $config '_delegate_from' '')
        $isSub = ($source -eq 'subagent') -or [bool]$delegateFrom

        $prompt = Limit-Text ($firstBySession[$id]) 160
        $title = [string](Get-Field $row 'title' '')
        $name = $title
        if (-not $name) { $name = [string](Get-Field $row 'display_name' '') }
        if (-not $name) { $name = Get-SessionName -SessionId $id -Prompt $prompt }
        if ($name.Length -gt 28) { $name = $name.Substring(0, 25).TrimEnd() + '...' }

        $task = ''
        if ($isSub) { $task = Limit-Text $prompt 80 }

        $startedMs = [long]([double](Get-Field $row 'started_at' 0) * 1000)
        $lastTs = Get-Field $row 'last_ts'
        $updatedMs = $startedMs
        if ($null -ne $lastTs) { $updatedMs = [long]([double]$lastTs * 1000) }
        $endedAt = Get-Field $row 'ended_at'

        $profile = $Target.Profile
        if (-not $profile) { $profile = [string](Get-Field $row 'profile_name' '') }
        $agent = 'hermes'
        if ($isSub) { $agent = 'subagent' }
        elseif ($profile) { $agent = 'hermes/' + $profile }

        $tokens = @{
            input      = [long](Get-Field $row 'input_tokens' 0)
            output     = [long](Get-Field $row 'output_tokens' 0)
            reasoning  = [long](Get-Field $row 'reasoning_tokens' 0)
            cacheRead  = [long](Get-Field $row 'cache_read_tokens' 0)
            cacheWrite = [long](Get-Field $row 'cache_write_tokens' 0)
        }
        $tokens.total = $tokens.input + $tokens.output + $tokens.reasoning

        $cost = Get-Field $row 'actual_cost_usd'
        if ($null -eq $cost) { $cost = Get-Field $row 'estimated_cost_usd' 0 }

        $nodeId = 'hermes:' + $Target.Key + ':' + $id
        $parentId = $null
        if ($delegateFrom) { $parentId = 'hermes:' + $Target.Key + ':' + $delegateFrom }

        $since = Set-HermesSince -Id $nodeId -State $state -Now $NowMs

        # Sessions without a working directory (chat platforms, cron) are grouped by platform.
        $cwd = [string](Get-Field $row 'cwd' '')
        $dirPath = $cwd
        $dirLabel = ''
        if (-not $cwd) {
            $platform = $source
            if (-not $platform) { $platform = 'sessions' }
            $dirPath = 'hermes://' + $platform
            $dirLabel = 'hermes ' + $platform
        }

        [void]$nodes.Add(@{
            id            = $nodeId
            shortId       = $(if ($id.Length -gt 8) { $id.Substring(0, 8) } else { $id })
            parentId      = $parentId
            depth         = 0
            source        = 'hermes'
            platform      = $source
            name          = $name
            slug          = ''
            title         = $title
            prompt        = $prompt
            task          = $task
            activity      = $activity
            activityFull  = $activityFull
            delegations   = (New-Object System.Collections.ArrayList)
            agent         = $agent
            model         = [string](Get-Field $row 'model' '')
            state         = $state
            stateDetail   = $stateDetail
            stateSince    = $since
            runningSince  = $(if ($state -eq 'running') { $since } else { $null })
            createdAt     = $startedMs
            updatedAt     = $updatedMs
            idleAt        = $(if ($null -ne $endedAt) { [long]([double]$endedAt * 1000) } else { $null })
            outcome       = $(if ($state -eq 'failed' -or $state -eq 'interrupted') { $state } else { $null })
            cost          = [double]$cost
            tokens        = $tokens
            stateRank     = (Get-StateRank $state)
            children      = (New-Object System.Collections.ArrayList)
            directoryPath = $dirPath
            directoryLabel = $dirLabel
        })
    }

    $todayRow = @($results[3])[0]
    $today = @{
        tokens = @{
            input      = [long](Get-Field $todayRow 'input' 0)
            output     = [long](Get-Field $todayRow 'output' 0)
            reasoning  = [long](Get-Field $todayRow 'reasoning' 0)
            cacheRead  = [long](Get-Field $todayRow 'cache_read' 0)
            cacheWrite = [long](Get-Field $todayRow 'cache_write' 0)
        }
        cost     = [double](Get-Field $todayRow 'cost' 0)
        steps    = [long](Get-Field $todayRow 'steps' 0)
        sessions = [long](Get-Field $todayRow 'sessions' 0)
    }

    return @{ Nodes = $nodes; Today = $today }
}

function Update-HermesSnapshot {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    # Querying is cheap natively, but each WSL query starts a process: poll on our own clock.
    if ($script:HM.LastResult -and ($now - $script:HM.LastPoll) -lt $HermesIntervalMs) {
        return $script:HM.LastResult
    }
    $script:HM.LastPoll = $now

    if ($null -eq $script:HM.Targets -or ($now - $script:HM.LastFind) -ge 60000) {
        $script:HM.Targets = Find-HermesTargets
        $script:HM.LastFind = $now
    }

    $todayLocal = Get-Date
    $midnightSec = ([DateTimeOffset]::new($todayLocal.Date)).ToUnixTimeMilliseconds() / 1000.0
    $cutoffSec = ($now / 1000.0) - [double]$ClaudeHours * 3600

    $all = New-Object System.Collections.ArrayList
    $today = @{ tokens = (New-TokenSet); cost = [double]0; steps = [long]0; sessions = [long]0; date = $todayLocal.ToString('yyyy-MM-dd'); updatedAt = $now }
    $errors = New-Object System.Collections.ArrayList

    foreach ($target in @($script:HM.Targets)) {
        try {
            $read = Read-HermesTarget -Target $target -NowMs $now -CutoffSec $cutoffSec -MidnightSec $midnightSec
        }
        catch {
            # A schema change would make the cached column list stale.
            $script:HM.Columns.Remove($target.Key)
            [void]$errors.Add($target.Path + ': ' + $_.Exception.Message)
            continue
        }
        foreach ($node in $read.Nodes) { [void]$all.Add($node) }
        foreach ($key in @($today.tokens.Keys)) { $today.tokens[$key] += $read.Today.tokens[$key] }
        $today.cost += $read.Today.cost
        $today.steps += $read.Today.steps
        $today.sessions += $read.Today.sessions
    }

    # Trees: subagents under the session that delegated to them.
    $byId = @{}
    foreach ($node in $all) { $byId[$node.id] = $node }
    $roots = New-Object System.Collections.ArrayList
    $maxTokens = [long]0
    foreach ($node in $all) {
        if ($node.tokens.total -gt $maxTokens) { $maxTokens = $node.tokens.total }
        if ($node.parentId -and $byId.ContainsKey($node.parentId)) {
            [void]$byId[$node.parentId].children.Add($node)
            if ($node.state -eq 'running') {
                [void]$byId[$node.parentId].delegations.Add(@{
                    childId = $node.id; agent = $node.agent; description = $node.task; startedAt = $node.createdAt
                })
            }
        }
        else {
            if ($node.parentId) { $node.parentId = $null }   # parent outside the window: show as a root
            [void]$roots.Add($node)
        }
    }

    $directories = @{}
    foreach ($root in $roots) {
        $key = Get-DirectoryKey $root.directoryPath
        if ($root.directoryPath -like 'hermes://*') { $key = $root.directoryPath }
        if (-not $directories.ContainsKey($key)) {
            $label = $root.directoryLabel
            if (-not $label) { $label = Split-Path -Leaf $root.directoryPath }
            $directories[$key] = @{
                id = $key; path = $root.directoryPath; label = $label
                sessionCount = 0; runningCount = 0; waitingCount = 0
                sessions = (New-Object System.Collections.ArrayList)
            }
        }
        [void]$directories[$key].sessions.Add($root)
    }

    function Measure-HermesTree {
        param($Node, [int]$Depth, $Directory)
        $Node.depth = $Depth
        $Directory.sessionCount++
        if ($Node.state -eq 'running') { $Directory.runningCount++ }
        if ($Node.state -eq 'waiting') { $Directory.waitingCount++ }
        foreach ($child in $Node.children) { Measure-HermesTree -Node $child -Depth ($Depth + 1) -Directory $Directory }
    }

    $directoryList = New-Object System.Collections.ArrayList
    foreach ($directory in $directories.Values) {
        foreach ($session in $directory.sessions) { Measure-HermesTree -Node $session -Depth 0 -Directory $directory }
        $directory.sessions = Sort-SessionJson -Sessions $directory.sessions
        [void]$directoryList.Add($directory)
    }
    foreach ($node in $all) { $node.Remove('directoryPath'); $node.Remove('directoryLabel') }

    foreach ($id in @($script:HM.Since.Keys)) {
        if (($now - [long]$script:HM.Since[$id].seen) -gt 600000) { $script:HM.Since.Remove($id) }
    }

    $result = @{
        directories = $directoryList
        maxTokens   = $maxTokens
        databases   = @($script:HM.Targets).Count
        today       = $today
        error       = $(if ($errors.Count) { $errors -join '; ' } else { $null })
    }
    $script:HM.LastResult = $result
    return $result
}
