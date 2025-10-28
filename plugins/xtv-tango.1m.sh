#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

# Dependencies (what/why/how to install)
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
#   SWIFTBAR_PLUGIN_CACHE_PATH  base dir for avatar/conversation/approvals caches
#   default '~/Library/Caches/com.ameba.SwiftBar/Plugins/xtv-tango.1m.sh'

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

# CONFIG:
# ---------
SORT_PREF="number"                # "activity" or "number"
SORT_DIR="desc"                   # "asc" or "desc"
REPO_HEADER_COLOR="#0A3069"       # dark blue for repo headers
REPO_HEADER_FONT="Helvetica-Bold" # bold header font (use a font installed on your Mac)
REPO_HEADER_SIZE="13"             # header font size

# Notification preferences (1=on, 0=off)
NOTIFY_NEW_PR=1
NOTIFY_NEW_COMMENT=1
NOTIFY_QUEUE=1
NOTIFY_MERGED=1
NOTIFY_NEWLY_ASSIGNED=1
NOTIFY_REREQUESTED=1

# Cache TTL for team members list (seconds). Default: 24 hours
TEAM_MEMBERS_CACHE_TTL=86400

# Concurrency for "Raised by" per-author fetch (parallel gh calls); must be a positive integer
RAISED_BY_CONCURRENCY=12
# Concurrency for "Assigned to" totals-count across teams; must be a positive integer
ASSIGNED_TOTALS_CONCURRENCY=12

# Marks for metrics/state; customize as you like
APPROVAL_MARK="✅"
CHANGES_REQUESTED_MARK="⛔"
COMMENT_MARK="💬"
DRAFT_MARK="⚪"
NOT_PARTICIPATED_MARK="🔅" # Shown when I'm not involved yet. Clears after I comment/approve/request changes or react to PR body. Comment reactions not counted.
QUEUE_MARK="🟠"
REREQUESTED_MARK="🔄"
UNREAD_MARK="🔺"

# Teams configuration: one org/team slug per line
ASSIGNED_TO_TEAMS="
NBCUDTC/xtv-tango
NBCUDTC/gst-apps-client-lib-steering-committee
NBCUDTC/xtv-devs
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
NBCUDTC/github-repos-deploy
NBCUDTC/gst-apps-client-lib
NBCUDTC/gst-apps-xtv
NBCUDTC/gst-apps-xtv-config
NBCUDTC/gst-shader-service
NBCUDTC/peacock-cliapps-ci
NBCUDTC/peacock-cliapps-nbcu-release
NBCUDTC/peacock-clients-dev-dns
"

# ROUTINES:
# ---------

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

# Cache and compute conversation count for a PR
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

# Cache and compute approvals count (unique approvers with latest state APPROVED)
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

