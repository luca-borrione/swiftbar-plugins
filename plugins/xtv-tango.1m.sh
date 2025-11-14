#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC1091
# SC2034: Many variables appear unused but are used in sourced library files
# SC1091: Shellcheck can't follow sourced files (they exist, this is informational only)
set -euo pipefail

# ============================================================================
# XTV-TANGO: GitHub Pull Request Menu Bar Plugin for SwiftBar
# ============================================================================

# DEPENDENCIES:
# ----------------------------------------------------------------------------
# - SwiftBar (or xbar) [host]: runs this plugin in your menu bar.
#   Install: brew install swiftbar
#
# - gh – GitHub CLI [required]: GraphQL/REST calls to list PRs, reviews and counts.
#   Install: brew install gh
#   Login:   gh auth login -h github.com --web
#
# - jq [required]: JSON processing for GraphQL responses.
#   Install: brew install jq
#
# - curl [required]: downloads user avatars. Preinstalled on macOS.
# - sips [required, built-in]: resizes avatar images. Preinstalled on macOS.
#
# Environment knobs:
#   SWIFTBAR_PLUGIN_CACHE_PATH       base dir for avatar/conversation/approvals caches
#   default '~/Library/Caches/com.ameba.SwiftBar/Plugins/xtv-tango.1m.sh'

# ----------------------------------------------------------------------------
# Logging (lightweight, file-based). Enable with XTV_LOG_LEVEL=[DEBUG|INFO|WARN|ERROR]
# Defaults to INFO. Logs are written under SWIFTBAR_PLUGIN_CACHE_PATH (or /tmp).
set -E
: "${XTV_LOG_LEVEL:=INFO}"
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
log_level_num() { case "$1" in DEBUG) echo 10 ;; INFO) echo 20 ;; WARN) echo 30 ;; ERROR) echo 40 ;; *) echo 20 ;; esac }
LOG_LEVEL_NUM=$(log_level_num "$XTV_LOG_LEVEL")
_log_write() {
  local lvl="$1"
  shift
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s [%s] %s\n' "$ts" "$lvl" "$*" >>"$XTV_LOG_FILE"
}
log_debug() { [ "$(log_level_num DEBUG)" -ge "$LOG_LEVEL_NUM" ] && _log_write DEBUG "$@"; }
log_info() { [ "$(log_level_num INFO)" -ge "$LOG_LEVEL_NUM" ] && _log_write INFO "$@"; }
log_warn() { [ "$(log_level_num WARN)" -ge "$LOG_LEVEL_NUM" ] && _log_write WARN "$@"; }
log_error() { [ "$(log_level_num ERROR)" -ge "$LOG_LEVEL_NUM" ] && _log_write ERROR "$@"; }
export XTV_LOG_FILE XTV_LOG_LEVEL LOG_LEVEL_NUM
export -f log_debug log_info log_warn log_error log_level_num _log_write
trap 'log_error "ERR trap exit=$? line=$LINENO cmd=$BASH_COMMAND"' ERR
log_info "=== xtv-tango run start pid=$$ ==="

# MODULES:
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Notes:
# => Keep the shellcheck comments to allow jump to definition in the source files

# shellcheck source=plugins/xtv-tango/cache-utils.sh
source "${SCRIPT_DIR}/xtv-tango/cache-utils.sh"

# shellcheck source=plugins/xtv-tango/fetch-pr-data-utils.sh
source "${SCRIPT_DIR}/xtv-tango/fetch-pr-data-utils.sh"

# shellcheck source=plugins/xtv-tango/render-utils.sh
source "${SCRIPT_DIR}/xtv-tango/render-utils.sh"

# shellcheck source=plugins/xtv-tango/fetch-prs-utils.sh
source "${SCRIPT_DIR}/xtv-tango/fetch-prs-utils.sh"

# # You need to ignore these in order to be able to pass your ssh to gh
# unset GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

# CONFIG:
# ---------
# Export variables used by sourced library files
export SORT_PREF="number"                # "activity" or "number"
export SORT_DIR="desc"                   # "asc" or "desc"
export REPO_HEADER_COLOR="#0A3069"       # dark blue for repo headers
export REPO_HEADER_FONT="Helvetica-Bold" # bold header font (use a font installed on your Mac)
export REPO_HEADER_SIZE="13"             # header font size

