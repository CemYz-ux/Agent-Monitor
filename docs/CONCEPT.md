# Agent Monitoring — concept & implementation notes

A live, local dashboard for OpenCode, Claude Code and Hermes Agent. One
PowerShell process polls the OpenCode background service, reads Claude Code's
session files and Hermes Agent's SQLite database, writes one merged JSON snapshot,
serves a static D3 page over a loopback HTTP server, and opens that page in the
browser.

Session data never leaves the machine; the only outbound request is the browser
loading D3 from jsDelivr. No build step, no npm install, no cloud service.

---

## 1. Folder layout

```
Agent-Monitor/
  Watch-OpencodeSessions.ps1      the collector, HTTP server, and lifecycle
  ClaudeSessions.ps1              Claude Code collector, dot-sourced by the script above
  HermesSessions.ps1              Hermes Agent collector, dot-sourced by the script above
  tools/hermes-query.py           read-only SQLite helper for a Hermes database inside WSL
  index.html                      the D3 dashboard (D3 v7.9.0 loaded from jsDelivr)
  smiley-prototype.html           prototype view, served at /smiley
  sessions.json                   generated — machine-readable snapshot (every second)
  .monitor-state.json             generated — prompts and observed state timestamps
  docs/CONCEPT.md                 this file
```

The monitor only observes sessions; it never creates or changes them.

---

## 2. What OpenCode gives us

Verified against the local service (OpenCode 2.1.3):

| Need | Source |
|---|---|
| Service URL + password | `%USERPROFILE%\.local\state\opencode\service.json` |
| Auth | HTTP Basic, user `opencode`, password from that file |
| All sessions | `GET /api/session?limit=200&order=desc` |
| Which sessions are executing | `GET /api/session/active` |
| Subagent tree | `parentID` on each session |
| Current tool / running detail | `GET /api/session/{id}/message?limit=1&order=desc&type=assistant` |
| Waiting for approval | `GET /api/permission/request` |
| Today's token totals | `GET /api/experimental/session/stats?from=<midnight>&to=<now>&tools=none` |
| First user prompt (session name) | `GET /api/session/{id}/message?limit=1&order=asc&type=user` |

`Session.Info` fields used: `id`, `parentID`, `agent`, `model`, `cost`, `tokens`,
`outcome`, `time.{created,updated,idle,archived}`, `location.directory`.

Two quirks shaped the design:

1. **Titles are usually null, and the API has no slug.** OpenCode's friendly
   slug (`witty-squid`) lives only in its database, which the monitor does not
   read. Sessions are named from their first user prompt instead, fetched once
   through the API and cached in `.monitor-state.json`.
2. **`/api/session/active` only reports "running".** It says nothing about
   *what* is running. The tool name comes from the last assistant message's
   first tool part with `state.status = "running"`.

The service occasionally blocks `/api/session` for several seconds while an
agent turn is being processed. The monitor uses a 4-second HTTP timeout, does not
retry timeouts, and keeps the last snapshot on failure instead of crashing.

### What Claude Code gives us

Claude Code has no service to poll, so the monitor reads its files
(verified against Claude Code 2.1.316):

| Need | Source |
|---|---|
| Which sessions are open, busy or idle | `%USERPROFILE%\.claude\sessions\<pid>.json` (`sessionId`, `status`, `cwd`); kept only if the pid is alive |
| Transcript | `%USERPROFILE%\.claude\projects\<dir>\<sessionId>.jsonl` |
| Subagents | `<sessionId>\subagents\agent-<id>.jsonl` plus `agent-<id>.meta.json` (`agentType`, `description`, `toolUseId`, `finished`) |
| Current tool | `tool_use` blocks in assistant lines with no matching `tool_result` yet |
| Tokens | `message.usage` on assistant lines, counted once per message id |
| Cost | the latest `cost-state` line, when the session wrote one |

Transcripts can be several megabytes and include large request dumps. Each file
is read once, then only the bytes appended since the previous tick are parsed;
`api-request*`, `file-history` and `queue-operation` lines are skipped unparsed.
Sessions written to in the last `-ClaudeHours` (24) are shown, plus every open
one. A subagent's parent is the transcript whose `Agent` call has the
subagent's `toolUseId`, so nested subagents nest on the map too.

