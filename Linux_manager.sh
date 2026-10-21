#!/usr/bin/env bash
# Amazon Linux 2023 System Management Tool
# Usage: chmod +x al2023_manager.sh && ./al2023_manager.sh
# Run as ec2-user; sudo is requested only for privileged actions.

set -o nounset
IFS=$'\n\t'

APP_NAME="Amazon Linux 2023 System Manager"
VERSION="1.1"

pause() { printf '\n'; read -r -p "Press Enter to continue..." _; }
header() {
    clear 2>/dev/null || true
    printf '%s\n' "============================================================"
    printf '  %s - v%s\n' "$APP_NAME" "$VERSION"
    printf '%s\n\n' "============================================================"
    printf '%s\n\n' "$1"
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_sudo() {
    if (( EUID == 0 )); then return 0; fi
    if ! have_cmd sudo; then echo "sudo is not available."; return 1; fi
    sudo -v || { echo "Sudo authentication failed or was cancelled."; return 1; }
}
confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}
valid_pid() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && kill -0 "$1" 2>/dev/null; }
valid_port() { [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_unit() { [[ "${1:-}" =~ ^[A-Za-z0-9_.@:-]+(\.(service|socket|target|timer))?$ ]]; }

# System monitoring
show_cpu() {
    header "CPU INFORMATION"
    if have_cmd lscpu; then
        lscpu | grep -E '^(Architecture|CPU\(s\)|On-line CPU|Thread|Core|Socket|Model name|CPU max MHz|Virtualization):' || lscpu
    else
        grep -m 1 '^model name' /proc/cpuinfo 2>/dev/null || true
        printf 'Logical CPU count: '; getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown
    fi
    printf '\nTop CPU-consuming processes:\n'
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 11
    pause
}
show_memory() {
    header "RAM AND SWAP"
    free -h
    printf '\nMemory details:\n'
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null || true
    pause
}
show_disk_usage() {
    header "DISK USAGE"
    df -hT -x tmpfs -x devtmpfs 2>/dev/null || df -h
    printf '\nBlock devices:\n'
    if have_cmd lsblk; then lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS; else echo "lsblk is unavailable."; fi
    pause
}
show_uptime_load() {
    header "UPTIME AND LOAD AVERAGE"
    uptime
    printf '\nLoad average (1, 5, 15 minutes): '
    awk '{print $1 ", " $2 ", " $3}' /proc/loadavg 2>/dev/null
    pause
}
show_system_info() {
    header "SYSTEM INFORMATION"
    printf 'Hostname: '; hostname 2>/dev/null || echo unknown
    printf 'Operating system: '
    if [[ -r /etc/os-release ]]; then . /etc/os-release; echo "${PRETTY_NAME:-Amazon Linux}"; else echo unknown; fi
    printf 'Kernel: '; uname -srmo
    printf 'Architecture: '; uname -m
    printf 'Current user: '; id
    printf 'Virtualization: '; systemd-detect-virt 2>/dev/null || echo unknown
    printf 'Instance identity metadata is not queried by this script.\n'
    pause
}
monitor_menu() {
    while true; do
        header "SYSTEM MONITORING"
        cat <<'MENU'
1) CPU information and top CPU processes
2) RAM and swap usage
3) Disk usage and block devices
4) Uptime and load average
5) System information
0) Back
MENU
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) show_cpu ;; 2) show_memory ;; 3) show_disk_usage ;;
            4) show_uptime_load ;; 5) show_system_info ;; 0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}

