#!/usr/bin/env bash

set -eEuo pipefail

log() {
  printf '%s\n' "$@" >&2
}

_get_next_open_port() {
  local -n _fn_port="${1:?Missing port argument}"; shift
  local -i _port=49152
  # Find the first ephemeral port that isn't open
  while {
    printf '' >"/dev/tcp/localhost/${_port}" ;
  }; do
    ((_port++))
  done
  if [[ "${_port}" -gt 65535 ]]; then
    log --level=error "Unable to find an open port"
    return 1
  fi
  _fn_port="${_port}"
  # Assert the port is't open
  if  printf '' >"/dev/tcp/localhost/${_port}"; then
    log --level=error "Port ${_port} is in use"
    return 1
  fi
}

_set_vm_opts() {
  log "Alpine Version: ${alpine_ver}" "Alpine Architecture: ${alpine_arch}" "Cache Directory: ${cache_dir}"
  declare -g _qemu_system; _qemu_system="$(command -v "qemu-system-${alpine_arch}")"
  declare -gi ssh_port; _get_next_open_port ssh_port
  printf '%s\n' "${ssh_port}" > "${cache_dir}/ssh.port"
  declare -gA qemu_net_user_opts=(
    [net]=169.254.0.0/24
    [host]=169.254.0.2
    [dns]=169.254.0.3
    [ipv4]=on
    [ipv6]=off
    [restrict]=off
    [hostfwd]="tcp:127.0.0.1:${ssh_port}-:22"
  )
  mapfile -t < <(
    for key in "${!qemu_net_user_opts[@]}"; do
      printf -- "%s=%s\n" "${key}" "${qemu_net_user_opts[${key}]}"
    done
  )
  declare -g _net_user_opts; _net_user_opts="$(printf '%s,' "${MAPFILE[@]}")"; _net_user_opts="${_net_user_opts%,}"; declare -r _net_user_opts
  # declare uefi_firmware="/home/linuxbrew/.linuxbrew/share/qemu/edk2-${alpine_arch}-code.fd"
  declare -g uefi_firmware="/usr/share/OVMF/OVMF_CODE.fd"
  [[ -f "${uefi_firmware}" ]] || (
    export DEBIAN_FRONTEND=noninteractive
    export TZ="${TZ:-UTC}"
    { sudo apt-get update && sudo apt-get install -y ovmf; } || {
      log "Failed to Install OVMF"
      exit 1
    }
  )
  [[ -f "${uefi_firmware}" ]] || {
    log "Missing EUFI Firmware: ${uefi_firmware}"
    exit 1
  }
  declare -g accel
  if [[ -c /dev/kvm ]]; then
    accel="kvm"
    declare kvm_group; kvm_group="$(stat -c '%G' /dev/kvm)"
    # Check if user is in the kvm group
    {
      getent group "${kvm_group}" | grep -q "$(id -un)"
    } || {
      log "Adding User to the kvm Group"
      sudo usermod -aG "${kvm_group}" "$(id -un)"
      log "Please logout and login again to use KVM Acceleration"
      exit 1
    }
  else
    accel="tcg"
  fi
  declare -ig cpus; cpus="$(nproc)"; cpus="$(( 75 * cpus / 100 ))"; cpus="$(( cpus % 2 ? cpus + 1 : cpus ))"
  local -i total_mem_kb; total_mem_kb="$(grep -F 'MemTotal:' /proc/meminfo | awk '{print $2}')"
  declare -ig mem_gb; mem_gb="$(( 75 * (total_mem_kb / ( 1024 * 1024 )) / 100 ))"
}

exec_installer_vm() {
  log "Dropping into an Interactive Session w/ the Alpine Installer"
  _set_vm_opts
  set -x
  exec sudo $_qemu_system \
    -name "alpine-image-builder" \
    -machine "type=q35,accel=${accel}" \
    -bios "${uefi_firmware}" \
    -smp "cpus=${cpus}" \
    -m "size=${mem_gb}G" \
    -display none \
    -serial mon:stdio \
    -netdev "user,id=net0,${_net_user_opts}" \
    -device "virtio-net,netdev=net0" \
    -blockdev driver=file,node-name=file0,filename="${cache_dir}/alpine.iso" \
    -blockdev driver=raw,node-name=cd0,file=file0 \
    -device virtio-blk,drive=cd0 \
    -blockdev driver=file,node-name=file1,filename="${cache_dir}/root.img" \
    -blockdev driver=qcow2,node-name=disk0,file=file1 \
    -device virtio-blk,drive=disk0 \
    -boot order=d
}