Both tools' sessions go into the same snapshot. Each session has
`source: "opencode" | "claude"`, and a project folder used by both becomes one
directory bubble with `sources: ["opencode", "claude"]`. Either source can fail
on its own; `sources.<name>.ok` says which one is down. Claude Code's daily
totals are in `claudeToday` (no cost: Claude Code writes none per day).

### What Hermes Agent gives us

Written from the Hermes docs (schema version 31), not yet checked against a real
install. Hermes keeps everything in one SQLite database in WAL mode:
`%LOCALAPPDATA%\hermes\state.db` on Windows, `~/.hermes/state.db` on Linux and
WSL, `HERMES_HOME` overriding both, and `profiles/<name>/state.db` per profile.

| Need | Source |
|---|---|
| Sessions | `sessions` (`id`, `source` = platform, `model`, `title`, `cwd`, `started_at`, `ended_at`, `end_reason`, token and cost columns) |
| Subagents | sessions with `source = 'subagent'`; the parent is `model_config._delegate_from` (`parent_session_id` is compression lineage, not delegation) |
| Current tool | the newest message: an assistant row with `tool_calls` (OpenAI-style JSON) is a tool still running |
| Name | `title`, else the first user message |
| Today | sums over sessions started since midnight |

Timestamps are Unix seconds (floats). Hermes has no running flag, and
`ended_at` stays empty for runs that died, so the state is inferred: ended
sessions are idle (or failed / interrupted by `end_reason`); open ones are
working while their newest message is a tool call under 10 minutes old, or a
prompt or tool result newer than `-HermesActiveMs`; otherwise idle.

A native database is opened read-only through Windows' `winsqlite3.dll` via a
small P/Invoke class, so no SQLite install is needed. A WSL database
(`-HermesWsl`) is queried by `tools/hermes-query.py` under WSL's `python3`, one
process per poll, with the same SQL. Queries only name columns the database
actually has (`pragma_table_info`), so older or newer schemas still work. Sessions
with no `cwd` (chat platforms, cron) go into a `hermes://<platform>` directory.

---

## 3. Architecture

```
  opencode service (localhost)
          │  HTTP + Basic auth
          ▼
  Watch-OpencodeSessions.ps1
    1. resolve service.json (re-read after connection failures)
    2. every tick:  sessions + active + permissions + last active message
                    + first prompt for new sessions
       every 10 s:  today's token totals
    3. merge with .monitor-state.json (observed state, first prompt)
    4. build one snapshot object
    5. write sessions.json atomically
    6. serve index.html / sessions.json on 127.0.0.1
    7. sleep until the next tick, serving requests while waiting
          │
          ▼  once at startup
  Start-Process http://127.0.0.1:<port>/
```

### Why a local HTTP server

A `file://` page cannot `fetch()` a neighboring JSON file, and a `<script src>`
reload leaves the UI unable to distinguish "data is old" from "the monitor is
gone". A loopback `HttpListener` gives the page a normal `fetch()` loop, proper
status codes, and a lifecycle tied to the PowerShell process:

- The listener is created in the same process as the collector.
- It is closed in a `finally` block, so Ctrl+C and closing the window stop it.
- The page polls `/sessions.json` once per second with `Cache-Control: no-store`.
- Port 8787 is the default; if it is busy, the next free port is used.
- Only `127.0.0.1` is bound. No external interface is exposed.

The page itself is never rewritten. Only `sessions.json` changes.

---

## 4. Snapshot contract (`sessions.json`)

