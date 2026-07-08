#!/bin/sh
# Host-side launcher for the DoItList MCP stdio adapter (m03.02). An MCP
# client (`claude mcp add`, or any other stdio-capable client) execs this
# directly; it forwards stdio into the already-running `web` container,
# where the adapter's own mix project (mcp_server/) lives. Requires
# `docker compose up` already running — this does not start the stack.
set -e

cd "$(dirname "$0")/.."

# Frame log (transport debugging): keep a host-side copy of every byte this
# connection exchanges, one .in/.out/.err triplet per connection under
# /tmp/doitlist-mcp/. Lets us see exactly what a remote client sent when a
# request comes back -32600, without any client-side setup.
FRAMES=/tmp/doitlist-mcp
mkdir -p "$FRAMES"
BASE="$FRAMES/$(date +%Y%m%dT%H%M%S).$$"

tee -a "$BASE.in" | docker compose exec -T -e DOITLIST_API_TOKEN -e DOITLIST_API_URL web \
  sh -c "cd /app/mcp_server && exec mix run --no-halt --no-compile" \
  2>>"$BASE.err" | tee -a "$BASE.out"
