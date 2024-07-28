#!/usr/bin/env bash

: <<'DOC'

Imports all other utils

- First Finds all *.sh files in the `utils` folder
- Then Filters out all files matching `*.test.sh`
- Sorts the remaining List
- Sources the sorted list

DOC

(return 0 &>/dev/null) || { printf '%s\n' "this script must be sourced: ${BASH_SOURCE[0]}"; exit 1; }

_import_log() { printf '%b\n' "[$(date +'%Y-%m-%dT%H:%M:%S%z')]::$*" >&2; }

declare _utilsdir="${BASH_SOURCE[0]%/*}"
[[ -d "${_utilsdir:-}" ]] || {
  _import_log "utils dir does not exist: ${_utilsdir}"
  return 1
}

# Find all *.sh files that aren't 
mapfile -t _import_pkgs < <(
  find "${_utilsdir}" \
    -type f \
    -name '*.sh' \
    ! -name '*.test.sh' \
    ! -name "${BASH_SOURCE[0]##*/}" \
    -print | sort
)
for pkg in "${_import_pkgs[@]}"; do
  _import_log "importing util: ${pkg#$_utilsdir/}"
  source "${pkg}" || {
    _import_log "importing failed"
    return 1
  }
done
_import_log "imports complete"
unset -v _import_pkgs; unset -f _import_log
