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
source "${CI_PROJECT_DIR}/src/utils/000_import.sh"

### Functions ###

_cloudinit_gen() {
  local -A o=(); parse_kv o "$@"

}

: <<'DOC'
# Network Design

We create a fully contained Software Defined Network for all the VMs to use.

A Tap Device is created to serve as the gateway for the VMs to communicate northbound.
MACVLAN Interfaces are created off the gateway interface per VM & set into bridge mode to allow
cross-VM communication.

All Network Services, such as NTP, DHCP, DNS, and IPAM are provided by the Gateway VM
spread accross multiple IP Addresses. Besides IPAM, all network services are stateless; that is on teardown
all state is lost.

All SDN Traffic uses a dedicated Routing Table to ensure that only SDN Traffic is routed through the Gateway.

DOC
_network_init() {
  log 'Initializing the Network'
  local -A o=(
    [name]=qemu0 # The name of the SDN Gateway Interface
    [inf]= # The Name of the Parent Interface; if not provided will use the Interface of the default Gateway
    [host]= # The IP Address of the Host; if not provided it will be determined from the host
    [gateway]= # The IP Address of the Gateway upstream of the SDN Gateway; if not provided it will be determined from the host
    [table]=1 # The Routing Table to use; will create if it does not exist
    [fwmark]=0x8765 # The Firewall Mark to use for SDN Traffic
    [domain]=vm # The Domain Name for the VM Network
  ); parse_kv o "$@"
  local -r netdir="${datadir}/net"
  [[ -d "${netdir}" ]] || install -dm0750 "${netdir}"
  kv init "d=${netdir}/kv"
  _kv() { kv "$1" "d=${netdir}/kv" "${@:2}"; }
  ! _kv get "k=.init" >/dev/null || { log 'Network already initialized'; return 0; }

  local ipamdir="${datadir}/ipam"
  _ipam_kv() { kv "$1" "d=${ipamdir}/kv" "${@:2}"; }
  _ipam_kv get "k=.init" >/dev/null || { log 'IPAM must be initialized before the network can be setup'; return 1; }

  # Record static vars
  _kv set "k=domain" "v=${o[domain]}"
  _kv set "k=fwmark" "v=${o[fwmark]}"

  # Determine the Host IP Address
  [[ -n "${o[host]:-}" ]] || {
    log 'Determining the Host IP Address'
    o[host]="$(
      ip -j route show default |
        jq -r '.[0].dev' |
        xargs -I {} ip -j addr show {} |
        jq -r '.[0].addr_info | map(select(.family == "inet"))[0].local'
    )" || {
      log 'Failed to determine the Host IP Address'
      return 1
    }
  }
  _kv set "k=hostIP" "v=${o[host]}"
  local _host_inf; _host_inf="$(
    # Find the Network Interface that has the Host IP Address
    ip -j addr show |
      jq -r --arg host "${o[host]}" \
        '.[] | select(.addr_info | map(select(.local == $host)) | length > 0) | .ifname'
  )"
  _kv set "k=hostInf" "v=${_host_inf}"

  # Determine the Gateway IP Address
  [[ -n "${o[gateway]:-}" ]] || {
    log 'Determining the Gateway IP Address'
    o[gateway]="$(
      ip -j route show default |
        jq -r '.[0].gateway'
    )" || {
      log 'Failed to determine the Gateway IP Address'
      return 1
    }
  }
  _kv set "k=gatewayIP" "v=${o[gateway]}"
  local _gtwy_inf; _gtwy_inf="$(
    # Find the Network Interface that routes the Gateway IP Address
    ip -j route get "${o[gateway]}" |
      jq -r '.[0].dev'
  )"
  _kv set "k=gatewayInf" "v=${_gtwy_inf}"

  # TODO: Do I need to make this idempotent
  log 'Creating the Gateway Interface'
  # NOTE: We can just create nested macvlan interfaces; but this requires that parent interface has an ethernet address
  #       We can't use something like a WireGuard Interface as the parent interface; later, we can probably check for
  #       MAC Support & otherwise create a dummy interface
  if [[ -z "${o[inf]:-}" ]]; then { local _parent_inf="${_gtwy_inf}"; }; else { local _parent_inf="${o[inf]}"; }; fi
  { ip -j link show "${_parent_inf}" | jq -e '.[0].link_type == "ether"' >/dev/null ; } || {
    log 'NotImplemented: Parent Interface does not have an Ethernet Address'
    return 1
  }
  _kv set "k=parentInf" "v=${_parent_inf}"
  _sudo ip link add link "${_parent_inf}" name "${o[name]}" type macvlan mode bridge
  _kv set "k=inf" "v=${o[name]}"

  log 'Assigning the SDN Gateway Interface IP Address'
  local _net; _net="$(_ipam_kv get "k=net")"
  local _prefix; _prefix="${_net##*/}"
  local _gtwy_ip; _gtwy_ip="$(_ipam_kv get "k=gatewayIP")"
  _sudo ip addr add "${_gtwy_ip}/${_prefix}" dev "${o[name]}"

  local _host_vip; _host_vip="$(_ipam_kv get "k=hostIP")"
  local _netsvc_vip; _netsvc_vip="$(_ipam_kv get "k=netsvcIP")"
  local _net_bcst; _net_bcst="$(_ipam_kv get "k=broadcast")"

  log 'Adding Packet Filtering Rules'
  : <<'DOC'
