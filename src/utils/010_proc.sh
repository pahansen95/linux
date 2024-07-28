#!/usr/bin/env bash

: <<'DOC'

This is an PoC of implementing a Service Controller in Bash.

The Design Goals of the process controller is to:

- Allow spawning of long lived services that persist after the script has exited
- Load last known set of processes (reschedule) service controllers
- Manage Process Lifecycle; restart process on a crash

To do this we need:

- State Directory Per Service
- Spawning of a Process

State directory can be maintained as an ondisk KVStore

Spawning the process should result in the service controller being spawned in a standalone process.
The Controller then sets up the process's executing environment (workdir, env, stdin/out/err, etc...)
The Controller then runs the service process in a subproc.
The Controller handles all signals passing them through to the service proc as appropriate.
If the Service Proc Unexpectadly fails, then the Controller restarts it.
If the Serice Proc Exists, then the Controller exits

This script provides a functional interface to interacting with the controller:
- Start & Stop Controller
- Query State & Gather Service Results

## Service Def

```json
{
  "cmd": "/abs/path/to/executable"
  "argv": [ "list", "of", "args", "to", "pass" ],
  "env": { "KEY": "VAL" },
  "cwd": "/abs/path/to/working/dir",
  "stdin": "/abs/path/to/file",
  "stdout": "/abs/path/to/file",
  "stderr": "/abs/path/to/file",
  "user": 1000,
  "group": 1000,
  "timeout": 0,
}
```

### Controller States

- undefined: Some undefined state (such as before initialization)
- up: The Controller is currently up & running
- down: The Controller was brought down
- error: The Controller experienced some sort of error outside of the service (ie. a runtime error)
- complete,pass: The Service has completed successfully
- complete,fail: The Service has completed on failure

DOC

declare -A _procerr=(
  [NO]='No Error'
  [RUNTIME]='!!! RUNTIME ERROR !!!'
  [SPAWN]='Failed To Spawn Service Controller'
  [TIMEOUT]='The Service Controller Timed Out'
  [DEAD]='The Service Controller Unexpectedly Died'
)

### The Controller Runtime

_svcdef_cmd() { jq -er '.cmd'; }
_svcdef_argv() {
  local -n _fn_nr_argv="${1:?Missing Array Nameref}"
  mapfile -t _fn_nr_argv < <(
    jq -er '.argv[]'
  )
}
_svcdef_env() {
  local -n _fn_nr_env="${1:?Missing Assoc Array Nameref}"
  # TODO If ENV Object is empty then load some basic Env vars from the current environment
  { log "Not Implemented: ${FUNCNAME}"; return 127; }
}
_svcdef_stdin() { log "Not Implemented: ${FUNCNAME}"; return 127; }
_svcdef_stdout() { log "Not Implemented: ${FUNCNAME}"; return 127; }
_svcdef_stderr() { log "Not Implemented: ${FUNCNAME}"; return 127; }
_svcdef_cwd() { log "Not Implemented: ${FUNCNAME}"; return 127; }
_svcdef_uid() { log "Not Implemented: ${FUNCNAME}"; return 127; }
_svcdef_gid() { log "Not Implemented: ${FUNCNAME}"; return 127; }
_svcdef_timeout() { log "Not Implemented: ${FUNCNAME}"; return 127; }