# Section visibility knobs (1=show, 0=hide)
SHOW_ALL_SECTION=1
SHOW_MENTIONED_SECTION=1
SHOW_PARTICIPATED_SECTION=1
SHOW_RAISED_BY_ME_SECTION=1
# SHOW_RAISED_BY_TEAMS_SECTION will be derived from the content of RAISED_BY_TEAMS
SHOW_RECENTLY_MERGED_SECTION=1
SHOW_REQUESTED_TO_ME_SECTION=1
# SHOW_REQUESTED_TO_TEAMS_SECTION will be derived from the content of REQUESTED_TO_TEAMS

# Section configuration
RECENTLY_MERGED_DAYS=7

# Cache TTL for team members list (seconds). Default: 24 hours
export TEAM_MEMBERS_CACHE_TTL=86400

# Marks for metrics/state; customize as you like
export APPROVAL_DISMISSED_MARK="⚪"
export APPROVAL_MARK="✅"
export APPROVED_BY_ME_MARK="🟢"
export CHANGES_REQUESTED_MARK="🔴"
export COMMENT_MARK="💬"
export DO_NOT_REVIEW_MARK="🚫"
export DRAFT_MARK="▪️"
export QUEUE_LEFT_MARK="🟡"
export QUEUE_MARK="🟠"
export REREQUESTED_MARK="🔄"
export UNREAD_MARK="🔺"

# Teams configuration: one org/team slug per line
# NBCUDTC/xtv-devs
REQUESTED_TO_TEAMS="
NBCUDTC/xtv-tango
NBCUDTC/gst-apps-client-lib-steering-committee
"

# Teams for "Raised by" section (one org/team slug per line)
RAISED_BY_TEAMS="
NBCUDTC/xtv-bravo
NBCUDTC/xtv-delta
NBCUDTC/xtv-tango
"

# Repos allowlist (limits searches to these repos when non-empty)
WATCHED_REPOS="
NBCUDTC/client-container-lg
NBCUDTC/client-container-prospero
NBCUDTC/client-container-tizen
NBCUDTC/client-container-webmaf
NBCUDTC/client-lib-js-device
NBCUDTC/gst-apps-client-lib
NBCUDTC/gst-apps-xtv
NBCUDTC/gst-apps-xtv-config
NBCUDTC/peacock-cliapps-ci
NBCUDTC/peacock-cliapps-nbcu-release
NBCUDTC/peacock-clients-dev-dns
"
# NBCUDTC/github-repos-deploy
# NBCUDTC/gst-shader-service

# ============================================================================
# MAIN CODE
# ============================================================================

# Global author exclusion used by sections that would otherwise duplicate "Raised by Me"
AUTHOR_EXCL=""
if [ "${SHOW_RAISED_BY_ME_SECTION:-0}" = "1" ]; then AUTHOR_EXCL=" -author:@me"; fi
export AUTHOR_EXCL

