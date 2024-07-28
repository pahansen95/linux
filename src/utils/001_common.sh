#!/usr/bin/env bash

(return 0 &>/dev/null) || { printf '%s\n' "this script must be sourced: ${BASH_SOURCE[0]}"; exit 1; }

: "${workdir:?Missing workdir}"
: "${eventdir:?Missing eventdir}"

log() { printf '%b\n' "[$(date +'%Y-%m-%dT%H:%M:%S%z')]::$*" >&2; }
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

### Miscellaneous ###

_assert() { eval "${1:?Missing Assertion Statement}" || { log "Assertion Failed: ${1}"; return 1; }; }
boot_id() { awk '/btime/ {print $2}' /proc/stat | md5sum | awk '{print $1}'; }
pgid() { ps -o pgid= "${1:?Missing PID}" | awk '{print $1}'; }

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
  local -A o=(
    [sep]= # The Separator to Split on
    [str]= # The String to Split
    [max]=0 # The Maximum Number of Splits; 0 implies no limit
  ); parse_kv o "$@"
  printf %s "${o[str]}" | awk -v sep="${o[sep]}" -v max="${o[max]}" '
  # Treat the whole document as a single string instead of evaluating each line
  BEGIN { RS = "^$" }
  {
    # Find every Index of the seperator up to max times (or unlimited if max is 0)
    start = 1
    split_count = 0
    while (1) {
      split_pos = index(substr($0, start), sep)
      
      # Break if no more separators found or max splits reached (if max > 0)
      if (split_pos == 0 || (max > 0 && split_count == max)) break
      
      # print the substrings, one per line, inbetween each split index
      print substr($0, start, split_pos - 1)
      start += split_pos + length(sep) - 1
      split_count++
    }
    # Print the remaining part of the string
    print substr($0, start)
  }
  '
}
_str_filter() {
  local _re="${1:?Missing Regular Expression}"; shift 1
  [[ "$#" -ge 1 ]] || { log "Expected at least 1 string to filter"; return 1; }
  printf '%s\n' "$@" | awk -v re="${_re}" '$0 ~ re'
}
_str_rand() {
  local -i _len="${1:?Missing Length}"; shift 1
  [[ "${_len}" -gt 0 ]] || { log "Length must be in range [0, inf]"; return 1; }
  until [[ "${#_str}" -ge "${_len}" ]]; do
    _str+="$(
      md5sum <(
        printf '%s' "${EPOCHSECONDS}"
        dd if=/dev/urandom bs=32 count=1 status=none
      ) | awk '{ print $1 }'
    )"
  done
  awk -v "len=${_len}" '{ print substr($1, 0, len) }' <<< "${_str}"
}
str() {
  local _subcmd="${1:?Missing Subcommand}"; shift 1
  case "${_subcmd}" in
    join|split|filter|rand ) "_str_${_subcmd}" "$@" ;;
    * )
      log "Unknown Subcommand: ${_subcmd}"
      return 1
      ;;
  esac
}

### (Stupid Simple) Key-Value Store ###

_kv_init() {
  local -A o=(
    [d]= # The Directory to Store the KV
  ); parse_kv o "$@"
  [[ -d "${o[d]}" ]] || install -dm0755 "${o[d]}"
}
_kv_set() {
  local -A o=(
    [d]= # The Directory to Store the KV
    [k]= # The Key
    [v]=true # The Value
  ); parse_kv o "$@"
  printf '%s\n' "${o[v]}" > "${o[d]}/${o[k]}"
}
_kv_get() {
  local -A o=(
    [d]= # The Directory to Store the KV
    [k]= # The Key
    [v]= # The Default Value if the Key does not exist
  ); parse_kv o "$@"
  [[ -f "${o[d]}/${o[k]}" ]] || {
    [[ -n "${o[v]:-}" ]] || return 1
    printf '%s\n' "${o[v]}"
    return 0
  }
  cat "${o[d]}/${o[k]}"
}
_kv_clear() {
  local -A o=(
    [d]= # The Directory to Store the KV
    [k]= # The Key to clear
  ); parse_kv o "$@"
  [[ ! -f "${o[d]}/${o[k]}" ]] || unlink "${o[d]}/${o[k]}"
}
_kv_flush() {
  local -A o=(
    [d]= # The Directory to Store the KV
  ); parse_kv o "$@"
  local _emptydir; _emptydir="$(mktemp -d)"; trap "rmdir '${_emptydir}' &>/dev/null || true" RETURN
  rsync -a --delete "${_emptydir}/" "${o[d]}/"  &>/dev/null || {
    log "Failed to drop the KV Store"
    return 1
  }
}
kv() {
  local _subcmd="${1:?Missing Subcommand}"; shift 1
  case "${_subcmd}" in
    init|set|get|clear|flush ) "_kv_${_subcmd}" "$@" ;;
    * )
      log "Unknown Subcommand: ${_subcmd}"
      return 1
      ;;
  esac
}

