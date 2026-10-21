#!/bin/bash

while true
do
    echo "1. Check RAM"
    echo "2. Check Disk"
    echo "3. Check Uptime"
    echo "0. Exit"

    read -p "Choose option: " choice

    case $choice in
        1) free -h ;;
        2) df -h ;;
        3) uptime ;;
        0) exit ;;
        *) echo "Invalid options" ;;
    esac
done