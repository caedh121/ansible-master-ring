#!/bin/bash
# Probes each active SSM tunnel port to prevent SSM idle session timeout (60-min hard ceiling).
# Sends an HTTPS request to /wsman — WinRM returns 401 but bytes flow both ways, resetting the timer.
# Works for both HTTP and HTTPS WinRM targets: a TLS probe to an HTTP listener still sends data.
#
# Usage: ssm_keepalive.sh <state_dir> [interval_seconds]

STATE_DIR="${1:?STATE_DIR required}"
INTERVAL="${2:-900}"   # seconds between probe rounds, default 15 min
PID_FILE="${STATE_DIR}/ssm_keepalive.pid"
LOG_FILE="${STATE_DIR}/ssm_keepalive.log"

echo $$ > "$PID_FILE"
echo "[$(date -u +%FT%TZ)] keepalive started (state_dir=${STATE_DIR}, interval=${INTERVAL}s)" >> "$LOG_FILE"

probe_port() {
    local port="$1"
    local log="$2"
    curl -sk --max-time 5 -o /dev/null \
        "https://127.0.0.1:${port}/wsman" 2>/dev/null
    echo "[$(date -u +%FT%TZ)] probed port ${port} (exit $?)" >> "$log"
}
export -f probe_port

while true; do
    sleep "$INTERVAL"

    ports=$(find "${STATE_DIR}" -maxdepth 1 -name 'ssm_tunnel_*.port' -exec cat {} + 2>/dev/null | sort -u)
    if [ -z "$ports" ]; then
        echo "[$(date -u +%FT%TZ)] no port files found, skipping round" >> "$LOG_FILE"
        continue
    fi

    echo "$ports" | xargs -P 10 -I{} bash -c 'probe_port "$@"' _ {} "$LOG_FILE"
done