The Ruleset is relatively simple:

- Mark SDN Traffic, all other rules are based on this mark as not to impact non-SDN Traffic
  - Any traffic sourced from or destined to the SDN Network Range
  - Any traffic whose ingress interface is the SDN Gateway Interface
- Explicitly Allow
  - All Established/Related Traffic
  - All new traffic originating from the SDN's Network Range
    - But don't allow SDN traffic destined to the Gateway IP Address; Peers must use the Network Service VIPs
- Setup DNAT rules for the Network Services:
  - Map Network Services VIP to the Gateway's IP Address
  - Map the Host VIP to the Host's IP Address
DOC
  _sudo nft -f - <<NFT
table ip ${o[name]} {
  # Everytime a VM is created/destroyed we have to update this set
  set sdn_ifnames {
    type ifname
    elements = { "${o[name]}" }
  }
  # Mark the SDN Traffic & Jump to the SDN Chains
  chain mark_sdn {
    type filter hook prerouting priority mangle
    ip saddr ${_net} meta mark set ${o[fwmark]} return
    ip daddr ${_net} meta mark set ${o[fwmark]} return
    iifname @sdn_ifnames meta mark set ${o[fwmark]} return
  }
  chain input {
    type filter hook input priority filter
    meta mark ${o[fwmark]} jump sdn_input
  }
  chain forward {
    type filter hook forward priority filter
    meta mark ${o[fwmark]} jump sdn_forward
  }
  chain output {
    type filter hook output priority filter
    meta mark ${o[fwmark]} jump sdn_output
  }
  chain prerouting {
    type nat hook prerouting priority dstnat
    meta mark ${o[fwmark]} jump sdn_prerouting
  }
  chain postrouting {
    type nat hook postrouting priority srcnat
    meta mark ${o[fwmark]} jump sdn_postrouting
  }

  # Packet Filtering
  chain sdn_input {
    ct state { established, related } accept
    # Eval NetSvcs Traffic in another chain
    th dport { 53, 67, 68, 123 } jump sdn_netsvcs
    # Block all SDN Unicast Network Traffic, sourced from peers, Destined to the SDN Gateway IP
    ip saddr ${_net} ip daddr ${_gtwy_ip} ip saddr != ${_gtwy_ip} pkttype != { broadcast, multicast } drop
    # Allow all other SDN Traffic
    ip saddr ${_net} ct state new accept
    log prefix "SDN Traffic: " flags all
    drop
  }
  chain sdn_netsvcs {
    accept
    ### TODO
    # th dport { 53, 67, 68, 123 } ip daddr { ${_gtwy_ip}, ${_netsvc_vip} } accept
    # drop
  }
  chain sdn_forward {
    ct state { established, related } accept
    ip saddr ${_net} ct state new accept
    log prefix "SDN Traffic: " flags all
    drop
  }
  chain sdn_output {
    accept # TODO: For now just allow all outbound
  }

  # NAT & VIP Mapping
  chain sdn_prerouting {
    # Map the Network Services VIP to the Gateway's IP Address
    ip daddr ${_netsvc_vip} dnat to ${_gtwy_ip}
    # Map the Host VIP to the Host's IP Address
    ip daddr ${_host_vip} dnat to ${o[host]}
    accept
  }
  chain sdn_postrouting {
    # Masquerade all outbound traffic
    ip saddr ${_net} oifname "${o[name]}" masquerade
    accept
  }
}
NFT
  _kv set "k=nftable" "v=${o[name]}"

  # We have to bring the interface up before we can add routes
  log 'Bringing Up the Gateway Interface'
  _sudo ip link set dev "${o[name]}" up

  log 'Adding Conditional Routing'
  _kv set "k=table" "v=${o[table]}"
  # Create a new Routing table for the SDN
  _add_route() { _sudo ip route add "$@" table "${o[table]}"; }
  _add_route "${_net}" dev "${o[name]}" # Route all SDN Traffic to the Gateway Interface
  _add_route default via "${o[gateway]}" # Route all non-SDN Traffic to the Gateway
  # Add a rule for all SDN traffic to use the SDN Routing Table
  _add_rule() { _sudo ip rule add "$@" lookup "${o[table]}"; }
  _add_rule to "${_net}" # All Traffic to the SDN Network
  _add_rule from "${_net}" # All Traffic from the SDN Network

  log 'Enabling IP Forwarding'
  for syskey in \
    "net.ipv4.conf.${o[name]}.forwarding" \
    "net.ipv4.conf.${_host_inf}.forwarding" \
    "net.ipv4.conf.${_gtwy_inf}.forwarding" \
  ; do
    _kv set "k=${syskey}" "v=$(sysctl -n "${syskey}")"
    _sudo sysctl -qw "${syskey}=1"
  done

  log 'Network Initialized'
  _kv set "k=.init"
}
_network_revert() {
  log 'Reverting the Network State'
  local -r netdir="${datadir}/net"
  [[ -d "${netdir}" ]] || { log "Network not initialized"; return 0; }
  _kv() { kv "$1" "d=${netdir}/kv" "${@:2}"; }
  # _kv get "k=.init" || { log 'Network not initialized'; return 0; }
  local ipamdir="${datadir}/ipam"
  _ipam_kv() { kv "$1" "d=${ipamdir}/kv" "${@:2}"; }

  log 'Bringing down the Gateway Interface'
  local _inf; _inf="$(_kv get "k=inf")"
  _sudo ip link set dev "${_inf}" down

  log 'Disabling IP Forwarding'
  for syskey in \
    "net.ipv4.conf.${_inf}.forwarding" \
    "net.ipv4.conf.$(_kv get "k=hostInf").forwarding" \
    "net.ipv4.conf.$(_kv get "k=gatewayInf").forwarding" \
  ; do
    _sudo sysctl -qw "${syskey}=$(_kv get "k=${syskey}")"
  done

  log 'Removing Conditional Routing'
  local _net; _net="$(_ipam_kv get "k=net")"
  local _table; _table="$(_kv get "k=table")"
  _rm_rule() { _sudo ip rule del "$@" lookup "${_table}"; }
  _rm_rule to "${_net}"
  _rm_rule from "${_net}"
  _sudo ip route flush table "${_table}"

  log 'Flushing Netfilter Table'
  local _nftable; _nftable="$(_kv get "k=nftable")"
  _sudo nft "delete table ip ${_nftable}"

  log 'Removing the SDN Gateway Interface'
  _sudo ip link del dev "${_inf}"

  log 'Flushing the KV Store'
  _kv flush
}
_dnsmasq_gencfg() {
  log 'Generating dnsmasq Configs'
  local \
    netdir="${datadir}/net" \
    ipamdir="${datadir}/ipam"
    masqdir="${datadir}/net/dnsmasq"
  install -dm0750 "${masqdir}"{,/kv,/conf.d}
  _kv() { kv "$1" "d=${masqdir}/kv" "${@:2}"; }
  _netkv() { kv "$1" "d=${netdir}/kv" "${@:2}"; }
  _ipamkv() { kv "$1" "d=${ipamdir}/kv" "${@:2}"; }

  local _netmask; _netmask="$(_ipamkv get "k=net")"; _netmask="${_netmask##*/}"; _netmask="$(
    inet4 cidr2mask "${_netmask}"
  )"

  install -m0640 <(cat  <<DNSMASQ
### The Server's Main Configuration ###

# Socket Opts
listen-address=$(_ipamkv get "k=gatewayIP") # Listen ONLY on the SDN Gateway IP

# DNS
resolv-file=/etc/resolv.conf # Use the Host's DNS Servers
clear-on-reload # Flush the DNS cache when resolv.conf changes
strict-order # Search upstream DNS Servers in the order they are listed in resolv.conf
no-hosts # Don't serve DNS Records from /etc/hosts
domain=$(_netkv get "k=domain")
local=/$(_netkv get "k=domain")/
stop-dns-rebind # Prevent DNS Rebinding Attacks
rebind-localhost-ok # Allow DNS Rebinding to localhost

# DHCP
dhcp-generate-names # Generate DHCP Names if the client doesn't provide one
dhcp-range=$(_ipamkv get "k=dhcp"),1h # The DHCP Range
dhcp-option=option:netmask,${_netmask} # The Network Mask
dhcp-option=option:router,$(_ipamkv get "k=gatewayIP") # The Gateway IP
dhcp-option=28,$(_ipamkv get "k=broadcast") # The Broadcast Address
dhcp-option=54,$(_ipamkv get "k=netsvcIP") # The DHCP Server IP clients will use
dhcp-option=51,600 # The Lease Time in seconds
dhcp-option=option:dns-server,$(_ipamkv get "k=netsvcIP") # The DNS Server IP clients will use
dhcp-option=option:ntp-server,$(_ipamkv get "k=netsvcIP") # The NTP Server IP clients will use
dhcp-option=option:domain-name,$(_netkv get "k=domain") # The Domain Name
dhcp-option=option:domain-search,$(_netkv get "k=domain") # The Domain Search List

# Meta Options
log-facility=- # Log to stderr
log-queries # Log DNS Queries
log-dhcp # Log DHCP Requests
cache-size=1000 # Cache Size

# Finally include the conf.d directory
conf-dir=${masqdir}/conf.d/,*.conf

DNSMASQ
  ) "${masqdir}/main.conf"

}
_dnsmasq_up() {
  log 'Bringing Up the dnsmasq Server'
  local -A o=(
    [bin]= # The Path to the dnsmasq binary
  ); parse_kv o "$@"
  kv get "d=${datadir}/net/kv" "k=.init" >/dev/null || { log 'Network not initialized'; return 1; }
  local masqdir="${datadir}/net/dnsmasq"
  install -dm0750 "${masqdir}"{,/kv}
  install -m0640 /dev/null "${masqdir}/leases"
  _kv() { kv "$1" "d=${masqdir}/kv" "${@:2}"; }

  case "$(_kv get "k=.status")" in
    up ) log 'dnsmasq already running'; return 0 ;;
    down | "" ) : ;; # Do Nothing
    * ) log 'Unknown dnsmasq Status'; return 1 ;;
  esac

  ### TODO: Keep after development?

  log 'Sanity Checks'
  # Check if there is a dnsmasq process running
  ! _kv get "k=pid" &>/dev/null || {
    ! proc test "pid=$(_kv get "k=pid")" || {
      log 'There is already a dnsmasq instance running'
      return 1
    }
  }

  ###

  _dnsmasq_gencfg || { log 'Failed to Generate dnsmasq Configs'; return 1; }

  local dnsmasq="${o[bin]:-}"; [[ -n "${dnsmasq:-}" ]] || dnsmasq="$(command -v dnsmasq)"
  [[ -x "${dnsmasq}" ]] || { log 'dnsmasq not found'; return 1; }
  _kv set "k=bin" "v=${dnsmasq}"

  log 'Validating dnsmasq Configs'
  "${dnsmasq}" --test --conf-file="${masqdir}/main.conf" || {
    log 'Failed to Validate dnsmasq Configs'
    return 1
  }

  log 'Running dnsmasq'
  local -A _dnsmasq_res _dnsmasq_env
  # Merge current envvars w/ dnsmasq
  mapfile -t curenv < <( env | sort );
  for kre in \
    '^PATH' \
    '^LC_' \
    '^LANG' \
  ; do
    mapfile -t filterenv < <( str filter "${kre}=" "${curenv[@]}" )
    for line in "${filterenv[@]}"; do
      local k="${line%%=*}" v="${line#*=}"
      _dnsmasq_env["${k}"]="${v}"
    done
  done
  log "Using the Following Env for DNSMasq: $(declare -p _dnsmasq_env)"
  local -a _dnsmasq_argv=(
    --keep-in-foreground
    --dhcp-leasefile="${masqdir}/leases"
    # TODO: --dhcp-script="${masqdir}/dhcp-lease.sh"
    --conf-file="${masqdir}/main.conf"
  )
  proc start \
    name=dnsmasq \
    result=_dnsmasq_res \
    "cmd=${dnsmasq}" \
    argv=_dnsmasq_argv \
    env=_dnsmasq_env \
    workdir="${masqdir}" \
    stdout="${masqdir}/dnsmasq.log" \
    stderr="${masqdir}/dnsmasq.log" \
    uid=0 gid=0
  _kv set "k=pid" "v=${_dnsmasq_res[pid]}"
  _kv set "k=pgid" "v=${_dnsmasq_res[pgid]}"
  _kv set "k=.status" "v=up"
}
_dnsmasq_down() {
  log 'Bringing Down the dnsmasq Server'
  local masqdir="${datadir}/net/dnsmasq"
  install -dm0750 "${masqdir}"{,/kv}
  _kv() { kv "$1" "d=${masqdir}/kv" "${@:2}"; }

  local _pid; _pid="$(_kv get "k=pid")" || {
    log 'dnsmasq not running'
    _kv set "k=.status" "v=down"
    return 0
  }
  proc test "pid=${_pid}" || {
    log 'dnsmasq not running'
    _kv set "k=.status" "v=down"
    return 0
  }
  log 'Killing dnsmasq'
  proc stop "pid=${_pid}" || {
    log 'Failed to Stop dnsmasq'
    return 1
  }
  _kv set "k=.status" "v=down"
}
_chrony_up() {
  log 'Bringing Up the Chrony Server'
  : # TODO
}
_chrony_down() {
  log 'Bringing Down the Chrony Server'
  : # TODO
}

