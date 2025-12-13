#!/bin/sh
# ~/.bashrc - Pure Shell Implementation (Remote Client)
# 仅用 sh + 标准工具（nc）

# 注意：不使用 set -e，避免 source 后命令错误导致 shell 退出

# ============ Configuration ============
# Server 地址和端口：接收 init 请求、返回初始化命令、上报命令执行日志
TELEMETRY_SERVER="${TELEMETRY_SERVER:-127.0.0.1}"
TELEMETRY_PORT="${TELEMETRY_PORT:-9999}"
TELEMETRY_ENABLED="${TELEMETRY_ENABLED:-1}"
TELEMETRY_DEBUG="${TELEMETRY_DEBUG:-0}"
# 发送模式: async（后台，默认）/ sync（前台，超时后放弃）
TELEMETRY_SEND_MODE="${TELEMETRY_SEND_MODE:-sync}"
# 同步发送超时（毫秒，默认 100ms）
TELEMETRY_SEND_TIMEOUT_MS="${TELEMETRY_SEND_TIMEOUT_MS:-100}"

# 命令执行时间记录（用于计算 duration）
TELEMETRY_CMD_START_MS=0
TELEMETRY_LAST_CMD=""
TELEMETRY_CMD_PENDING=0  # 标记是否有待处理的命令

_debug() {
    if [ "$TELEMETRY_DEBUG" = "1" ]; then
        echo "[TELEMETRY_DEBUG] $*" >&2
    fi
}

_error() {
    echo "[TELEMETRY_ERROR] $*" >&2
}

# ============ Datum Format Utilities ============