# Process management
list_processes() {
    header "RUNNING PROCESSES"
    ps -eo pid,ppid,user,stat,%cpu,%mem,etime,comm --sort=-%cpu | head -n 31
    echo "Showing up to 30 processes, sorted by CPU use."
    pause
}
search_processes() {
    local term
    header "SEARCH PROCESSES"
    read -r -p "Enter process name or command fragment: " term
    if [[ -z "$term" ]]; then echo "Search term cannot be empty."; pause; return; fi
    ps -eo pid,ppid,user,stat,%cpu,%mem,comm,args | grep -F -- "$term" | grep -v 'grep -F' || echo "No matching process found."
    pause
}
inspect_process() {
    local pid
    header "INSPECT PROCESS"
    read -r -p "Enter PID: " pid
    if ! valid_pid "$pid"; then echo "PID is invalid, inaccessible, or no longer exists."; pause; return; fi
    ps -p "$pid" -o pid,ppid,user,group,stat,%cpu,%mem,lstart,etime,cmd
    if [[ -r "/proc/$pid/status" ]]; then grep -E '^(Name|State|Threads|VmRSS|VmSize|Uid|Gid):' "/proc/$pid/status" || true; fi
    if have_cmd pstree; then printf '\nProcess tree:\n'; pstree -sp "$pid" 2>/dev/null || true; fi
    pause
}
terminate_process() {
    local pid
    header "TERMINATE PROCESS"
    read -r -p "Enter PID to terminate: " pid
    if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then echo "Enter a valid positive PID."; pause; return; fi
    if (( pid == 1 )); then echo "Refusing to signal PID 1."; pause; return; fi
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Process is missing or requires elevated permissions."
        if ! need_sudo; then pause; return; fi
        if ! sudo kill -0 "$pid" 2>/dev/null; then echo "Process does not exist."; pause; return; fi
    fi
    ps -p "$pid" -o pid,ppid,user,stat,comm,args 2>/dev/null || sudo ps -p "$pid" -o pid,ppid,user,stat,comm,args
    if ! confirm "Send SIGTERM to PID $pid?"; then echo Cancelled.; pause; return; fi
    if kill -TERM "$pid" 2>/dev/null; then echo "SIGTERM sent."
    elif need_sudo && sudo kill -TERM "$pid"; then echo "SIGTERM sent using sudo."
    else echo "Could not terminate process."; fi
    pause
}
process_menu() {
    while true; do
        header "PROCESS MANAGEMENT"
        cat <<'MENU'
1) List processes
2) Search processes
3) Inspect a process by PID
4) Terminate a process by PID (SIGTERM)
0) Back
MENU
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) list_processes ;; 2) search_processes ;; 3) inspect_process ;;
            4) terminate_process ;; 0) return ;; *) echo "Invalid option."; pause ;;
        esac
    done
}

# Port management
show_ports() {
    header "LISTENING PORTS AND ASSOCIATED PROCESSES"
    if have_cmd ss; then ss -lntup 2>/dev/null || ss -lntp
    elif have_cmd netstat; then netstat -lntup 2>/dev/null || netstat -lntp
    else echo "Install iproute (provides ss) to inspect listening ports."; fi
    echo "Some process details may require sudo."
    pause
}
find_port_process() {
    local port
    header "FIND PROCESS BY PORT"
    read -r -p "Enter TCP/UDP port (1-65535): " port
    if ! valid_port "$port"; then echo "Invalid port."; pause; return; fi
    if have_cmd lsof; then
        lsof -nP -i :"$port" 2>/dev/null || {
            echo "No result or permissions insufficient; retrying with sudo."
            if need_sudo; then sudo lsof -nP -i :"$port" 2>/dev/null || true; fi
        }
    elif have_cmd fuser; then fuser -v "$port"/tcp "$port"/udp 2>&1 || true
    elif have_cmd ss; then ss -lntup 2>/dev/null | awk -v p=":$port" 'index($0,p) {print}'
    else echo "Install lsof or iproute."; fi
    pause
}
kill_process_by_port() {
    local port pids pid
    header "TERMINATE PROCESS BY PORT"
    read -r -p "Enter port number (1-65535): " port
    if ! valid_port "$port"; then echo "Invalid port."; pause; return; fi
    if ! have_cmd lsof; then echo "Install lsof with: sudo dnf install -y lsof"; pause; return; fi
    pids="$(lsof -t -i :"$port" 2>/dev/null | sort -u || true)"
    if [[ -z "$pids" ]]; then
        if need_sudo; then pids="$(sudo lsof -t -i :"$port" 2>/dev/null | sort -u || true)"; fi
    fi
    if [[ -z "$pids" ]]; then echo "No process found on port $port."; pause; return; fi
    echo "Processes using port $port:"
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        ps -p "$pid" -o pid,ppid,user,stat,comm,args 2>/dev/null || sudo ps -p "$pid" -o pid,ppid,user,stat,comm,args
    done <<< "$pids"
    echo "Warning: a process may serve other ports or users too."
    if ! confirm "Send SIGTERM to the process(es) listed above?"; then echo Cancelled.; pause; return; fi
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        if kill -TERM "$pid" 2>/dev/null; then echo "SIGTERM sent to PID $pid."
        elif need_sudo && sudo kill -TERM "$pid"; then echo "SIGTERM sent to PID $pid using sudo."
        else echo "Could not signal PID $pid."; fi
    done <<< "$pids"
    pause
}
port_menu() {
    while true; do
        header "PORT MANAGEMENT"
        cat <<'MENU'
1) List listening ports
2) Find processes using a port
3) Terminate process(es) using a port (SIGTERM)
0) Back
MENU
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) show_ports ;; 2) find_port_process ;; 3) kill_process_by_port ;;
            0) return ;; *) echo "Invalid option."; pause ;;
        esac
    done
}

