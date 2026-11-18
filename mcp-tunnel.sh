#!/bin/bash
# Self-healing SSH tunnel for Windows-MCP (no ControlMaster multiplexing).
# Forwards VM 127.0.0.1:18000 -> PC 127.0.0.1:8000 (Windows-MCP server).
#
# TEMPLATE — set these to your own values before use. Nothing in this file
# is specific to one setup: there are no hardcoded addresses, accounts,
# key paths, or proxy hostnames below.
#
# Required environment variables:
#   TAILSCALE_IP   your PC's Tailscale IP (the SSH target)
#   SSH_USER       the non-admin SSH account on the PC (key login, no password)
#   SSH_KEY        path to your SSH private key (0600)
# Optional:
#   EGRESS_PROXY   your VM's egress proxy host:port (host:port form).
#                  Set it only if your VM cannot reach the tailnet directly.
#                  If unset, ssh connects directly (no ProxyCommand).
#   SSH_CMD (default /usr/bin/ssh), TUNNEL_LOG, TUNNEL_MAX_INITIAL_FAILURES=10,
#   TUNNEL_BACKOFF_BASE=5, TUNNEL_BACKOFF_MAX=60
#
# EVENT-DRIVEN, NOT POLLING: this script is started ON DEMAND only — the
# agent runs it (via ensure-tunnel.sh) right before a desktop task. Nothing
# wakes up on a timer, no agent run, no tokens while it idles. While it runs,
# the loop below keeps itself alive: if ssh drops AFTER a successful
# connection, it reconnects with backoff, forever. If the PC was never
# reachable (off / Tailscale off / sshd down), it gives up after
# MAX_INITIAL_FAILURES consecutive fast failures and exits — the next
# on-demand check will try again. That is the whole watchdog: a dumb shell
# loop, not a cron.
set -u

if [ -z "${TAILSCALE_IP:-}" ]; then
  echo "error: TAILSCALE_IP is not set — set it to your PC's Tailscale IP before use" >&2
  exit 2
fi
if [ -z "${SSH_USER:-}" ]; then
  echo "error: SSH_USER is not set — set it to the non-admin SSH account on the PC" >&2
  exit 2
fi
if [ -z "${SSH_KEY:-}" ]; then
  echo "error: SSH_KEY is not set — set it to the path of your SSH private key (0600)" >&2
  exit 2
fi

SSH_CMD="${SSH_CMD:-/usr/bin/ssh}"
LOG="${TUNNEL_LOG:-$HOME/workspace/mcp-client/tunnel-restarts.log}"
PIDFILE="$HOME/workspace/mcp-client/mcp-tunnel.pid"
MAX_INITIAL_FAILURES="${TUNNEL_MAX_INITIAL_FAILURES:-10}"
BACKOFF_BASE="${TUNNEL_BACKOFF_BASE:-5}"
BACKOFF_MAX="${TUNNEL_BACKOFF_MAX:-60}"
CONNECTED_SECS="${TUNNEL_CONNECTED_SECS:-30}"

echo $$ >"$PIDFILE"

failures=0
reconnects=0
connected_once=0
delay="$BACKOFF_BASE"

log() { echo "$(date -Is) $*" >>"$LOG"; }

SSH_OPTS=(
  -i "$SSH_KEY"
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$HOME/.ssh/known_hosts"
  -o BatchMode=yes
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -L 18000:127.0.0.1:8000 -N
)
if [ -n "${EGRESS_PROXY:-}" ]; then
  SSH_OPTS+=(-o "ProxyCommand=nc -X connect -x $EGRESS_PROXY %h %p")
fi

while true; do
  start="$(date +%s)"
  "$SSH_CMD" "${SSH_OPTS[@]}" "$SSH_USER@$TAILSCALE_IP"
  rc=$?
  elapsed=$(( $(date +%s) - start ))

  # A run lasting >=CONNECTED_SECS counts as "was connected" (ssh -N only
  # exits on drop / clean close after that long); reset the never-connected
  # counter.
  if [ "$elapsed" -ge "$CONNECTED_SECS" ]; then
    connected_once=1
    failures=0
    delay="$BACKOFF_BASE"
    log "tunnel dropped after ${elapsed}s (exit $rc); reconnecting"
  else
    if [ "$connected_once" -eq 1 ]; then
      # Was connected before: the drop is transient (or the PC went off
      # mid-session). Keep retrying with backoff, forever, in this background
      # process — it costs no agent tokens. It only ends when the tunnel is
      # killed or the PC comes back.
      reconnects=$((reconnects + 1))
      log "tunnel down after ${elapsed}s (exit $rc), reconnect attempt $reconnects (was connected before, retrying)"
    else
      failures=$((failures + 1))
      log "tunnel ssh exited after ${elapsed}s (exit $rc), consecutive fast failure $failures/$MAX_INITIAL_FAILURES"
      if [ "$failures" -ge "$MAX_INITIAL_FAILURES" ]; then
        log "giving up: PC never reachable after $failures attempts; next on-demand check will retry"
        exit 1
      fi
    fi
  fi

  sleep "$delay"
  delay=$(( delay * 2 ))
  [ "$delay" -gt "$BACKOFF_MAX" ] && delay="$BACKOFF_MAX"
done