### IP Address Tools ###

# Convert between integer & string notation
_inet4_int_to_octet() {
  printf '%d.%d.%d.%d\n' \
    $(( (${1:?Missing Integer} >> 24) & 255 )) \
    $(( ($1 >> 16) & 255 )) \
    $(( ($1 >> 8) & 255 )) \
    $(( $1 & 255 ))
}
_inet4_octet_to_int() {
  local -i _int=0
  IFS='.' read -ra _octets <<< "${1:?Missing Octet String}"
  # For each octet, convert to an 8 bit integer & shift it to the correct position w/in the 32 bit integer
  for i in {0..3}; do
    (( _int = (_int << 8) + _octets[i] ))
  done
  printf '%d\n' "${_int}"
}
# Convert between CIDR & Mask Notation
_inet4_cidr_to_mask() {
  local -i _cidr="${1:?Missing CIDR}"
  local -i _mask=0
  # Left shift a full mask by the number of bits to not mask
  (( _mask = 0xffffffff << (32 - _cidr) ))
  _inet4_int_to_octet "${_mask}"
}
_inet4_mask_to_cidr() {
  local -i _mask; _mask="$(_inet4_octet_to_int "${1:?Missing Mask}")"
  local -i _cidr=0
  # Left shift the mask, counting how many times the Most Significant Bit is 1; stop when the MSB is 0
  while (( _mask & 0x80000000 )); do
    (( _cidr += 1 ))
    (( _mask <<= 1 ))
  done
  printf '%d\n' "${_cidr}"
}
inet4() {
  local _subcmd="${1:?Missing Subcommand}"; shift 1
  case "${_subcmd}" in
    int2str ) _inet4_int_to_octet "$@" ;;
    str2int ) _inet4_octet_to_int "$@" ;;
    cidr2mask ) _inet4_cidr_to_mask "$@" ;;
    mask2cidr ) _inet4_mask_to_cidr "$@" ;;
    * )
      log "Unknown Subcommand: ${_subcmd}"
      return 1
      ;;
  esac
}

### Process & Concurrency Tools ###

