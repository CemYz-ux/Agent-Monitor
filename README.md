# Agent-Monitor

A live, local dashboard for [OpenCode](https://opencode.ai), Claude Code and
[Hermes Agent](https://hermes-agent.nousresearch.com) sessions. One PowerShell script
polls the local OpenCode background service, reads Claude Code's session files under
`~/.claude`, reads Hermes Agent's `state.db`, serves a D3 bubble graph on `127.0.0.1`,
and opens it in your browser. It shows each session's state, the tool it is running,
subagents and their task handoffs, and token usage.

All tools share one map. A project folder used by several shows up as one bubble, and
each session face is tagged `oc` (OpenCode), `cc` (Claude Code) or `hm` (Hermes). The
`all / opencode / claude code / hermes` switch in the header (or keys `1`-`4`) narrows
the map to one tool. Any tool may be absent: the others still show.

Hermes sessions without a project folder (Telegram, Discord, cron, ...) are grouped in a
`hermes <platform>` bubble. A native Windows install (`%LOCALAPPDATA%\hermes`) is read
through Windows' built-in SQLite, so nothing extra is needed. For Hermes inside WSL, add
`-HermesWsl`: the monitor then runs `tools/hermes-query.py` with WSL's `python3`.

## Requirements

- Windows with PowerShell 5.1+
- OpenCode running its background service
- Internet access in the browser (D3 is loaded from the jsDelivr CDN)

## Usage

Start the monitor by double-clicking `Start-Monitor.cmd`, or from a terminal:

```powershell
.\Start-Monitor.cmd
```

The launcher runs the script with `-ExecutionPolicy Bypass` for that one process, so it
works even when the machine policy is `AllSigned` or `Restricted`. Parameters are passed
through (`.\Start-Monitor.cmd -NoBrowser`). The equivalent direct call is:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Watch-OpencodeSessions.ps1
```

The dashboard opens at `http://127.0.0.1:8787/` (the next free port is used if 8787
is busy). Stop it with Ctrl+C.

| Parameter | Default | Purpose |
|---|---|---|
| `-IntervalMs` | `1000` | snapshot / graph refresh |
| `-TokenIntervalMs` | `10000` | daily token total refresh |
| `-Limit` | `200` | max sessions to read |
| `-Port` | `8787` | first loopback port to try |
| `-ClaudeHours` | `24` | show Claude Code sessions written to in the last N hours |
| `-ClaudeLimit` | `40` | max Claude Code sessions |
| `-ClaudeSubagentLimit` | `12` | finished subagents shown per Claude Code session |
| `-NoClaude` | off | don't read Claude Code sessions |
| `-HermesWsl` | off | also read a Hermes database inside the default WSL distro |
| `-HermesIntervalMs` | `2000` | how often Hermes databases are queried |
| `-HermesLimit` | `100` | max Hermes sessions per database |
| `-HermesActiveMs` | `120000` | how recent a prompt or tool result must be to count as working |
| `-NoHermes` | off | don't read Hermes Agent sessions |
| `-NoBrowser` | off | don't open the browser |
| `-Once` | off | write one `sessions.json` snapshot and exit |

## Files

- `Start-Monitor.cmd`: double-clickable launcher
- `Watch-OpencodeSessions.ps1`: collector and local HTTP server
- `ClaudeSessions.ps1`: Claude Code collector, loaded by the script above
- `HermesSessions.ps1`: Hermes Agent collector, loaded by the script above
- `tools/hermes-query.py`: read-only query helper for a Hermes database inside WSL
- `index.html`: the dashboard
- `sessions.json`, `.monitor-state.json`: generated at runtime (git-ignored)

## Design notes

See [docs/CONCEPT.md](docs/CONCEPT.md) for the architecture, the `sessions.json`
format, the state model, and the design decisions.