# Render RESP and update pagination variables
render_and_update_pagination() {
  # Emoji symbols (only these are colored; rest of the line remains normal)
  DRAFT_EMOJI="${DRAFT_MARK:-⚪}"
  MERGE_QUEUE_EMOJI="${QUEUE_MARK:-🟠}"

  local STREAM
  STREAM=$(echo "$RESP" | jq -r \
    --arg draft "$DRAFT_EMOJI" \
    --arg queue "$MERGE_QUEUE_EMOJI" \
    --arg sort "$SORT_PREF" \
    --arg dir "$SORT_DIR" \
    --arg hdr "$REPO_HEADER_COLOR" \
    --arg hdrFont "$REPO_HEADER_FONT" \
    --arg hdrSize "$REPO_HEADER_SIZE" \
    --arg hdrLink "$HEADER_LINK_Q" '
    [ .data.search.edges[].node
      | {repo: .repository.nameWithOwner, number, title, url, isDraft, isInMergeQueue, updatedAt,
          author: (.author.login // "unknown"),
          avatar: (.author.avatarUrl // ""),
          comments: ((.comments.totalCount // 0) + (((.reviewThreads.nodes // []) | map(.comments.totalCount // 0) | add) // 0)),
          reviewDecision: (.reviewDecision // ""),
          viewerReacted: (((.reactionGroups // []) | map(.viewerHasReacted) | any) // false)
        }
      | .title |= (
          gsub("\r";"") | gsub("\n";" ")
          | gsub("\\|";"¦")
        )
      | .prefix = (
          if .isDraft then "\($draft) DRAFT "
          else if .isInMergeQueue then "\($queue) QUEUED "
          else "" end end
        )
    ]
    | group_by(.repo)
    | sort_by((.[0].repo | if . == "NBCUDTC/gst-apps-xtv" then 0 else 1 end), (.[0].repo))
    | to_entries
    | .[]
    | (if .key > 0 then "__SEP__" else empty end),
      (.value[0].repo + ": " + ((.value | length) | tostring) + " | href=https://github.com/\(.value[0].repo)/pulls?q=\($hdrLink) color=\($hdr) font=\($hdrFont) size=\($hdrSize)"),
      ( ((if $sort == "activity"
           then (.value | sort_by(.updatedAt | fromdateiso8601))
           else (.value | sort_by(.number))
         end)
         | (if $dir == "desc" then reverse else . end)
        )[]
        | "__PR__\t\(.author)\t\(.avatar)\t\(.url)\t\(.repo)\t\(.number)\t\(.updatedAt)\t\(.comments)\t\(.prefix)\(.title)\t\(.isInMergeQueue)\t\(.reviewDecision)\t\(.viewerReacted)" )
  ')
  TMP_OUT=$(mktemp)
  idx=0
  MAX_PAR="${XTV_CONC:-6}"
  SEEN_HEADER=0

  while IFS= read -r line; do
    if [[ "$line" == $'__PR__\t'* ]]; then
      IFS=$'\t' read -r _ login avatar url repo number updated comments title in_queue review_decision viewer_reacted <<<"$line"
      local_idx=$idx
      idx=$((idx + 1))
      (
        conv=$(get_conv_count "$repo" "$number" "$updated" 2>/dev/null)
        if ! [[ "$conv" =~ ^[0-9]+$ ]]; then conv="$comments"; fi
        label="$title"
        b64=$(get_avatar_b64 "$login" "$avatar" 20)
        # conversation and approvals emoji suffixes
        appr=$(get_approval_count "$repo" "$number" "$updated" 2>/dev/null)
        if ! [[ "$appr" =~ ^[0-9]+$ ]]; then appr=0; fi
        suffix=""
        if ((conv > 0)); then suffix+="  ${COMMENT_MARK:-💬}${conv}"; fi
        if ((appr > 0)); then suffix+="  ${APPROVAL_MARK:-✅}${appr}"; fi
        # key for lookups
        needle="$repo"$'\t'"$number"
        # not participated yet (no involves:@me and no reaction on PR body)
        participated=0
        if [ -s "$INVOLVES_FILE" ] && grep -x -F -- "$needle" "$INVOLVES_FILE" >/dev/null 2>&1; then
          participated=1
        fi
        if [ "$participated" -eq 0 ] && [ "${viewer_reacted:-false}" != "true" ]; then
          label="${NOT_PARTICIPATED_MARK:-🟡} $label"
        fi

        if [ "${review_decision:-}" = "CHANGES_REQUESTED" ]; then suffix+="  ${CHANGES_REQUESTED_MARK:-🛑}"; fi
        # unread notifications red dot
        if [ -s "$UNREAD_FILE" ] && grep -x -F -- "$needle" "$UNREAD_FILE" >/dev/null 2>&1; then
          suffix+="  ${UNREAD_MARK:-❗}"
        fi
        # marker for PRs that were re-requested in the previous run
        marked_rereq=0
        if [ -s "$REREQ_HITS_FILE" ] && grep -x -F -- "$needle" "$REREQ_HITS_FILE" >/dev/null 2>&1; then
          suffix+="  ${REREQUESTED_MARK:-🔄}"
          marked_rereq=1
        fi

        # record assigned PR to index if enabled
        if [ "$COLLECT_ASSIGNED" = "1" ] && [ -n "$ASSIGNED_FILE" ]; then
          printf "%s\t%s\n" "$repo" "$number" >>"$ASSIGNED_FILE"
        fi

        # record current open PR with metrics for notifications
        if [ -n "${CURRENT_OPEN_FILE:-}" ]; then
          assigned_flag="0"
          [ "$COLLECT_ASSIGNED" = "1" ] && assigned_flag="1"
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$repo" "$number" "$label" "$url" "$conv" "$in_queue" "$assigned_flag" >>"$CURRENT_OPEN_FILE"
        fi

        if [[ -n "$b64" ]]; then
          if [ "${marked_rereq:-0}" -eq 1 ]; then
            _click_cmd="grep -v -F -- \"$needle\" \"$REREQ_HITS_FILE\" >\"$REREQ_HITS_FILE.tmp\" || true; mv \"$REREQ_HITS_FILE.tmp\" \"$REREQ_HITS_FILE\" || true; open \"$url\""
            printf "%s\t-- %s%s | bash=/bin/bash param1=-lc param2=%q terminal=false refresh=true image=%s\n" \
              "$local_idx" "$label" "$suffix" "$_click_cmd" "$b64"
          else
            printf "%s\t-- %s%s | href=%s image=%s\n" "$local_idx" "$label" "$suffix" "$url" "$b64"
          fi
        else
          if [ "${marked_rereq:-0}" -eq 1 ]; then
            _click_cmd="grep -v -F -- \"$needle\" \"$REREQ_HITS_FILE\" >\"$REREQ_HITS_FILE.tmp\" || true; mv \"$REREQ_HITS_FILE.tmp\" \"$REREQ_HITS_FILE\" || true; open \"$url\""
            printf "%s\t-- %s%s | bash=/bin/bash param1=-lc param2=%q terminal=false refresh=true sfimage=person.crop.circle\n" \
              "$local_idx" "$label" "$suffix" "$_click_cmd"
          else
            printf "%s\t-- %s%s | href=%s sfimage=person.crop.circle\n" "$local_idx" "$label" "$suffix" "$url"
          fi
        fi

      ) >>"$TMP_OUT" &
      # Throttle concurrency
      while (($(jobs -pr | wc -l | tr -d ' ') >= MAX_PAR)); do sleep 0.05; done
    else
      # Ignore any explicit separator tokens from jq (we'll insert ourselves)
      if [[ "$line" == "__SEP__" ]]; then
        continue
      fi
      # Flush pending PR entries before starting a new header block
      if [[ -n "$line" ]]; then
        for pid in $(jobs -pr); do wait "$pid" 2>/dev/null || true; done
        if [[ -s "$TMP_OUT" ]]; then
          sort -n -t $'\t' -k1,1 "$TMP_OUT" | cut -f2-
          : >"$TMP_OUT"
        fi
        # Insert a separator before this repo header, except before the very first one
        if ((SEEN_HEADER == 1)); then echo "--"; fi
        SEEN_HEADER=1
      fi
      echo "-- $line"
    fi
  done <<<"$STREAM"
  # Final flush
  for pid in $(jobs -pr); do wait "$pid" 2>/dev/null || true; done
  if [[ -s "$TMP_OUT" ]]; then
    sort -n -t $'\t' -k1,1 "$TMP_OUT" | cut -f2-
  fi
  rm -f "$TMP_OUT" 2>/dev/null || true
  HAS_NEXT=$(echo "$RESP" | jq -r '.data.search.pageInfo.hasNextPage')
  CURSOR=$(echo "$RESP" | jq -r '.data.search.pageInfo.endCursor')
}

# MAIN CODE:
# ---------

# Parse into array (trim whitespace, drop empty lines) - compatible with older bash
ASSIGNED_ARR=()
while IFS= read -r line; do
  line=$(printf "%s" "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -z "$line" ] && continue
  ASSIGNED_ARR+=("$line")
done <<<"$ASSIGNED_TO_TEAMS"

RAISED_ARR=()
while IFS= read -r line; do
  line=$(printf "%s" "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -z "$line" ] && continue
  RAISED_ARR+=("$line")
done <<<"$RAISED_BY_TEAMS"

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

# Index of PRs already listed in ASSIGNED_TO_TEAMS (repo\tnumber)
ASSIGNED_FILE="$(mktemp)"
: >"$ASSIGNED_FILE"
# Header link query string for repo header href (URL-encoded)
HEADER_LINK_Q=""
# Flags used by renderer
COLLECT_ASSIGNED=0

# Build index of unread PR notifications (requires notifications scope)
UNREAD_FILE="$(mktemp)"
if ! gh api -H "Accept: application/vnd.github+json" 'notifications?per_page=100' \
  --jq '.[] | select(.unread == true and .subject.type == "PullRequest") | [.repository.full_name, (.subject.url | sub(".*/pulls/"; ""))] | @tsv' \
  >"$UNREAD_FILE" 2>/dev/null; then
  : >"$UNREAD_FILE"
fi

# Build index of PRs I have participated in (involves:@me). Limit to 100 for speed.
INVOLVES_FILE="$(mktemp)"
if ! gh api graphql -F q="is:pr is:open involves:@me" -F n="100" -f query='
  query($q:String!,$n:Int!){
    search(query:$q,type:ISSUE,first:$n){
      edges{node{... on PullRequest{ number repository{nameWithOwner} }}}
    }
  }' \
  --jq '.data.search.edges[].node | [.repository.nameWithOwner, (.number|tostring)] | @tsv' \
  >"$INVOLVES_FILE" 2>/dev/null; then
  : >"$INVOLVES_FILE"
fi

# Start: buffer for the per-team menu and compute totals across teams
TMP_MENU="$(mktemp)"

ASSIGNED_MAX_PAR="${ASSIGNED_TOTALS_CONCURRENCY:-8}"
if ! [[ "$ASSIGNED_MAX_PAR" =~ ^[1-9][0-9]*$ ]]; then ASSIGNED_MAX_PAR=8; fi
# Personal sections before team sections
# 0.a Assigned to Me (review requested to me)
echo "Assigned to Me" >>"$TMP_MENU"
TMP_ME_MENU="$(mktemp)"
# Build repo allowlist qualifier if provided
REPO_Q=""
if [ "${#WATCHED_ARR[@]}" -gt 0 ]; then
  for r in "${WATCHED_ARR[@]}"; do REPO_Q+=" repo:${r}"; done
fi
if [ -n "$REPO_Q" ]; then
  Q="is:pr is:open review-requested:@me${REPO_Q}"
else
  Q="is:pr is:open review-requested:@me"
fi
HEADER_LINK_Q="is%3Apr+is%3Aopen+review-requested%3A%40me"
COLLECT_ASSIGNED=0
RESP=$(gh api graphql -F q="$Q" -F n="50" -f query='
  query($q:String!,$n:Int!){
    search(query:$q,type:ISSUE,first:$n){
      pageInfo{hasNextPage endCursor}
      edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted}}}}
    }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
render_and_update_pagination >>"$TMP_ME_MENU"
while [ "$HAS_NEXT" = "true" ]; do
  RESP=$(gh api graphql -F q="$Q" -F n="50" -F cursor="$CURSOR" -f query='
    query($q:String!,$n:Int!,$cursor:String!){
      search(query:$q,type:ISSUE,first:$n,after:$cursor){
        pageInfo{hasNextPage endCursor}
        edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted}}}}
      }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
  render_and_update_pagination >>"$TMP_ME_MENU"
done
cat "$TMP_ME_MENU" >>"$TMP_MENU"
rm -f "$TMP_ME_MENU" 2>/dev/null || true

# 0.b Raised by Me (my authored PRs)
echo "Raised by Me" >>"$TMP_MENU"
TMP_MYPR_MENU="$(mktemp)"
REPO_Q=""
if [ "${#WATCHED_ARR[@]}" -gt 0 ]; then
  for r in "${WATCHED_ARR[@]}"; do REPO_Q+=" repo:${r}"; done
fi
if [ -n "$REPO_Q" ]; then
  Q="is:pr is:open author:@me${REPO_Q}"
else
  Q="is:pr is:open author:@me"
fi
HEADER_LINK_Q="is%3Apr+is%3Aopen+author%3A%40me"
COLLECT_ASSIGNED=0
RESP=$(gh api graphql -F q="$Q" -F n="50" -f query='
  query($q:String!,$n:Int!){
    search(query:$q,type:ISSUE,first:$n){
      pageInfo{hasNextPage endCursor}
      edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted}}}}
    }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
render_and_update_pagination >>"$TMP_MYPR_MENU"
while [ "$HAS_NEXT" = "true" ]; do
  RESP=$(gh api graphql -F q="$Q" -F n="50" -F cursor="$CURSOR" -f query='
    query($q:String!,$n:Int!,$cursor:String!){
      search(query:$q,type:ISSUE,first:$n,after:$cursor){
        pageInfo{hasNextPage endCursor}
        edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted}}}}
      }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
  render_and_update_pagination >>"$TMP_MYPR_MENU"
done
cat "$TMP_MYPR_MENU" >>"$TMP_MENU"
rm -f "$TMP_MYPR_MENU" 2>/dev/null || true

echo "Assigned to" >>"$TMP_MENU"

TP_COUNT=0

# Run total counts concurrently across all configured teams
TOTAL_DIR="$(mktemp -d)"
TOTAL_PIDS=()
for team in "${ASSIGNED_ARR[@]}"; do

  COLLECT_ASSIGNED=1

  # Build repo allowlist qualifier if provided
  REPO_Q=""
  if [ "${#WATCHED_ARR[@]}" -gt 0 ]; then
    for r in "${WATCHED_ARR[@]}"; do REPO_Q+=" repo:${r}"; done
  fi
  if [ -n "$REPO_Q" ]; then
    q="is:pr is:open team-review-requested:${team}${REPO_Q}"
  else
    q=""
  fi
  f="$TOTAL_DIR/${team//\//_}.txt"
  TP_COUNT=$((TP_COUNT + 1))
  if [ $((TP_COUNT % ASSIGNED_MAX_PAR)) -eq 0 ]; then
    for pid in "${TOTAL_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
    TOTAL_PIDS=()
  fi

  if [ -n "$q" ]; then
    (gh api graphql -f query='query($q:String!){ search(query:$q, type: ISSUE){ issueCount } }' -F q="$q" --jq '.data.search.issueCount' >"$f" 2>/dev/null || echo "0" >"$f") &
    TOTAL_PIDS+=($!)
  else
    echo "0" >"$f"
  fi
done

# 2.
# Show the list of PRs per configured team
N=50
for team in "${ASSIGNED_ARR[@]}"; do
  team_org="${team%%/*}"
  team_name="${team#*/}"
  echo "$team_name" >>"$TMP_MENU"
  TMP_TEAM_MENU="$(mktemp)"
  # Build repo allowlist qualifier if provided
  REPO_Q=""
  if [ "${#WATCHED_ARR[@]}" -gt 0 ]; then
    for r in "${WATCHED_ARR[@]}"; do REPO_Q+=" repo:${r}"; done
  fi
  if [ -n "$REPO_Q" ]; then
    Q="is:pr is:open team-review-requested:${team}${REPO_Q}"
  else
    Q="is:pr is:open org:${team_org} team-review-requested:${team}"
  fi
  HEADER_LINK_Q="is%3Apr+is%3Aopen+team-review-requested%3A${team//\//%2F}"

  if [ -n "$REPO_Q" ]; then
    RESP=$(gh api graphql -F q="$Q" -F n="$N" -f query='
      query($q:String!,$n:Int!){
        search(query:$q,type:ISSUE,first:$n){
          pageInfo{hasNextPage endCursor}
          edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted}}}}
        }}')
  else
    RESP='{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
  fi
  render_and_update_pagination >>"$TMP_TEAM_MENU"
  while [ "$HAS_NEXT" = "true" ]; do
    RESP=$(gh api graphql -F q="$Q" -F n="$N" -F cursor="$CURSOR" -f query='
      query($q:String!,$n:Int!,$cursor:String!){
        search(query:$q,type:ISSUE,first:$n,after:$cursor){
          pageInfo{hasNextPage endCursor}
          edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted}}}}
        }}')
    render_and_update_pagination >>"$TMP_TEAM_MENU"
  done
  cat "$TMP_TEAM_MENU" >>"$TMP_MENU"
  rm -f "$TMP_TEAM_MENU" 2>/dev/null || true