# systemd services
list_services() { header "SYSTEMD SERVICES"; systemctl list-units --type=service --all --no-pager; pause; }
service_status() {
    local unit
    header "INSPECT SYSTEMD SERVICE"
    read -r -p "Enter service unit (e.g. sshd.service or crond.service): " unit
    if ! valid_unit "$unit"; then echo "Invalid unit name."; pause; return; fi
    systemctl status --no-pager --full "$unit"
    pause
}
service_action() {
    local action="$1" unit
    header "${action^^} SYSTEMD SERVICE"
    read -r -p "Enter service unit (e.g. sshd.service): " unit
    if ! valid_unit "$unit"; then echo "Invalid unit name."; pause; return; fi
    if ! systemctl cat "$unit" >/dev/null 2>&1; then echo "Unit not found or unreadable."; pause; return; fi
    if ! confirm "Run systemctl $action $unit?"; then echo Cancelled.; pause; return; fi
    if need_sudo; then sudo systemctl "$action" "$unit" && echo "Command completed." || echo "Command failed; inspect the journal."; fi
    pause
}
service_logs() {
    local unit
    header "SERVICE JOURNAL"
    read -r -p "Enter service unit (e.g. sshd.service): " unit
    if ! valid_unit "$unit"; then echo "Invalid unit name."; pause; return; fi
    journalctl -u "$unit" -n 80 --no-pager
    pause
}
service_menu() {
    while true; do
        header "SERVICE MANAGEMENT (systemd)"
        cat <<'MENU'
1) List services
2) Start service
3) Stop service
4) Restart service
5) Inspect service status
6) View recent service logs
0) Back
MENU
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) list_services ;; 2) service_action start ;; 3) service_action stop ;;
            4) service_action restart ;; 5) service_status ;; 6) service_logs ;;
            0) return ;; *) echo "Invalid option."; pause ;;
        esac
    done
}

# Network tools
show_ip_addresses() {
    header "NETWORK INTERFACES AND IP ADDRESSES"
    if have_cmd ip; then ip -brief address; printf '\nRoutes:\n'; ip route
    else hostname -I 2>/dev/null || echo "ip command unavailable."; fi
    printf '\nInstance private/public addressing is managed by EC2 networking.\n'
    pause
}
show_connections() {
    header "ACTIVE NETWORK CONNECTIONS"
    if have_cmd ss; then ss -tunap
    elif have_cmd netstat; then netstat -tunap 2>/dev/null || netstat -tuna
    else echo "Install iproute."; fi
    pause
}
check_connectivity() {
    local host
    header "CHECK CONNECTIVITY"
    read -r -p "Enter hostname or IP (e.g. amazon.com): " host
    if [[ -z "$host" || "$host" =~ [[:space:]] || "$host" == -* ]]; then echo "Invalid host."; pause; return; fi
    if ! have_cmd ping; then echo "ping is unavailable. Install iputils."; pause; return; fi
    ping -c 4 -W 2 -- "$host"
    local rc=$?
    if (( rc == 0 )); then echo "Ping succeeded."; else echo "Ping failed. ICMP may be blocked by network rules even if the host is reachable."; fi
    if have_cmd getent; then printf '\nDNS lookup:\n'; getent ahosts "$host" | head -n 10 || true; fi
    pause
}
network_menu() {
    while true; do
        header "NETWORK TOOLS"
        cat <<'MENU'
1) Show IP addresses and routes
2) Show active connections
3) Check connectivity (ping and DNS)
0) Back
MENU
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) show_ip_addresses ;; 2) show_connections ;; 3) check_connectivity ;;
            0) return ;; *) echo "Invalid option."; pause ;;
        esac
    done
}

