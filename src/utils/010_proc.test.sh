#!/usr/bin/env bash

(return 0 &>/dev/null) || {
  printf '%s\n' "Tests must be sourced from the test scheduler" >&2
  exit 1
}

test_proc() {
  local eventdir="${PWD}/.events"
  source "${CI_PROJECT_DIR}/src/utils/000_import.sh"
  log "hello world!"
}

### Register the tests to run
TEST_REGISTRY+=(
  [test_proc]="$( testdef factory fn=test_proc )"
)