#!/usr/bin/env bash
# =============================================
#  Docker → VM Manager (User Version)
#  Only Start / Stop / Console – shows specs
#  Usage: bash <(curl -fsSL https://raw.githubusercontent.com/Vmallu00/pterodactyl/master/user_vm_manager.sh)
# =============================================

set -e

VM_DIR="${HOME}/docker-vms"
PID_FILE="${VM_DIR}/vm.pid"
CONSOLE_TYPE="serial"   # Must match admin script

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- Show VM Specs ----------
show_specs() {
    VM_NAME=$(cat "${VM_DIR}/current_vm.name" 2>/dev/null)
    if [ -z "$VM_NAME" ]; then
        echo -e "${RED}No VM found. Please contact the administrator.${NC}"
        exit 1
    fi

    CONFIG="${VM_DIR}/${VM_NAME}.conf"
    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}Configuration file missing. Contact admin.${NC}"
        exit 1
    fi

    source "$CONFIG"
    echo "========================================="
    echo -e "  ${GREEN}VM Name:${NC}     $VM_NAME"
    echo -e "  ${GREEN}CPU:${NC}         $CPU_CORES cores"
    echo -e "  ${GREEN}RAM:${NC}         $RAM_MB MB"
    echo -e "  ${GREEN}Disk:${NC}        $DISK_SIZE"
    echo -e "  ${GREEN}User:${NC}        $VM_USER"
    echo -e "  ${GREEN}SSH enabled:${NC} $ENABLE_SSH"
    echo "========================================="
}

# ---------- Start VM ----------
start_vm() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${YELLOW}VM is already running.${NC}"
        return
    fi

    VM_NAME=$(cat "${VM_DIR}/current_vm.name" 2>/dev/null)
    if [ -z "$VM_NAME" ]; then
        echo -e "${RED}No VM found.${NC}"
        return
    fi

    source "${VM_DIR}/${VM_NAME}.conf"
    if [ ! -f "$OUTPUT_IMAGE" ]; then
        echo -e "${RED}Image file not found.${NC}"
        return
    fi

    echo -e "${GREEN}Starting VM...${NC}"
    QEMU_OPTS="-m $RAM_MB -smp cores=$CPU_CORES -drive file=$OUTPUT_IMAGE,format=qcow2 -netdev user,id=net0 -device virtio-net-pci,netdev=net0"

    if [ "$CONSOLE_TYPE" = "vnc" ]; then
        qemu-system-x86_64 $QEMU_OPTS -vnc :0 -daemonize
        echo $! > "$PID_FILE"
        echo -e "${GREEN}Started on VNC :0${NC}"
    else
        screen -dmS docker-vm qemu-system-x86_64 $QEMU_OPTS -nographic -serial mon:stdio
        echo "screen" > "$PID_FILE"
        echo -e "${GREEN}Started in screen session 'docker-vm'${NC}"
    fi
}

# ---------- Stop VM ----------
stop_vm() {
    if [ ! -f "$PID_FILE" ]; then
        echo -e "${YELLOW}No VM is running.${NC}"
        return
    fi

    PID=$(cat "$PID_FILE")
    if [ "$PID" = "screen" ]; then
        screen -S docker-vm -X quit 2>/dev/null && echo -e "${GREEN}VM stopped.${NC}"
        rm -f "$PID_FILE"
    else
        kill "$PID" 2>/dev/null && echo -e "${GREEN}VM stopped.${NC}" || echo -e "${YELLOW}Already stopped.${NC}"
        rm -f "$PID_FILE"
    fi
}

# ---------- Console ----------
console_vm() {
    if [ "$CONSOLE_TYPE" = "vnc" ]; then
        if command -v vncviewer &>/dev/null; then
            vncviewer localhost:0
        else
            echo -e "${RED}vncviewer not installed.${NC}"
        fi
    else
        if screen -list | grep -q docker-vm; then
            screen -r docker-vm
        else
            echo -e "${RED}No screen session found. VM not running.${NC}"
        fi
    fi
}

# ---------- Menu ----------
show_menu() {
    clear
    show_specs
    echo " 1. Start VM"
    echo " 2. Stop VM"
    echo " 3. Console"
    echo " 4. Exit"
    echo "========================================="
    read -p "Choose option [1-4]: " opt
    case $opt in
        1) start_vm ;;
        2) stop_vm ;;
        3) console_vm ;;
        4) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
    read -p "Press Enter to continue..."
}

# ---------- Main ----------
if ! command -v screen &>/dev/null || ! command -v qemu-system-x86_64 &>/dev/null; then
    echo -e "${RED}Missing dependencies: screen or qemu-system-x86_64${NC}"
    echo "Install: sudo apt install screen qemu-system-x86 qemu-utils"
    exit 1
fi

mkdir -p "$VM_DIR"
while true; do show_menu; done