fork_builder_vm() {
  log "Forking a VM to Build the Alpine Image"
  (
    _set_vm_opts
    set -x
    sudo $_qemu_system \
      -name "alpine-image-builder" \
      -machine "type=q35,accel=${accel}" \
      -bios "${uefi_firmware}" \
      -smp "cpus=${cpus}" \
      -m "size=${mem_gb}G" \
      -display none \
      -serial mon:stdio \
      -netdev "user,id=net0,${_net_user_opts}" \
      -device "virtio-net,netdev=net0" \
      -blockdev driver=file,node-name=file1,filename="${cache_dir}/root.img" \
      -blockdev driver=qcow2,node-name=disk0,file=file1 \
      -device virtio-blk,drive=disk0 \
  ) &> "${cache_dir}/vm.log" &
  declare vm_pid=$!
  printf '%s\n' "${vm_pid}" > "${cache_dir}/vm.pid"
  disown "${vm_pid}"
}

_ssh() {
  ssh \
    -o "UserKnownHostsFile=/dev/null" \
    -o "StrictHostKeyChecking=no" \
    -o "LogLevel=ERROR" \
    -o "ConnectTimeout=5" \
    -o "IdentityFile=${cache_dir}/id_ed25519" \
    -p "$(< "${cache_dir}/ssh.port")" \
    root@localhost "$@" 0<&0 1>&1 2>&2
}
exec_ssh() {
  exec ssh \
    -o "UserKnownHostsFile=/dev/null" \
    -o "StrictHostKeyChecking=no" \
    -o "LogLevel=ERROR" \
    -o "ConnectTimeout=5" \
    -o "IdentityFile=${cache_dir}/id_ed25519" \
    -p "$(< "${cache_dir}/ssh.port")" \
    root@localhost "$@" 0<&0 1>&1 2>&2
}

declare alpine_ver="${ALPINE_VERSION:?Missing ALPINE_VERSION}"
declare cache_dir="${CI_PROJECT_DIR:?Missing CI_PROJECT_DIR}/.cache/alpine-vm"
case "$(uname -p)" in
  x86_64) declare alpine_arch="x86_64" ;;
  aarch64) declare alpine_arch="aarch64" ;;
  *) log "Unsupported Architecture: $(uname -p)"; exit 1 ;;
esac
[[ -d "${cache_dir%/*}" ]] || {
  log "Cache Parent Directory: ${cache_dir%/*} does not exist"
  exit 1
}
install -dm0755 "${cache_dir}"

