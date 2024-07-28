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

DOC


### Functions

_assert() { eval "${1:?Missing Assertion Statement}" || { log "Assertion Failed: ${1}"; return 1; }; }
_boot_id() { awk '/btime/ {print $2}' /proc/stat | md5sum | awk '{print $1}'; }

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
}
_svcdef_stdin() {}
_svcdef_stdout() {}
_svcdef_stderr() {}
_svcdef_cwd() {}
_svcdef_uid() {}
_svcdef_gid() {}
_svcdef_timeout() {}

_controller_loop() {
  # Start the Controller
  local -A o=(
    [statedir]= # The Directory to store relevant state int
  ); parse_kv o "$@"
  [[ -d "${o[statedir]}" ]] || { log "Controller State Directory does not exist: ${o[statedir]}"; return 1; }
  [[ -d "${o[statedir]}/kv" ]] || { log "Controller KV Directory does not exist: ${o[statedir]}/kv"; return 1; }
  _kv() { kv "${1:?Missing KV Subcmd}" "d=${o[statedir]}/kv" "$@" ; }
  local svc_name; svc_name="$(_kv get k=name)" || { log 'Controller failed to get Service Name'; return 1; }
  _log() { log "${svc_name}::$*" ; }
  
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
  _handle_signal() {
    local s="${1:?Missing Signal}"
    _log "Recieved Signal: ${s}"
    case "${s}" in
      CHLD ) : ;; # TODO: Handle Child Signal
      TERM ) : ;; # TODO: Handle Service Termination
      * ) : ;; # TODO: Passthrough Signal
    esac
  }  

  _assert "[[ ${svc_timeout} -le 0 ]]"
  local gate="${o[statedir]}/.svcgate"; install -m0640 /dev/null "${gate}"
  (
    # Wait until the Parent opens the gate
    _assert "[[ -f '${gate}' ]]"
    inotifywait --event delete_self "${gate}" &>/dev/null
    exec "${cmd[@]}" <"${svc_stdin}" >"${svc_stdout}" 2>"${svc_stderr}"
  ) &
  local -i svc_pid="$!"
  _kv set k=svcpid "v=${svc_pid}"

  # Delete the gate
  unlink "${gate}"

  # TODO: Block until event occurs; we need to also support Signal events; maybe write events to a dir as a file & then sort the dir on creation date?
  _log "Waiting for Service to complete"
  tail --pid="${svc_pid}" -f /dev/null &>/dev/null
}

### The Controller Interface

_controller_up() {
  # Bring Up a Controller to manage a service
  local -A o=(
    [statedir]= # The Directory to store relevant state int
    [svcdef]= # The Service Definition Encoded as a JSON String
  ); parse_kv o "$@"
  [[ -d "${o[statedir]}" ]] || install -dm0750 "${o[statedir]}"
  [[ -d "${o[statedir]}/kv" ]] || install -dm0750 "${o[statedir]}/kv"
  _kv() { kv "${1:?Missing KV Subcmd}" "d=${o[statedir]}/kv" "$@" ; }

  [[ "$(_kv get k=.status v=down)" != 'up' ]] || {
    log 'TODO: Handle Controller State when it is already up'
    return 1
    [[ "$(_kv get k=.bootid)" == "$(_boot_id)" ]] | {
      log 'Boot ID Mismatch!'
      return 1 # TODO
    }
  }
  _assert "[[ '$(_kv get k=.status v=down)' == 'down' ]]"

  # Parse & Record the Service Definition
  jq <<< "${o[svcdef]}" > "${o[statedir]}/svcdef.json" || {
    log 'Failure Parsing the Service Definition'
    return 1
  }

  ### Spawn the Controller Job
  # Create the Synchronization Gate
  local gate="${o[statedir]}/.cntrlgate"; install -m0600 /dev/null "${gate}"
  (
    # Wait until the Parent opens the gate
    _assert "[[ -f '${gate}' ]]"
    inotifywait --event delete_self "${gate}" &>/dev/null
    setsid --fork "$(readlink -f "${BASH_SOURCE[0]}")" \
      controller loop "statedir=${o[statedir]}"
  ) 0</dev/null 1>"${o[statedir]}/controller.stdout" 2>"${o[statedir]}/controller.stderr" &
  local _controller_pid=$!
  disown "${_controller_pid}" || true # Disown to be safe
  _kv set k=cntrl-pid "v=${_controller_pid}"
  
  # Open the Gate
  unlink "${gate}"

  # Record the Boot ID to track system changes
  _kv set k=.bootid "v=$(_boot_id)"
  _kv set k=.status v=up
}

_controller_down() {
  # Teardown a Controller & its service
}

_controller_status() {
  # Query a Controller for its service status
}

### The Controller's Functional Interface ###

controller() {
  local subcmd="${1:?Missing SubCommand}"; shift 1
  case "${subcmd}" in
    up | down | status ) "_controller_${subcmd}" "$@" ;; # The Controller Functional Interface
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
