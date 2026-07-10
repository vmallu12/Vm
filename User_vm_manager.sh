#!/bin/bash
set -e

# --------------------------------------------
# Configuration
# --------------------------------------------
VM_BASE_DIR="${VM_BASE_DIR:-$HOME/vms}"
SSH_DEFAULT_PORT=2222

mkdir -p "$VM_BASE_DIR"
VM_BASE_DIR=$(realpath "$VM_BASE_DIR")

# --------------------------------------------
# Minimal QEMU/KVM setup
# --------------------------------------------
install_qemu() {
    if command -v apk &>/dev/null; then
        apk add --no-cache qemu-system-x86_64 qemu-img curl genisoimage 2>/dev/null || true
    elif command -v apt &>/dev/null; then
        apt update 2>/dev/null
        apt install -y qemu-system-x86 qemu-utils curl genisoimage --no-install-recommends 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y qemu-kvm qemu-img curl genisoimage 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y qemu-kvm qemu-img curl genisoimage 2>/dev/null || true
    fi
}

check_kvm() {
    if [ ! -e /dev/kvm ]; then
        echo "❌ /dev/kvm missing – mount it with -v /dev/kvm:/dev/kvm" >&2
        exit 1
    fi
    if [ ! -w /dev/kvm ]; then
        echo "❌ /dev/kvm not writable – run with --privileged or --group-add=$(stat -c '%g' /dev/kvm)" >&2
        exit 1
    fi
}

# --------------------------------------------
# VM status and listing
# --------------------------------------------
get_vm_status() {
    local pid_file="$1/pid"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" >/dev/null 2>&1; then
            echo "running"
            return
        fi
    fi
    echo "stopped"
}

get_vm_list() {
    local vms=()
    if [[ -d "$VM_BASE_DIR" ]]; then
        for d in "$VM_BASE_DIR"/*/; do
            if [[ -f "$d/config.conf" ]]; then
                vms+=("$(basename "$d")")
            fi
        done
    fi
    echo "${vms[@]}"
}

# --------------------------------------------
# Select a VM (all UI to stderr)
# --------------------------------------------
select_vm() {
    local vms=($(get_vm_list))
    if [[ ${#vms[@]} -eq 0 ]]; then
        echo "📭 No VMs found." >&2
        return 1
    fi
    echo "📁 Available VMs:" >&2
    local i=1
    for name in "${vms[@]}"; do
        status=$(get_vm_status "$VM_BASE_DIR/$name")
        case "$status" in
            running) icon="▶️" ;;
            *) icon="💤" ;;
        esac
        echo "   $i) $name $icon" >&2
        ((i++))
    done
    local choice
    read -p "🎯 Select VM (number or name): " choice
    local selected=""
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice-1))
        if [[ $idx -ge 0 && $idx -lt ${#vms[@]} ]]; then
            selected="${vms[$idx]}"
        fi
    else
        for name in "${vms[@]}"; do
            if [[ "$name" == "$choice" ]]; then
                selected="$name"
                break
            fi
        done
    fi
    if [[ -n "$selected" && -d "$VM_BASE_DIR/$selected" && -f "$VM_BASE_DIR/$selected/config.conf" ]]; then
        echo "$selected"
        return 0
    else
        echo "❌ Invalid selection." >&2
        return 1
    fi
}

# --------------------------------------------
# Start / Restart a VM (always background)
# --------------------------------------------
start_vm() {
    local vm_name="$1"
    local vm_dir="$VM_BASE_DIR/$vm_name"
    source "$vm_dir/config.conf"

    local status=$(get_vm_status "$vm_dir")
    if [[ "$status" == "running" ]]; then
        echo "🔄 VM is already running – restarting..."
        local pid=$(cat "$vm_dir/pid")
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$vm_dir/pid"
    fi

    local cmd="qemu-system-x86_64"
    cmd+=" -enable-kvm -m $MEMORY -smp cores=$CPUS -cpu host"
    cmd+=" -drive file=$IMAGE,format=qcow2"
    [[ -f "$CLOUD_ISO" ]] && cmd+=" -cdrom $CLOUD_ISO"
    cmd+=" -nic user,hostfwd=tcp::$SSH_PORT-:22"
    if [[ -n "$EXTRA_PORTS" ]]; then
        IFS=',' read -ra ADDR <<< "$EXTRA_PORTS"
        for pair in "${ADDR[@]}"; do
            host_port=${pair%:*}
            guest_port=${pair#*:}
            cmd+=",hostfwd=tcp::$host_port-:$guest_port"
        done
    fi
    # Headless background: use -display none (works with -daemonize)
    if [[ "$GUI" == [yY] ]]; then
        cmd+=" -vnc :0"
        echo "🖥️  VNC on port 5900 (inside container)."
    else
        cmd+=" -display none"
    fi

    echo "🚀 Starting '$vm_name' (SSH port $SSH_PORT)..."
    cmd+=" -daemonize -pidfile $vm_dir/pid"
    eval $cmd
    sleep 1
    if [[ -f "$vm_dir/pid" ]]; then
        echo "✅ VM started (PID $(cat $vm_dir/pid))"
    else
        echo "❌ Failed to start."
    fi
}

# --------------------------------------------
# Stop a VM
# --------------------------------------------
stop_vm() {
    local vm_name="$1"
    local vm_dir="$VM_BASE_DIR/$vm_name"
    local status=$(get_vm_status "$vm_dir")
    if [[ "$status" != "running" ]]; then
        echo "⚠️  VM '$vm_name' is not running."
        return 0
    fi
    local pid=$(cat "$vm_dir/pid")
    echo "🛑 Stopping '$vm_name' (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$vm_dir/pid"
    echo "✅ Stopped."
}

# --------------------------------------------
# Main menu
# --------------------------------------------
main_menu() {
    echo ""
    echo "📋 Simple VM Control"
    echo "  1) Start (or restart) a VM"
    echo "  2) Stop a VM"
    echo "  0) Exit"
    read -p "🎯 Choice: " choice
    case "$choice" in
        1)
            local vm=$(select_vm) || return
            start_vm "$vm"
            ;;
        2)
            local vm=$(select_vm) || return
            stop_vm "$vm"
            ;;
        0)
            echo "Bye."
            exit 0
            ;;
        *)
            echo "❌ Invalid choice."
            ;;
    esac
}

# --------------------------------------------
# Init
# --------------------------------------------
init() {
    install_qemu
    check_kvm
    echo "✅ Simple VM manager ready (VMs in $VM_BASE_DIR)"
}

init
while true; do
    main_menu
    read -p "⏎ Press Enter to continue..."
done
