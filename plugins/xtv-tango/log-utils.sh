#!/usr/bin/env bash
# shellcheck shell=bash

# ----------------------------------------------------------------------------
# Logging (lightweight, file-based). Enable with XTV_LOG_LEVEL=[DEBUG|INFO|WARN|ERROR]
# Default level is ERROR to keep normal runs quiet; logs are written under
# SWIFTBAR_PLUGIN_CACHE_PATH (or /tmp). This module is sourced by xtv-tango.1m.sh.
# ----------------------------------------------------------------------------

: "${XTV_LOG_LEVEL:=ERROR}"

# Base directory for logs and other run-state files (e.g. queue state)
LOG_BASE_DIR="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}"
mkdir -p "$LOG_BASE_DIR" 2>/dev/null || true

XTV_LOG_FILE="$LOG_BASE_DIR/xtv-tango.run.log"

# Simple rotation to last ~2000 lines
if [ -f "$XTV_LOG_FILE" ]; then
  LINES=$(wc -l <"$XTV_LOG_FILE" 2>/dev/null || echo 0)
  if [ "${LINES:-0}" -gt 5000 ]; then
    tail -n 2000 "$XTV_LOG_FILE" >"${XTV_LOG_FILE}.tmp" 2>/dev/null && mv "${XTV_LOG_FILE}.tmp" "$XTV_LOG_FILE"
  fi
fi

log_level_num() {
  case "$1" in
  DEBUG) echo 10 ;;
  INFO) echo 20 ;;
  WARN) echo 30 ;;
  ERROR) echo 40 ;;
  *) echo 20 ;;
  esac
}

_log_write() {
  local lvl="$1"
  shift
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s [%s] %s\n' "$ts" "$lvl" "$*" >>"$XTV_LOG_FILE"
}

log_debug() {
  [ "$(log_level_num DEBUG)" -ge "$(log_level_num "${XTV_LOG_LEVEL:-ERROR}")" ] && _log_write DEBUG "$@"
}
log_info() {
  [ "$(log_level_num INFO)" -ge "$(log_level_num "${XTV_LOG_LEVEL:-ERROR}")" ] && _log_write INFO "$@"
}
log_warn() {
  [ "$(log_level_num WARN)" -ge "$(log_level_num "${XTV_LOG_LEVEL:-ERROR}")" ] && _log_write WARN "$@"
}
log_error() {
  [ "$(log_level_num ERROR)" -ge "$(log_level_num "${XTV_LOG_LEVEL:-ERROR}")" ] && _log_write ERROR "$@"
}

export XTV_LOG_FILE XTV_LOG_LEVEL LOG_BASE_DIR
export -f log_debug log_info log_warn log_error log_level_num _log_write

# ERR trap: logs unexpected errors with line number and command
trap 'log_error "ERR trap exit=$? line=$LINENO cmd=$BASH_COMMAND"' ERR