```jsonc
{
  "schemaVersion": 1,
  "generatedAt": 1792757399157,            // epoch ms
  "generatedAtIso": "2026-10-23T12:09:59.157+00:00",
  "tick": 1042,
  "intervalMs": 1000,
  "monitor": {
    "pid": 41232,
    "startedAt": 1792745259912,
    "stale": false,
    "error": null,
    "slowUpdatedAt": 1792757398100          // last 10s refresh
  },
  "server": {
    "url": "http://127.0.0.1:28894",
    "version": "2.1.3",
    "pid": 13748,
    "healthy": true,
    "latencyMs": 8
  },
  "totals": {
    "directories": 2,
    "sessions": 6,
    "subagents": 3,
    "running": 2,
    "waiting": 1,
    "idle": 3,
    "failed": 0
  },
  "today": {
    "date": "2026-10-23",
    "tokens": {
      "input": 536534,
      "output": 86941,
      "reasoning": 132559,
      "cacheRead": 19063296,
      "cacheWrite": 0
    },
    "cost": 0,
    "steps": 230,
    "sessions": 2,
    "prompts": 13,
    "updatedAt": 1792757397000
  },
  "maxSessionTokens": 698150,               // bubble-size denominator
  "directories": [
    {
      "id": "c:\\users\\yazic\\documents\\knowledgebase",
      "path": "C:\\Users\\yazic\\Documents\\Knowledgebase",
      "label": "Knowledgebase",
      "sessionCount": 4,
      "runningCount": 2,
      "waitingCount": 0,
      "sessions": [
        {
          "id": "ses_e97cf5308ffe3niWO0JuK9L9q1",
          "shortId": "e97cf530",
          "parentId": null,
          "depth": 0,
          "name": "Build a powershell script...", // first prompt, truncated (see §6)
          "slug": "",                           // reserved, currently always empty
          "title": "",                          // reserved, currently always empty
          "prompt": "Build a powershell script that opens 6 terminals…",
          "task": "",                           // description this session was handed by its parent (kept after the handoff)
          "activity": "CONCEPT.md (lines 246-253)",  // running tool's input, short (≤80 chars)
          "activityFull": "C:\\…\\CONCEPT.md (lines 246-253)", // longer form for the panel (≤300 chars)
          "delegations": [                      // running `subagent` calls = active handoffs
            { "childId": "ses_…", "agent": "critic", "description": "Verify web roster consistency", "startedAt": 1792749390000 }
          ],
          "agent": "build",
          "model": "opencode/deepseek-v4.1-flash-free",
          "state": "running",
          "stateDetail": "shell",
          "stateSince": 1792749382932,
          "runningSince": 1792749382932,
          "createdAt": 1792749382932,
          "updatedAt": 1792749418363,
          "idleAt": null,
          "outcome": null,
          "cost": 0,
          "tokens": {
            "input": 16454,
            "output": 976,
            "reasoning": 871,
            "cacheRead": 82560,
            "cacheWrite": 0,
            "total": 18301                    // input + output + reasoning
          },
          "children": []
        }
      ]
    }
  ]
}
```

Design rules:

- **One object, no parallel arrays.** The UI walks
  `directories[].sessions[].children[]` directly; the PowerShell script builds
  that tree, so the browser does not reconstruct parentage.
- **Milliseconds, epoch.** Matches the API; the UI formats durations.
- **`tokens.total` excludes cache reads** so a 19M cache read does not dwarf
  everything. Cache is still present in the object and shown separately.
- **Directory ids are normalized paths** (lowercase, backslashes). The UI
  prefixes them with `dir:` to avoid colliding with session ids.
- **Archived sessions are omitted.** The scope is "all current sessions".
- **Never omit an idle session.** The dashboard is also a history view.

---

## 5. State model

Precedence, evaluated top to bottom:

| State | Condition | Colour |
|---|---|---|
| `waiting` | session has a pending permission request | amber, dashed halo |
| `running` | session appears in `/api/session/active` | green + pulse |
| `failed` | `outcome = failed` | red |
| `interrupted` | `outcome = interrupted` | violet |
| `idle` | has `time.idle` | slate |
| `new` | exists, never ran (`created == updated`) | cyan, dashed ring |

`stateDetail` refines the state:

- `shell` / `read` / `edit` / `subagent` … — first tool with `state.status = "running"`
- `thinking` — assistant message streaming, no active tool
- `retrying` — assistant message carries a `retry` object
- permission `action` — for `waiting`

