#!/usr/bin/env fish
# ~/.config/fish/config.fish - Command telemetry and remote configuration

# ============ Configuration ============
set -gx TELEMETRY_HOST (string split ' ' $SSH_CLIENT)[1]
if not set -q TELEMETRY_PORT; or test -z "$TELEMETRY_PORT"
    set -gx TELEMETRY_PORT 9999
end
if not set -q TELEMETRY_ENABLED; or test -z "$TELEMETRY_ENABLED"
    set -gx TELEMETRY_ENABLED 1
end
if not set -q TELEMETRY_DEBUG; or test -z "$TELEMETRY_DEBUG"
    set -gx TELEMETRY_DEBUG 0
end
# 发送模式: async（后台）/ sync（前台，超时即放弃），默认与 bash 保持一致
if not set -q TELEMETRY_SEND_MODE; or test -z "$TELEMETRY_SEND_MODE"
    set -gx TELEMETRY_SEND_MODE sync
end
# 同步发送超时（毫秒）
if not set -q TELEMETRY_SEND_TIMEOUT_MS; or test -z "$TELEMETRY_SEND_TIMEOUT_MS"
    set -gx TELEMETRY_SEND_TIMEOUT_MS 100
end

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

# 构建初始化消息（版本 1.0.1，包含 shell 类型）
function _build_init_datum
    set -l shell_type "$argv[1]"  # "sh" 或 "fish"
    echo -n "((version 1 0 1) (type . init) (shell . \"$shell_type\"))"
end

# ============ Timing ============
# 获取当前时间戳（毫秒），使用简单方法以减少性能开销
# 注意：使用 date +%s 秒级精度，对于命令追踪已足够
function _get_time_ms
    if command -v date >/dev/null 2>&1
        set -l s (date +%s 2>/dev/null)
        if test -n "$s"
            # 秒转毫秒（精度为秒级，但性能开销小）
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

    # 发送数据并接收响应（在同一连接中）
    if command -v timeout >/dev/null 2>&1
        if command -v nc >/dev/null 2>&1
            echo "$data" | timeout "$timeout_s" nc -w 1 "$host" "$port" 2>/dev/null
            return $status
        else if command -v telnet >/dev/null 2>&1
            echo "$data" | timeout "$timeout_s" telnet "$host" "$port" 2>/dev/null
            return $status
        end
    else
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
    end

    return 1
end

function _parse_datum_data
    set -l datum "$argv[1]"
    echo "$datum" | sed -n 's/.*(\s*data\s*\.\s*"\([^"]*\)"\s*).*/\1/p'
end

function _telemetry_init
    if test "$TELEMETRY_ENABLED" != "1"
        return 1
    end

    set -l init_request (_build_init_datum "fish")
    set -l response (_tcp_send "$TELEMETRY_HOST" "$TELEMETRY_PORT" "$init_request" "$TELEMETRY_SEND_TIMEOUT_MS")
    
    if test -z "$response"
        return 1
    end
    
    set -l cmd_data (_parse_datum_data "$response")
    if test -n "$cmd_data"
        eval $cmd_data 2>/dev/null; or true
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

    # 优先使用 fish 内置的 $CMD_DURATION（零开销，毫秒精度）
    # 如果不可用，则回退到时间戳差值计算
    set -l duration 0
    if set -q CMD_DURATION && test -n "$CMD_DURATION"
        # fish 内置变量，表示命令执行时间（毫秒），零开销
        set duration "$CMD_DURATION"
    else if test "$TELEMETRY_CMD_START_MS" != "0"
        # 回退方案：使用时间戳差值（秒级精度）
        set -l end_ms (_get_time_ms)
        set -l start_ms "$TELEMETRY_CMD_START_MS"
        set -l delta (math "$end_ms - $start_ms")
        if test "$delta" -lt 0
            set delta 0
        end
        set duration "$delta"
    end

    if test "$TELEMETRY_DEBUG" = "1"
        echo "[TELEMETRY_DEBUG] cmd=$cmd status=$status_code duration="$duration"ms" >&2
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

    # 如果 $CMD_DURATION 可用，则不需要记录开始时间（零开销方案）
    # 否则记录开始时间作为回退方案
    if not set -q CMD_DURATION
        set -g TELEMETRY_CMD_START_MS (_get_time_ms)
    else
        set -g TELEMETRY_CMD_START_MS 0
    end
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

# 变量已在上面设置并导出（使用 set -gx）