case "${1:?Missing Subcommand}" in
  init )
    [[ -f "${cache_dir}/alpine.iso" ]] || {
      log "Fetching the Alpine ISO"
      curl -fsSL -o "${cache_dir}/alpine.iso" \
        "https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver%.*}/releases/${alpine_arch}/alpine-virt-${alpine_ver}-${alpine_arch}.iso"
    }

    [[ -f "${cache_dir}/root.img" ]] || {
      log "Creating the Root Image"
      qemu-img create -f qcow2 "${cache_dir}/root.img" 64G
    }

    [[ -f "${cache_dir}/id_ed25519" ]] || {
      rm -f "${cache_dir}/id_ed25519"{,.pub} &>/dev/null || true
      log "Generating SSH Key"
      ssh-keygen -t ed25519 -f "${cache_dir}/id_ed25519" -N '' -C "alpine-image-builder"
    }

    exec_installer_vm
    ;;
  cleanup )
    { [[ -f "${cache_dir}/vm.pid" ]] && kill -0 "$(< "${cache_dir}/vm.pid")" &>/dev/null ; } && {
      log "VM is still running, please stop it first"
      exit 1
    }
    [[ -d "${cache_dir}" ]] && {
      declare empty_dir; empty_dir="$(mktemp -d)"
      rsync -a --delete "${empty_dir}/" "${cache_dir}/"
    }
    log "Alpine VM Has Been Cleaned Up"
    ;;
  up )
    # Check if the VM is still Running
    [[ -f "${cache_dir}/vm.pid" ]] && {
      kill -0 "$(< "${cache_dir}/vm.pid")" &>/dev/null || {
        log "VM Doesn't seem to be running, cleaning up old files"
        rm -f "${cache_dir}/vm.pid" "${cache_dir}/vm.log"
      }
    }

    # If the PID File doesn't exist then start the VM
    [[ -f "${cache_dir}/vm.pid" ]] || {
      log "Starting Alpine VM"
      fork_builder_vm
    }

    log "Alpine VM is running"
    ;;
  down )
    [[ -f "${cache_dir}/vm.pid" ]] && {
      log "Stopping Alpine VM"
      kill "$(< "${cache_dir}/vm.pid")" &>/dev/null || true
    }
    rm -f "${cache_dir}/vm.pid" "${cache_dir}/vm.log" "${cache_dir}/ssh.port"
    log "Alpine VM is stopped"
    ;;
  util )
    case "${2:?Missing A Util}" in
      ssh )
        exec_ssh "${@:3}"
        ;;
      bootstrap )
        log "Bootstrapping the Alpine VM"
        log "Patching Alpine Repositories"
        [[ -f "${CI_PROJECT_DIR}/helpers/alpine-repositories" ]] || {
          log "Missing Alpine Repositories File: ${CI_PROJECT_DIR}/helpers/alpine-repositories"
          exit 1
        }
        _ssh "cat > /etc/apk/repositories" < "${CI_PROJECT_DIR}/helpers/alpine-repositories"
        log "Installing Required Packages"
        _ssh "apk add --no-cache rsync git python3"
        log "Creating Python Virtual Environment"
        _ssh "[[ -d /root/.venv ]] || python3 -m venv /root/.venv"
        log "Installing Pip in the Virtual Environment"
        _ssh "source /root/.venv/bin/activate && python3 -m ensurepip"
        log "Alpine VM has been bootstrapped"
        ;;
      sync )
        log "Syncing Project Directory to Alpine VM"
        rsync -avz --delete --progress \
          --rsh="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentityFile=${cache_dir}/id_ed25519 -p $(< "${cache_dir}/ssh.port")" \
          --exclude=".*" \
          "${CI_PROJECT_DIR}/" \
          "root@localhost:/root/image-builder/" || {
            log "Failed to Sync Project Directory to Alpine VM"
            exit 1
          }
        log "Project Directory has been Synced to Alpine VM"
        ;;
      install-deps )
        log "Installing Project Dependencies"
        _ssh "source /root/.venv/bin/activate && pip install -r /root/image-builder/src/requirements.txt"
        _ssh "apk add fish"
        _ssh "apk add qemu qemu-system-${alpine_arch} qemu-tools qemu-img"
        _ssh "apk add losetup parted wipefs lvm2 btrfs-progs dosfstools e2fsprogs f2fs-tools xfsprogs ntfs-3g"
        _ssh "apk add build-base curl perl gmp-dev mpc1-dev mpfr-dev elfutils-dev bash flex bison zstd sed installkernel bc linux-headers linux-firmware-any openssl-dev>3 mawk diffutils findutils zstd pahole python3 gcc>=13.1.1_git20230624"
        log "Project Dependencies have been installed"
        ;;
      build )
        log "Remotely building the Alpine Image"
        _ssh "install -dm0755 /mnt/build /mnt/build/rootfs"
        declare _arg_list; _arg_list="$(printf -- "%q " "${@:3}")"
        _ssh "source /root/.venv/bin/activate && ( cd /root/image-builder/src && LOG_LEVEL=${LOG_LEVEL:-INFO} python3 build.py ${_arg_list})"
        log "Remote build complete"
        ;;
      cleanup-build )
        log "Cleaning up the Remote Build Directory"
        _ssh "set -x; cut -f1 -d' ' /proc/mounts | grep -F /mnt/build | xargs -r -n 1 -P \$(nproc) umount"
        _ssh "set -x; losetup -D"
        _ssh "set -x; install -dm0755 /mnt/build /tmp/empty && rsync -a --delete /tmp/empty/ /mnt/build/"
        log "Remote Build Directory has been cleaned up"
        ;;
      * )
        log "Unknown Util: ${2}"
        exit 1
        ;;
    esac
    ;;
  * )
    log "Unknown Subcommand: ${1}"
    exit 1
    ;;
esac

log "fin"