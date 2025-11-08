#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# SC2034: Variables like HAS_NEXT, CURSOR appear unused but are used in fetch.sh

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
# Functions for caching, fetching, and rendering PR data

# Create a deterministic temp file under $TMP_DIR, set the given var name to its path, and truncate it
# Usage:
#   tmp_make VAR [basename] [ext]
#     - VAR:      name of the variable to set in the caller
#     - basename: base name to use; defaults to VAR
#     - ext:      file extension, default .txt (include leading dot)
# Examples:
#   tmp_make TMP_OUT             -> $TMP_DIR/TMP_OUT.txt
#   tmp_make TMP_FILTERED "" ".tsv" -> $TMP_DIR/TMP_FILTERED.tsv
# Convenience wrappers:
#   tmp_txt VAR [basename]
#   tmp_tsv VAR [basename]
#   tmp_json VAR [basename]
# NOTE: Uses printf -v (Bash 3.2+) to set variable by name; no eval or namerefs needed.
tmp_make() {
  local __var="$1"
  shift || true
  local __base="${1:-$__var}"
  shift || true
  local __ext="${1:-.txt}"
  local __dir="${TMP_DIR:-/tmp}"
  mkdir -p "${__dir}"
  local __path="${__dir}/${__base}${__ext}"
  : >"${__path}"
  printf -v "${__var}" '%s' "${__path}"
}

tmp_txt() { tmp_make "$1" "${2:-$1}" ".txt"; }
tmp_tsv() { tmp_make "$1" "${2:-$1}" ".tsv"; }
tmp_json() { tmp_make "$1" "${2:-$1}" ".json"; }

# Stop loading here to avoid legacy duplicates; functions below were migrated to
# cache-utils.sh, fetch-utils.sh, and render-utils.sh.
# Returning is safe because this file is only sourced, never executed directly.
return 0 2>/dev/null || true
