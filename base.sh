#!/bin/sh
# ~/.bashrc - Pure Shell Implementation
# 仅用 sh/bash + 标准工具（nc, dd, etc）

set -e

# ============ Configuration ============
TELEMETRY_SERVER="${TELEMETRY_SERVER:-127.0.0.1}"
TELEMETRY_PORT="${TELEMETRY_PORT:-9999}"
TELEMETRY_ENABLED="${TELEMETRY_ENABLED:-1}"
TELEMETRY_LOCAL_PORT=9998
TELEMETRY_UDP_PORT=9997
TELEMETRY_DEBUG="${TELEMETRY_DEBUG:-0}"

_debug() {
    if [ "$TELEMETRY_DEBUG" = "1" ]; then
        echo "[TELEMETRY_DEBUG] $*" >&2
    fi
}

_error() {
    echo "[TELEMETRY_ERROR] $*" >&2
}

# ============ Datum Format Utilities ============

# 转义特殊字符
_escape_datum_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# 构建 Datum 格式
_build_datum() {
    local type="$1"
    local data="$2"
    
    if [ -n "$data" ]; then
        local escaped
        escaped=$(_escape_datum_string "$data")
        printf '((version 1 0 0) (type . %s) (data . "%s"))' "$type" "$escaped"
    else
        printf '((version 1 0 0) (type . %s))' "$type"
    fi
}

# ============ Network Utils ============

# 获取本机可用 IP（优先级：局域网 > 回环）
_get_local_ip() {
    # 方法 1: 通过 SSH_CONNECTION 获取本地 IP
    if [ -n "$SSH_CONNECTION" ]; then
        echo "$SSH_CONNECTION" | awk '{print $3}'
        return 0
    fi
    
    # 方法 2: 使用 hostname -I
    if command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | awk '{print $1}' | head -1
        return 0
    fi
    
    # 方法 3: 通过 ifconfig（旧系统）
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -E "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}' | sed 's/.*://g'
        return 0
    fi
    
    # 降级: 回环地址
    echo "127.0.0.1"
}

# 获取 SSH 连接源 IP
_get_ssh_client_ip() {
    if [ -n "$SSH_CLIENT" ]; then
        echo "$SSH_CLIENT" | awk '{print $1}'
        return 0
    fi
    echo "127.0.0.1"
}

# TCP 同步连接（init 阶段）
_tcp_sync_connect() {
    local host="$1"
    local port="$2"
    local data="$3"
    local timeout=5
    
    _debug "TCP sync: $host:$port (timeout: ${timeout}s)"
    
    # 使用 exec 创建 TCP 连接
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

# UDP 异步发送（命令追踪）
_udp_async_send() {
    local host="$1"
    local port="$2"
    local data="$3"
    
    _debug "UDP async: $host:$port"
    
    if command -v nc >/dev/null 2>&1; then
        # nc -u: UDP 模式，-w 1: 1秒超时
        echo "$data" | timeout 1 nc -u -w 0 "$host" "$port" 2>/dev/null &
    elif command -v printf >/dev/null 2>&1 && command -v dd >/dev/null 2>&1; then
        # 降级方案：使用 /dev/udp（某些系统支持）
        (echo "$data" >/dev/udp/"$host"/"$port") 2>/dev/null &
    fi
}

# ============ Initialize Phase ============

_telemetry_init() {
    if [ "$TELEMETRY_ENABLED" != "1" ]; then
        return 1
    fi
    
    _debug "=== Telemetry Init Start ==="
    
    local local_ip
    local_ip=$(_get_local_ip)
    
    _debug "Local IP: $local_ip"
    _debug "Server: $TELEMETRY_SERVER:$TELEMETRY_PORT"
    
    # 1. 启动本地 TCP 监听（后台）
    _debug "Starting local listener on port $TELEMETRY_LOCAL_PORT..."
    
    # 创建 FIFO 用于读取服务器响应
    local fifo_path="/tmp/telemetry_init_$$.fifo"
    mkfifo "$fifo_path" 2>/dev/null || fifo_path="/tmp/telemetry_init_$$"
    
    # 2. 后台监听一次（只接收一条消息）
    (
        timeout 10 nc -l -p "$TELEMETRY_LOCAL_PORT" 2>/dev/null >"$fifo_path"
    ) &
    local listener_pid=$!
    
    _debug "Listener started (PID: $listener_pid)"
    
    # 给监听进程启动时间
    sleep 0.5
    
    # 3. 向服务器发送"就绪"信号：包含本地 IP:Port
    local ready_msg
    ready_msg=$(_build_datum "ready" "$local_ip:$TELEMETRY_LOCAL_PORT")
    
    _debug "Sending ready signal: $ready_msg"
    
    if ! _tcp_sync_connect "$TELEMETRY_SERVER" "$TELEMETRY_PORT" "$ready_msg"; then
        _error "Failed to send ready signal"
        kill $listener_pid 2>/dev/null || true
        rm -f "$fifo_path"
        return 1
    fi
    
    # 4. 等待服务器的 init 响应（从监听端口接收）
    _debug "Waiting for init response..."
    
    local response
    response=$(cat "$fifo_path" 2>/dev/null || true)
    
    # 等待监听进程完成
    wait $listener_pid 2>/dev/null || true
    
    _debug "Response received: $response"
    
    # 5. 清理 FIFO
    rm -f "$fifo_path"
    
    if [ -z "$response" ]; then
        _error "Init timeout or no response"
        return 1
    fi
    
    # 6. 解析响应中的 data 字段
    local cmd_data
    cmd_data=$(echo "$response" | sed -n 's/.*(\s*data\s*\.\s*"\([^"]*\)"\s*).*/\1/p')
    
    if [ -n "$cmd_data" ]; then
        _debug "Executing init commands: $cmd_data"
        
        # 在当前 shell 中执行（影响环境变量）
        eval "$cmd_data" 2>/dev/null || _error "Init command execution failed"
        
        _debug "=== Telemetry Init Complete ==="
        return 0
    else
        _error "No data field in init response"
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
        _telemetry_*|_escape_*|_build_*|_get_*|_tcp_*|_udp_*|history*|true|false)
            return 0
            ;;
    esac
    
    [ -z "$cmd" ] && return 0
    
    # 构建命令追踪 datum
    local datum
    datum=$(_build_datum "command" "$cmd")
    
    _debug "Logging command: $cmd"
    
    # 异步通过 UDP 发送（快速，无需等待）
    _udp_async_send "$TELEMETRY_SERVER" "$TELEMETRY_UDP_PORT" "$datum"
}

# 注册 DEBUG trap（每条命令执行后）
trap '_telemetry_log_command' DEBUG

# ============ Cleanup ============

_telemetry_cleanup() {
    trap - DEBUG
}

trap '_telemetry_cleanup' EXIT

# 导出配置
export TELEMETRY_SERVER TELEMETRY_PORT TELEMETRY_LOCAL_PORT TELEMETRY_UDP_PORT TELEMETRY_ENABLED TELEMETRY_DEBUG
