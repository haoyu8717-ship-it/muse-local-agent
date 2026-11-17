#!/bin/bash
# Self-healing SSH tunnel for Windows-MCP (no ControlMaster multiplexing).
# Forwards VM 127.0.0.1:18000 -> PC 127.0.0.1:8000 (Windows-MCP server).
#
# EVENT-DRIVEN, NOT POLLING (Haoyu, 2026-11-17 17:42): this script is started
# ON DEMAND only — Muse runs it (via ensure-tunnel.sh) right before a desktop
# task. Nothing wakes up on a timer, no agent run, no tokens while it idles.
# While it runs, the loop below keeps itself alive: if ssh drops AFTER a
# successful connection, it reconnects with backoff, forever. If the PC was
# never reachable (off / Tailscale off / sshd down), it gives up after
# MAX_INITIAL_FAILURES consecutive fast failures and exits — the next
# on-demand check will try again. That is the whole watchdog: a dumb shell
# loop, not a cron.
#
# Env overrides (defaults shown) — used by tests, not normally set:
#   SSH_CMD (default /usr/bin/ssh), TUNNEL_LOG, TUNNEL_MAX_INITIAL_FAILURES=10,
#   TUNNEL_BACKOFF_BASE=5, TUNNEL_BACKOFF_MAX=60
set -u
SSH_CMD="${SSH_CMD:-/usr/bin/ssh}"
LOG="${TUNNEL_LOG:-/home/hatch/workspace/mcp-client/tunnel-restarts.log}"
PIDFILE="/home/hatch/workspace/mcp-client/mcp-tunnel.pid"
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

while true; do
  start="$(date +%s)"
  "$SSH_CMD" \
    -i /home/hatch/.ssh/cloud_bridge \
    -o "ProxyCommand=nc -X connect -x hatch-egress-proxy:3130 %h %p" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/home/hatch/.ssh/known_hosts \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -L 18000:127.0.0.1:8000 -N \
    muse-bridge@100.93.233.19
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