_controller_monitor() {
  # Monitor a Controller for Events; events are ommitted in the format 'EVENT[|OPTS[,OPTS...]]'
  local -A o=(
    [statedir]= # The Directory to store relevant state in
    [sink]= # The optional file to write events to; by default writes to stdout
    [sep]=":," # The Seperators to use: 1st char is outer, 2nd char is inner
    [timeout]=0 # Optionally sets a timeout event after N seconds; if 0 then no timeout is set
    [sig]=false # Setup Signal Handling?
  ); parse_kv o "$@"
  [[ -d "${o[statedir]}" ]] || { log "Controller State Directory does not exist: ${o[statedir]}"; return 1; }
  [[ -d "${o[statedir]}/kv" ]] || { log "Controller KV Directory does not exist: ${o[statedir]}/kv"; return 1; }
  _kv() { kv "${1:?Missing KV Subcmd}" "d=${o[statedir]}/kv" "$@" ; }
  local svc_name; svc_name="$(_kv get k=name)" || { log 'Controller failed to get Service Name'; return 1; }
  _log() { log "${svc_name}::$*" ; }

  # Setup Signal Handling as early as possible
  [[ "${o[sig]}" == false ]] || trap 'exit 0' TERM

  _assert "[[ ${#o[sep]} -eq 2 ]]"
  local _OS="${o[sep]:0:1}" _IS="${o[sep]:1:1}"

  if [[ -z ${o[sink]:-} ]]; then
    _emit() { printf '%s\n' "$(str join "${_OS}" "$@")" ; }
  else
    _emit() { printf '%s\n' "$(str join "${_OS}" "$@")" >"${o[sink]}" ; }
  fi
  trap '_emit exit' EXIT # Make sure to publish an exit event

  event_generator() {
    local _tmpdir; _tmpdir="$(mktemp -d -p "${o[statedir]}/.tmp")"
    local -a _jobs
    _cleanup() {
      [[ "${#_jobs[@]}" -le 0 ]] || {
        kill -TERM "${_jobs[@]}" || true
        wait "${_jobs[@]}" || true
      }
      [[ ! -d "${_tmpdir}" ]] || {
        rm -rf "${_tmpdir}" || true
      }
    }; trap _cleanup RETURN
    # Conditionally Schedule a Timeout
    [[ "${o[timeout]}" -le 0 ]] || (
      trap 'exit 0' TERM
      sleep "${o[timeout]}"
      printf '%s\n' 'timeout'
    ) > "${_tmpdir}/timeout.events" &
    _jobs+=( $! )
    # Listen for a Dead Controller
    (
      trap 'exit 0' TERM
      [[ -f "${o[statedir]}/kv/cntrlpid" ]] || inotifywait -e create "${o[statedir]}/kv/cntrlpid" # Wait for the key to exist
      tail --pid="$(_kv get k=cntrlpid)" -f /dev/null
      printf '%s\n' 'dead:cntrl'
    ) > "${_tmpdir}/dead-cntrl.events" &
    _jobs+=( $! )
    # Listen for a Service Exit
    (
      trap 'exit 0' TERM
      [[ -f "${o[statedir]}/kv/svcpid" ]] || inotifywait -e create "${o[statedir]}/kv/svcpid" # Wait for the key to exist
      tail --pid="$(_kv get k=svcpid)" -f /dev/null
      printf '%s\n' 'dead:svc'
    ) > "${_tmpdir}/dead-svc.events"
    # Listen for KV CRUD Events
    inotifywait --monitor \
      --format '%e:%f%n' \
      -e 'create' -e 'delete' -e 'close_write' \
      "${o[statedir]}/kv" \
    > "${_tmpdir}/kv.events" &
    _jobs+=( $! )
    # Publish all events
    printf '%s\n' init # Publish an init message to let any subscribers know we are ready to go
    tail -f "${_tmpdir}/"*.events
  }
  event_emitter() {
    while IFS= read -r line; do
      local event=""; local -a opts=()
      mapfile -t < <( str split 'sep=:' "str=${line}" "max=1" )
      # _assert "[[ ${#MAPFILE[@]} -eq 2 ]]"
      local _e="${MAPFILE[0],,}" _k="${MAPFILE[1]:-}"
      case "${_e}" in
        timeout ) event=TIMEOUT ;;
        dead ) event=DEAD; opts+=( "$_k" ) ;;
        create | close_write ) event=UPDATE; opts+=( "$_k" "$(_kv get "k=$_k")" ) ;;
        delete ) event=DELETE; opts+=( "$_k" ) ;;
        * ) _log "${_procerr[RUNTIME]}: unhandled event: ${_e}"; exit 1;;
      esac
      case "${#opts[@]}" in
        0 ) _emit "${event}" ;;
        1 ) _emit "${event}" "${opts[0]}"
        * ) _emit "${event}" "$(str join "${_IS}" "${opts[@]}")"
      esac
    done
  }
  
  # TODO: This blocks forever; Is this desirable?
  log 'Scheduling Controller Monitor'
  event_emitter < <( event_generator )

}

