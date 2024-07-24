#!/usr/bin/env bash
: <<'DOC'

Manage the Development VM

DOC

set -eEou pipefail

declare -r name="dev-vm"
declare -r workdir="${CI_PROJECT_DIR:?Missing CI_PROJECT_DIR}/.cache/${name}"
declare -r \
  eventdir="${workdir}/.events" \
  builddir="${workdir}/build" \
  datadir="${workdir}/data"
install -dm0750 "${workdir}" "${eventdir}" "${builddir}" "${datadir}"
source "${CI_PROJECT_DIR}/src/_common.sh"

### Functions ###

_cloudinit_gen() {
  local -A _opts=()
  parse_kv _opts "$@"

  : # TODO

}

_load_runtime() {
  local -n _opts_fn_nr="${1:?Missing Assoc Array Name}"
  
  # Find the QEMU System Binary
  local _arch="${_opts_fn_nr[arch]:-$(uname -m)}"
  local _qemu_system; _qemu_system="$(command -v "qemu-system-${_arch}" 2>/dev/null)" || {
    log "qemu-system-${_arch} not found"
    return 1
  }

  # Determine the CPU & System Memory
  local _cpus; _cpus="$(nproc)"
  [[ "${_cpus}" -gt 0 ]] || { log 'Failed to determine CPU Count'; return 1; }
  local _mem; _mem="$(( $(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}') / 1024 / 1024 * 9 / 10 ))"
  [[ "${_mem}" -gt 0 ]] || { log 'Failed to determine System Memory'; return 1; }

  # Determine the Accelerator
  if [[ -c '/dev/kvm' ]]; then
    local _accel='kvm'
  else
    local _accel='tcg'
  fi

  # Find the BIOS & EFI Firmware

}

_spawn_vm() {
  log 'Spawning VM'
  local -A _user_opts=(
    [name]='dev-vm'
    [machine]=q35 # q35 | pc | microvm
    [rootDisk]="${datadir}/alpine-root.img"
    [cdrom]="${datadir}/ci.iso"
    # Runtime Overrides
    [arch]= # Defaults to Host Arch
    [cpus]= # Defaults to Host CPU Count
    [mem]= # Defaults to 90% of Host Memory
    [accel]= # Defaults to KVM
    [efiFirmware]=
    [biosFirmware]=
  )
  parse_kv _user_opts "$@"

  # These are determined at runtime
  local -A _sys_opts=(
    [arch]= # Defaults to Host Arch
    [cpus]= # Defaults to Host CPU Count
    [mem]= # Defaults to 90% of Host Memory
    [accel]=
    [efiFirmware]=
    [biosFirmware]=
    [netOpts]=
  )
  _load_runtime _sys_opts
  
  local -A o=()
  merge_kv o _sys_opts _user_opts

  local -r _dir="${datadir}/${o[name]}"
  install -dm0750 "${_dir}"

  if [[ "${o[machine]}" == q35 ]]; then
    local -a _machine_flags=(
      -machine "type=q35,accel=${o[accel]}"
      -bios "${o[efiFirmware]}"
    )
  elif [[ "${o[machine]}" == pc ]]; then
    local -a _machine_flags=(
      -machine "type=pc,accel=${o[accel]}"
      -bios "${o[biosFirmware]}"
    )
  elif [[ "${o[machine]}" == microvm ]]; then
    log "Not Yet Implemented: ${o[machine]}"
    return 1
  else
    log "Unknown Machine Type: ${o[machine]}"
    return 1
  fi

  local -a _monitor=( # The QEMU Monitor for the VM
    # A Unix socket; Configured for QMP JSON Commands
    -chardev "socket,id=monitor0,path=${_dir}/monitor.sock,server,nowait,logfile=${_dir}/monitor.log"
    -mon "chardev=monitor0,mode=control"
  )
  local -a _serial=( # The VM Serial Console
    -nographic # Completely Disable Graphics; Serial Only
    # Unix Socket w/ extra opts: a logfile, no signals
    -chardev "socket,id=serial0,path=${_dir}/serial.sock,server,nowait,logfile=${_dir}/serial.log,signal=off"
    -serial "chardev:serial0"
  )
  local -a _netdevs=( # Network Devices
    -netdev "user,id=net0,${o[netOpts]}"
    -device "virtio-net,netdev=net0"
  )
  local -a _blkdevs=( # Block Devices
    # CDROM
    -blockdev "driver=file,node-name=file0,filename=${o[cdrom]}"
    -device 'scsi-cd,drive=file0'
    # Root Disk
    -blockdev "driver=file,node-name=file1,filename=${o[rootDisk]}"
    -blockdev 'driver=qcow2,node-name=disk0,file=file1'
    -device 'virtio-blk,drive=disk0'
    # Boot Order
    -boot 'order=cd' # First HardDisk, then CDROM
  )
  local -a _miscdevs=( # Miscalleaneous Devices
    # RNG
    -object 'rng-random,id=rng0,filename=/dev/urandom'
    -device 'virtio-rng-device,rng=rng0'
    # TPM ; TODO: Check for Host TPM & Passthrough
    -chardev "socket,id=chrtpm0,path=${_dir}/tpm0.sock"
    -tpmdev 'emulator,id=tpm0,chardev=chrtpm0'
    -device 'tpm-tis,tpmdev=chrtpm0'
  )
  local -a _qemu_argv=(
    -name "${o[name]}"
    "${_machine_flags[@]}"
    -smp "cpus=${o[cpus]}"
    -m "size=${o[mem]}G"
    "${_monitor[@]}"
    "${_serial[@]}"
    "${_netdevs[@]}"
    "${_blkdevs[@]}"
    "${_miscdevs[@]}"
  )
  log "Running VM: ${_qemu_system}...\n$(printf '\t%s\n' "${_qemu_argv[@]}")"
  sudo "${_qemu_system}" "${_qemu_argv[@]}" &>"${_dir}/qemu.log" &
  printf %s "$!" > "${_dir}/qemu.pid"
  kill -0 "$(< "${_dir}/qemu.pid")" || {
    log 'Failed to Start VM'
    return 1
  }
  disown "$(< "${_dir}/qemu.pid")"
}

