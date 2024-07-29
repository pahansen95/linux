#!/usr/bin/env bash

(return 0 &>/dev/null) || {
  printf '%s\n' "Tests must be sourced from the test scheduler" >&2
  exit 1
}

test_proc() {
  echo "hello world!"
}

### Register the tests to run
[[ -v TEST_REGISTRY ]] || {
  _log "Can't find the Test Registry"
  return 1
}
TEST_REGISTRY+=(
  [test_proc]="$( testdef factory fn=test_proc )"
)