_ipam_init() {
  log 'Initializing IPAM'
  local -A o=(
    [net]="169.254.0.0/24" # The Network Range
    [svc]="169.254.0.1,169.254.0.9" # The Service Range (Reserved for Network Services)
    [static]="169.254.0.10,169.254.0.99" # The Static IP Range
    [dhcp]="169.254.0.100,169.254.0.254" # The DHCP Range
    [broadcast]="169.254.0.255" # The Broadcast Address (Must be the top most ip address of the network)
    [gatewayIP]="169.254.0.1" # The Network's Gateway Address
    [netsvcIP]="169.254.0.2" # The VIP for the Network Services
    [hostIP]="169.254.0.3" # The VIP for the Host
  ); parse_kv o "$@"
  [[ -d "${datadir}/ipam" ]] || install -dm0750 "${datadir}/ipam"
  [[ -d "${datadir}/ipam/kv" ]] || install -dm0750 "${datadir}/ipam/kv"
  _kv() { kv "$1" "d=${datadir}/ipam/kv" "${@:2}"; }
  ! _kv get "k=.init" || { log 'IPAM already initialized'; return 0; }
  install -dm0750 "${datadir}/ipam/leases"

  # Write the KV Pairs to disk
  for k in \
    net svc static dhcp broadcast gatewayIP netsvcIP hostIP \
  ; do
    _kv set "k=${k}" "v=${o[$k]}"
  done

  _kv set "k=.init"
}