_kill_vm() {
  : # TODO Kill the VM Process
}

_init_vm() {
  local -A _opts=()
  parse_kv _opts "$@"

}

### SubCommands ###

qemu_init() {
  log 'Initializing the QEMU Environment'

  if check_root &>/dev/null; then { log 'Do not run as root'; return 1; }; fi

  command -v "qemu-system-$(uname -m)" &> /dev/null || { log 'QEMU not found'; return 1; }

  get_event 'fetch-alpine' || {
    log 'Fetching the Alpine Base Image'
    curl -fsSL -o "${datadir}/alpine-base.img" \
      "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.1-x86_64-uefi-cloudinit-r0.qcow2"
    set_event 'fetch-alpine'
  }

  get_event 'fetch-seabios' || {
    log 'Fetching the SeaBIOS Firmware Source'
    curl -fsSL -o "${datadir}/seabios.tar.gz" \
      "https://github.com/coreboot/seabios/archive/refs/tags/rel-1.16.3.tar.gz"
    install -dm0750 "${datadir}/seabios"
    tar -C "${datadir}/seabios" --strip-components 1 -xzf "${datadir}/seabios.tar.gz"
    set_event 'fetch-seabios'
  }

  get_event 'setup-build-env' || {
    log 'Setting up the Build Environment'
    get_event 'init-build-chroot' || {
      log 'Initializing the Build Chroot'
      install -dm0750 "${builddir}/"{rootfs,.lower,.lower/0000-base}
      init_chroot \
        "base=${builddir}/.lower/0000-base" \
        "debcache=${builddir}/.debcache"
      set_event 'init-build-chroot'
    }
    get_event 'setup-build-chroot' || {
      log 'Setting up the Chroot Environment'
      setup_chroot \
        'name=qemu-builder-chroot' \
        "root=${builddir}/rootfs" \
        "search=${builddir}/.lower" \
        "data=${datadir}"
      set_event 'setup-build-chroot'
    }
    get_event 'install-build-deps' || {
      log 'Installing Build Dependencies'
      local -a _build_deps=(
        jq curl git 
        python3 python3-pip python3-distutils python3-setuptools python-is-python3
        build-essential uuid-dev iasl nasm
      )
      chroot_shell "${builddir}/rootfs" apt-get update
      chroot_shell "${builddir}/rootfs" apt-get install -y "${_build_deps[@]}"
      set_event 'install-build-deps'
    }
    get_event 'mount-workdir-chroot' || {
      log 'Mounting the Working Directory into the Build Chroot'
      _sudo install -Ddm0750 "${builddir}/rootfs/mnt/data"
      safe_mount \
        "type=bind" "src=${workdir}" "dst=${builddir}/rootfs/mnt/data"
      set_event 'mount-workdir-chroot'
    }
    set_event 'setup-build-env'
  }

  get_event 'fetch-edk2' || {
    log 'Fetching the EDK2 (EFI Dev Kit II) Firmware Source'
    git clone -b edk2-stable202405 --depth 1 'git@github.com:tianocore/edk2.git' "${datadir}/edk2"
    pushd "${datadir}/edk2"
    git submodule update --init --recursive
    popd
    set_event 'fetch-edk2'
  }

  get_event 'build-seabios' || {
    log 'Building the SeaBIOS Firmware'
    local _datadir="/mnt/data/$(realpath --relative-to="${workdir}" "${datadir}")"
    chroot_shell "${builddir}/rootfs" \
      "cd '${_datadir}/seabios' && make -j$(nproc)" || {
        log 'Failed to Build SeaBIOS'
        return 1
      }
    log "Installing SeaBIOS"
    _sudo install -m0644 "${datadir}/seabios/out/bios.bin" "${datadir}/bios.bin"
    set_event 'build-seabios'
  }

  get_event 'build-edk2' || {
    log 'Building the EDK2 (EFI Dev Kit II) Firmware'
    local _datadir="/mnt/data/$(realpath --relative-to="${workdir}" "${datadir}")"
    { chroot_exec "${builddir}/rootfs" bash -l -s <<EDKBUILD
#!/usr/bin/env bash
pushd '${_datadir}/edk2'
echo 'BUILDING TOOLS'
make -C BaseTools clean || exit 1
make -C BaseTools -j$(nproc) || exit 1
install -m0644 <(cat <<EOF
# Based on https://github.com/tianocore/edk2/blob/master/BaseTools/Conf/target.template
ACTIVE_PLATFORM               = OvmfPkg/OvmfPkgX64.dsc
TARGET                        = RELEASE
TARGET_ARCH                   = X64
TOOL_CHAIN_CONF               = Conf/tools_def.txt
TOOL_CHAIN_TAG                = GCC
MAX_CONCURRENT_THREAD_NUMBER  = $(( $(nproc) - 1 ))
BUILD_RULE_CONF               = Conf/build_rule.txt
EOF
) Conf/target.txt || exit 1
echo 'SOURCING EDK2 SETUP'
source 'edksetup.sh' || exit 1
echo 'BUILDING EDK2'
build clean || exit 1
build || exit 1
EDKBUILD
    } || {
      log 'Failed to Build EDK2'
      return 1
    }
    log "Installing EDK2"
    # See https://github.com/tianocore/edk2/blob/master/OvmfPkg/README
    # The 3 Important Files Are:
    #   - Build/OvmfX64/RELEASE_GCC/FV/OVMF.fd
    #   - Build/OvmfX64/RELEASE_GCC/FV/OVMF_CODE.fd
    #   - Build/OvmfX64/RELEASE_GCC/FV/OVMF_VARS.fd
    # Optionally enable Secure Boot w/ `-D SECURE_BOOT_ENABLE` but you will need to install the keys
    local -i uid gid; uid="$(id -u)" gid="$(id -g)"
    _sudo install -o "${uid}" -g "${gid}" -m0644 \
      "${datadir}/edk2/Build/OvmfX64/RELEASE_GCC/FV/OVMF.fd" "${datadir}/OVMF.fd"
    set_event 'build-edk2'
  }

  log 'QEMU Environment Initialized'
  set_event 'qemu-init'
}

