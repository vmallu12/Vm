#!/bin/bash
set -e

# --------------------------------------------
# Configuration
# --------------------------------------------
VM_BASE_DIR="${VM_BASE_DIR:-$HOME/vms}"
SSH_DEFAULT_PORT=2222

# Ensure base directory exists and is absolute
mkdir -p "$VM_BASE_DIR"
VM_BASE_DIR=$(realpath "$VM_BASE_DIR")

# --------------------------------------------
# 1. OS detection & minimal QEMU install
# --------------------------------------------
install_qemu() {
    if command -v apk &>/dev/null; then
        apk add --no-cache qemu-system-x86_64 qemu-img curl genisoimage
    elif command -v apt &>/dev/null; then
        apt update
        apt install -y qemu-system-x86 qemu-utils curl genisoimage --no-install-recommends
    elif command -v dnf &>/dev/null; then
        dnf install -y qemu-kvm qemu-img curl genisoimage
    elif command -v yum &>/dev/null; then
        yum install -y qemu-kvm qemu-img curl genisoimage
    else
        echo "❌ Unsupported OS. Install QEMU manually."
        exit 1
    fi
}

check_kvm() {
    if [ ! -e /dev/kvm ]; then
        echo "❌ /dev/kvm missing – mount it with -v /dev/kvm:/dev/kvm"
        exit 1
    fi
    if [ ! -w /dev/kvm ]; then
        echo "❌ /dev/kvm not writable – run with --privileged or --group-add=$(stat -c '%g' /dev/kvm)"
        exit 1
    fi
}

# --------------------------------------------
# 2. Helpers
# --------------------------------------------
find_free_port() {
    local port=$1
    while ss -lntn | grep -q ":$port "; do
        ((port++))
    done
    echo "$port"
}

get_image_url() {
    case "$1" in
        1|ubuntu22) echo "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" ;;
        2|almalinux9) echo "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2" ;;
        3|centosstream9) echo "https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2" ;;
        4|ubuntu24) echo "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
        5|rocky9) echo "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2" ;;
        6|fedora40) echo "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2" ;;
        7|debian11) echo "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2" ;;
        8|debian13) echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-trixie-genericcloud-amd64.qcow2" ;;
        9|debian12) echo "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2" ;;
        10|alpine) echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-virt-3.20.2-x86_64.qcow2" ;;
        *) echo "" ;;
    esac
}

download_image() {
    local url="$1" dest="$2" size="$3"
    if [[ ! -f "$dest" ]]; then
        echo "⬇️  Downloading image..."
        curl -L -o "${dest}.tmp" "$url"
        mv "${dest}.tmp" "$dest"
        qemu-img resize "$dest" "$size"
    fi
}

# --------------------------------------------
# 3. Cloud-init ISO generation (for Ubuntu/Debian)
# --------------------------------------------
create_cloud_init_iso() {
    local vm_dir="$1" username="$2" password="$3" hostname="$4"
    mkdir -p "$vm_dir/cloud-init"
    cat > "$vm_dir/cloud-init/meta-data" <<EOF
instance-id: $hostname
local-hostname: $hostname
EOF
    local hashed
    if command -v openssl &>/dev/null; then
        hashed=$(echo "$password" | openssl passwd -6 -stdin 2>/dev/null)
    fi
    if [[ -z "$hashed" ]]; then
        hashed="$password"
    fi
    cat > "$vm_dir/cloud-init/user-data" <<EOF
#cloud-config
users:
  - name: $username
    passwd: "$hashed"
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
ssh_pwauth: true
chpasswd:
  expire: false
EOF
    (cd "$vm_dir/cloud-init" && genisoimage -output seed.iso -volid cidata -joliet -rock meta-data user-data 2>/dev/null || mkisofs -output seed.iso -volid cidata -joliet -rock meta-data user-data)
    echo "$vm_dir/cloud-init/seed.iso"
}