_ipam_lease_addr() {
  log 'Leasing a static IP Address'
  : # TODO
}

_ipam_release_addr() {
  log 'Releasing a static IP Address'
  : # TODO
}

_runtime_load() {
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

  # Find the EFI Firmware
  local _efi_firmware
  for _search_path in \
    "${datadir}" \
    "/home/linuxbrew/.linuxbrew/share/qemu" \
    "/usr/share/OVMF" \
  ; do
    mapfile -t _fws < <( find "${_search_path}/" -type f -iname '*.fd' -print )
    [[ "${#_fws[@]}" -gt 0 ]] || continue
    mapfile -t <( str filter "/(edk2-${_arch}-code|OVMF_CODE|OVMF)\." "${_fws[@]}" )
    log "Found EFI Firmware: $(str join ', ' "${MAPFILE[@]}")"
    [[ "${#MAPFILE[@]}" -gt 0 ]] || continue
    _efi_firmware="${MAPFILE[0]}"
    break
  done
  [[ -n "${_efi_firmware}" ]] || {
    log 'Failed to find EFI Firmware; if you have skipped building OVMF during initialization than please install your distributions OVMF package; on Debian/Ubuntu it is `ovmf`'
    return 1
  }
  log "Using EFI Firmware: ${_efi_firmware}"

  # Find the BIOS Firmware
  local _bios_firmware
  for _path in \
    "${datadir}" \
    "/home/linuxbrew/.linuxbrew/share/qemu" \
    "/usr/share/seabios" \
  ; do
    mapfile -t _fws < <( find "${_search_path}/" -type f -iname '*.bin' -print )
    [[ "${#_fws[@]}" -gt 0 ]] || continue
    mapfile -t <( str filter '/(bios)\.' "${_fws[@]}" )
    log "Found BIOS Firmware: $(str join ', ' "${MAPFILE[@]}")"
    [[ "${#MAPFILE[@]}" -gt 0 ]] || continue
    _bios_firmware="${MAPFILE[0]}"
    break
  done
  [[ -n "${_bios_firmware}" ]] || {
    log 'Failed to find BIOS Firmware; if you have skipped building SeaBIOS during initialization than please install your distributions SeaBIOS package; on Debian/Ubuntu it is `seabios`'
    return 1
  }
  log "Using BIOS Firmware: ${_bios_firmware}"

  # Load the Network Options
  local _net_opts; mapfile -t < <(
    for k in \
      net dhcp static host dns ipv4 ipv6 restrict \
    ; do
      printf '%s=%s\n' "$k" "${datadir}/ipam/opts/$k"
    done
  ); _net_opts="$(str join ',' "${MAPFILE[@]}")"

  # Assemble the System Options
  _opts_fn_nr[arch]="${_arch}"
  _opts_fn_nr[cpus]="${_cpus}"
  _opts_fn_nr[mem]="${_mem}"
  _opts_fn_nr[accel]="${_accel}"
  _opts_fn_nr[efiFirmware]="${_efi_firmware}"
  _opts_fn_nr[biosFirmware]="${_bios_firmware}"
  _opts_fn_nr[netOpts]="${_net_opts}"
}