vm_init() {
  local -A _opts=(
    [name]='dev-vm'
  ); parse_kv _opts "$@"

  get_event 'qemu-init' || { log 'QEMU doesnt seem to be initialized, rerun the init subcmd and try again'; return 1; }

  local vmdir="${workdir}/${_opts[name]}"
  install -dm0750 "${vmdir}"

  log 'Initializing the Development VM'

  get_event 'build-root-img' || {
    log 'Building the Root Image'
    qemu-img create -f qcow2 \
        -b "${datadir}/alpine-base.img" -F qcow2 \
      "${vmdir}/root.img" '64G'
    set_event 'build-root-img'
  }

  get_event 'gen-ssh-keys' || {
    log 'Generating SSH Keys'
    ssh-keygen -t ed25519 -f "${vmdir}/id_ed25519" -N '' -C "dev-vm"
    set_event 'gen-ssh-keys'
  }

  get_event 'generate-ci' || {
    log 'Generating CloudInit User Data'
    _cloudinit_gen \
      "dst=${vmdir}/ci.img" \
      "ssh=${vmdir}/id_ed25519.pub"
    set_event 'generate-ci'
  }

  get_event 'initialize-vm' || {
    log 'Initializing the VM'
    _init_vm \
      "root=${vmdir}/root.img" \
      "ci=${vmdir}/ci.img"
    set_event 'initialize-vm'
  }

}

up() {
  log 'Bringing Up Development VM'
  : # TODO
}

down() {
  log 'Bringing Down Development VM'
  : # TODO
}

purge() {
  log 'Purging the Development VM'

  : # TODO: Add Sanity Checks the VM is not Running

  mapfile -t < <( grep "${workdir}" /proc/mounts | awk '{ print $2; }' )
  [[ "${#MAPFILE[@]}" -le 0 ]] || {
    log "Unmounting all"
    safe_lazy_unmounts "${MAPFILE[@]}"
  }

  log "Purging Files"
  clean_dirs "dirs=${workdir}" elevate=true

}

### Main ###

declare -r subcmd="${1:-build}"; [[ -z "${1:-}" ]] || shift
case "${subcmd}" in
  init ) qemu_init ;;
  purge ) can_sudo && purge;;
  vm-init ) can_sudo && vm_init;;
  vm-purge ) can_sudo && vm_purge;;
  * ) log "Unknown subcommand: ${subcmd}"; exit 1 ;;
esac
