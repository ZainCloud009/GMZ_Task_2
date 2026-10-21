#!/bin/bash

while true
do
    echo ""
    echo "===== Amazon Linux 2023 Manager ====="
    echo "1. Check System Info"
    echo "2. Check RAM and Swap"
    echo "3. Check Disk Space"
    echo "4. Check CPU Load and Uptime"
    echo "5. List Processes"
    echo "6. Search Process"
    echo "7. Inspect or Stop Process"
    echo "8. Check Listening Ports"
    echo "9. Check Port"
    echo "10. Check Service Status"
    echo "11. Start / Stop / Restart Service"
    echo "12. Network Information"
    echo "13. Ping a Host"
    echo "14. Check DNS"
    echo "15. Check Large Folders"
    echo "16. Check Recent System Logs"
    echo "17. Troubleshooting Summary"
    echo "0. Exit"

    read -r -p "Choose option: " choice

    case "$choice" in
        1)
            hostnamectl
            uname -a
            ;;
        2)
            free -h
            swapon --show
            ;;
        3)
            df -hT
            ;;
        4)
            uptime
            top -b -n 1 | head -n 12
            ;;
        5)
            ps aux --sort=-%cpu | head -n 15
            ;;
        6)
            read -r -p "Enter process name: " pname
            if [[ -n "$pname" ]]; then
                pgrep -a -f -- "$pname" || echo "No matching process found."
            else
                echo "Process name cannot be empty."
            fi
            ;;
        7)
            read -r -p "Enter PID: " pid
            if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                ps -p "$pid" -o pid,ppid,user,stat,%cpu,%mem,etime,cmd
                read -r -p "Stop this process? (y/N): " answer
                if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
                    kill -TERM "$pid" && echo "Stop signal sent."
                else
                    echo "No changes made."
                fi
            else
                echo "Invalid PID or process not found."
            fi
            ;;
        8)
            sudo ss -lntup
            ;;
        9)
            read -r -p "Enter port number (1-65535): " port
            if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
                sudo ss -lntup "sport = :$port"
            else
                echo "Invalid port number."
            fi
            ;;
        10)
            read -r -p "Enter service name (example: sshd): " service
            if [[ -n "$service" ]]; then
                systemctl status "$service" --no-pager
            else
                echo "Service name cannot be empty."
            fi
            ;;
        11)
            read -r -p "Enter service name: " service
            if [[ -n "$service" ]]; then
                echo "1. Start"
                echo "2. Stop"
                echo "3. Restart"
                read -r -p "Choose action: " action
                case "$action" in
                    1) sudo systemctl start "$service" ;;
                    2|3)
                        read -r -p "Confirm action on $service? (y/N): " answer
                        if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
                            if [[ "$action" == "2" ]]; then
                                sudo systemctl stop "$service"
                            else
                                sudo systemctl restart "$service"
                            fi
                        else
                            echo "No changes made."
                        fi
                        ;;
                    *) echo "Invalid action." ;;
                esac
            else
                echo "Service name cannot be empty."
            fi
            ;;
        12)
            ip -brief address
            ip route
            ;;
        13)
            read -r -p "Enter hostname or IP: " host
            if [[ -n "$host" ]]; then
                ping -c 4 "$host"
            else
                echo "Host cannot be empty."
            fi
            ;;
        14)
            read -r -p "Enter domain name: " domain
            if [[ -n "$domain" ]]; then
                getent hosts "$domain" || echo "DNS lookup failed."
            else
                echo "Domain cannot be empty."
            fi
            ;;
        15)
            sudo du -xhd1 / 2>/dev/null | sort -h | tail -n 10
            ;;
        16)
            sudo journalctl -p warning -n 30 --no-pager
            ;;
        17)
            echo "--- Disk space ---"
            df -hT
            echo "--- Memory ---"
            free -h
            echo "--- High CPU processes ---"
            ps aux --sort=-%cpu | head -n 8
            echo "--- Failed services ---"
            systemctl --failed --no-pager
            echo "--- Recent warnings/errors ---"
            sudo journalctl -p warning -n 15 --no-pager
            ;;
        0)
            echo "Goodbye."
            exit 0
            ;;
        *)
            echo "Invalid option. Please choose again."
            ;;
    esac

done