_controller_loop() {
  # Start the Controller
  local -A o=(
    [statedir]= # The Directory to store relevant state in
  ); parse_kv o "$@"
  [[ -d "${o[statedir]}" ]] || { log "Controller State Directory does not exist: ${o[statedir]}"; return 1; }
  [[ -d "${o[statedir]}/kv" ]] || { log "Controller KV Directory does not exist: ${o[statedir]}/kv"; return 1; }
  _kv() { kv "${1:?Missing KV Subcmd}" "d=${o[statedir]}/kv" "$@" ; }
  local svc_name; svc_name="$(_kv get k=name)" || { log 'Controller failed to get Service Name'; return 1; }
  _log() { log "${svc_name}::$*" ; }

  # Set certain Information as early as possible
  _kv set k=cntrlpid "v=$$"
  _kv set k=cntrlpgid "v=$(pgid $$)"
  _kv set k=bootid "v=$(boot_id)"
  
  # TODO: Parse the Service Def to generate the SVC vars
  local svc_cmd svc_stdin svc_stdout svc_stderr svc_cwd
  local -i svc_uid svc_gid
  svc_cmd="$( _svcdef_cmd < "${o[statedir]}/svcdef.json" )" || { _log "Failed to load the SvcDef cmd"; return 1; }
  svc_stdin="$( _svcdef_stdin < "${o[statedir]}/svcdef.json" )" || { _log "Failed to load the SvcDef stdin"; return 1; }
  svc_stdout="$( _svcdef_stdout < "${o[statedir]}/svcdef.json" )" || { _log "Failed to load the SvcDef stdout"; return 1; }
  svc_stderr="$( _svcdef_stderr < "${o[statedir]}/svcdef.json" )" || { _log "Failed to load the SvcDef stderr"; return 1; }
  svc_cwd="$( _svcdef_cwd < "${o[statedir]}/svcdef.json" )" || { _log "Failed to load the SvcDef WorkDir"; return 1; }
  svc_uid="$( _svcdef_uid < "${o[statedir]}/svcdef.json" )" || { _log "Failed to load the SvcDef UserID"; return 1; }
  svc_gid="$( _svcdef_gid < "${o[statedir]}/svcdef.json" )" || { _log "Failed to load the SvcDef GroupID"; return 1; }
  svc_timeout="$( _svcdef_timeout < "${o[statedir]}/svcdef.json" )" || { _log "Failed to load the SvcDef Timeout"; return 1; }
  local -a svc_argv; _svcdef_argv _argv < "${o[statedir]}/svcdef.json" || { _log 'Failed to load SvcDef ARGV'; return 1; }
  local -a svc_env; _svcdef_env _env < "${o[statedir]}/svcdef.json" || { _log 'Failed to load SvcDef ENV'; return 1; }
  local -a cmd=(
    env --ignore-environment "${_env[@]}"
    sudo --non-interactive --preserve-env --chdir="${svc_cwd}" --user="${svc_uid}" --group="${svc_gid}" --
    "${svc_cmd}" "${svc_argv[@]}"
  )
  
  # Setup Signal Handling
  _svc_kill() {
    # Send the service a signal
    local s="${1:?Missing Signal}"
    kill -$s "$(_kv get k=svcpid)" || {
      log "Failed to send signal to the service: ${s}"
      return 1
    }
  }
  _handle_signal() {
    local s="${1:?Missing Signal}"
    _log "Recieved Signal: ${s}"
    # For a list of signals & their usage, see https://www.gnu.org/software/libc/manual/html_node/Standard-Signals.html
    case "${s}" in
      HUP ) log 'Signal Handler Not Implemented' ;; # TODO: Restart the Service
      QUIT | INT ) _svc_kill TERM ;;
      TERM ) _svc_kill KILL ;;
      STOP | STP | CONT | CHLD | CLD ) log 'Ignoring Signal' ;;
      * ) _svc_kill "$s" ;;
    esac
  }

  _assert "[[ ${svc_timeout} -le 0 ]]"
  local gate="${o[statedir]}/.svcgate"; install -m0640 /dev/null "${gate}"
  (
    # Wait until the Parent opens the gate
    _assert "[[ -f '${gate}' ]]"
    inotifywait --event delete_self "${gate}" &>/dev/null
    # Execute the Service Command
    exec "${cmd[@]}" <"${svc_stdin}" >"${svc_stdout}" 2>"${svc_stderr}"
  ) &
  local -i svc_pid="$!"
  _kv set k=svcpid "v=${svc_pid}"

  # Delete the gate
  unlink "${gate}"

  # TODO: Block for more than just the process exiting; but this is good enough for now
  _log "Waiting for Service to complete"
  tail --pid="${svc_pid}" -f /dev/null &>/dev/null

  # Determine what happened
  wait "${svc_pid}"
  local -i _svc_rc="$?"
  case "${_svc_rc}" in
    0 )
      _log "Service Completed Successfully"
      _kv set k=status "v=complete,pass"
      ;;
    * )
      _log "Service Completed on Failure"
      _kv set k=status "v=complete,fail"
      _kv set k=rc v="${_svc_rc}"
      ;;
  esac

  # TODO: Implement Service Restart
}

### The Controller Interface

