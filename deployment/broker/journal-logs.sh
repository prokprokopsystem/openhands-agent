#!/usr/bin/bash
# Narrow root helper for the broker journal_logs Level A tool.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: journal-logs <service> <lines>" >&2
    exit 64
fi

service="$1"
lines="$2"

case "${service}" in
    openhands-agent|openhands-agent.service) ;;
    *)
        echo "ERROR: unsupported service" >&2
        exit 64
        ;;
esac

if ! [[ "${lines}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: lines must be an integer" >&2
    exit 64
fi

line_count=$((10#${lines}))
if [ "${line_count}" -lt 1 ] || [ "${line_count}" -gt 500 ]; then
    echo "ERROR: lines must be between 1 and 500" >&2
    exit 64
fi

exec /usr/bin/journalctl \
    --unit="${service}" \
    --lines="${line_count}" \
    --no-pager
