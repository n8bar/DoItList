#!/bin/sh
# Host-side launcher for the DoItList MCP stdio adapter (m03.02). An MCP
# client (`claude mcp add`, or any other stdio-capable client) execs this
# directly; it forwards stdio into the already-running `web` container,
# where the adapter's own mix project (mcp_server/) lives. Requires
# `docker compose up` already running — this does not start the stack.
set -e

cd "$(dirname "$0")/.."

# --- API token resolution (m03.04 item 2.13) --------------------------------
# Three sources; the rule they must satisfy: a token refreshed mid-session by
# the adapter (elicited after a 401, persisted to the refresh file below)
# takes effect on the NEXT connect even though the MCP client's config still
# injects the stale token via env. Precedence, strongest first:
#
#   1. The FRESHEST (newest mtime) of the two token files:
#        ~/.config/doitlist/mcp.env         — operator-maintained, host-only,
#          outside the repository, mode 0600
#        .doitlist/mcp-refreshed-token.env  — written by the adapter inside
#          the container after an in-session refresh; the repo bind mount
#          (.:/app) carries it across to the host
#      Newest wins in BOTH directions: an in-session refresh beats a stale
#      mcp.env, and a later hand-edit of mcp.env beats an old refresh — the
#      operator never has to delete the refresh file to make an edit stick.
#   2. Client-config env: whatever DOITLIST_API_TOKEN the MCP client already
#      exported. Used only when neither file exists — files always beat env,
#      because 2.13's whole point is recovery without touching client config.
#
# DOITLIST_MCP_ENV / DOITLIST_MCP_REFRESH_FILE override the file paths
# (launcher tests use them; harmless otherwise).
MCP_ENV="${DOITLIST_MCP_ENV:-$HOME/.config/doitlist/mcp.env}"
REFRESH_FILE="${DOITLIST_MCP_REFRESH_FILE:-.doitlist/mcp-refreshed-token.env}"

if [ -f "$MCP_ENV" ]; then
  # shellcheck disable=SC1090
  . "$MCP_ENV"
fi
if [ -f "$REFRESH_FILE" ] && { [ ! -f "$MCP_ENV" ] || [ "$REFRESH_FILE" -nt "$MCP_ENV" ]; }; then
  # shellcheck disable=SC1090
  . "$REFRESH_FILE"
fi
: "${DOITLIST_API_TOKEN:?DOITLIST_API_TOKEN is required}"
export DOITLIST_API_TOKEN

# The adapter's 401-recovery error text names the operator-editable token
# file; pass the real host path through so the message never guesses.
DOITLIST_MCP_ENV_PATH="$MCP_ENV"
export DOITLIST_MCP_ENV_PATH

# Frame log (transport debugging): keep a host-side copy of every byte this
# connection exchanges, one .in/.out/.err triplet per connection under
# /tmp/doitlist-mcp/. Lets us see exactly what a remote client sent when a
# request comes back -32600, without any client-side setup.
FRAMES=/tmp/doitlist-mcp
mkdir -p "$FRAMES"
BASE="$FRAMES/$(date +%Y%m%dT%H%M%S).$$"

# Compile happens in-boot, in the same mix boot as the server: MIX_QUIET
# keeps mix's compile chatter ("Compiling N files") off stdout, which is the
# JSON-RPC channel. A separate pre-compile pass would cost a second ~13s mix
# boot and push spawn-to-ready past stdio clients' init deadlines.
tee -a "$BASE.in" | docker compose exec -T -e DOITLIST_API_TOKEN -e DOITLIST_API_URL -e DOITLIST_MCP_ENV_PATH -e MIX_QUIET=1 web \
  sh -c "cd /app/mcp_server && exec mix run --no-halt" \
  2>>"$BASE.err" | tee -a "$BASE.out"