_controller_up() {
  # Bring Up a Controller to manage a service
  local -A o=(
    [statedir]= # The Directory to store relevant state in
    [svcdef]= # The Service Definition Encoded as a JSON String
    [name]= # The Name of the service; if not specified, & this is initialization, a random name will be generated
  ); parse_kv o "$@"
  [[ -d "${o[statedir]}" ]] || install -dm0750 "${o[statedir]}"{,/.tmp}
  [[ -d "${o[statedir]}/kv" ]] || install -dm0750 "${o[statedir]}/kv"
  _kv() { kv "${1:?Missing KV Subcmd}" "d=${o[statedir]}/kv" "$@" ; }
  
  # If the name isn't set, then set it, otherwise use the previously set name
  _kv get k=name &>/dev/null || {
    [[ -n "${o[name]:-}" ]] || o[name]="svc-$( str rand 16 )"
    _kv set k=name "v=${o[name]}"
  }
  o[name]="$(_kv get k=name)"
  _log() { log "${o[name]}::$*" ; }

  # Get the Controller's Current status
  local _init=false
  case "$(_kv get k=status "v=undefined")" in
    undefined )
      ! _kv get k=status &>/dev/null || {
        _log '!!! FATAL ERROR !!! The Controller is in an undefined state; refusing to proceed.'
        return 1
      }
      _log 'Initializing the Controller'
      _init=true
      ;;
    error )
      _log "Controller encountered an error; refusing to proceed: $(_kv get k=error "v=Error Unknown")"
      return 1
      ;;
    up )
      [[ "$(_kv get k=bootid v="$(boot_id)")" != "$(boot_id)" ]] || {
        # TODO: Make a sanity Check the controller is actually up?
        _log 'Controller is already up'
        return 0
      }
      _log 'Boot ID Mismatch; will respawn the controller'
      ;;
    down )
      _log 'Bringing Up Controller'
      ;;
    complete* )
      _log 'Can not bring up a completed controller, please retrieve results & bring the controller down first'
      return 1
      ;;
  esac
  _assert "[[ '$(_kv get k=status "v=undefined")' == 'down' || '$(_kv get k=status "v=undefined")' == 'undefined' ]]"

  # Parse & Record the Service Definition
  case "${_init}" in
    true )
      [[ -n "${o[svcdef]:-}" ]] || {
        _log 'No Service Definition Provided'
        return 1
      }
      _log 'Recording the Service Definition'
      jq <<< "${o[svcdef]}" > "${o[statedir]}/svcdef.json" || {
        log 'Failure Parsing the Service Definition'
        return 1
      }
      ;;
    false )
      [[ -z "${o[svcdef]:-}" ]] || {
        log 'Not allowed to update a Service Definition after Creation'
        return 1
      }
      ;;
    * ) _log 'RUNTIME ERROR'; return 127;;
  esac

  ### Watch for events of interest
  # TODO: Probably need to replace this with either a pipe, a ring buffer or some sort of rotating file
  local _event_sink; _event_sink="$(mktemp -m 0600 -p "${o[statedir]}/.tmp")"
  _controller_monitor "statedir=${o[statedir]}" "sink=${_event_sink}" "timeout=10" "sig=true" &
  local -i _eventmonitor_pid=$!
  _cleanup_eventmonitor() {
    kill -TERM $_eventmonitor_pid &>/dev/null
    wait $_eventmonitor_pid || true
    rm -f $_event_sink || true
  }
  # Wait for the init message
  read -r _event <"${_event_sink}"
  [[ "${_event}" == 'init' ]] || {
    log "${_procerr[RUNTIME]}: The First Event should have been an init event: got ${_event}"
    return 127
  }

  ### Spawn the Controller Job as a seperate process
  setsid --fork "$(readlink -f "${BASH_SOURCE[0]}")" \
    controller loop "statedir=${o[statedir]}" || {
      _log 'Failed to Spawn the Controller'
      _kv set k=status "v=error"; _kv set k=error "v=${_procerr[SPAWN]}";
      return 1
    }
  
  ### Wait until either the controller pid is set or the state changes
  # This is psuedo code
  _log 'Waiting for Controller'
  local -i _rc=0
  while IFS= read -r event; do # Reads from the event sink, see end of the while loop def
    case "${event}" in
      CREATE:svcpid,* )
        _log 'Service Spawned'
        break
        ;;
      UPDATE:status,error )
        _log "Controller encountered an error before it could spawn the service: $(_kv get k=error "v=Unknown Error")"
        _rc=127; break
        ;;
      UPDATE:status,undefined )
        _log "${_procerr[RUNTIME]} Controller is in an undefined state"
        _kv set k=status v=error; _kv set k=error "v=${_procerr[RUNTIME]}"
        _rc=127; break
        ;;
      DEAD:cntrl )
        _log "${_procerr[DEAD]}"
        _kv set k=status v=error; _kv set k=error "v=${_procerr[DEAD]}"
        _rc=127; break
        ;; # The Controller unexpectadely dead
      TIMEOUT:* )
        _log "${_procerr[TIMEOUT]}"
        _kv set k=status v=error; _kv set k=error "v=${_procerr[TIMEOUT]}"
        _rc=127; break
        ;; # TODO: Handle Special Case of a Timeout
      DEAD:svc | DELETE:* ) : ;; # Ignore these events
      * )
        log "${_procerr[RUNTIME]} Unhandled State: ${event}:${key:-}:${value:-}"
        _kv set k=status v=error; _kv set k=error "v=${_procerr[RUNTIME]}"
        _rc=127; break
        ;; # Unhandled State
    esac
  done < "${_event_sink}"
  _cleanup_eventmonitor
  return "${_rc}"
}

