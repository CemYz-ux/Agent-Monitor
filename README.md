# Agent-Monitor

A live, local dashboard for [OpenCode](https://opencode.ai) sessions. One PowerShell
script polls the local OpenCode background service, serves a D3 bubble graph on
`127.0.0.1`, and opens it in your browser. It shows each session's state, the tool it
is running, subagents, and token usage.

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
| `-NoBrowser` | off | don't open the browser |
| `-Once` | off | write one `sessions.json` snapshot and exit |

## Files

- `Start-Monitor.cmd`: double-clickable launcher
- `Watch-OpencodeSessions.ps1`: collector and local HTTP server
- `index.html`: the dashboard
- `sessions.json`, `.monitor-state.json`: generated at runtime (git-ignored)

## Design notes

See [docs/CONCEPT.md](docs/CONCEPT.md) for the architecture, the `sessions.json`
format, the state model, and the design decisions.
