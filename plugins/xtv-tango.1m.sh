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
# - terminal-notifier [optional]: sends macOS notifications for new team‑assigned PRs.
#   Install: brew install terminal-notifier
#
# - curl [required]: downloads user avatars. Preinstalled on macOS.
# - sips [required, built-in]: resizes avatar images. Preinstalled on macOS.
#
# Environment knobs:
#   SWIFTBAR_PLUGIN_CACHE_PATH       base dir for avatar/conversation/approvals caches
#   default '~/Library/Caches/com.ameba.SwiftBar/Plugins/xtv-tango.1m.sh'

# MODULES:
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the shellcheck comments to allow jump to definition in the source files
# shellcheck source=plugins/xtv-tango/utils.sh
source "${SCRIPT_DIR}/xtv-tango/utils.sh"
# shellcheck source=plugins/xtv-tango/notifications.sh
source "${SCRIPT_DIR}/xtv-tango/notifications.sh"
# shellcheck source=plugins/xtv-tango/fetch.sh
source "${SCRIPT_DIR}/xtv-tango/fetch.sh"

# You need to ignore these in order to be able to pass your ssh to gh
unset GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

# Optional: macOS notification wrapper (no-op if terminal-notifier is missing)
notify() {
  if command -v terminal-notifier >/dev/null 2>&1; then
    # Strip any -sender <bundle-id> so clicks perform our -open action instead of activating an app
    local args=()
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-sender" ]; then
        shift 2
        continue
      fi
      args+=("$1")
      shift
    done
    terminal-notifier "${args[@]}" >/dev/null 2>&1 || true
  else
    return 0
  fi
}

# File used to mark PRs that were re-requested in the previous run (for menu emoji)
REREQ_HITS_FILE="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-tango.rerequest.hits"
# File used to record "my approval dismissed" hits (for notifications)
DISMISSED_HITS_FILE="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-tango.approvaldismissed.hits"

# CONFIG:
# ---------
# Export variables used by sourced library files
export SORT_PREF="number"                # "activity" or "number"
export SORT_DIR="desc"                   # "asc" or "desc"
export REPO_HEADER_COLOR="#0A3069"       # dark blue for repo headers
export REPO_HEADER_FONT="Helvetica-Bold" # bold header font (use a font installed on your Mac)
export REPO_HEADER_SIZE="13"             # header font size

# Section visibility knobs (1=show, 0=hide)
SHOW_RAISED_BY_ME_SECTION=1
SHOW_MENTIONED_SECTION=1
SHOW_PARTICIPATED_SECTION=1
SHOW_ASSIGNED_TO_ME_SECTION=1
SHOW_RECENTLY_MERGED_SECTION=1

# Section configuration
RECENTLY_MERGED_DAYS=7

# Notification preferences (1=on, 0=off)
export NOTIFY_APPROVAL_DISMISSED=1
export NOTIFY_MENTIONED=1
export NOTIFY_MERGED=1
export NOTIFY_NEW_COMMENT=1
export NOTIFY_NEW_PR=1
export NOTIFY_NEWLY_ASSIGNED=1
export NOTIFY_QUEUE=1
export NOTIFY_REREQUESTED=1

# Cache TTL for team members list (seconds). Default: 24 hours
export TEAM_MEMBERS_CACHE_TTL=86400

# Concurrency for "Raised by" per-author fetch (parallel gh calls); must be a positive integer
export RAISED_BY_CONCURRENCY=12
# Concurrency for "Assigned to" totals-count across teams; must be a positive integer
export ASSIGNED_TOTALS_CONCURRENCY=12
# ⚪
# Marks for metrics/state; customize as you like
export APPROVAL_DISMISSED_MARK="⚪"
export APPROVAL_MARK="✅"
export APPROVED_BY_ME_MARK="🟢"
export CHANGES_REQUESTED_MARK="⛔"
export COMMENT_MARK="💬"
export DRAFT_MARK="▪️"
export NOT_PARTICIPATED_MARK="🔅" # Shown when I'm not involved yet. Clears after I comment/approve/request changes or react to PR body. Comment reactions not counted.
export QUEUE_MARK="🟠"
export REREQUESTED_MARK="🔄"
export UNREAD_MARK="🔺"