**"Running since" is observed, not read.** `time.updated` is the last write, not
the start of the current run. The monitor records the tick when it first saw the
session in `running` and stores it in `.monitor-state.json`. If the state
changes, the clock restarts. If the monitor itself was stopped (or blocked) for
more than 10 seconds, the clock restarts on the next observation, so the bubble
never claims to know time it did not witness.

The state file also caches the first user prompt (fetched once per session) and
is pruned to sessions seen in the last 24 hours.

---

## 6. Naming a session

First match wins:

1. First user message, whitespace collapsed and cut to 28 characters
   (`Build a powershell script...`).
2. `Session e97cf530` — the short id, if no prompt could be fetched.

The prompt is fetched with `GET /api/session/{id}/message?limit=1&order=asc&type=user`
when a session is first seen, and again when it starts running if it was still
empty (at most 5 fetches per tick). Up to 160 characters are cached in
`.monitor-state.json`, so each session is fetched once.

The name and the full prompt appear in the tooltip and the detail panel, while
the bubble itself shows the agent (§7).

---

## 7. Visualization

### Layout

Force-directed, three levels:

```
   ┌─────────── Directory bubble (fixed radius 92) ───────────┐
   │                                                          │
   │      ( session )──────( subagent )                       │
   │          │                 └──────( subagent )           │
   │      ( session )                                         │
   │                                                          │
   └──────────────────────────────────────────────────────────┘
```

- **Directory node** — fixed radius 92, labelled with the folder name and
  `N running · M sessions`. Directories are pinned on a ring around the center;
  their position does not depend on how many sessions they contain.
- **Session node** — radius `27 + 23·√(tokens/max)`, clamped 27–56.
- **Subagent node** — radius `19 + 13·√(tokens/max)`, clamped 19–34, nested
  recursively by `parentID`.
- **Links** — directory→session and session→subagent, trimmed at both bubble
  edges. A link to a running node is animated (dash offset).
- Forces: `link` (168 directory→session, `38 + r₁ + r₂` parent→child),
  `charge(-230 / -1100 directory)`, `collide(r + 7)`, and weak x/y pull toward
  the parent (subagents) or directory (roots). Directories are pinned.

### Inside a bubble

```
┌────────────────────┐
│     digestion      │  agent name, bold, ellipsised at the edge
│   running · shell  │  state + running tool
│ 1m 32s · 563.9k tok│  observed duration + token total
└────────────────────┘
```

- Colour encodes state; a soft animated halo marks `running`, a dashed halo
  marks `waiting`.
- The bubble names the **agent** (`build`, `collector`, `digestion`, `critic`) —
  not the session name, never a truncated prompt. Several sessions can run the
  same agent; the session's own name and first prompt are one hover or click
  away, so the bubble stays scannable.
- Subagent bubbles omit the token line to stay readable.
- Hover → native SVG tooltip with full path, id, model, tokens, cost.
- Click → side panel with state, agent, model, ids, directory, timestamps,
  token breakdown, first prompt, and clickable subagents.
- Clicking a directory shows its path, counts, and root sessions.

### Activity and task handoffs

- **Activity** — the running tool's *input* (file name, command, pattern, or the
  subagent's task) is summarised under each running bubble. Tool output is never read.
- **Handoff** — an agent hands work to another by calling the `subagent` tool
  (`input.agent`, `input.description`, `state.metadata.sessionID` = the child).
  While that call runs, the parent is drawn dimmed as *delegating* and the link is
  teal and animated.
