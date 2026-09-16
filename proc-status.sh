#!/usr/bin/env bash
# Per-process state from the running phrocs, read over its unix socket.
# Lives on the box because the socket is local to it.
#
# Prints "<name> <status> <ready>" per process, sorted. With process names as
# arguments, prints only those and exits 1 unless every one is running and ready.
# Exits 2 when no phrocs is listening.
#
# `phrocs wait` cannot answer this: its classify() counts `stopped` as ready,
# which is exactly the steady state of an `autostart: false` unit.
set -uo pipefail

POSTHOG_DIR="${POSTHOG_DIR:-$HOME/posthog}"

python3 - "$POSTHOG_DIR" "$@" <<'PY'
import hashlib
import json
import os
import socket
import sys

workdir, *wanted = sys.argv[1:]

real = os.path.realpath(workdir)
digest = hashlib.sha256(real.encode()).hexdigest()[:8]
sock_path = f"/tmp/phrocs-{digest}.sock"

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(sock_path)
    sock.sendall(b'{"cmd":"status_all"}\n')
    with sock.makefile("r") as stream:
        response = json.loads(stream.readline())
except OSError as err:
    print(f"proc-status: no phrocs listening on {sock_path} ({err})", file=sys.stderr)
    raise SystemExit(2)

if not response.get("ok"):
    print(f"proc-status: {response.get('error')}", file=sys.stderr)
    raise SystemExit(2)

processes = response.get("processes") or {}
failed = []
for name in wanted or sorted(processes):
    snapshot = processes.get(name)
    if snapshot is None:
        print(f"{name} absent false")
        failed.append(name)
        continue
    status = snapshot.get("status", "unknown")
    ready = bool(snapshot.get("ready"))
    print(f"{name} {status} {str(ready).lower()}")
    if wanted and not (status == "running" and ready):
        failed.append(name)

raise SystemExit(1 if failed else 0)
PY
