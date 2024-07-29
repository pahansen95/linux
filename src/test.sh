#!/usr/bin/env bash

# Ensure this script fails on sourcing
! (return 0 &>/dev/null) || {
  printf '%s\n' "You cannot import ${BASH_SOURCE[0]}" >&2
  exit 1
}

set -eEou pipefail

declare -ir root_pid=$$
declare -A TEST_REGISTRY
: <<'DOC'
A Registry of Tests -> { Name: Def }

A Test Def is a JSON Object

```json
{
  "fn": "function_name",
  "stdin": "/path/to/stdin",
}
```
DOC

_log() { printf '%b\n' "[$(date +'%Y-%m-%dT%H:%M:%S%z')]::$*" >&2; }
_parse_kv() {
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

testdef() {
  local subcmd=${1:?Missing Subcmd for testdef}; shift
  case "${subcmd}" in
    get )
      local k="${1:?Missing Key to extract}"; shift
      jq -ecr --arg key "${k}" '.[$k]'
      ;;
    factory )
      local -A o=(
        [fn]=
        [stdin]=/dev/null
      ); parse_kv o "$@"
      jq -ncr --arg fn "${fn}" --arg stdin "${stdin}" \
        '{ "fn": $fn, "stdin": $stdin }'
      ;;
    * ) _log "Unknown SubCommand: ${subcmd}"; return 1 ;;
  esac
}

run_test() {
  local name="${1:?Missing the Name for the Test}"; shift
  local def="${1:?Missing the Test Def}"; shift
  local workdir="${1:?Missing the Test Work Dir}"; shift
  [[ -d "${workdir}" ]] || { _log "[[TEST:${name}]]::Missing working directory: ${workdir}"; return 1; }
  install -dm 0755 "${workdir}/run"
  pushd "${workdir}/run" || { _log "[[TEST:${name}]]::Failed to change to the run directory: ${workdir}/run"; return 1; }
  trap 'popd' RETURN
  local fn; fn="$(testdef get fn <<< "${def}")" || { _log "[[TEST:${name}]]::Failed to parse a value for 'fn' from the test def"; return 1; }
  command -v "${fn}" &>/dev/null || { _log "[[TEST:${name}]]::Can not find the test function '${fn}'"; return 1; }
  local stdin; stdin="$(testdef get stdin <<< "${def}")" || { _log "[[TEST:${name}]]::Failed to parse a value for 'stdin' from the test def"; return 1; }
  _log "[[TEST:${name}]]::Start"
  if {
    fn <"${stdin}" >"${workdir}/stdout" 2>"${workdir}/stderr"
  }; then { local result=pass; }; else { local result=fail; }; fi
  _log "[[TEST:${name}]]::Complete"
  install -m0644 /dev/null "${workdir}/${result}"
}

run_test_group() {
  [[ $$ != $root_pid ]] || { _log "You must run the test group as a subprocess!"; return 1; }
  local tg_name="${1:?Missing the Name for the Test Group}"; shift
  local tg_import="${1:?Missing the Test Group to import}"; shift
  local workdir="${1:?Missing the Test Group Working Directory}"; shift

  ### Import the test group
  _log "[[TESTGROUP:${tg_name})]]::Importing Test Group"
  source "${tg_import}"

  ### Spawn each individual Test
  [[ "${#TEST_REGISTRY[@]}" -ge 1 ]] || {
    _log "[[TESTGROUP:${tg_name})]]::No tests were registered"
    return 1
  }
  _log "[[TESTGROUP:${tg_name})]]::Scheduling Tests"
  local -a test_pids=()
  for name in "${!TEST_REGISTRY[@]}"; do
    local test_def="${TEST_REGISTRY[@]}"
    install -dm0755 "${workdir}/${name}"
    run_test "${name}" "${test_def}" "${workdir}/${name}" &
    test_pids+=( $! )
  done

  # Wait for tests to complete
  wait "${test_pids[@]}" || true
  
  _log "[[TESTGROUP:${tg_name})]]::Test Group has completed"
}

schedule_tests() {
  local _rootdir="${1:?Missing the Root Directory to run tests from}"; shift
  local _workdir="${1:?Missing the Working Directory to write results to}"; shift
  
  [[ -d "${_rootdir}" ]] || {
    _log "Missing Root Directory: ${_rootdir}"
    return 1
  }
  [[ -d "${_workdir}" ]] || {
    _log "Missing Working Directory: ${_workdir}"
    return 1
  }

  ### Find the Test Groups
  mapfile -t test_groups < <(
    find "${_rootdir}" \
      -type f \
      -name '*.test.sh' \
      ! -name "${BASH_SOURCE[0]##*/}" \
      -print | sort -u
  )
  [[ "${#test_groups[@]}" -ge 1 ]] || {
    _log "No Test Groups found under ${_rootdir}"
    return 1
  }

  ### Schedule the Test Groups
  local -a tg_pids
  for tg in "${test_groups[@]}"; do
    local tg_name="${tg##*/}"; tg_name="${tg%.test.sh}"
    install -dm0755 "${_workdir}/${tg_name}"
    run_test_group "${tg_name}" "${tg}" "${_workdir}/${tg_name}" </dev/null &>"${_workdir}/${tg_name}.log" &
    printf %s $! > "${_workdir}/${tg_name}.pid"
    tg_pids+=( "$(< "${_workdir}/${tg_name}.pid")" )
  done

  ### Wait for all Test Groups to finish
  wait "${tg_pids[@]}" || _log "WARNING: Some TestGroups encountered a runtime error!"

  ### Parse the results
  : # TODO
}

install -dm0755 "${CI_PROJECT_DIR:?Env Var CI_PROJECT_DIR not set}/.cache/tests"
declare -A argv=(
  [search]="${CI_PROJECT_DIR}/src/utils"
  [cache]="${CI_PROJECT_DIR}/.cache/tests"
); _parse_kv argv "$@"
[[ -d "${argv[cache]}" ]] || { _log "FATAL: Cache Parent Directory not found: ${argv[cache]%/*}"; return 1; }
[[ -d "${argv[cache]}/${argv[search]##*/}" ]] || install -dm0755 "${argv[cache]}/${argv[search]##*/}"
schedule_tests "${argv[search]}" "${argv[cache]}/${argv[search]##*/}"