# Teams configuration: one org/team slug per line
# NBCUDTC/xtv-devs
ASSIGNED_TO_TEAMS="
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
ASSIGNED_TO_TEAMS_ARRAY=()
while IFS= read -r line; do
  line=$(printf "%s" "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -z "$line" ] && continue
  ASSIGNED_TO_TEAMS_ARRAY+=("$line")
done <<<"$ASSIGNED_TO_TEAMS"

# Derived visibility flag for clarity
if [ "${#ASSIGNED_TO_TEAMS_ARRAY[@]}" -gt 0 ]; then
  SHOW_ASSIGNED_TO_TEAMS_SECTION=1
else
  SHOW_ASSIGNED_TO_TEAMS_SECTION=0
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

# 1.
# Accumulator for all open PRs across sections (for notifications)
CURRENT_OPEN_FILE="$(mktemp)"

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

# If no watched repos are configured, render only the bar icon with 0 and no primary menu
if [ "${#WATCHED_ARR[@]}" -eq 0 ]; then
  echo "🔀 0"
  echo "---"
  exit 0
fi

# Initialize indexes and global variables
init_indexes

# Header link query string for repo header href (URL-encoded)
HEADER_LINK_Q=""
# Flags used by renderer
COLLECT_ASSIGNED=0

# Start: buffer for the per-team menu and compute totals across teams
TMP_MENU="$(mktemp)"

# Track seen PR URLs to avoid duplicates across sections
SEEN_PRS_FILE="$(mktemp)"
export SEEN_PRS_FILE

# Ensure cache directory is available

if [ -z "$SWIFTBAR_PLUGIN_CACHE_PATH" ]; then
  SWIFTBAR_PLUGIN_CACHE_PATH="$HOME/Library/Caches/com.ameba.SwiftBar/Plugins/xtv-tango.1m.sh"
fi
mkdir -p "$SWIFTBAR_PLUGIN_CACHE_PATH" 2>/dev/null || true

export SWIFTBAR_PLUGIN_CACHE_PATH

ASSIGNED_MAX_PAR="${ASSIGNED_TOTALS_CONCURRENCY:-8}"
if ! [[ "$ASSIGNED_MAX_PAR" =~ ^[1-9][0-9]*$ ]]; then ASSIGNED_MAX_PAR=8; fi

# Personal sections before team sections
# 0.a Raised by Me (my authored PRs)
if [ "${SHOW_RAISED_BY_ME_SECTION:-0}" = "1" ]; then
  echo "Raised by Me" >>"$TMP_MENU"
  TMP_MYPR_MENU="$(mktemp)"
  fetch_raised_by_me "$TMP_MYPR_MENU"
  cat "$TMP_MYPR_MENU" >>"$TMP_MENU"
  rm -f "$TMP_MYPR_MENU" 2>/dev/null || true
fi

# 0.b Mentioned (tagged me in comments)
if [ "${SHOW_MENTIONED_SECTION:-0}" = "1" ]; then
  echo "Mentioned" >>"$TMP_MENU"
  TMP_MENTIONED_MENU="$(mktemp)"
  # Collect current mentions for notification diffing
  MENTIONED_CURR_FILE="$(mktemp)"
  export MENTIONED_CURR_FILE
  fetch_mentioned "$TMP_MENTIONED_MENU"
  cat "$TMP_MENTIONED_MENU" >>"$TMP_MENU"
  rm -f "$TMP_MENTIONED_MENU" 2>/dev/null || true
fi

# 0.c Participated (any involvement on open PRs)
if [ "${SHOW_PARTICIPATED_SECTION:-0}" = "1" ]; then
  echo "Participated" >>"$TMP_MENU"
  TMP_PART_MENU="$(mktemp)"
  fetch_participated "$TMP_PART_MENU"
  cat "$TMP_PART_MENU" >>"$TMP_MENU"
  rm -f "$TMP_PART_MENU" 2>/dev/null || true
fi

# 0.d Assigned to Me (review requested to me)
if [ "${SHOW_ASSIGNED_TO_ME_SECTION:-0}" = "1" ]; then
  echo "Assigned to Me" >>"$TMP_MENU"
  TMP_ME_MENU="$(mktemp)"
  fetch_assigned_to_me "$TMP_ME_MENU"
  cat "$TMP_ME_MENU" >>"$TMP_MENU"
  rm -f "$TMP_ME_MENU" 2>/dev/null || true
fi

# 0.e Recently Merged (my recently merged PRs)
if [ "${SHOW_RECENTLY_MERGED_SECTION:-0}" = "1" ] &&
  [[ -n "${RECENTLY_MERGED_DAYS:-}" ]] &&
  [[ "${RECENTLY_MERGED_DAYS}" =~ ^[0-9]+$ ]] &&
  ((RECENTLY_MERGED_DAYS > 0)); then
  echo "Recently Merged" >>"$TMP_MENU"
  TMP_MERGED_MENU="$(mktemp)"
  fetch_recently_merged "$TMP_MERGED_MENU" "$RECENTLY_MERGED_DAYS"
  cat "$TMP_MERGED_MENU" >>"$TMP_MENU"
  rm -f "$TMP_MERGED_MENU" 2>/dev/null || true
fi

# Separator between personal sections and team sections
if { [ "${SHOW_ASSIGNED_TO_TEAMS_SECTION:-0}" = "1" ]; } || { [ "${SHOW_RAISED_BY_TEAMS_SECTION:-0}" = "1" ]; }; then
  # Team sections
  echo "---" >>"$TMP_MENU"
fi

if [ "${SHOW_ASSIGNED_TO_TEAMS_SECTION:-0}" = "1" ]; then
  echo "Assigned to" >>"$TMP_MENU"
fi

if [ "${SHOW_ASSIGNED_TO_TEAMS_SECTION:-0}" = "1" ]; then
  TP_COUNT=0
  # Run total counts concurrently across all configured teams
  TOTAL_DIR="$(mktemp -d)"
  TOTAL_PIDS=()
  for team in "${ASSIGNED_TO_TEAMS_ARRAY[@]}"; do
    REPO_Q=$(build_repo_qualifier)
    COLLECT_ASSIGNED=1
    q="is:pr is:open team-review-requested:${team}${REPO_Q}"
    f="$TOTAL_DIR/${team//\//_}.txt"
    TP_COUNT=$((TP_COUNT + 1))
    if [ $((TP_COUNT % ASSIGNED_MAX_PAR)) -eq 0 ]; then
      for pid in "${TOTAL_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
      TOTAL_PIDS=()
    fi
    (gh api graphql -f query='query($q:String!){ search(query:$q, type: ISSUE){ issueCount } }' -F q="$q" --jq '.data.search.issueCount' >"$f" 2>/dev/null || echo "0" >"$f") &
    TOTAL_PIDS+=($!)
  done
fi

if [ "${SHOW_ASSIGNED_TO_TEAMS_SECTION:-0}" = "1" ]; then
  # 2.
  # Show the list of PRs per configured team
  N=50
  for team in "${ASSIGNED_TO_TEAMS_ARRAY[@]}"; do
    team_name="${team#*/}"
    echo "$team_name" >>"$TMP_MENU"
    TMP_TEAM_MENU="$(mktemp)"
    fetch_team_prs "$team" "$TMP_TEAM_MENU"
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
    echo "$r_name" >>"$TMP_MENU"
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
    : >"$RB_NODES_FILE"

    # Parallelize per-author queries to speed up Raised by section
    RB_DIR="$(mktemp -d)"
    RB_PIDS=()
    RB_MAX_PAR="${RAISED_BY_CONCURRENCY:-8}"
    # Validate positive integer; fallback to 8 if invalid
    if ! [[ "$RB_MAX_PAR" =~ ^[1-9][0-9]*$ ]]; then RB_MAX_PAR=8; fi
    RB_COUNT=0
    for u in $MEMBERS; do
      # Build server-side qualifiers using watched repos
      REPO_Q=$(build_repo_qualifier)

      RQ="is:pr is:open author:${u}${REPO_Q}"
      (
        gh api graphql -F q="$RQ" -F n="$N" -f query='
          query($q:String!,$n:Int!){
            search(query:$q,type:ISSUE,first:$n){
              edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted}}}}
            }}' \
          --jq '.data.search.edges[].node' 2>/dev/null >"$RB_DIR/$u.json" || true
      ) &
      RB_PIDS+=($!)
      RB_COUNT=$((RB_COUNT + 1))
      if [ $((RB_COUNT % RB_MAX_PAR)) -eq 0 ]; then
        for pid in "${RB_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
        RB_PIDS=()
      fi
    done
    # Wait for remaining jobs
    for pid in "${RB_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
    # Concatenate all results
    if ls "$RB_DIR"/*.json >/dev/null 2>&1; then
      cat "$RB_DIR"/*.json >>"$RB_NODES_FILE" 2>/dev/null || true
    fi
    rm -rf "$RB_DIR" 2>/dev/null || true

    # Build synthetic RESP excluding PRs already listed under ASSIGNED_TO_TEAMS
    if [ -s "$RB_NODES_FILE" ]; then
      RESP=$(jq -s --rawfile assigned "$ASSIGNED_FILE" '
        unique_by(.repository.nameWithOwner + "#" + (.number|tostring))
        | map(
            . as $n
            | select( ($n.repository.nameWithOwner + "\t" + ($n.number|tostring)) as $k | ($assigned | split("\n") | index($k) | not))
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
    COLLECT_ASSIGNED=0
    render_and_update_pagination >>"$TMP_TEAM_MENU"
    unset HEADER_LINK_KIND

    cat "$TMP_TEAM_MENU" >>"$TMP_MENU"
    rm -f "$TMP_TEAM_MENU" "$RB_NODES_FILE" 2>/dev/null || true
  done
fi

# Separator and "All" section listing every open PR in watched repos (deduped against previous sections)
if [ "${SHOW_RAISED_BY_TEAMS_SECTION:-0}" = "1" ]; then
  echo "---" >>"$TMP_MENU"
fi

echo "All" >>"$TMP_MENU"
TMP_ALL_MENU="$(mktemp)"
(
  # Dedupe "All" against earlier sections (use SEEN_PRS_FILE)
  fetch_all "$TMP_ALL_MENU"
)
cat "$TMP_ALL_MENU" >>"$TMP_MENU"
ALL_TOTAL=$(awk 'match($0, /^-- [^:]+: ([0-9]+)/, a){sum+=a[1]} END{print (sum+0)}' "$TMP_ALL_MENU" 2>/dev/null || echo 0)

rm -f "$TMP_ALL_MENU" 2>/dev/null || true

# Wait for total count jobs, then print header and buffered list
for pid in "${TOTAL_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
TOTAL=0
for f in "$TOTAL_DIR"/*.txt; do
  v=$(cat "$f" 2>/dev/null || echo "0")
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  TOTAL=$((TOTAL + v))
done

# Bar Title for when logged in: just an icon and the total PR count (All section grand total)
echo "🔀 ${ALL_TOTAL}"
echo "---"
cat "$TMP_MENU"

# Cleanup temp files (menu buffers)
rm -f "$TMP_MENU" "$UNREAD_FILE" "$ASSIGNED_FILE" "$INVOLVES_FILE" 2>/dev/null || true
rm -rf "$TOTAL_DIR" 2>/dev/null || true

# 3. Notifications across all sections (assigned + raised-by)
STATE_DIR="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}"
STATE_FILE="$STATE_DIR/xtv-tango.state.tsv"
NOTIFIED_FILE="$STATE_DIR/xtv-tango.notified.tsv"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
touch "$NOTIFIED_FILE"
# Temporarily relax -e for notifications to avoid SwiftBar error panel on intermittent API issues
set +e

# CURRENT_OPEN_FILE contains: repo\tnumber\ttitle\turl\tconv\tin_queue\tassigned_in_team\tcomment_id\tcomment_author\tcomment_body
if [ ! -s "$STATE_FILE" ]; then
  # Prime state on first run; avoid spamming notifications
  cp "$CURRENT_OPEN_FILE" "$STATE_FILE" 2>/dev/null || true

else
  # Build maps for current and previous
  PREV="$STATE_FILE"

  # Call notification functions
  notify_new_prs "$CURRENT_OPEN_FILE" "$PREV" "$NOTIFIED_FILE"
  notify_newly_assigned "$CURRENT_OPEN_FILE" "$PREV" "$NOTIFIED_FILE" "$STATE_DIR"
  # Mentions: compare current vs previous Mentioned list and notify on new entries
  if [ -n "${MENTIONED_CURR_FILE:-}" ]; then
    STATE_MENTION_FILE="${STATE_DIR}/xtv-tango.mention.state.tsv"
    notify_mentions "$CURRENT_OPEN_FILE" "$STATE_MENTION_FILE" "$MENTIONED_CURR_FILE" "$NOTIFIED_FILE"
  fi

  # Re-requested review (more complex, kept inline for now)
  # Re-requested review to your team (fires even if already assigned)
  if [ "${NOTIFY_REREQUESTED:-1}" = "1" ]; then
    STATE_REREQ_FILE="${STATE_DIR}/xtv-tango.rerequest.state.tsv"
    CURR_REREQ_FILE="${STATE_DIR}/xtv-tango.rerequest.curr.tsv"
    : >"$CURR_REREQ_FILE"

    # prepare current run re-request hits file (for next menu render)
    REREQ_HITS_TMP="${REREQ_HITS_FILE}.tmp"
    if [ -s "$REREQ_HITS_FILE" ]; then
      cp "$REREQ_HITS_FILE" "$REREQ_HITS_TMP" 2>/dev/null || : >"$REREQ_HITS_TMP"
    else
      : >"$REREQ_HITS_TMP"
    fi

    # Build teams JSON array for jq membership check
    ASSIGNED_JSON="["
    for t in "${ASSIGNED_TO_TEAMS_ARRAY[@]}"; do ASSIGNED_JSON+="\"$t\","; done
    ASSIGNED_JSON="${ASSIGNED_JSON%,}]"

    # For each current PR assigned to team, fetch latest team ReviewRequestedEvent timestamp
    while IFS=$'\t' read -r repo num title url conv in_queue assigned_in_team; do
      [ "$assigned_in_team" = "1" ] || continue
      owner="${repo%%/*}"
      rname="${repo#*/}"
      last_ts=$(gh api graphql -F owner="$owner" -F name="$rname" -F number="$num" -f query='
          query($owner:String!,$name:String!,$number:Int!){
            repository(owner:$owner,name:$name){
              pullRequest(number:$number){
                timelineItems(last: 20, itemTypes: REVIEW_REQUESTED_EVENT){
                  nodes{
                    createdAt
                    requestedReviewer{
                      __typename
                      ... on Team { slug organization{ login } }
                      ... on User { login }
                    }
                  }
                }
              }
            }
          }' 2>/dev/null | jq -r --argjson TEAMS "$ASSIGNED_JSON" '
            (.data.repository?.pullRequest?.timelineItems?.nodes // [])
            | map(select(.requestedReviewer? and .requestedReviewer.__typename=="Team")
                  | {t: (.requestedReviewer.organization.login + "/" + .requestedReviewer.slug), createdAt})
            | map(select($TEAMS | index(.t)))
            | (map(.createdAt) | max) // empty' || true)
      if [ -n "$last_ts" ]; then
        printf "%s#%s\t%s\n" "$repo" "$num" "$last_ts" >>"$CURR_REREQ_FILE"
      fi
    done <"$CURRENT_OPEN_FILE"

    # Compare to previous map and notify only when timestamp increased
    if [ -s "$STATE_REREQ_FILE" ]; then
      { join -t $'\t' -1 1 -2 1 "$STATE_REREQ_FILE" "$CURR_REREQ_FILE" || true; } |
        while IFS=$'\t' read -r key prev_ts curr_ts; do
          if [ -n "$curr_ts" ] && [ "$curr_ts" \> "$prev_ts" ]; then
            repo="${key%%#*}"
            num="${key##*#}"
            # Check if we already notified about this re-request timestamp
            notif_key="rerequest:${key}:${curr_ts}"
            if grep -q -F -x "$notif_key" "$NOTIFIED_FILE" 2>/dev/null; then
              continue
            fi
            row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$CURRENT_OPEN_FILE")
            [ -z "$row" ] && continue
            # record marker for next menu render
            printf "%s\t%s\n" "$repo" "$num" >>"$REREQ_HITS_TMP"

            title=$(echo "$row" | cut -f3)
            url=$(echo "$row" | cut -f4)
            gid="xtv-pr-${repo//\//-}-${num}-rerequest"
            notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Re-requested review" -subtitle "$repo #$num" -message "${title//\"/\\\"}" -open "$url" -sound default
            # Mark as notified with timestamp to track this specific re-request event
            echo "$notif_key" >>"$NOTIFIED_FILE"
          fi
        done
    fi

    # Persist current map (prime if first run)

    # Persist re-request hits for next run's menu
    mv "$REREQ_HITS_TMP" "$REREQ_HITS_FILE" 2>/dev/null || cp "$REREQ_HITS_TMP" "$REREQ_HITS_FILE" 2>/dev/null || true

    mv "$CURR_REREQ_FILE" "$STATE_REREQ_FILE" 2>/dev/null || cp "$CURR_REREQ_FILE" "$STATE_REREQ_FILE" 2>/dev/null || true
  fi

  # Approval dismissed notifications (built during render)
  notify_approval_dismissed "$CURRENT_OPEN_FILE" "$NOTIFIED_FILE" "$DISMISSED_HITS_FILE"

  notify_new_comments "$CURRENT_OPEN_FILE" "$NOTIFIED_FILE"
  notify_queue "$CURRENT_OPEN_FILE" "$PREV" "$NOTIFIED_FILE" "$STATE_DIR"
  notify_merged "$CURRENT_OPEN_FILE" "$PREV" "$NOTIFIED_FILE"
fi

# Restore strict error handling after notifications
set -e

# Clean up old notification entries for PRs that no longer exist
# Keep only entries for PRs that are currently open or were just closed (in PREV)
if [ -s "$NOTIFIED_FILE" ]; then
  NOTIFIED_TMP="$(mktemp)"

  while IFS= read -r notif_line; do
    # Extract repo#num from notification key (format: type:repo#num or type:repo#num:extra)
    pr_key=$(echo "$notif_line" | sed -E 's/^[^:]+:([^:]+)(:.+)?$/\1/')
    # Keep if PR exists in current or previous state
    if grep -q -F "$pr_key" <(cut -f1,2 "$CURRENT_OPEN_FILE" "$PREV" 2>/dev/null | awk '{print $1"#"$2}') 2>/dev/null; then
      echo "$notif_line" >>"$NOTIFIED_TMP"
    fi
  done <"$NOTIFIED_FILE"

  mv "$NOTIFIED_TMP" "$NOTIFIED_FILE" 2>/dev/null || cp "$NOTIFIED_TMP" "$NOTIFIED_FILE" 2>/dev/null || true
  rm -f "$NOTIFIED_TMP" 2>/dev/null || true
fi

# Clean up seen PRs tracking file
rm -f "$SEEN_PRS_FILE" 2>/dev/null || true

# Persist state for next run
cp "$CURRENT_OPEN_FILE" "$STATE_FILE" 2>/dev/null || true
rm -f "$CURRENT_OPEN_FILE" 2>/dev/null || true
