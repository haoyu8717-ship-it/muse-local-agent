#!/bin/bash
# On-demand tunnel check for Windows-MCP. Idempotent; safe to call any time.
# Forwards VM 127.0.0.1:18000 -> PC 127.0.0.1:8000 (Windows-MCP server).
#
# CALL THIS ONLY BEFORE A DESKTOP TASK. There is deliberately NO cron and NO
# polling behind it (Haoyu, 2026-11-17 17:42: a 5-minute check would be 288
# agent runs/day and burn his token quota — rejected in favour of the
# WeChat model: wake on demand, silent otherwise).
#
# How it works: this script starts mcp-tunnel.sh if it is not already
# running. mcp-tunnel.sh IS the loop (self-healing, backoff, give-up after
# 10 fast failures when the PC was never reachable) — there is no separate
# supervisor and no systemd. The loop is a dumb shell process: no agent,
# no tokens while it runs. After a VM replacement the loop is gone; the
# next on-demand call restarts it.
#
# Detection uses a PID file (mcp-tunnel.sh writes its own PID), NOT pgrep:
# pgrep -f matches this very script's own command line and gives false
# positives when run from an agent exec call.
#
# Exit codes: 0 = tunnel listening on 18000; 2 = started it but no listener
# within 10s (PC likely off / Tailscale off / sshd down / MCP server down —
# check those first, do NOT retry in a loop here; the loop keeps retrying
# in the background, and the next on-demand call tries again).
# Every (re)start is logged to tunnel-restarts.log so stuck points are
# remembered.
set -u
TUNNEL_SCRIPT="/home/hatch/.local/bin/mcp-tunnel.sh"
PIDFILE="/home/hatch/workspace/mcp-client/mcp-tunnel.pid"
LOG="/home/hatch/workspace/mcp-client/tunnel-restarts.log"

# Tunnel is up if something is listening on 18000.
if ss -ltn 2>/dev/null | grep -q ':18000 '; then
  exit 0
fi

# Loop already running? Check its PID file.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  for _ in $(seq 1 10); do
    sleep 1
    if ss -ltn 2>/dev/null | grep -q ':18000 '; then
      exit 0
    fi
  done
  exit 2
fi

# Start the loop detached (no systemd: /etc does not survive VM replacement).
setsid "$TUNNEL_SCRIPT" >>"$LOG" 2>&1 </dev/null &
echo "$(date -Is) tunnel loop (re)started on demand" >>"$LOG"

for _ in $(seq 1 10); do
  sleep 1
  if ss -ltn 2>/dev/null | grep -q ':18000 '; then
    exit 0
  fi
done
exit 2
