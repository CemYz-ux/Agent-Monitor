#!/usr/bin/env python3
"""Read-only bridge to a Hermes Agent database inside WSL.

Watch-OpencodeSessions.ps1 runs this with WSL's python3 and writes one JSON
request to stdin:

  {"action": "find"}
      -> {"databases": [{"path": "/home/u/.hermes/state.db", "profile": ""}, ...]}

  {"action": "query", "db": "<path>", "queries": [{"sql": "...", "args": [...]}, ...]}
      -> {"results": [[{column: value, ...}, ...], ...]}   one row list per query

The database is opened read-only; nothing is ever written.
"""

import json
import os
import sqlite3
import sys


def hermes_homes():
    homes = []
    if os.environ.get("HERMES_HOME"):
        homes.append(os.environ["HERMES_HOME"])
    homes.append(os.path.expanduser("~/.hermes"))
    return homes


def find():
    found, seen = [], set()
    for home in hermes_homes():
        candidates = [(os.path.join(home, "state.db"), "")]
        profiles = os.path.join(home, "profiles")
        if os.path.isdir(profiles):
            for name in sorted(os.listdir(profiles)):
                candidates.append((os.path.join(profiles, name, "state.db"), name))
        for path, profile in candidates:
            real = os.path.realpath(path)
            if real in seen or not os.path.isfile(path):
                continue
            seen.add(real)
            found.append({"path": path, "profile": profile})
    return {"databases": found}


def query(db, queries):
    conn = sqlite3.connect("file:" + db + "?mode=ro", uri=True, timeout=1.5)
    conn.row_factory = sqlite3.Row
    try:
        results = []
        for q in queries:
            args = [a for a in (q.get("args") or []) if a is not None]
            rows = conn.execute(q["sql"], args).fetchall()
            results.append([dict(r) for r in rows])
        return {"results": results}
    finally:
        conn.close()


def main():
    request = json.loads(sys.stdin.buffer.read().decode("utf-8") or "{}")
    if request.get("action") == "find":
        out = find()
    elif request.get("action") == "query":
        out = query(request["db"], request.get("queries") or [])
    else:
        raise SystemExit("unknown action")
    sys.stdout.write(json.dumps(out, ensure_ascii=True))


if __name__ == "__main__":
    main()