_proc_pgid() { ps -o pgid= -p "${1:?Missing Process ID}" | awk '{ print $1; }'; }
_proc_test() {
  local -A o=(
    [pid]= # The PID to Check
  ); parse_kv o "$@"
  kill -0 "${o[pid]}" &>/dev/null
}
_proc_stop() {
  local -A o=(
    [pid]= # The PID to Send the Signal to
    [sig]=TERM # The Signal to Send
    [timeout]=10 # The Timeout to Wait for the Process to Stop
    [kill]=true # Whether to Send a Kill Signal on Timeout
  ); parse_kv o "$@"

  log "Stopping Process ${o[pid]}"
  kill -s "${o[sig]}" "${o[pid]}" &>/dev/null || {
    log "Failed to stop Process ${o[pid]}"
    return 1
  }
  log "Waiting for Process ${o[pid]} to stop"
  timeout -s TERM "${o[timeout]}" tail --pid="${o[pid]}" -f /dev/null || {
    log "Timed out waiting for Process ${o[pid]} to stop"
    [[ "${o[kill]}" ]] || return 1
    log "Killing Process ${o[pid]}"
    kill -s KILL "${o[pid]}" &>/dev/null || {
      log "Failed to kill Process ${o[pid]}"
      return 1
    }
  }
}
_proc_start() {
  # Run a process in the background
  local -A o=(
    [name]= # The Name of the Process
    [result]= # An Associative Array name to store the results of spawning the process (on success only)
    [cmd]= # The Command to run
    [argv]= # An Array name holding the Arguments to pass to the command
    [env]= # An Associative Array name holding the Environment Variables to set; by default, the current environment is used
    [workdir]= # The Working Directory for the Command; defaults to the current working directory
    [stdin]= # The File to use as stdin; defaults to /dev/null
    [stdout]= # The File to write stdout to; defaults to $PWD/name.stdout
    [stderr]= # The File to write stderr to; defaults to $PWD/name.stderr
    [uid]= # The User ID to run the command as; defaults to the calling process's UID
    [gid]= # The Group ID to run the command as; defaults to the calling process's GID
  ); parse_kv o "$@"

  # Sanity Checks & Set Defaults
  [[ -n "${o[name]}" ]] || { log "Missing Name"; return 1; }
  [[ -n "${o[result]}" ]] || { log "(Proc ${o[name]}) Missing Result Variable"; return 1; }
  [[ -n "${o[cmd]}" ]] || { log "(Proc ${o[name]}) Missing Command"; return 1; }
  [[ -n "${o[workdir]}" ]] || o[workdir]="${PWD}"
  [[ -n "${o[stdin]}" ]] || o[stdin]="/dev/null"
  [[ -n "${o[stdout]}" ]] || o[stdout]="${PWD}/${o[name]}.stdout"
  [[ -n "${o[stderr]}" ]] || o[stderr]="${PWD}/${o[name]}.stderr"
  [[ -n "${o[uid]}" ]] || o[uid]="$(id -u)"
  [[ -n "${o[gid]}" ]] || o[gid]="$(id -g)"
  [[ -n "${o[env]}" ]] || {
    mapfile -t < <( env | sort )
    local -A _current_env; parse_kv _current_env "${MAPFILE[@]}"
    o[env]="_current_env"
  }
  [[ -n "${o[argv]:-}" ]] || { local -a _emtpy_argv=(); o[argv]="_emtpy_argv"; }
 
  # Deference Variables
  local -n _fn_nr_argv="${o[argv]}"
  local -n _fn_nr_env="${o[env]}"
  local -n _fn_nr_result="${o[result]}"

  # Setup the Output Files
  [[ -d "${o[workdir]}" ]] || install -dm0750 "${o[workdir]}"
  [[ -e "${o[stdin]}" ]] || { log "(Proc ${o[name]}) stdin not found: ${o[stdin]}"; return 1; }
  [[ -e "${o[stdout]}" ]] || install -m0640 /dev/null "${o[stdout]}"
  [[ -e "${o[stderr]}" ]] || install -m0640 /dev/null "${o[stderr]}"

  log "(Proc ${o[name]}) Spawning Background Process ${o[cmd]}"
  (
    # Variable Initialization
    local -A v=(
      [pid]=
      [pgid]=
      [cwd]="${o[workdir]}"
      [stdin]="${o[stdin]}"
      [stdout]="${o[stdout]}"
      [stderr]="${o[stderr]}"
    )
    # Sanity Checks
    [[ -d "${o[workdir]}" ]] || { log "(Proc ${o[name]}) workdir Not Found: ${o[workdir]}"; exit 127; }
    [[ -e "${o[stdin]}" ]] || { log "(Proc ${o[name]}) stdin Not Found: ${o[stdin]}"; exit 127; }
    [[ -e "${o[stdout]}" ]] || { log "(Proc ${o[name]}) stdout Not Found: ${o[stdout]}"; exit 127; }
    [[ -e "${o[stderr]}" ]] || { log "(Proc ${o[name]}) stderr Not Found: ${o[stderr]}"; exit 127; }
    
    # Assemble the Env
    mapfile -t envvars < <(
      for _key in "${!_fn_nr_env[@]}"; do
        printf '%s=%s\n' "${_key}" "${_fn_nr_env[${_key}]}"
      done
    )

    # Setup Signal Handling
    _handle_sig() {
      local s="${1:?Missing Signal}"; shift 1
      log "(Proc ${o[name]}) Received Signal: ${s}"
      case "${s}" in
        # The child process has terminated, stoped or has resumed
        CHLD)
          [[ -n "${v[pid]:-}" ]] || { log "(Proc ${o[name]}) No Process to Signal"; return 1; }
          kill -0 "${v[pid]}" &>/dev/null || {
            log "(Proc ${o[name]}) Child Process ${v[pid]} has Terminated"
            exit 0
          }
          log "(Proc ${o[name]}) TODO: Child Process ${v[pid]} still exists"
          ;;
        # Terminate the Process Group
        QUIT|TERM|INT)
          [[ -n "${v[pgid]:-}" ]] || { log "(Proc ${o[name]}) No Process Group to Signal"; return 1; }
          log "(Proc ${o[name]}) Terminating Process Group ${v[pgid]}"
          kill -TERM -"${v[pgid]}"
          ;;
        # Passthrough the Signal to the Root Process
        *)
          [[ -n "${v[pid]:-}" ]] || { log "(Proc ${o[name]}) No Process to Signal"; return 1; }
          log "(Proc ${o[name]}) Passthrough Signal ${v[pid]}"
          kill -$s "${v[pid]}"
          ;;
      esac
    }
    for i in {1..31}; do trap "_handle_sig $(kill -l $i)" "${i}"; done

    # Run the command in the background
    local _sync; _sync="$(mktemp)"
    local -a _setsid=( setsid --fork )
    local -a _env=( env --ignore-environment "${envvars[@]}" )
    local -a _run=(
      sudo --non-interactive
      --preserve-env --chdir="${o[workdir]}"
      --user="${o[uid]}" --group="${o[gid]}"
      --
    )
    local _cmd=( "${_setsid[@]}" "${_env[@]}" "${_run[@]}" "${o[cmd]}" "${_fn_nr_argv[@]}" )
    (
      while [[ -f "${_sync}" ]]; do sleep 0.1; done
      log "(Proc ${o[name]}) Running Command: ${_cmd[*]}"
      exec "${_cmd[@]}"
    ) <"${o[stdin]}" >>"${o[stdout]}" 2>>"${o[stderr]}" &
    v[pid]=$!
    v[pgid]="$(_proc_pgid "${v[pid]}")"
    disown "${v[pid]}"

    # Wait for the command to exit
    log "(Proc ${o[name]}) Removing Sync File"
    unlink "${_sync}"
    log "(Proc ${o[name]}) Waiting for Process ${v[pid]} to exit"
    tail --pid="${v[pid]}" -f /dev/null
  ) &
  local _pid=$!
  # Make sure the command started
  kill -0 "${_pid}" &>/dev/null || {
    log "(Proc ${o[name]}) Failed to start Background Process"
    return 1
  }
  # Disown the process
  disown "${_pid}"

  # Record Process information
  local _pgid; _pgid="$(_proc_pgid "${_pid}")"

  _fn_nr_result+=(
    [pid]="${_pid}"
    [pgid]="${_pgid}"
    [cwd]="$(readlink -f "${o[workdir]}")"
    [stdin]="${o[stdin]}"
    [stdout]="${o[stdout]}"
    [stderr]="${o[stderr]}"
  )

}
proc() {
  local _subcmd="${1:?Missing Subcommand}"; shift 1
  case "${_subcmd}" in
    start|stop|test|pgid ) "_proc_${_subcmd}" "$@" ;;
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
  local -a _dirs; mapfile -t _dirs < <(str split sep=: "str=${_o[dirs]}")
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