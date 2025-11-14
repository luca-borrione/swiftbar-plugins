#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034

# ============================================================================
# CACHE UTILS
# Functions for caching results (avatars, conv count, approvals count)
# ============================================================================

# Cache and return base64 avatar for a GitHub login
get_avatar_b64() {
  local login="$1" url="$2" size="${3:-20}"
  local dir="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-avatars"
  mkdir -p "$dir"
  local file="$dir/${login}-${size}.png"
  if [[ ! -s "$file" ]]; then
    # Ensure we request a small size and hard-cap it with sips (identicons can ignore size)
    local sized_url="$url"
    if [[ -n "$url" ]]; then
      if [[ "$url" != *"size="* && "$url" != *"s="* ]]; then
        local delim="?"
        [[ "$url" == *"?"* ]] && delim="&"
        sized_url="${url}${delim}s=${size}"
      fi
      local tmp="$file.tmp"
      curl -sL "$sized_url" -o "$tmp" >/dev/null 2>&1 || true
      if [[ -s "$tmp" ]]; then
        # Resize largest dimension to $size, overwriting target; fallback to raw if sips is unavailable
        sips -Z "$size" "$tmp" --out "$file" >/dev/null 2>&1 || mv "$tmp" "$file" >/dev/null 2>&1 || true
      fi
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  if [[ -s "$file" ]]; then
    base64 <"$file" | tr -d '\n'
  else
    echo ""
  fi
}