_controller_down() {
  # Teardown a Controller & its service
  local -A o=(
    [statedir]= # The Directory storing the controller state
    [timeout]=10 # How long to wait for the controller to stop
  ); parse_kv o "$@"
  [[ -d "${o[statedir]}" ]] || { log "the controller state directory does not exist"; return 1; }
  [[ -d "${o[statedir]}/kv" ]] || install -dm0750 "${o[statedir]}/kv"
  _kv() { kv "${1:?Missing KV Subcmd}" "d=${o[statedir]}/kv" "$@" ; }

  # Let's check some states
  [[ "$(_kv get k=status "v=down")" == "v=down" ]] || {
    log 'TODO: Handle Non-Up State'
    return 127
  }
  [[ "$(_kv get k=bootid "v=$(boot_id)")" == "$(boot_id)" ]] || {
    log 'TODO: Handle Up State when a reboot encountered'
    return 127
  }

  # Assert we are UP & no reboot has occured
  _assert "[[ '$(_kv get k=status v=down)' == 'v=down' && '$(_kv get k=bootid "v=${_cur_boot_id}")' == '${_cur_boot_id}' ]]"

  # Kill the Service Controller
  local cntrl_pid; cntrl_pid="$(_kv get k=cntrlpid)" || {
    log "Runtime Error: No Controler PID Found!"
    return 2
  }
  log "Requesting Service to Terminate"
  kill -QUIT "${cntrl_pid}" # The Controller uses QUIT to request service termination
  timeout "${o[timeout]}" tail --pid="${cntrl_pid}" -f /dev/null || {
    log "Service took too long (${o[timeout]}); killing"
    kill -TERM "${cntrl_pid}" # The Controller uses TERM to kill the service
    timeout 5 tail --pid="${cntrl_pid}" -f /dev/null || {
      log "!!! CRITICAL FAILURE !!! The Service Controller is not responding; forcefully killing the controller's entire process group. Resultant behaviour is undefined."
      local cntrl_pgid; cntrl_pgid="$(_kv get k=cntrlpgid)" || { log 'Runtime Error: cntrlpgid was never set'; return 127; }
      kill -KILL "-${cntrl_pgid}"
      _kv set k=status "v=undefined"
    }
  }

  [[ "$(_kv get k=status "v=undefined")" != "v=undefined" ]] || return 1 # Short-Circuit if the Controller Status is now undefined
  _kv set k=status "v=down"
  # Should other state be cleaned up or set when brought down?
}

_controller_status() {
  # Query a Controller for its service status
  log 'Not Implemented'
  return 1
}

_controller_purge() {
  # Purge all on disk state of a Controller; Controller must be in a down state.
  log 'Not Implemented'
  return 1
}

### The Controller's Functional Interface ###

controller() {
  local subcmd="${1:?Missing SubCommand}"; shift 1
  case "${subcmd}" in
    up | down | status | purge ) "_controller_${subcmd}" "$@" ;; # The Controller Functional Interface
    loop ) _controller_loop "$@" ;; # Run the Controller Loop for a given State Directory
    *) log "Uknown Subcmd: {$subcmd}"; return 1;;
  esac
}

###

(return 0 &>/dev/null) || { # Source Guard

set -eEou pipefail
source "${CI_PROJECT_DIR:?Missing CI_PROJECT_DIR}/src/utils/000_import.sh"

# The CLI Interface
declare _cli_cmd="${1:?Missing CLI Command}"; shift 1
case "${cli_cmd}" in
  controller) controller "$@" ;;
  * ) log "Unknown CLI Command: ${cli_cmd}"; exit 1;;
esac

}