# Parse into array (trim whitespace, drop empty lines) - compatible with older bash
REQUESTED_TO_TEAMS_ARRAY=()
while IFS= read -r line; do
  line=$(printf "%s" "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -z "$line" ] && continue
  REQUESTED_TO_TEAMS_ARRAY+=("$line")
done <<<"$REQUESTED_TO_TEAMS"

# Derived visibility flag for clarity
if [ "${#REQUESTED_TO_TEAMS_ARRAY[@]}" -gt 0 ]; then
  SHOW_REQUESTED_TO_TEAMS_SECTION=1
else
  SHOW_REQUESTED_TO_TEAMS_SECTION=0
fi

RAISED_BY_TEAMS_ARRAY=()
while IFS= read -r line; do
  line=$(printf "%s" "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -z "$line" ] && continue
  RAISED_BY_TEAMS_ARRAY+=("$line")
done <<<"$RAISED_BY_TEAMS"

# Derived visibility flag for clarity
if [ "${#RAISED_BY_TEAMS_ARRAY[@]}" -gt 0 ]; then
  SHOW_RAISED_BY_TEAMS_SECTION=1
else
  SHOW_RAISED_BY_TEAMS_SECTION=0
fi

# Allowlist of repos (owner/repo) to constrain searches when provided
WATCHED_ARR=()
while IFS= read -r line; do
  line=$(printf "%s" "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -z "$line" ] && continue
  WATCHED_ARR+=("$line")
done <<<"$WATCHED_REPOS"

# If gh has not access to your gitub account, show a link to authorise it
if ! gh auth status -h github.com >/dev/null 2>&1; then
  # Bar title when not logged in
  echo "🔀 ❌"
  echo "---"
  echo "Login | bash=gh param1=auth param2=login param3=-h param4=github.com param5=--web terminal=true"
  echo "Check status    | bash=gh param1=auth param2=status param3=-h param4=github.com terminal=true"
  exit 0
fi

# If no watched repos are configured, render only the bar icon with - and no primary menu
if [ "${#WATCHED_ARR[@]}" -eq 0 ]; then
  echo "🔀 -"
  echo "---"
  exit 0
fi

# Initialize indexes and global variables
init_indexes

# Header link query string for repo header href (URL-encoded)
HEADER_LINK_Q=""

# Start: buffer for the per-team menu and compute totals across teams
TMP_MENU="$(mktemp)"

# Track seen PR URLs to avoid duplicates across sections
SEEN_PRS_FILE="$(mktemp)"

export SEEN_PRS_FILE
# Count seen PRs across open sections for menubar when All is hidden
COUNT_SEEN=1

# Track merge-queue membership between runs (for QUEUE_LEFT_MARK)
QUEUE_STATE_FILE="$LOG_BASE_DIR/xtv-queue-state.txt"
QUEUE_STATE_NEXT="$(mktemp)"
export QUEUE_STATE_FILE QUEUE_STATE_NEXT

# Current section label used by renderer to apply per-section decorations
CURRENT_SECTION=""
export CURRENT_SECTION

# Personal sections before team sections
# 0.a Raised by Me (my authored PRs)
if [ "${SHOW_RAISED_BY_ME_SECTION:-0}" = "1" ]; then
  TMP_MYPR_MENU="$(mktemp)"

  CURRENT_SECTION="raised_by_me"
  fetch_raised_by_me "$TMP_MYPR_MENU"
  SECTION_COUNT=$(sed -n 's/^-- [^:]*: \([0-9][0-9]*\).*/\1/p' "$TMP_MYPR_MENU" | awk '{s+=$1} END{print s+0}')
  [[ "$SECTION_COUNT" =~ ^[0-9]+$ ]] || SECTION_COUNT=0
  log_info "section: RaisedByMe count=${SECTION_COUNT}"

  if [ "$SECTION_COUNT" -gt 0 ]; then
    echo "Raised by Me: ${SECTION_COUNT}" >>"$TMP_MENU"
  else
    echo "Raised by Me" >>"$TMP_MENU"
  fi
  cat "$TMP_MYPR_MENU" >>"$TMP_MENU"
  rm -f "$TMP_MYPR_MENU" 2>/dev/null || true
fi

# 0.b Mentioned (tagged me in comments)
if [ "${SHOW_MENTIONED_SECTION:-0}" = "1" ]; then
  TMP_MENTIONED_MENU="$(mktemp)"

  CURRENT_SECTION="mentioned"
  fetch_mentioned "$TMP_MENTIONED_MENU"
  SECTION_COUNT=$(sed -n 's/^-- [^:]*: \([0-9][0-9]*\).*/\1/p' "$TMP_MENTIONED_MENU" | awk '{s+=$1} END{print s+0}')
  [[ "$SECTION_COUNT" =~ ^[0-9]+$ ]] || SECTION_COUNT=0
  log_info "section: Mentioned count=${SECTION_COUNT}"

  if [ "$SECTION_COUNT" -gt 0 ]; then
    echo "Mentioned: ${SECTION_COUNT}" >>"$TMP_MENU"
  else
    echo "Mentioned" >>"$TMP_MENU"
  fi
  cat "$TMP_MENTIONED_MENU" >>"$TMP_MENU"
  rm -f "$TMP_MENTIONED_MENU" 2>/dev/null || true
fi

# 0.c Requested to Me (review-requested:@me)
if [ "${SHOW_REQUESTED_TO_ME_SECTION:-0}" = "1" ]; then
  TMP_ME_MENU="$(mktemp)"

  CURRENT_SECTION="requested_to_me"
  fetch_requested_to_me "$TMP_ME_MENU"
  SECTION_COUNT=$(sed -n 's/^-- [^:]*: \([0-9][0-9]*\).*/\1/p' "$TMP_ME_MENU" | awk '{s+=$1} END{print s+0}')
  [[ "$SECTION_COUNT" =~ ^[0-9]+$ ]] || SECTION_COUNT=0
  log_info "section: RequestedToMe count=${SECTION_COUNT}"

  if [ "$SECTION_COUNT" -gt 0 ]; then
    echo "Requested to Me: ${SECTION_COUNT}" >>"$TMP_MENU"
  else
    echo "Requested to Me" >>"$TMP_MENU"
  fi
  cat "$TMP_ME_MENU" >>"$TMP_MENU"
  rm -f "$TMP_ME_MENU" 2>/dev/null || true
fi

# 0.d Participated (any involvement on open PRs)
if [ "${SHOW_PARTICIPATED_SECTION:-0}" = "1" ]; then
  TMP_PART_MENU="$(mktemp)"

  CURRENT_SECTION="participated"
  fetch_participated "$TMP_PART_MENU"

  SECTION_COUNT=$(sed -n 's/^-- [^:]*: \([0-9][0-9]*\).*/\1/p' "$TMP_PART_MENU" | awk '{s+=$1} END{print s+0}')
  [[ "$SECTION_COUNT" =~ ^[0-9]+$ ]] || SECTION_COUNT=0
  log_info "section: Participated count=${SECTION_COUNT}"

  if [ "$SECTION_COUNT" -gt 0 ]; then
    echo "Participated: ${SECTION_COUNT}" >>"$TMP_MENU"
  else
    echo "Participated" >>"$TMP_MENU"
  fi
  cat "$TMP_PART_MENU" >>"$TMP_MENU"
  rm -f "$TMP_PART_MENU" 2>/dev/null || true
fi

# 0.e Recently Merged (my recently merged PRs)
if [ "${SHOW_RECENTLY_MERGED_SECTION:-0}" = "1" ] &&
  [[ -n "${RECENTLY_MERGED_DAYS:-}" ]] &&
  [[ "${RECENTLY_MERGED_DAYS}" =~ ^[0-9]+$ ]] &&
  ((RECENTLY_MERGED_DAYS > 0)); then
  echo "Recently Merged" >>"$TMP_MENU"
  TMP_MERGED_MENU="$(mktemp)"

  # Do not count merged PRs into SEEN_PRS_FILE (menubar count when All is hidden)
  _PREV_COUNT_SEEN="${COUNT_SEEN:-1}"
  COUNT_SEEN=0
  CURRENT_SECTION="recently_merged"
  fetch_recently_merged "$TMP_MERGED_MENU" "$RECENTLY_MERGED_DAYS"
  COUNT_SEEN="${_PREV_COUNT_SEEN}"
  cat "$TMP_MERGED_MENU" >>"$TMP_MENU"
  rm -f "$TMP_MERGED_MENU" 2>/dev/null || true
fi

# Separator between personal sections and team sections
if { [ "${SHOW_REQUESTED_TO_TEAMS_SECTION:-0}" = "1" ]; } || { [ "${SHOW_RAISED_BY_TEAMS_SECTION:-0}" = "1" ]; }; then
  # Team sections
  echo "---" >>"$TMP_MENU"
fi

if [ "${SHOW_REQUESTED_TO_TEAMS_SECTION:-0}" = "1" ]; then
  echo "Requested to" >>"$TMP_MENU"
fi

if [ "${SHOW_REQUESTED_TO_TEAMS_SECTION:-0}" = "1" ]; then
  # 2.
  # Show the list of PRs per configured team

  N=50
  for team in "${REQUESTED_TO_TEAMS_ARRAY[@]}"; do
    team_name="${team#*/}"
    TMP_TEAM_MENU="$(mktemp)"

    CURRENT_SECTION="requested_to_team"
    fetch_team_prs "$team" "$TMP_TEAM_MENU"
    SECTION_COUNT=$(sed -n 's/^-- [^:]*: \([0-9][0-9]*\).*/\1/p' "$TMP_TEAM_MENU" | awk '{s+=$1} END{print s+0}')
    [[ "$SECTION_COUNT" =~ ^[0-9]+$ ]] || SECTION_COUNT=0
    log_info "section: RequestedToTeam[${team_name}] count=${SECTION_COUNT}"

    if [ "$SECTION_COUNT" -gt 0 ]; then

      echo "$team_name: ${SECTION_COUNT}" >>"$TMP_MENU"
    else
      echo "$team_name" >>"$TMP_MENU"
    fi
    cat "$TMP_TEAM_MENU" >>"$TMP_MENU"
    rm -f "$TMP_TEAM_MENU" 2>/dev/null || true
  done
fi

# Raised by section
if [ "${SHOW_RAISED_BY_TEAMS_SECTION:-0}" = "1" ]; then
  echo "---" >>"$TMP_MENU"
  echo "Raised by" >>"$TMP_MENU"
  for rteam in "${RAISED_BY_TEAMS_ARRAY[@]}"; do
    r_org="${rteam%%/*}"
    r_name="${rteam#*/}"
    TMP_TEAM_MENU="$(mktemp)"

    # Collect team members (requires read:org). Single page (100) for speed; cached per TEAM_MEMBERS_CACHE_TTL (default 24h)
    MEM_CACHE_DIR="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-team-members"
    mkdir -p "$MEM_CACHE_DIR"
    MEM_CACHE_FILE="$MEM_CACHE_DIR/${r_org}_${r_name}.txt"
    now_ts=$(date +%s)
    cache_ok=0
    if [ -s "$MEM_CACHE_FILE" ]; then
      # macOS stat for mtime
      mtime=$(stat -f %m "$MEM_CACHE_FILE" 2>/dev/null || echo 0)
      age=$((now_ts - mtime))
      # Cache TTL (seconds). Default 24h; configurable via TEAM_MEMBERS_CACHE_TTL
      if [ "$age" -lt "${TEAM_MEMBERS_CACHE_TTL:-86400}" ]; then
        cache_ok=1
      fi
    fi
    if [ "$cache_ok" -eq 1 ]; then
      MEMBERS=$(cat "$MEM_CACHE_FILE")
    else
      MEMBERS=$(gh api "orgs/$r_org/teams/$r_name/members?per_page=100" --jq '.[].login' 2>/dev/null || true)
      printf "%s\n" "$MEMBERS" >"$MEM_CACHE_FILE" 2>/dev/null || true
    fi
    # Build active-window qualifier and authors list for header links (space-separated author: qualifiers)
    RB_AUTHORS_LIST=""
    for u in $MEMBERS; do
      RB_AUTHORS_LIST+=" author:${u}"
    done

    RB_NODES_FILE="$(mktemp)"

    RB_DIR="$(mktemp -d)"
    for u in $MEMBERS; do
      # Build server-side qualifiers using watched repos
      REPO_Q=$(build_repo_qualifier)

      RQ="is:pr is:open author:${u}${REPO_Q}"
      gh api graphql -F q="$RQ" -F n="$N" -f query='
          query($q:String!,$n:Int!){
            search(query:$q,type:ISSUE,first:$n){
              edges{node{... on PullRequest{
                number
                title
                url
                updatedAt
                isDraft
                isInMergeQueue
                repository{nameWithOwner}
                author{login avatarUrl(size:28)}
                comments{totalCount}
                reviewDecision
                labels(first:20){nodes{name}}
              }}}
            }}' \
        --jq '.data.search.edges[].node' 2>/dev/null >"$RB_DIR/$u.json" || true
    done
    # Concatenate all results
    if ls "$RB_DIR"/*.json >/dev/null 2>&1; then
      cat "$RB_DIR"/*.json >>"$RB_NODES_FILE" 2>/dev/null || true
    fi
    rm -rf "$RB_DIR" 2>/dev/null || true

    # Build synthetic RESP excluding PRs already listed under REQUESTED_TO_TEAMS
    if [ -s "$RB_NODES_FILE" ]; then
      RESP=$(jq -s --rawfile requested "$REQUESTED_FILE" '
        unique_by(.repository.nameWithOwner + "#" + (.number|tostring))
        | map(
            . as $n
            | select( ($n.repository.nameWithOwner + "\t" + ($n.number|tostring)) as $k | ($requested | split("\n") | index($k) | not))
          )

        | {data:{search:{edges:(map({node:.})), pageInfo:{hasNextPage:false, endCursor:null}}}}' "$RB_NODES_FILE" 2>/dev/null ||
        echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
    else
      RESP='{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
    fi

    if [ -n "$RB_AUTHORS_LIST" ]; then
      HEADER_LINK_Q="is:pr is:open${RB_AUTHORS_LIST}"
    else

      HEADER_LINK_Q="is:pr is:open"
    fi
    HEADER_LINK_KIND="search"
    CURRENT_SECTION="raised_by_team"
    render_and_update_pagination >>"$TMP_TEAM_MENU"
    unset HEADER_LINK_KIND

    SECTION_COUNT=$(sed -n 's/^-- [^:]*: \([0-9][0-9]*\).*/\1/p' "$TMP_TEAM_MENU" | awk '{s+=$1} END{print s+0}')
    [[ "$SECTION_COUNT" =~ ^[0-9]+$ ]] || SECTION_COUNT=0
    log_info "section: RaisedByTeam[${r_name}] count=${SECTION_COUNT}"

    if [ "$SECTION_COUNT" -gt 0 ]; then

      echo "$r_name: ${SECTION_COUNT}" >>"$TMP_MENU"

    else
      echo "$r_name" >>"$TMP_MENU"
    fi
    cat "$TMP_TEAM_MENU" >>"$TMP_MENU"
    rm -f "$TMP_TEAM_MENU" "$RB_NODES_FILE" 2>/dev/null || true
  done
fi

# Separator and "All" section listing every open PR in watched repos (deduped against previous sections)
if [ "${SHOW_RAISED_BY_TEAMS_SECTION:-0}" = "1" ] && [ "${SHOW_ALL_SECTION:-1}" = "1" ]; then
  echo "---" >>"$TMP_MENU"
fi

if [ "${SHOW_ALL_SECTION:-1}" = "1" ]; then
  TMP_ALL_MENU="$(mktemp)"

  # Compute the All total directly during rendering via a single accumulator
  ALL_TOTAL=0
  ACCUMULATE_ALL_TOTAL=1
  CURRENT_SECTION="all"
  fetch_all "$TMP_ALL_MENU"
  unset ACCUMULATE_ALL_TOTAL
  SECTION_COUNT=$(sed -n 's/^-- [^:]*: \([0-9][0-9]*\).*/\1/p' "$TMP_ALL_MENU" | awk '{s+=$1} END{print s+0}')
  [[ "$SECTION_COUNT" =~ ^[0-9]+$ ]] || SECTION_COUNT=0
  log_info "section: All count=${SECTION_COUNT}"

  if [ "$SECTION_COUNT" -gt 0 ]; then
    echo "All: ${SECTION_COUNT}" >>"$TMP_MENU"
  else

    echo "All" >>"$TMP_MENU"
  fi
  cat "$TMP_ALL_MENU" >>"$TMP_MENU"
  rm -f "$TMP_ALL_MENU" 2>/dev/null || true
fi

# Bar Title for when logged in: just an icon and the total PR count
if [ "${SHOW_ALL_SECTION:-1}" = "1" ]; then
  echo "🔀 ${ALL_TOTAL:-0}"
else
  SEEN_COUNT=$(wc -l <"$SEEN_PRS_FILE" 2>/dev/null | tr -d '[:space:]')
  [[ "$SEEN_COUNT" =~ ^[0-9]+$ ]] || SEEN_COUNT=0
  echo "🔀 ${SEEN_COUNT}"
fi
echo "---"
cat "$TMP_MENU"

# Persist merge-queue state for QUEUE_LEFT_MARK
if [ -n "${QUEUE_STATE_FILE:-}" ] && [ -n "${QUEUE_STATE_NEXT:-}" ]; then
  sort -u "$QUEUE_STATE_NEXT" >"${QUEUE_STATE_FILE}.tmp" 2>/dev/null && mv "${QUEUE_STATE_FILE}.tmp" "$QUEUE_STATE_FILE" 2>/dev/null || true
  rm -f "$QUEUE_STATE_NEXT" 2>/dev/null || true
fi

# Cleanup temp files (menu buffers)
rm -f "$TMP_MENU" "$REQUESTED_FILE" "$SEEN_PRS_FILE" 2>/dev/null || true