_vm_spawn() {
  log 'Spawning VM'
  local -A _user_opts=(
    [name]='dev-vm'
    [machine]=q35 # q35 | pc | microvm
    [rootDisk]= # The Root Disk Image
    [cdrom]= # The CDROM Image
    # Runtime Overrides
    [arch]= # Defaults to Host Arch
    [cpus]= # Defaults to Host CPU Count
    [mem]= # Defaults to 90% of Host Memory
    [accel]= # Defaults to KVM
    [efiFirmware]= # The EFI Firmware to use
    [biosFirmware]= # The BIOS Firmware to use 
  ); parse_kv _user_opts "$@"
  local -r vmdir="${datadir}/${o[name]}"

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
  _runtime_load _sys_opts
  
  local -A o=(); merge_kv o _sys_opts _user_opts

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
    -chardev "socket,id=monitor0,path=${vmdir}/monitor.sock,server,nowait,logfile=${vmdir}/monitor.log"
    -mon "chardev=monitor0,mode=control"
  )
  local -a _serial=( # The VM Serial Console
    -nographic # Completely Disable Graphics; Serial Only
    # Unix Socket w/ extra opts: a logfile, no signals
    -chardev "socket,id=serial0,path=${vmdir}/serial.sock,server,nowait,logfile=${vmdir}/serial.log,signal=off"
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
    -chardev "socket,id=chrtpm0,path=${vmdir}/tpm0.sock"
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
  sudo "${_qemu_system}" "${_qemu_argv[@]}" &>"${vmdir}/qemu.log" &
  printf %s "$!" > "${vmdir}/qemu.pid"
  kill -0 "$(< "${vmdir}/qemu.pid")" || {
    log 'Failed to Start VM'
    return 1
  }
  disown "$(< "${vmdir}/qemu.pid")"
}

