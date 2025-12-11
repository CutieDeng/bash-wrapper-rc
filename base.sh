#!/bin/sh
# ~/.bashrc - Pure Shell Implementation (Remote Client)
# 仅用 sh + 标准工具（nc）

set -e

# ============ Configuration ============
# Server 地址和端口：接收 init 请求、返回初始化命令、上报命令执行日志
TELEMETRY_SERVER="${TELEMETRY_SERVER:-127.0.0.1}"
TELEMETRY_PORT="${TELEMETRY_PORT:-9999}"
TELEMETRY_ENABLED="${TELEMETRY_ENABLED:-1}"
TELEMETRY_DEBUG="${TELEMETRY_DEBUG:-0}"

# 命令执行时间记录（用于计算 duration）
TELEMETRY_CMD_START_TIME=0

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
    local timeout=5
    
    _debug "TCP send to $host:$port"
    
    # 使用 nc 建立连接并发送数据
    if command -v nc >/dev/null 2>&1; then
        echo "$data" | timeout "$timeout" nc -w 1 "$host" "$port" 2>/dev/null || return 1
    elif command -v telnet >/dev/null 2>&1; then
        (echo "$data"; sleep 1) | timeout "$timeout" telnet "$host" "$port" 2>/dev/null || return 1
    else
        _error "No nc/telnet available"
        return 1
    fi
    
    return 0
}

## Timing now uses $SECONDS (seconds precision). Removed _get_time_ms to avoid expensive calls.

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
    
    # 2. 主动连接到服务器，获取初始化命令
    _debug "Connecting to init server..."
    
    local init_response
    init_response=$(_tcp_send "$server_ip" "$TELEMETRY_PORT" "init")
    
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

# ============ Time Tracking ============

_telemetry_cmd_start() {
    if [ "$TELEMETRY_ENABLED" = "1" ]; then
        TELEMETRY_CMD_START_TIME=$SECONDS
    fi
}

# ============ Command Tracking ============

_telemetry_log_command() {
    if [ "$TELEMETRY_ENABLED" != "1" ]; then
        return 0
    fi
    
    local cmd="$BASH_COMMAND"
    
    # 跳过内部命令
    case "$cmd" in
        _telemetry_*|_escape_*|_build_*|_get_*|_tcp_*|history*|true|false)
            return 0
            ;;
    esac
    
    [ -z "$cmd" ] && return 0
    
    _debug "Logging command: $cmd"
    
    # 确定服务器地址
    local server_ip
    server_ip=$(_get_server_ip)
    
    # 计算命令执行时间（以 $SECONDS 为基准，精度为秒），将结果转换为毫秒整数
    local duration=0
    if [ "$TELEMETRY_CMD_START_TIME" -gt 0 ] 2>/dev/null; then
        local end_time
        end_time=$SECONDS
        local delta
        delta=$((end_time - TELEMETRY_CMD_START_TIME))
        [ $delta -lt 0 ] && delta=0
        duration=$((delta * 1000))
    fi

    _debug "Command duration: ${duration}ms"

    # 构建 Datum 格式的消息（包含 duration 毫秒整数）
    local datum
    datum=$(_build_datum "command" "$cmd" "$duration")
    
    _debug "Datum message: $datum"
    
    # 通过 TCP 发送日志
    _tcp_send "$server_ip" "$TELEMETRY_PORT" "$datum" 2>/dev/null || _error "Failed to send command log"
}

# ============ Cleanup ============

_telemetry_cleanup() {
    trap - DEBUG
}

# 导出配置
export TELEMETRY_SERVER TELEMETRY_PORT TELEMETRY_ENABLED TELEMETRY_DEBUG

trap '_telemetry_cleanup' EXIT

# 注册 trap 处理（命令执行前后）
trap '_telemetry_cmd_start' DEBUG
trap '_telemetry_log_command' DEBUG