- **Task token** — when a new handoff appears, a teal token carrying the task
  description travels from the parent to the child and rests on the child's rim.
  When the handoff ends it travels back: green `✓ done`, red `✗ failed`, violet
  `■ interrupted` (from the child's state), then fades.
- **Holder** — a running session with no active handoff is the one actually doing
  the work: rotating teal ring, and listed in the top-left *working now* strip as
  its chain (`build → critic`) plus its current activity.
- Handoffs that already exist when the page loads are shown at rest, not replayed.
  A subagent that starts and finishes between two one-second polls gets no animation.

### Page chrome

- Top bar: live/stale dot, server version + address + latency, and counts
  (directories, sessions, running, waiting, subagents).
- Bottom right: **today's token usage** (input + output + reasoning), breakdown,
  cache reads, cost, and steps. Refreshed every 10 seconds.
- Bottom left: legend.
- Auto-fit zoom once, after the force layout settles; afterwards the user's
  pan/zoom is preserved. Double-click the background to re-fit.
- `#select=<session-id>` opens the detail panel directly (useful for links).
- Reduced-motion media query disables the pulse, link animation, and live dot.
- One dark theme, no dependencies beyond D3 (loaded from jsDelivr).

---

## 8. The collector loop

```
tick (every 1000 ms):
  sessions = GET /api/session?limit=200&order=desc
  active   = GET /api/session/active
  perms    = GET /api/permission/request
  for each active session:
      last = GET /api/session/{id}/message?limit=1&order=desc&type=assistant
  for each session without a cached prompt (max 5 per tick):
      first = GET /api/session/{id}/message?limit=1&order=asc&type=user
  merge + derive + save state
  write sessions.json atomically
  serve HTTP requests until the next tick

slow lane (every 10000 ms):
  stats = GET /api/experimental/session/stats?from=<local midnight>&to=<now>
```

- One `System.Net.Http.HttpClient` for the whole run, 4-second timeout.
- Timeouts do not trigger a service reload; connection failures do.
- Writes go to `*.tmp` first, then replace, so the browser never parses a
  half-written file. Retries handle the rare Windows file-lock race.
- UTF-8 **without BOM** (`UTF8Encoding($false)`).
- If `service.json` is missing or the service is down, the last snapshot is
  rewritten with `monitor.stale = true`, `server.healthy = false`, and the error
  text. The loop keeps running and reconnects automatically.
- Ctrl+C is the normal stop. The listener is closed in `finally`.

Expected cost with 6 sessions: ~3 base requests + 6 message requests per second
against localhost, plus one stats request every 10 seconds.

### Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-IntervalMs` | `1000` | snapshot / graph cadence |
| `-TokenIntervalMs` | `10000` | daily token total refresh |
| `-Limit` | `200` | max sessions to read |
| `-Port` | `8787` | first loopback port to try |
| `-NoBrowser` | off | do not open the page |
| `-Once` | off | one snapshot, then exit (no server) |

If the execution policy blocks the script, run it through `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`.

---

## 9. Failure modes and edge cases

| Situation | Behaviour |
|---|---|
| Service restarting | stale snapshot + reconnect; running clocks restart on next observation |
| Service busy (long agent turn) | 4s timeout, keep last graph, stale banner, retry next tick |
| Session archived | omitted (`time.archived` set) |
| Subagent outlives parent | promoted to the directory level if `parentID` is missing |
| Directory deleted | bubble stays while its sessions exist; path shown as recorded |
| Clock skew | all elapsed values come from the monitor's clock |
| Very long names | ellipsis in the bubble, full text in the detail panel |
| 100+ sessions | `-Limit` + collision layout; consider collapsing idle sessions later |
| First prompt not fetchable | name falls back to `Session <short id>`; retried when the session starts running |

---

## 10. Decisions taken

1. **Scope** — all current (non-archived) sessions, up to `-Limit`.
2. **Name** — first user prompt via the API, falling back to the short id. No
   database access, so the monitor only needs the HTTP API.
3. **Refresh** — a loopback HTTP server inside the PowerShell process, so the
   page can `fetch()` every second and the server dies with the process.
4. **Bubble size** — token usage: sessions 27–56 px, subagents 19–34 px.
   Directories are fixed at 92 px. Token counts are printed inside the bubble.
5. **Daily total** — bottom-right panel, from the stats endpoint, refreshed every
   10 seconds. Input + output + reasoning is the headline; cache reads are shown
   separately because they are an order of magnitude larger.
6. **Dependencies** — PowerShell 5.1 and D3 v7.9 from the jsDelivr CDN.