_vm_kill() {
  : # TODO Kill the VM Process
}

_vm_wait_for() {
  : # TODO Wait for a condition to be met
}

### SubCommands ###

qemu_init() {
  log 'Initializing the QEMU Environment'

  if check_root &>/dev/null; then { log 'Do not run as root'; return 1; }; fi

  command -v "qemu-system-$(uname -m)" &> /dev/null || { log 'QEMU not found'; return 1; }

  get_event 'ipam-init' || {
    log 'Initializing IPAM'
    _ipam_init
    set_event 'ipam-init'
  }

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

  get_event 'ipam-init' || {
    # log 'Initializing IPAM'
    _ipam_init
    set_event 'ipam-init'
  }

  get_event 'net-init' || {
    # log 'Initializing the Network'
    _network_init
    set_event 'net-init'
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

  get_event 'first-boot' || {
    log 'Spawning the VM'
    _vm_spawn "name=${_opts[name]}" \
      "root=${vmdir}/root.img" \
      "ci=${vmdir}/ci.img"
    
    log 'Waiting for VM Bootstrapping to Finalize'
    _vm_wait_for "name=${_opts[name]}" \
      "event=..."

    log 'Killing the VM'
    _vm_kill "name=${_opts[name]}"

    set_event 'first-boot'
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
  init ) can_sudo && qemu_init ;;
  purge ) can_sudo && purge;;
  vm-init ) can_sudo && vm_init;;
  vm-purge ) can_sudo && vm_purge;;
  _dev ) can_sudo && "$@";;
  * ) log "Unknown subcommand: ${subcmd}"; exit 1 ;;
esac
