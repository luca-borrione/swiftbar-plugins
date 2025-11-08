#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# SC2034: Variables like HAS_NEXT, CURSOR appear unused but are used in fetch.sh

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
# Functions for caching, fetching, and rendering PR data

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

# Combined GraphQL function to fetch all PR data in one call
# Returns: conv_count<TAB>approval_count<TAB>latest_comment_id<TAB>latest_comment_author<TAB>latest_comment_body
get_pr_data_combined() {
  local repo="$1" number="$2" updatedAt="$3"
  local cache_dir="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-pr-data"
  mkdir -p "$cache_dir"
  local key="${repo//\//_}-${number}.txt"
  local file="$cache_dir/$key"

  # Check cache
  if [[ -s "$file" ]]; then
    local cached_updated cached_data
    IFS=$'\t' read -r cached_updated cached_data <"$file" || true
    if [[ "$cached_updated" == "$updatedAt" ]]; then
      echo "$cached_data"
      return 0
    fi
  fi

  # Fetch everything in one GraphQL call
  local owner="${repo%%/*}"
  local rname="${repo#*/}"

  local result
  result=$(gh api graphql -F owner="$owner" -F name="$rname" -F number="$number" -f query='
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$number){
          comments(last:1){
            nodes{
              id
              author{login}
              body
            }
            totalCount
          }
          reviewThreads{totalCount}
          reviews(last:100){
            nodes{
              author{login}
              state
              body
            }
          }
          latestReviews(last:100){
            nodes{
              author{login}
              state
            }
          }
        }
      }
    }' 2>/dev/null | jq -r '
      .data.repository.pullRequest as $pr |
      if $pr == null then
        "0\t0\t\t\t"
      else
        # Conversation count: comments + review threads + reviews with body
        (($pr.comments.totalCount // 0) + ($pr.reviewThreads.totalCount // 0) + ([($pr.reviews.nodes // [])[] | select((.body // "") != "")] | length)) as $conv |

        # Approval count: unique approvers with latest state APPROVED
        ([($pr.latestReviews.nodes // []) | reverse | reduce .[] as $r ({}; .[$r.author.login] //= $r.state) | to_entries[] | select(.value == "APPROVED")] | length) as $appr |

        # Latest comment info (for notifications)
        (($pr.comments.nodes // [])[0] // {}) as $comment |
        ($comment.id // "") as $cid |
        (($comment.author // {}).login // "") as $cauthor |
        ($comment.body // "") as $cbody |

        "\($conv)\t\($appr)\t\($cid)\t\($cauthor)\t\($cbody)"
      end
    ' 2>/dev/null)

  # Validate result (at minimum we need conv and appr counts)
  if [[ "$result" =~ ^[0-9]+$'\t'[0-9]+ ]]; then
    # Cache it
    printf "%s\t%s\n" "$updatedAt" "$result" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
    echo "$result"
  else
    # Return defaults if query failed
    echo "0${TAB}0${TAB}${TAB}${TAB}"
  fi
}

# Return 1 if my latest review is APPROVED (and not superseded by CHANGES_REQUESTED/DISMISSED), else 0
get_my_approval_flag() {
  local repo="$1" number="$2" updatedAt="$3"
  local cache_dir="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-my-approval-v1"
  mkdir -p "$cache_dir"
  local key="${repo//\//_}-${number}.txt"
  local file="$cache_dir/$key"

  if [[ -s "$file" ]]; then
    local cached_updated cached_flag
    IFS=$'\t' read -r cached_updated cached_flag <"$file" || true
    if [[ "$cached_updated" == "$updatedAt" && "$cached_flag" =~ ^[01]$ ]]; then
      echo "$cached_flag"
      return 0
    fi
  fi

  local owner="${repo%%/*}"
  local rname="${repo#*/}"
  local viewer="${MY_LOGIN:-}"

  local me_login_used mine_state latest_count flag dbg_out rest_state
  dbg_out=$(gh api graphql -F owner="$owner" -F name="$rname" -F number="$number" -f query='
    query($owner:String!,$name:String!,$number:Int!){
      viewer { login }
      repository(owner:$owner,name:$name){
        pullRequest(number:$number){
          latestReviews(last:100){ nodes{ author{login} state } }
        }
      }
    }' 2>/dev/null | jq -r --arg viewer "$viewer" '
      . as $root |
      ($root.data.viewer.login // "") as $viewerLogin |
      $root.data.repository.pullRequest as $pr |
      if $pr == null then
        ("\t\t0\t0")
      else
        (($viewer // "") | length) as $len |
        (if $len > 0 then $viewer else $viewerLogin end) as $meLogin |
        (($pr.latestReviews.nodes // [])) as $nodes |
        (reduce $nodes[] as $r ({}) (.[(($r.author.login // "") | ascii_downcase)] = ($r.state // ""))) as $latest |
        ($latest[($meLogin | ascii_downcase)] // "") as $mine |
        (if $mine == "APPROVED" then "1" else "0" end) as $flag |
        "\($meLogin)\t\($mine)\t\($flag)\t\($nodes|length)"
      end
    ' 2>/dev/null)
  IFS=$'\t' read -r me_login_used mine_state flag latest_count <<<"$dbg_out"

  # Fallback via REST: verify latest state per user
  if [[ "$flag" != "1" && (-z "$me_login_used" || "$latest_count" = "0") ]]; then
    rest_state=$(gh api "repos/$repo/pulls/$number/reviews?per_page=100" \
      --jq 'reverse | reduce .[] as $r ({}; .[$r.user.login] //= ($r.state // "")) | .["'"${viewer:-}"'"] // ""' 2>/dev/null || echo "")
    if [[ "$rest_state" == "APPROVED" ]]; then flag="1"; elif [[ "$flag" != "1" ]]; then flag="0"; fi
  fi

  if [[ "$flag" != "1" && "$flag" != "0" ]]; then flag="0"; fi
  printf "%s\t%s\n" "$updatedAt" "$flag" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
  echo "$flag"
}

# Return my latest review state (APPROVED/CHANGES_REQUESTED/COMMENTED/DISMISSED), its timestamp, and whether I have ever approved this PR
get_my_review_status() {
  local repo="$1" number="$2" updatedAt="$3"
  local cache_dir="${SWIFTBAR_PLUGIN_CACHE_PATH:-/tmp}/xtv-my-review-v1"
  mkdir -p "$cache_dir"
  local key="${repo//\//_}-${number}.txt"
  local file="$cache_dir/$key"

  if [[ -s "$file" ]]; then
    local cached_updated state ts had
    IFS=$'\t' read -r cached_updated state ts had <"$file" || true
    if [[ "$cached_updated" == "$updatedAt" ]]; then
      printf "%s\t%s\t%s\n" "${state:-}" "${ts:-}" "${had:-false}"
      return 0
    fi
  fi

  local viewer="${MY_LOGIN:-}"
  if [ -z "$viewer" ]; then
    viewer=$(gh api graphql -f query='query{viewer{login}}' --jq '.data.viewer.login' 2>/dev/null || gh api user --jq '.login' 2>/dev/null || echo "")
  fi

  local out
  out=$(gh api "repos/$repo/pulls/$number/reviews?per_page=100" 2>/dev/null | jq -r --arg me "$viewer" '
    def low(s): s|ascii_downcase;
    . as $arr |
    (reduce (reverse)[] as $r (null; if .==null and low(($r.user.login // "")) == low($me) then $r else . end)) as $latest |
    ($latest.state // "") as $state |
    (($latest.submitted_at // $latest.submittedAt // "")) as $ts |
    ([ $arr[] | select(low((.user.login // "")) == low($me) and .state == "APPROVED") ] | length > 0) as $had |
    "\($state)\t\($ts)\t\($had)"
  ' 2>/dev/null || printf "\t\tfalse\n")

  local state ts had
  IFS=$'\t' read -r state ts had <<<"$out"

  printf "%s\t%s\n" "$updatedAt" "$out" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
  printf "%s\t%s\t%s\n" "${state:-}" "${ts:-}" "${had:-false}"
}

# Render RESP and update pagination variables
render_and_update_pagination() {
  # Only emoji symbols can be colored; the rest of the line remains normal

  local STREAM
  # Get current user login (GraphQL viewer first; fallback to REST)
  local my_login
  my_login=$(gh api graphql -f query='query{viewer{login}}' --jq '.data.viewer.login' 2>/dev/null || gh api user --jq '.login' 2>/dev/null || echo "")

  # If RESP is not valid JSON, fall back to an empty search result to avoid jq parse errors
  if ! echo "$RESP" | jq -e . >/dev/null 2>&1; then
    RESP='{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
  fi

  STREAM=$(
    echo "$RESP" | jq -r \
      --arg draft "${DRAFT_MARK:-}" \
      --arg queue "${QUEUE_MARK:-}" \
      --arg sort "$SORT_PREF" \
      --arg dir "$SORT_DIR" \
      --arg hdr "$REPO_HEADER_COLOR" \
      --arg hdrFont "$REPO_HEADER_FONT" \
      --arg hdrSize "$REPO_HEADER_SIZE" \
      --arg hdrLink "$HEADER_LINK_Q" \
      --arg hdrLinkKind "${HEADER_LINK_KIND:-pulls}" \
      --arg myLogin "$my_login" \
      --arg filterIndividual "${FILTER_INDIVIDUAL_REVIEWS:-false}" '
    [ ((.data.search.edges // [])[] | .node)
      | {repo: .repository.nameWithOwner, number, title, url, isDraft, isInMergeQueue, updatedAt,
          author: (.author.login // "unknown"),
          avatar: (.author.avatarUrl // ""),
          comments: ((.comments.totalCount // 0) + (((.reviewThreads.nodes // []) | map(.comments.totalCount // 0) | add) // 0)),
          reviewDecision: (.reviewDecision // ""),
          viewerReacted: (((.reactionGroups // []) | map(.viewerHasReacted) | any) // false),
          reviewRequests: (.reviewRequests.nodes // [])
        }
      # Filter: if FILTER_INDIVIDUAL_REVIEWS is true, only keep PRs with individual review requests
      | if $filterIndividual == "true" then
          select(
            (.reviewRequests | length) == 0 or
            (.reviewRequests | map(select(.requestedReviewer.login == $myLogin)) | length) > 0
          )
        else
          .
        end
      | .title |= (
          (. // "") | gsub("\r";"") | gsub("\n";" ")
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
      (
        .value[0].repo + ": " + ((.value | length) | tostring) + " | href=" +
        (if $hdrLinkKind == "search"
         then ("https://github.com/search?q=" + (($hdrLink + " repo:" + .value[0].repo) | @uri) + "&type=pullrequests")
         else ("https://github.com/" + .value[0].repo + "/pulls?q=" + ($hdrLink|@uri))
         end)
        + " color=" + $hdr + " font=" + $hdrFont + " size=" + $hdrSize
      ),
      ( ((if $sort == "activity"
           then (.value | sort_by(.updatedAt | fromdateiso8601))
           else (.value | sort_by(.number))
         end)
         | (if $dir == "desc" then reverse else . end)
        )[]
        | "__PR__\t\(.author)\t\(.avatar)\t\(.url)\t\(.repo)\t\(.number)\t\(.updatedAt)\t\(.comments)\t\(.prefix)\(.title)\t\(.isInMergeQueue)\t\(.reviewDecision)\t\(.viewerReacted)" )
  '
  )

  # First pass: collect all non-duplicate PRs and count them by repo
  TMP_FILTERED=$(mktemp)
  TMP_COUNTS=$(mktemp)

  while IFS= read -r line; do
    if [[ "$line" == $'__PR__\t'* ]]; then
      IFS=$'\t' read -r _ login avatar url repo number updated comments title in_queue review_decision viewer_reacted <<<"$line"

      # Mentioned section: collect for notifications when enabled (capture before dedup)
      if [ "${MENTION_CAPTURE:-0}" = "1" ]; then
        if [ -n "${MENTIONED_CURR_FILE:-}" ]; then
          printf "%s\t%s\n" "$repo" "$number" >>"$MENTIONED_CURR_FILE"
        fi
      fi

      # Skip if this PR has already been displayed in a previous section
      if [ -n "${SEEN_PRS_FILE:-}" ] && [ -f "$SEEN_PRS_FILE" ] && grep -q -F -x "$url" "$SEEN_PRS_FILE" 2>/dev/null; then
        continue
      fi

      # Mark this PR as seen
      if [ -n "${SEEN_PRS_FILE:-}" ]; then
        echo "$url" >>"$SEEN_PRS_FILE"
      fi

      # Track count for this repo (using a file instead of associative array for Bash 3.2 compatibility)
      echo "$repo" >>"$TMP_COUNTS"

      # Save the line for second pass
      echo "$line" >>"$TMP_FILTERED"
    else
      # Save non-PR lines (headers, separators)
      echo "$line" >>"$TMP_FILTERED"
    fi
  done <<<"$STREAM"

  # Second pass: render with corrected counts
  TMP_OUT=$(mktemp)
  idx=0
  MAX_PAR="${XTV_CONC:-6}"
  SEEN_HEADER=0
  ALL_TOTAL=0

  while IFS= read -r line; do
    if [[ "$line" == $'__PR__\t'* ]]; then
      IFS=$'\t' read -r _ login avatar url repo number updated comments title in_queue review_decision viewer_reacted <<<"$line"

      local_idx=$idx
      idx=$((idx + 1))
      (
        # Get all PR data in one call (conversation, approvals, latest comment)
        pr_data=$(get_pr_data_combined "$repo" "$number" "$updated" 2>/dev/null)
        IFS=$'\t' read -r conv appr comment_id comment_author comment_body <<<"$pr_data"
        if ! [[ "$conv" =~ ^[0-9]+$ ]]; then conv="$comments"; fi
        if ! [[ "$appr" =~ ^[0-9]+$ ]]; then appr=0; fi

        label="$title"
        b64=$(get_avatar_b64 "$login" "$avatar" 20)
        suffix=""
        if ((conv > 0)); then suffix+="  ${COMMENT_MARK:-}${conv}"; fi
        if ((appr > 0)); then suffix+="  ${APPROVAL_MARK:-}${appr}"; fi
        # key for lookups
        needle="$repo"$'\t'"$number"
        # not participated yet (no involves:@me and no reaction on PR body)
        participated=0
        if [ -s "$INVOLVES_FILE" ] && grep -x -F -- "$needle" "$INVOLVES_FILE" >/dev/null 2>&1; then
          participated=1
        fi
        if [ "$participated" -eq 0 ] && [ "${viewer_reacted:-false}" != "true" ]; then
          label="${NOT_PARTICIPATED_MARK:-} $label"
        fi

        # When requested, check my latest review state for decoration/notification
        if [ "${CHECK_MY_APPROVAL:-0}" = "1" ] || [ "${CHECK_MY_REVIEW_DISMISSED:-0}" = "1" ]; then
          status=$(MY_LOGIN="$my_login" get_my_review_status "$repo" "$number" "$updated" 2>/dev/null)
          IFS=$'\t' read -r my_state my_ts my_had_appr <<<"$status"
          if [ "${CHECK_MY_APPROVAL:-0}" = "1" ] && [ "$my_state" = "APPROVED" ]; then
            label="${APPROVED_BY_ME_MARK:-🟢} $label"
          fi
          if [ "${CHECK_MY_REVIEW_DISMISSED:-0}" = "1" ] && [ "$my_state" = "DISMISSED" ]; then
            label="${APPROVAL_DISMISSED_MARK:-⚪} $label"
            if [ -n "${DISMISSED_HITS_FILE:-}" ] && [ -n "$my_ts" ]; then
              printf "%s\t%s\t%s\n" "$repo" "$number" "$my_ts" >>"$DISMISSED_HITS_FILE" 2>/dev/null || true
            fi
          fi
        fi

        if [ "${review_decision:-}" = "CHANGES_REQUESTED" ]; then suffix+="  ${CHANGES_REQUESTED_MARK:-}"; fi
        # unread notifications red dot
        if [ -s "$UNREAD_FILE" ] && grep -x -F -- "$needle" "$UNREAD_FILE" >/dev/null 2>&1; then
          suffix+="  ${UNREAD_MARK:-}"
        fi
        # marker for PRs that were re-requested in the previous run
        marked_rereq=0
        if [ -s "$REREQ_HITS_FILE" ] && grep -x -F -- "$needle" "$REREQ_HITS_FILE" >/dev/null 2>&1; then
          suffix+="  ${REREQUESTED_MARK:-}"
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
          # Sanitize title: replace tabs and newlines with spaces for safe TSV storage
          # Use original title (not decorated label) for notifications
          clean_title=$(echo "$title" | tr '\t\n\r' '   ')
          # Sanitize comment data for TSV storage
          clean_comment_id=$(echo "$comment_id" | tr '\t\n\r' '   ')
          clean_comment_author=$(echo "$comment_author" | tr '\t\n\r' '   ')
          clean_comment_body=$(echo "$comment_body" | tr '\t\n\r' '   ')
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$repo" "$number" "$clean_title" "$url" "$conv" "$in_queue" "$assigned_flag" "$clean_comment_id" "$clean_comment_author" "$clean_comment_body" >>"$CURRENT_OPEN_FILE"
        fi

        if [[ -n "$b64" ]]; then
          if [ "${marked_rereq:-0}" -eq 1 ]; then
            _click_cmd="grep -v -F -- \"$needle\" \"$REREQ_HITS_FILE\" >\"$REREQ_HITS_FILE.tmp\" || true; mv \"$REREQ_HITS_FILE.tmp\" \"$REREQ_HITS_FILE\" || true; open \"$url\""
            printf "%s\t-- %s%s | bash=/bin/bash param1=-lc param2='%s' terminal=false refresh=true image=%s\n" \
              "$local_idx" "$label" "$suffix" "$(printf "%s" "$_click_cmd" | sed "s/'/'\\''/g")" "$b64"
          else
            printf "%s\t-- %s%s | href=%s image=%s\n" "$local_idx" "$label" "$suffix" "$url" "$b64"
          fi
        else
          if [ "${marked_rereq:-0}" -eq 1 ]; then
            _click_cmd="grep -v -F -- \"$needle\" \"$REREQ_HITS_FILE\" >\"$REREQ_HITS_FILE.tmp\" || true; mv \"$REREQ_HITS_FILE.tmp\" \"$REREQ_HITS_FILE\" || true; open \"$url\""
            printf "%s\t-- %s%s | bash=/bin/bash param1=-lc param2='%s' terminal=false refresh=true sfimage=person.crop.circle\n" \
              "$local_idx" "$label" "$suffix" "$(printf "%s" "$_click_cmd" | sed "s/'/'\\''/g")"
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
      fi
      # Update the count in the header line
      # Extract repo name and original (pre-dedupe) count from header: "REPO: COUNT | href=..."
      if [[ "$line" =~ ^([^:]+):[[:space:]]*([0-9]+)[[:space:]]*\|(.*)$ ]]; then
        repo_name="${BASH_REMATCH[1]}"
        orig_count="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        # Count occurrences of this repo in TMP_COUNTS file (deduped count)
        corrected_count=$(grep -c -F -x "$repo_name" "$TMP_COUNTS" 2>/dev/null || echo "0")
        # Ensure corrected_count is a valid integer
        if ! [[ "$corrected_count" =~ ^[0-9]+$ ]]; then
          corrected_count=0
        fi
        # Only output the header (and a preceding separator) if there are PRs to show
        if [ "$corrected_count" -gt 0 ]; then
          if ((SEEN_HEADER == 1)); then echo "--"; fi
          SEEN_HEADER=1
          if [[ "$orig_count" =~ ^[0-9]+$ ]] && [ "$corrected_count" -ne "$orig_count" ]; then
            echo "-- $repo_name: $corrected_count out of $orig_count |$rest"
            ALL_TOTAL=$((ALL_TOTAL + orig_count))
          else
            echo "-- $repo_name: $corrected_count |$rest"
            ALL_TOTAL=$((ALL_TOTAL + corrected_count))
          fi
        fi
      else
        :
      fi
    fi
  done <"$TMP_FILTERED"
  # Final flush
  for pid in $(jobs -pr); do wait "$pid" 2>/dev/null || true; done
  if [[ -s "$TMP_OUT" ]]; then
    sort -n -t $'\t' -k1,1 "$TMP_OUT" | cut -f2-
  fi
  rm -f "$TMP_OUT" "$TMP_FILTERED" "$TMP_COUNTS" 2>/dev/null || true
  # Export pagination variables so they're available to fetch_and_render_prs
  HAS_NEXT=$(echo "$RESP" | jq -r '.data.search.pageInfo.hasNextPage')
  export HAS_NEXT
  CURSOR=$(echo "$RESP" | jq -r '.data.search.pageInfo.endCursor')
  export CURSOR
}