done
# Raised by section
if [ "${#RAISED_ARR[@]}" -gt 0 ]; then
  echo "---" >>"$TMP_MENU"
  echo "Raised by" >>"$TMP_MENU"
  for rteam in "${RAISED_ARR[@]}"; do
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

    # If no allowlist provided, keep this team submenu empty
    if [ "${#WATCHED_ARR[@]}" -eq 0 ]; then
      RESP='{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
      HEADER_LINK_Q="is%3Apr+is%3Aopen"
      COLLECT_ASSIGNED=0
      render_and_update_pagination >>"$TMP_TEAM_MENU"
      cat "$TMP_TEAM_MENU" >>"$TMP_MENU"
      rm -f "$TMP_TEAM_MENU" 2>/dev/null || true
      continue
    fi

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
      # Build server-side qualifiers
      # Build repo allowlist qualifier if provided for Raised by
      REPO_Q=""
      if [ "${#WATCHED_ARR[@]}" -gt 0 ]; then
        for r in "${WATCHED_ARR[@]}"; do REPO_Q+=" repo:${r}"; done
      fi
      if [ -n "$REPO_Q" ]; then
        RQ="is:pr is:open author:${u}${REPO_Q}"
      else
        RQ="is:pr is:open org:${r_org} author:${u}"
      fi
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

    HEADER_LINK_Q="is%3Apr+is%3Aopen"
    COLLECT_ASSIGNED=0
    render_and_update_pagination >>"$TMP_TEAM_MENU"

    cat "$TMP_TEAM_MENU" >>"$TMP_MENU"
    rm -f "$TMP_TEAM_MENU" "$RB_NODES_FILE" 2>/dev/null || true
  done
