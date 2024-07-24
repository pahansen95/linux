#!/usr/bin/env bash

(return 0 &>/dev/null) || { echo 'MUST BE SOURCED!'; exit 1; }

: "${CI_PROJECT_DIR:?Missing CI_PROJECT_DIR}"
: "${workdir:?Missing workdir}"
: "${eventdir:?Missing eventdir}"

log() { printf '%b\n' "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2; }
check_root() { [[ "$(id -u)" -eq 0 ]] || { log "user is not root"; return 1; }; }
can_sudo() { sudo -n true &>/dev/null || { log "user cannot sudo"; return 1; }; }
_sudo() { if check_root &>/dev/null; then "$@"; else { can_sudo && sudo "$@"; }; fi; }
parse_kv() {
  local -n _aarr_fn_nr="${1:?Missing Assoc Array Name}"; shift 1
  for arg in "$@"; do
    [[ "${arg}" =~ ^([^=]+)=(.*)$ ]] || {
      log "Invalid Key-Value Pair: ${arg}"
      return 1
    }
    local _key="${BASH_REMATCH[1]}"
    local _val="${BASH_REMATCH[2]}"
    _aarr_fn_nr["${_key}"]="${_val}"
  done
}
merge_kv() {
  local -n _write_aarr_fn_nr="${1:?Missing Assoc Array Name}"; shift 1
  for _var_name in "$@"; do
    local -n _read_arr_fn_nr="${_var_name}"
    for _key in "${!_read_arr_fn_nr[@]}"; do
      _write_aarr_fn_nr["${_key}"]="${_read_arr_fn_nr["${_key}"]}"
    done
  done
}

### Event Handling ###

set_event() { install -m0644 /dev/null "${eventdir}/${1}" ; }
clear_event() { rm -f "${eventdir}/${1}" &> /dev/null || true; }
get_event() { [[ -f "${eventdir}/${1}" ]]; }

### String Tools ###
_str_join() {
  local _sep="${1:?Missing Separator}"; shift 1
  printf '%s\n' "$@" | awk '{printf "%s%s", sep, $0; sep=FS}' FS=':'
}
_str_split() {
  local _sep="${1:?Missing Separator}"; shift 1
  [[ "$#" -le 1 ]] || { log "Expected exactly 2 args"; return 1; }
  printf %s "${1}" | awk -v sep="${_sep}" '{n=split($0, a, sep); for (i=1; i<=n; i++) print a[i]}'
}
str() {
  local _subcmd="${1:?Missing Subcommand}"; shift 1
  case "${_subcmd}" in
    join|split ) "_str_${_subcmd}" "$@" ;;
    * )
      log "Unknown Subcommand: ${_subcmd}"
      return 1
      ;;
  esac
}

### Directory & Mount Tools ###