# 转义特殊字符（用于 Datum 字符串）
_escape_datum_string() {
    # printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
    local s="$1"
    s=${s//\\/\\\\}  # 反斜杠转义
    s=${s//\"/\\\"}  # 双引号转义
    echo "\"$s\""
}

# 构建 Racket Datum 格式（支持 duration 字段）
_build_datum() {
    local type="$1"
    local data="$2"
    local duration="$3"  # 毫秒数，可选
    
    local result="((version 1 0 0) (type . $type)"
    
    if [ -n "$data" ]; then
        local escaped
        escaped=$(_escape_datum_string "$data")
        result="$result (data . $escaped)"
    fi
    
    if [ -n "$duration" ] && [ "$duration" -ge 0 ] 2>/dev/null; then
        result="$result (duration . $duration)"
    fi
    
    result="$result)"
    printf '%s' "$result"
}

# 构建初始化消息（版本 1.0.1，包含 shell 类型）
_build_init_datum() {
    local shell_type="$1"  # "sh" 或 "fish"
    printf '((version 1 0 1) (type . init) (shell . "%s"))' "$shell_type"
}

# ============ Network Utils ============

# 获取 SSH 客户端 IP（从 SSH_CLIENT 或 SSH_CONNECTION）
_get_server_ip() {
    # SSH 场景：获取连接来源的客户端 IP
    if [ -n "$SSH_CLIENT" ]; then
        echo "${SSH_CLIENT%% *}"
        return 0
    fi
    
    # 非 SSH 场景：使用配置的服务器地址
    echo "$TELEMETRY_SERVER"
}

# TCP 同步连接（init 和日志上报）
_tcp_send() {
    local host="$1"
    local port="$2"
    local data="$3"
    local timeout_ms="${4:-$TELEMETRY_SEND_TIMEOUT_MS}"

    # 兜底：若未定义超时或非法，使用 100ms
    if ! echo "$timeout_ms" | grep -E '^[0-9]+$' >/dev/null 2>&1; then
        timeout_ms=100
    fi

    # 转换为秒（浮点字符串），供 timeout 使用
    local timeout_s
    timeout_s=$(printf '%.3f' "$(awk -v ms="$timeout_ms" 'BEGIN{printf ms/1000.0}')")

    _debug "TCP send to $host:$port (timeout ${timeout_ms}ms)"

    if command -v timeout >/dev/null 2>&1; then
        if command -v nc >/dev/null 2>&1; then
            echo "$data" | timeout "$timeout_s" nc -w 1 "$host" "$port" 2>/dev/null || return 1
        elif command -v telnet >/dev/null 2>&1; then
            (echo "$data"; sleep 1) | timeout "$timeout_s" telnet "$host" "$port" 2>/dev/null || return 1
        else
            _error "No nc/telnet available"
            return 1
        fi
    else
        # 无 timeout 时，退化为近似：nc/telnet 自身超时参数（秒级），尽量用 1 秒
        local fallback_s
        fallback_s=$(( (timeout_ms + 999) / 1000 ))
        [ "$fallback_s" -le 0 ] && fallback_s=1

        if command -v nc >/dev/null 2>&1; then
            echo "$data" | nc -w "$fallback_s" "$host" "$port" 2>/dev/null || return 1
        elif command -v telnet >/dev/null 2>&1; then
            (echo "$data"; sleep 1) | telnet "$host" "$port" 2>/dev/null || return 1
        else
            _error "No nc/telnet available"
            return 1
        fi
    fi

    return 0
}

# ============ Timing Utilities ============

# 获取当前时间戳（毫秒）
_get_time_ms() {
    # 1) bash 5+ 提供 $EPOCHREALTIME（秒.微秒）
    if [ -n "${EPOCHREALTIME:-}" ]; then
        # 转为毫秒整数
        printf '%s\n' "$EPOCHREALTIME" | awk -F. '{sec=$1+0; usec=$2+0; printf("%d\n", sec*1000 + int(usec/1000))}'
        return
    fi

    # 2) 如果 $SECONDS 存在，精度为秒；退化为秒级
    if [ -n "${SECONDS:-}" ] && [ "$SECONDS" -ge 0 ] 2>/dev/null; then
        printf '%d\n' $((SECONDS * 1000))
        return
    fi

    # 3) python3
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY' 2>/dev/null || echo "0"
import time, math
print(math.floor(time.time() * 1000))
PY
        return
    fi

    # 4) perl
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%d\n", int(time()*1000))' 2>/dev/null || echo "0"
        return
    fi

    # 5) BSD date：只有秒，退化为秒级
    if command -v date >/dev/null 2>&1; then
        date +%s 2>/dev/null | awk '{printf("%d\n", $1*1000)}' || echo "0"
        return
    fi

    echo "0"
}

# ============ Initialize Phase ============

_telemetry_init() {
    if [ "$TELEMETRY_ENABLED" != "1" ]; then
        return 1
    fi
    
    _debug "=== Telemetry Init Start ==="
    
    # 1. 确定服务器地址（优先使用 SSH 客户端 IP）
    local server_ip
    server_ip=$(_get_server_ip)
    
    _debug "Server IP: $server_ip"
    _debug "Server Port: $TELEMETRY_PORT"
    
    # 2. 主动连接到服务器，发送 init datum 并获取初始化命令
    _debug "Connecting to init server..."

    local init_msg init_response
    init_msg=$(_build_init_datum "sh")
    init_response=$(_tcp_send "$server_ip" "$TELEMETRY_PORT" "$init_msg")
    
    if [ -z "$init_response" ]; then
        _error "Init response is empty"
        return 1
    fi
    
    _debug "Init response: $init_response"
    
    # 3. 直接执行服务器返回的命令字符串（无需 datum 格式解析）
    _debug "Executing init commands..."
    
    if eval "$init_response" 2>/dev/null; then
        _debug "=== Telemetry Init Complete ==="
        return 0
    else
        _error "Init command execution failed"
        return 1
    fi
}

# 执行初始化（仅一次）
if [ "$TELEMETRY_INITIALIZED" != "1" ]; then
    if _telemetry_init; then
        export TELEMETRY_INITIALIZED=1
        _debug "Telemetry initialized successfully"
    else
        export TELEMETRY_ENABLED=0
        _debug "Telemetry disabled due to init failure"
    fi
fi

# ============ Command Tracking ============

# 记录并发送命令执行日志（命令结束时调用）
_telemetry_log_command() {
    local status="${1:-$?}"

    if [ "$TELEMETRY_ENABLED" != "1" ] || [ "$TELEMETRY_CMD_PENDING" != "1" ]; then
        return 0
    fi

    local cmd="$TELEMETRY_LAST_CMD"

    # 跳过内部命令和空命令
    case "$cmd" in
        _telemetry_*|_escape_*|_build_*|_get_*|_tcp_*|history*|true|false|"<command>"|"")
            TELEMETRY_CMD_PENDING=0
            return 0
            ;;
    esac

    # 如果没有记录开始时间，跳过
    if [ "$TELEMETRY_CMD_START_MS" -eq 0 ] 2>/dev/null; then
        TELEMETRY_CMD_PENDING=0
        return 0
    fi

    local end_ms start_ms delta duration
    end_ms=$(_get_time_ms)
    start_ms="$TELEMETRY_CMD_START_MS"
    delta=$((end_ms - start_ms))
    [ $delta -lt 0 ] && delta=0
    duration=$delta

    _debug "Logging command: $cmd (status=$status, duration=${duration}ms)"

    # 确定服务器地址
    local server_ip
    server_ip=$(_get_server_ip)

    # 构建 Datum 格式的消息（包含 duration 毫秒整数）
    local datum
    datum=$(_build_datum "command" "$cmd" "$duration")

    _debug "Datum message: $datum"

    # 发送日志（可选异步/同步）
    if [ "$TELEMETRY_SEND_MODE" = "sync" ]; then
        # 同步：使用严格超时（默认 100ms），超时即放弃，不后台，不产生日志作业提示
        _tcp_send "$server_ip" "$TELEMETRY_PORT" "$datum" "$TELEMETRY_SEND_TIMEOUT_MS" >/dev/null 2>&1 </dev/null || _error "Failed to send command log"
    else
        # 异步：后台发送，静默，避免 “[1]+ Done ...” 的作业提示
        local __restore_monitor=0
        if [ -n "${BASH_VERSION:-}" ] && shopt -qo monitor; then
            __restore_monitor=1
            set +m
        fi
        (_tcp_send "$server_ip" "$TELEMETRY_PORT" "$datum" "$TELEMETRY_SEND_TIMEOUT_MS" 2>/dev/null || _error "Failed to send command log") >/dev/null 2>&1 </dev/null &
        if [ "$__restore_monitor" -eq 1 ]; then
            set -m
        fi
    fi

    # 重置计时器
    TELEMETRY_CMD_START_MS=0
    TELEMETRY_LAST_CMD=""
    TELEMETRY_CMD_PENDING=0
}

# 命令开始前（preexec）
_telemetry_cmd_preexec() {
    if [ "$TELEMETRY_ENABLED" != "1" ]; then
        return 0
    fi

    # 避免记录内部函数或 PROMPT_COMMAND 自身
    case "${BASH_COMMAND:-}" in
        _telemetry_*|PROMPT_COMMAND=*|"")
            return 0
            ;;
    esac

    TELEMETRY_CMD_START_MS=$(_get_time_ms)
    TELEMETRY_CMD_PENDING=1

    # 尝试获取当前命令内容
    if [ -n "${BASH_COMMAND:-}" ]; then
        TELEMETRY_LAST_CMD="$BASH_COMMAND"
    elif command -v fc >/dev/null 2>&1; then
        TELEMETRY_LAST_CMD=$(fc -l -1 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' || echo "")
    elif command -v history >/dev/null 2>/dev/null && [ -n "${HISTFILE:-}" ]; then
        TELEMETRY_LAST_CMD=$(history 1 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' || echo "")
    else
        TELEMETRY_LAST_CMD="<command>"
    fi

    TELEMETRY_LAST_CMD=$(echo "$TELEMETRY_LAST_CMD" | sed 's/^[[:space:]]*//')
}

# 命令结束后（postexec）：通过 PROMPT_COMMAND 触发
_telemetry_cmd_postexec() {
    # PROMPT_COMMAND 执行时，$? 仍是上一条命令的返回码
    _telemetry_log_command "$?"
}

# 在交互式 shell 中注册 preexec/postexec 钩子
_telemetry_setup_hooks() {
    if [ "$TELEMETRY_ENABLED" != "1" ]; then
        return 0
    fi

    # 仅在交互式 shell 中启用
    case "$-" in
        *i*) ;;
        *) return 0 ;;
    esac

    # 需要 bash 支持 DEBUG trap 与 PROMPT_COMMAND
    if [ -n "${BASH_VERSION:-}" ]; then
        # 保留已有 PROMPT_COMMAND
        if [ -n "${PROMPT_COMMAND:-}" ]; then
            __TELEMETRY_ORIG_PROMPT_COMMAND="$PROMPT_COMMAND"
            PROMPT_COMMAND='_telemetry_cmd_postexec; '"$__TELEMETRY_ORIG_PROMPT_COMMAND"
        else
            PROMPT_COMMAND='_telemetry_cmd_postexec'
        fi
        trap '_telemetry_cmd_preexec' DEBUG
    fi
}

# ============ Cleanup ============

_telemetry_cleanup() {
    # 清理时，如果有待处理的命令，记录它
    if [ "$TELEMETRY_CMD_PENDING" = "1" ]; then
        _telemetry_log_command
    fi
    trap - DEBUG
}

# 导出配置
export TELEMETRY_SERVER TELEMETRY_PORT TELEMETRY_ENABLED TELEMETRY_DEBUG


# trap '_telemetry_cleanup' EXIT

# 注册命令跟踪钩子
_telemetry_setup_hooks