# Disk and logs
find_large_files() {
    local directory limit
    header "FIND LARGE FILES"
    read -r -p "Directory to scan (default /var): " directory
    directory="${directory:-/var}"
    if [[ ! -d "$directory" ]]; then echo "Directory does not exist."; pause; return; fi
    read -r -p "Minimum size (e.g. +100M or +1G; default +100M): " limit
    limit="${limit:-+100M}"
    if ! [[ "$limit" =~ ^\+[0-9]+([kKmMgGtT])?$ ]]; then echo "Invalid size."; pause; return; fi
    echo "Scanning '$directory' (permission errors may be skipped)..."
    find "$directory" -xdev -type f -size "$limit" -printf '%s bytes\t%p\n' 2>/dev/null |
        sort -nr | head -n 50 | awk -F '\t' '{printf "%10.2f MiB  %s\n", $1/1048576, $2}'
    pause
}
view_system_logs() {
    local lines
    header "RECENT SYSTEM LOGS"
    read -r -p "Number of lines (default 100, max 1000): " lines
    lines="${lines:-100}"
    if ! [[ "$lines" =~ ^[0-9]+$ ]] || (( lines < 1 || lines > 1000 )); then echo "Enter 1-1000."; pause; return; fi
    journalctl -n "$lines" --no-pager
    pause
}
view_errors() {
    local since
    header "RECENT SYSTEM ERRORS"
    read -r -p "Look-back period (e.g. 30 minutes, 2 hours, 7 days; default 24 hours): " since
    since="${since:-24 hours}"
    if ! [[ "$since" =~ ^[0-9]+[[:space:]]+(minutes?|hours?|days?)$ ]]; then echo "Invalid period."; pause; return; fi
    journalctl -p err --since "$since" --no-pager
    pause
}
high_resource_usage() {
    header "HIGH RESOURCE USAGE SNAPSHOT"
    echo "Top CPU consumers:"
    ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 11
    printf '\nTop memory consumers:\n'
    ps -eo pid,user,%mem,%cpu,comm --sort=-%mem | head -n 11
    printf '\nMemory:\n'; free -h
    printf '\nFilesystems at 80%% or more:\n'
    df -hP -x tmpfs -x devtmpfs | awk 'NR==1 || $5 ~ /^[89][0-9]%$/ || $5 ~ /^100%$/'
    printf '\nLoad and uptime:\n'; uptime
    pause
}
disk_logs_menu() {
    while true; do
        header "DISK AND LOG ANALYSIS"
        cat <<'MENU'
1) Check filesystem usage
2) Find large files
3) View recent system logs
4) Show system errors by time period
5) High resource usage snapshot
0) Back
MENU
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) show_disk_usage ;; 2) find_large_files ;; 3) view_system_logs ;;
            4) view_errors ;; 5) high_resource_usage ;; 0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}

main_menu() {
    while true; do
        header "MAIN MENU"
        cat <<'MENU'
1) System monitoring
2) Process management
3) Port management
4) Service management
5) Network tools
6) Disk management and logs
7) Quick system health summary
8) Usage, dependencies, and safety notes
0) Exit
MENU
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) monitor_menu ;; 2) process_menu ;; 3) port_menu ;;
            4) service_menu ;; 5) network_menu ;; 6) disk_logs_menu ;;
            7)
                header "QUICK SYSTEM HEALTH SUMMARY"
                uptime; free -h; df -hP -x tmpfs -x devtmpfs
                printf '\nTop CPU processes:\n'; ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 6
                printf '\nRecent errors:\n'; journalctl -p err -n 10 --no-pager 2>/dev/null || echo "Could not read journal."
                pause
                ;;
            8)
                header "USAGE AND SAFETY"
                cat <<'NOTES'
Run as ec2-user:
  chmod +x al2023_manager.sh
  ./al2023_manager.sh

Optional diagnostic utilities:
  sudo dnf install -y lsof psmisc iproute procps-ng iputils findutils

Notes:
- Designed for Amazon Linux 2023 and systemd.
- Use sudo only when a selected administrative operation requires it.
- Process termination uses SIGTERM; SIGKILL is not used.
- Service stop/restart can interrupt applications.
- The script is read-only for disk analysis; it does not delete files.
- Some process/socket/log details may require sudo.
- EC2 security groups, network ACLs, and routes are not modified by this script.
- Ping can fail if ICMP is blocked by the target or network rules.
NOTES
                pause
                ;;
            0) echo "Exiting $APP_NAME."; exit 0 ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}
main_menu