clean_dirs() {
  local -A _o=(
    elevate=false # Whether to elevate the command
    dirs= # The Directories to Clean as a `:` separated list
  ); parse_kv _o "$@"
  local -a _dirs; mapfile -t _dirs < <(str split ':' "${_o[dirs]}")
  [[ "${#_dirs[@]}" -gt 0 ]] || {
    log "No Directories Specified"
    return 1
  }
  if [[ "${_o[elevate]}" == true ]]; then { local -a _rsync=( _sudo rsync ); }; else { local -a _rsync=( rsync ); }; fi
  local _empty_dir; _empty_dir="$(mktemp -d)"
  trap "[[ ! -d '${_empty_dir}' ]] || rmdir '${_empty_dir}' &>/dev/null || true" RETURN
  for _dir in "${_dirs[@]}"; do
    "${_rsync[@]}" -a --delete "${_empty_dir}/" "${_dir}/" &>/dev/null || {
      log "Failed to clean up ${_dir}"
      return 1
    }
  done
}
safe_mount() {
  local -A _o=(
    [type]= # The Mount Type
    [src]= # The Source of the Mount
    [dst]= # The Destination of the Mount
    [opts]="rw" # The Mount Options
  ); parse_kv _o "$@"
  local \
    _type="${_o[type]}" \
    _src="${_o[src]}" \
    _dst="${_o[dst]}" \
    _opts="${_o[opts]}"
  grep -q "${_src} ${_dst} ${_type}" /proc/mounts || {
    [[ -e "${_dst}" ]] || {
      # Create the Destination if it doesn't exist
      if [[ -f "${_src}" ]]; then
        install -m 0644 /dev/null "${_dst}"
      else
        [[ -d "${_src}" ]] || log "Unknown Source Type for '${_src}'; assuming directory"
        install -Ddm 0755 "${_dst}"
      fi
    }
    # Mount the Source
    case "${_type}" in
      bind)
        # Check if we RO was requested
        if [[ $_opts =~ ro ]]; then
          # First Bind Mount it in a private directory
          install -dm 0750 "${workdir}/.privmnts"
          local _tmp_dst; _tmp_dst="${workdir}/.privmnts/$( printf '%s' "${_dst}" | md5sum | awk '{ print $1; }' )"
          if [[ -f "${_dst}" ]]; then
            install -m 0600 /dev/null "${_tmp_dst}"
          else
            [[ -d "${_dst}" ]] || log "Unknown Destination Type for '${_dst}'; assuming directory"
            install -Ddm "$(stat -c '%a' "${_dst}")" "${_tmp_dst}"
          fi
          _sudo mount --bind -o "${_opts}" "${_src}" "${_tmp_dst}"
          # Next Remount it Read-Only
          _sudo mount -o remount,ro,bind "${_tmp_dst}"
          # Finally Bind Mount it to the destination
          _sudo mount --move "${_tmp_dst}" "${_dst}"
        else
          # A Normal Bind Mount
          _sudo mount --bind -o "${_opts}" "${_src}" "${_dst}"      
        fi
        ;;
      * )
        _sudo mount -o "${_opts}" -t "${_type}" "${_src}" "${_dst}"
        ;;
    esac    
  }
}
safe_lazy_unmounts() {
  local -a _mnts=( "${@}" )
  [[ "${#_mnts[@]}" -gt 0 ]] || {
    log "No Mounts Specified"
    return 1
  }
  log "Lazy Unmounting"
  for _mount in "${_mnts[@]}"; do
    if grep -q "${_mount}" /proc/mounts; then _sudo umount -l "${_mount}"; fi
  done
  log "Waiting for Lazy Unmounts to finalize"
  local -i _count=0
  while [[ "${_count}" -lt $(( 5 * 60 / 2 )) ]]; do
    mapfile -t < <(
      for _mount in "${_mnts[@]}"; do
        if grep -q "${_mount}" /proc/mounts; then
          printf '%s\n' "${_mount}"
        fi
      done
    )
    if [[ "${#MAPFILE[@]}" -le 0 ]]; then
      log "Lazy Unmounts finalized"
      return 0
    else
      _mnts=("${MAPFILE[@]}")
    fi
    sleep 2
    _count+=1
    log "Waiting for Lazy Unmounts to finalize"
  done
  log "Failed to finalize Lazy Unmount: $(printf '%s\n' "${_mnts[@]}")"
  return 1
}
mount_overlay() {
  log "Mounting an Overlay Filesystem"
  local -A _o=(
    [search]= # The Parent Directory of the Chroot Overlay
    [upper]= # The Upper Directory of the Chroot Overlay
    [work]= # The Work Directory of the Chroot Overlay
    [mount]= # The Mount Point of the Chroot Overlay
  ); parse_kv _o "$@"
  local _lower; _lower="$(
    str join ':' "$(
      find "${_o[search]}" -mindepth 1 -maxdepth 1 | sort -g
    )"
  )"
  log "Overlay Lowers: ${_lower}"
  safe_mount \
    "type=overlay" "src=overlay" "dst=${_o[mount]}" \
    "opts=lowerdir=${_lower},upperdir=${_o[upper]},workdir=${_o[work]}" || {
      log "Failed to mount the Overlay Filesystem"
      return 1
    }
}
init_chroot() {
  log 'Initializing the Chroot'
  local -A _o=(
    [base]= # The Directory to use as the Base of the Chroot
    [debcache]= # The Cache Directory to use for debootstrap
  ); parse_kv _o "$@"

  # Check the base is empty
  [[ -n "$(find "${_o[base]}" -maxdepth 0 -type d -empty -print)" ]] || {
    log "Chroot Base is not empty"
    return 1
  }

  install -Ddm0755 "${_o[base]}" "${_o[debcache]}"
  _sudo debootstrap --cache-dir="${_o[debcache]}" \
      --arch=amd64 \
      --variant=minbase \
      --merged-usr \
    stable \
    "${_o[base]}" \
    http://deb.debian.org/debian
  
}
setup_chroot() {
  log 'Setting up the Chroot Environment'
  local -A _o=(
    [name]= # The Name for the Chroot
    [root]= # The Root Directory of the Chroot
    [search]= # The Parent Directory to search for the Chroot Overlay Lowers
    [data]= # The Data Directory to use for the Chroot; the work & upper directories will be created here
  ); parse_kv _o "$@"

  # First check if the Chroot is already mounted
  grep -q "${_o[root]}" /proc/mounts && {
    log "Chroot already seems to be mounted"
    return 1
  }

  # Mount the Chroot Overlay
  install -Ddm0755 "${_o[data]}/.work" "${_o[data]}/.upper"
  mount_overlay "search=${_o[search]}" "upper=${_o[data]}/.upper" "work=${_o[data]}/.work" "mount=${_o[root]}" || {
    log "Failed to mount the Chroot Overlay"
    return 1
  }

  # Add the System Mounts
  log "Mounting Kernel & Temp Filesystems"
  safe_mount type=proc src=proc "dst=${_o[root]}/proc"
  safe_mount type=sysfs src=sysfs "dst=${_o[root]}/sys"
  if [[ -d /sys/firmware/efi/efivars ]]; then {
    safe_mount type=efivarfs src=/sys/firmware/efi/efivars "dst=${_o[root]}/sys/firmware/efi/efivars"
  }; fi
  safe_mount type=devtmpfs src=devtmpfs "dst=${_o[root]}/dev"
  safe_mount type=devpts src=devpts "dst=${_o[root]}/dev/pts"
  safe_mount type=tmpfs src=tmpfs "dst=${_o[root]}/tmp"
  safe_mount type=tmpfs src=tmpfs "dst=${_o[root]}/run"

  log "Mounting Bind Mounts"
  [[ -f "${_o[root]}/etc/resolv.conf" ]] || {
    _sudo install -m0644 /dev/null "${_o[root]}/etc/resolv.conf"
    safe_mount type=bind src=/etc/resolv.conf "dst=${_o[root]}/etc/resolv.conf" opts=ro
  }

  [[ -f "${_o[root]}/etc/hosts" ]] || {
    _sudo install -m0644 /dev/null "${_o[root]}/etc/hosts"
    safe_mount type=bind src=/etc/hosts "dst=${_o[root]}/etc/hosts" opts=ro
  }

  log "Writing Files"
  [[ -f "${_o[root]}/etc/hostname" ]] || \
    _sudo install -m0644 <( printf '%s\n' "${_o[name]}" ) "${_o[root]}/etc/hostname"
}
teardown_chroot() {
  log 'Tearing down the Chroot Environment'
  local -A _o=(
    [root]= # The Root Directory of the Chroot
    [mode]='down' # One of (down, clean or purge)
    [data]= # The Data Directory to use for the Chroot; only required when mode is one of (clean, purge)
    [base]= # The Base Directory of the Chroot; only required when mode is purge
  ); parse_kv _o "$@"

  local -a _mnts; mapfile -t _mnts < <(
    grep "${_o[root]}" /proc/mounts | awk '{ print $2; }'
  )
  safe_lazy_unmounts "${_mnts[@]}" || {
    log "Failed to unmount the Chroot"
    return 1
  }
  case "${_o[mode]}" in
    down) log "Chroot is down" ;;
    clean)
      log "Cleaning the Chroot Data"
      clean_dirs "dirs=$(str join ':' "${_o[data]}/.work" "${_o[data]}/.upper")"
      ;;
    purge)
      log "Purging the Chroot"
      clean_dirs "dirs=$(str join ':' "${_o[data]}/.work" "${_o[data]}/.upper" "${_o[base]}")"
      ;;
    *)
      log "Unknown Mode: ${_o[mode]}"
      return 1
      ;;
  esac
}
chroot_exec() {
  log "chroot_exec $*"
  if [[ "$#" -lt 2 ]]; then
    log "chroot_exec expects at least 2 arguments"
    return 1
  fi
  if [[ "${2}" =~ chroot ]]; then log "WARNING: You have called chroot from within chroot_exec"; fi
  _sudo env - "$(command -v chroot)" "$1" bash -l -c -- 'exec "$0" "$@"' "${@:2}"
}
chroot_shell() {
  if [[ "$#" -ge 2 ]]; then
    _sudo env - "$(command -v chroot)" "$1" bash -l -c -- "${*:2}"
  elif [[ "$#" -eq 1 ]]; then
    _sudo env - "$(command -v chroot)" "$1" bash -l -i
  else
    log "chroot_shell expects at least 1 arguments"
    return 1
  fi
}