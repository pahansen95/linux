#!/usr/bin/env bash
: <<'DOC'

Script Template Documentation...

DOC

set -eEou pipefail
declare -r name="script-template"
declare -r workdir="${CI_PROJECT_DIR:?Missing CI_PROJECT_DIR}/.cache/${name}"
declare -r \
  eventdir="${workdir}/.events"
install -dm0750 "${workdir}" "${eventdir}"
source "${CI_PROJECT_DIR}/src/_common.sh"

### Functions ###

### SubCommands ###

purge() {

  log "Purging Files"
  _clean_dirs "${eventdir}"

}

### Main ###

declare -r subcmd="${1:-build}"; [[ -z "${1:-}" ]] || shift
case "${subcmd}" in
  purge ) purge;;
  * ) log "Unknown subcommand: ${subcmd}"; exit 1 ;;
esac