fi

# Wait for total count jobs, then print header and buffered list
for pid in "${TOTAL_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
TOTAL=0
for f in "$TOTAL_DIR"/*.txt; do
  v=$(cat "$f" 2>/dev/null || echo "0")
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  TOTAL=$((TOTAL + v))
done

# Bar Title for when logged in: just an icon and the total PR count
echo "🔀 ${TOTAL}"
echo "---"
cat "$TMP_MENU"

# Cleanup temp files (menu buffers)
rm -f "$TMP_MENU" "$UNREAD_FILE" "$ASSIGNED_FILE" "$INVOLVES_FILE" 2>/dev/null || true
rm -rf "$TOTAL_DIR" 2>/dev/null || true

# 3. Notifications across all sections (assigned + raised-by)
STATE_DIR="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}"
STATE_FILE="$STATE_DIR/xtv-tango.state.tsv"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
# Temporarily relax -e for notifications to avoid SwiftBar error panel on intermittent API issues
set +e

# CURRENT_OPEN_FILE contains: repo\tnumber\ttitle\turl\tconv\tin_queue\tassigned_in_team
if [ ! -s "$STATE_FILE" ]; then
  # Prime state on first run; avoid spamming notifications
  cp "$CURRENT_OPEN_FILE" "$STATE_FILE" 2>/dev/null || true
else
  # Build maps for current and previous
  PREV="$STATE_FILE"
  # New PRs
  if [ "${NOTIFY_NEW_PR:-1}" = "1" ]; then
    { join -t $'\t' -v1 -1 1 -2 1 <(cut -f1,2 "$CURRENT_OPEN_FILE" | awk '{print $1"#"$2}' | sort -u) <(cut -f1,2 "$PREV" | awk '{print $1"#"$2}' | sort -u) || true; } |
      while IFS= read -r key; do
        repo="${key%%#*}"
        num="${key##*#}"
        # Lookup full row in CURRENT_OPEN_FILE
        row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$CURRENT_OPEN_FILE")
        [ -z "$row" ] && continue
        title=$(echo "$row" | cut -f3)
        url=$(echo "$row" | cut -f4)
        gid="xtv-pr-${repo//\//-}-${num}-new"
        notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "xtv-tango" -subtitle "$repo #$num" -message "${title//\"/\\\"}" -open "$url" -sound default
      done
    # Newly assigned to your team (transition from not-assigned -> assigned)
    if [ "${NOTIFY_NEWLY_ASSIGNED:-1}" = "1" ]; then
      awk -F'\t' '{a=$7; if (a=="") a="0"; printf "%s#%s\t%s\n",$1,$2,a}' "$PREV" | sort >"${STATE_DIR}/prev_assigned.tsv"
      awk -F'\t' '{a=$7; if (a=="") a="0"; printf "%s#%s\t%s\n",$1,$2,a}' "$CURRENT_OPEN_FILE" | sort >"${STATE_DIR}/curr_assigned.tsv"
      { join -t $'\t' -1 1 -2 1 "${STATE_DIR}/prev_assigned.tsv" "${STATE_DIR}/curr_assigned.tsv" || true; } |
        while IFS=$'\t' read -r key prev_a curr_a; do
          if [ "$prev_a" != "1" ] && [ "$curr_a" = "1" ]; then
            repo="${key%%#*}"
            num="${key##*#}"
            row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$CURRENT_OPEN_FILE")
            [ -z "$row" ] && continue
            title=$(echo "$row" | cut -f3)
            url=$(echo "$row" | cut -f4)
            gid="xtv-pr-${repo//\//-}-${num}-assigned"
            notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Assigned to your team" -subtitle "$repo #$num" -message "${title//\"/\\\"}" -open "$url" -sound default
          fi
        done
      rm -f "${STATE_DIR}/prev_assigned.tsv" "${STATE_DIR}/curr_assigned.tsv" 2>/dev/null || true
    fi

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
      for t in "${ASSIGNED_ARR[@]}"; do ASSIGNED_JSON+="\"$t\","; done
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
              row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$CURRENT_OPEN_FILE")
              [ -z "$row" ] && continue
              # record marker for next menu render
              printf "%s\t%s\n" "$repo" "$num" >>"$REREQ_HITS_TMP"

              title=$(echo "$row" | cut -f3)
              url=$(echo "$row" | cut -f4)
              gid="xtv-pr-${repo//\//-}-${num}-rerequest"
              notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Re-requested review" -subtitle "$repo #$num" -message "${title//\"/\\\"}" -open "$url" -sound default
            fi
          done
      fi

      # Persist current map (prime if first run)

      # Persist re-request hits for next run's menu
      mv "$REREQ_HITS_TMP" "$REREQ_HITS_FILE" 2>/dev/null || cp "$REREQ_HITS_TMP" "$REREQ_HITS_FILE" 2>/dev/null || true

      mv "$CURR_REREQ_FILE" "$STATE_REREQ_FILE" 2>/dev/null || cp "$CURR_REREQ_FILE" "$STATE_REREQ_FILE" 2>/dev/null || true
    fi

  fi

  # New comments
  if [ "${NOTIFY_NEW_COMMENT:-1}" = "1" ]; then
    # For each current PR, compare conversation count to previous run
    while IFS=$'\t' read -r repo num title url conv in_queue _assigned_in_team; do
      prev_conv=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print $5; exit}' "$PREV")
      [[ -z "$prev_conv" ]] && continue
      if [ "$conv" -gt "$prev_conv" ] 2>/dev/null; then
        delta=$((conv - prev_conv))
        gid="xtv-pr-${repo//\//-}-${num}-comment"
        notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "New comments (+$delta)" -subtitle "$repo #$num" -message "${title//\"/\\\"}" -open "$url" -sound default
      fi
    done <"$CURRENT_OPEN_FILE"
  fi

  # Pushed to queue
  if [ "${NOTIFY_QUEUE:-1}" = "1" ]; then
    awk -F'\t' '{print $1"#"$2"\t"$6}' "$PREV" | sort >"$STATE_DIR/prev_q.tsv"
    awk -F'\t' '{print $1"#"$2"\t"$6}' "$CURRENT_OPEN_FILE" | sort >"$STATE_DIR/curr_q.tsv"
    { join -t $'\t' -1 1 -2 1 "${STATE_DIR}/prev_q.tsv" "${STATE_DIR}/curr_q.tsv" || true; } |
      while IFS=$'\t' read -r key prev_q curr_q; do
        if [ "$prev_q" != "true" ] && [ "$curr_q" = "true" ]; then
          repo="${key%%#*}"
          num="${key##*#}"
          row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$CURRENT_OPEN_FILE")
          [ -z "$row" ] && continue
          title=$(echo "$row" | cut -f3)
          url=$(echo "$row" | cut -f4)
          gid="xtv-pr-${repo//\//-}-${num}-queue"
          notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Queued for merge" -subtitle "$repo #$num" -message "${title//\"/\\\"}" -open "$url" -sound default
        fi
      done
    rm -f "${STATE_DIR}/prev_q.tsv" "${STATE_DIR}/curr_q.tsv" 2>/dev/null || true
  fi

  # Merged (PR missing now; verify merged via REST)
  if [ "${NOTIFY_MERGED:-1}" = "1" ]; then
    { join -t $'\t' -v2 -1 1 -2 1 <(cut -f1,2 "$CURRENT_OPEN_FILE" | awk '{print $1"#"$2}' | sort -u) <(cut -f1,2 "$PREV" | awk '{print $1"#"$2}' | sort -u) || true; } |
      while IFS= read -r key; do
        repo="${key%%#*}"
        num="${key##*#}"
        owner="${repo%%/*}"
        rname="${repo#*/}"
        merged=$(gh api "repos/$owner/$rname/pulls/$num" --jq '.merged' 2>/dev/null || echo "false")
        if [ "$merged" = "true" ]; then
          # Try to get a title and url from previous state row
          prow=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$PREV")
          title=$(echo "$prow" | cut -f3)
          url=$(echo "$prow" | cut -f4)
          gid="xtv-pr-${repo//\//-}-${num}-merged"
          notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Merged" -subtitle "$repo #$num" -message "${title//\"/\\\"}" -open "$url" -sound default
        fi
      done
  fi
fi

# Restore strict error handling after notifications
set -e

# Persist state for next run
cp "$CURRENT_OPEN_FILE" "$STATE_FILE" 2>/dev/null || true
rm -f "$CURRENT_OPEN_FILE" 2>/dev/null || true