# --------------------------------------------
# 4. VM status and listing
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
# 5. Interactive selection (FIXED)
# --------------------------------------------
select_vm() {
    local vms=($(get_vm_list))
    if [[ ${#vms[@]} -eq 0 ]]; then
        echo "📭 No VMs found." >&2
        return 1
    fi
    echo "📁 Found ${#vms[@]} VM(s):" >&2
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
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice-1))
        if [[ $idx -ge 0 && $idx -lt ${#vms[@]} ]]; then
            echo "${vms[$idx]}"
            return 0
        fi
    else
        for name in "${vms[@]}"; do
            if [[ "$name" == "$choice" ]]; then
                echo "$name"
                return 0
            fi
        done
    fi
    echo "❌ Invalid selection." >&2
    return 1
}

# --------------------------------------------
# 6. VM operations
# --------------------------------------------
create_vm() {
    echo "🆕 Creating a new VM"
    echo "🌍 Select OS:"
    echo "  1) Ubuntu 22.04"
    echo "  2) AlmaLinux 9"
    echo "  3) CentOS Stream 9"
    echo "  4) Ubuntu 24.04"
    echo "  5) Rocky Linux 9"
    echo "  6) Fedora 40"
    echo "  7) Debian 11"
    echo "  8) Debian 13 (trixie)"
    echo "  9) Debian 12"
    echo "  10) Alpine"
    read -p "🎯 Enter choice (1-10): " os_choice
    local url=$(get_image_url "$os_choice")
    if [[ -z "$url" ]]; then
        echo "❌ Invalid choice."
        return 1
    fi

    read -p "🏷️  VM name: " vm_name
    if [[ -z "$vm_name" ]]; then
        echo "❌ Name required."
        return 1
    fi
    local vm_dir="$VM_BASE_DIR/$vm_name"
    if [[ -d "$vm_dir" ]]; then
        echo "❌ VM already exists."
        return 1
    fi
    mkdir -p "$vm_dir"

    read -p "🏠 Hostname (default: $vm_name): " hostname
    hostname=${hostname:-$vm_name}
    read -p "👤 Username (default: root): " username
    username=${username:-root}
    read -p "🔑 Password (default: root): " password
    password=${password:-root}
    read -p "💾 Disk size (default: 20G): " disk
    disk=${disk:-20G}
    read -p "🧠 Memory MB (default: 2048): " mem
    mem=${mem:-2048}
    read -p "⚡ CPUs (default: 2): " cpus
    cpus=${cpus:-2}

    local ssh_port
    while true; do
        read -p "🔌 SSH Port (default: $SSH_DEFAULT_PORT): " ssh_port
        ssh_port=${ssh_port:-$SSH_DEFAULT_PORT}
        local free=$(find_free_port "$ssh_port")
        if [[ "$free" -eq "$ssh_port" ]]; then
            break
        else
            echo "⚠️  Port $ssh_port busy, using $free instead."
            ssh_port=$free
            break
        fi
    done

    read -p "🖥️  GUI? (y/n, default: n): " gui
    gui=${gui:-n}
    read -p "🌐 Extra port forwards (e.g., 8080:80): " extra_ports

    local image_file="$vm_dir/disk.qcow2"
    download_image "$url" "$image_file" "$disk"

    local cloud_iso=""
    if [[ "$os_choice" =~ ^(1|4|7|8|9)$ ]]; then
        echo "📝 Generating cloud-init ISO..."
        cloud_iso=$(create_cloud_init_iso "$vm_dir" "$username" "$password" "$hostname")
    fi

    cat > "$vm_dir/config.conf" <<EOF
VM_NAME=$vm_name
HOSTNAME=$hostname
USERNAME=$username
PASSWORD=$password
DISK=$disk
MEMORY=$mem
CPUS=$cpus
SSH_PORT=$ssh_port
GUI=$gui
EXTRA_PORTS=$extra_ports
IMAGE=$image_file
CLOUD_ISO=$cloud_iso
OS_CHOICE=$os_choice
EOF
    echo "✅ VM '$vm_name' created successfully."
    echo "🔑 Login: $username / $password"
    echo "🔌 SSH: ssh -p $ssh_port $username@localhost"
}

start_vm() {
    local vm_name=$(select_vm) || return 1
    local vm_dir="$VM_BASE_DIR/$vm_name"
    local status=$(get_vm_status "$vm_dir")
    if [[ "$status" == "running" ]]; then
        echo "⚠️  VM is already running."
        return 0
    fi
    source "$vm_dir/config.conf"

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
    # Floppy disabled – we don't add -fda at all
    if [[ "$GUI" == [yY] ]]; then
        cmd+=" -vnc :0"
        echo "🖥️  VNC on port 5900 (inside container)."
    else
        cmd+=" -nographic"
    fi

    echo "🚀 Starting VM '$vm_name' (SSH port $SSH_PORT)..."
    read -p "Run in background? (y/n, default n): " bg
    if [[ "$bg" == [yY] ]]; then
        cmd+=" -daemonize -pidfile $vm_dir/pid"
        eval $cmd
        sleep 1
        if [[ -f "$vm_dir/pid" ]]; then
            echo "✅ VM started in background (PID $(cat $vm_dir/pid))"
        else
            echo "❌ Failed to start."
        fi
    else
        echo "🔴 VM console below. Press Ctrl+A then X to exit (or Ctrl+C to stop)."
        sleep 2
        exec $cmd
    fi
}

stop_vm() {
    local vm_name=$(select_vm) || return 1
    local vm_dir="$VM_BASE_DIR/$vm_name"
    local status=$(get_vm_status "$vm_dir")
    if [[ "$status" != "running" ]]; then
        echo "⚠️  VM is not running."
        return 0
    fi
    local pid=$(cat "$vm_dir/pid")
    echo "🛑 Stopping VM '$vm_name' (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$vm_dir/pid"
    echo "✅ Stopped."
}

vm_info() {
    local vm_name=$(select_vm) || return 1
    local vm_dir="$VM_BASE_DIR/$vm_name"
    echo "📊 Info for '$vm_name':"
    cat "$vm_dir/config.conf"
    echo "Status: $(get_vm_status "$vm_dir")"
}

delete_vm() {
    local vm_name=$(select_vm) || return 1
    local vm_dir="$VM_BASE_DIR/$vm_name"
    local status=$(get_vm_status "$vm_dir")
    if [[ "$status" == "running" ]]; then
        echo "⚠️  Stop it first."
        return 1
    fi
    read -p "🗑️  Delete VM '$vm_name'? (y/N): " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Cancelled."
        return 0
    fi
    rm -rf "$vm_dir"
    echo "✅ Deleted."
}

# --------------------------------------------
# 7. Main menu
# --------------------------------------------
main_menu() {
    echo ""
    echo "📋 Main Menu"
    echo "  1) 🆕 Create VM"
    echo "  2) 🚀 Start VM"
    echo "  3) 🛑 Stop VM"
    echo "  4) 📊 VM Info"
    echo "  5) 🗑️  Delete VM"
    echo "  0) 👋 Exit"
    read -p "🎯 Choice: " choice
    case "$choice" in
        1) create_vm ;;
        2) start_vm ;;
        3) stop_vm ;;
        4) vm_info ;;
        5) delete_vm ;;
        0) echo "Bye."; exit 0 ;;
        *) echo "❌ Invalid choice." ;;
    esac
}

# --------------------------------------------
# 8. Init
# --------------------------------------------
init() {
    mkdir -p "$VM_BASE_DIR"
    install_qemu
    check_kvm
    echo "✅ VM Manager ready (VMs in $VM_BASE_DIR)"
}

init
while true; do
    main_menu
    read -p "⏎ Press Enter to continue..."
done
