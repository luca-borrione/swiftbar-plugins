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

# Cache and compute conversation count for a PR (LEGACY - kept for compatibility)
get_conv_count() {
  local repo="$1" number="$2" updatedAt="$3"
  local cache_dir="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-conv"
  mkdir -p "$cache_dir"
  local key="${repo//\//_}-${number}.txt"
  local file="$cache_dir/$key"

  if [[ -s "$file" ]]; then
    local cached_updated cached_conv
    IFS=$'\t' read -r cached_updated cached_conv <"$file" || true
    if [[ "$cached_updated" == "$updatedAt" && "$cached_conv" =~ ^[0-9]+$ ]]; then
      echo "$cached_conv"
      return 0
    fi
  fi

  # Compute fresh value: comments + review_comments + reviews with body
  local base revs conv
  base=$(gh api "repos/$repo/pulls/$number" --jq '.comments + .review_comments' 2>/dev/null || true)
  revs=$(gh api "repos/$repo/pulls/$number/reviews?per_page=100" --jq '[.[] | select((.body // "") != "")] | length' 2>/dev/null || true)
  if [[ "$base" =~ ^[0-9]+$ && "$revs" =~ ^[0-9]+$ ]]; then
    conv=$((base + revs))
  else
    conv="${base:-0}"
  fi

  # Save to cache with the PR's updatedAt, so any activity invalidates it
  printf "%s\t%s\n" "$updatedAt" "$conv" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
  echo "$conv"
}

# Cache and compute approvals count (LEGACY - kept for compatibility)
get_approval_count() {
  local repo="$1" number="$2" updatedAt="$3"
  local cache_dir="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-approvals"
  mkdir -p "$cache_dir"
  local key="${repo//\//_}-${number}.txt"
  local file="$cache_dir/$key"

  if [[ -s "$file" ]]; then
    local cached_updated cached_count
    IFS=$'\t' read -r cached_updated cached_count <"$file" || true
    if [[ "$cached_updated" == "$updatedAt" && "$cached_count" =~ ^[0-9]+$ ]]; then
      echo "$cached_count"
      return 0
    fi
  fi

  local count
  count=$(gh api "repos/$repo/pulls/$number/reviews?per_page=100" \
    --jq 'reverse | reduce .[] as $r ({}; .[$r.user.login] //= ($r.state // "")) | to_entries | map(select(.value == "APPROVED")) | length' 2>/dev/null || echo "0")
  [[ "$count" =~ ^[0-9]+$ ]] || count=0

  printf "%s\t%s\n" "$updatedAt" "$count" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
  echo "$count"
}

