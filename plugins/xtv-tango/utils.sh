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

# Render RESP and update pagination variables
render_and_update_pagination() {
  # Emoji symbols (only these are colored; rest of the line remains normal)
  DRAFT_EMOJI="${DRAFT_MARK:-⚪}"
  MERGE_QUEUE_EMOJI="${QUEUE_MARK:-🟠}"

  local STREAM
  # Get current user login for filtering individual review requests
  local my_login
  my_login=$(gh api user --jq '.login' 2>/dev/null || echo "")

  STREAM=$(echo "$RESP" | jq -r \
    --arg draft "$DRAFT_EMOJI" \
    --arg queue "$MERGE_QUEUE_EMOJI" \
    --arg sort "$SORT_PREF" \
    --arg dir "$SORT_DIR" \
    --arg hdr "$REPO_HEADER_COLOR" \
    --arg hdrFont "$REPO_HEADER_FONT" \
    --arg hdrSize "$REPO_HEADER_SIZE" \
    --arg hdrLink "$HEADER_LINK_Q" \
    --arg myLogin "$my_login" \
    --arg filterIndividual "${FILTER_INDIVIDUAL_REVIEWS:-false}" '
    [ .data.search.edges[].node
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
      (.value[0].repo + ": " + ((.value | length) | tostring) + " | href=https://github.com/\(.value[0].repo)/pulls?q=\($hdrLink) color=\($hdr) font=\($hdrFont) size=\($hdrSize)"),
      ( ((if $sort == "activity"
           then (.value | sort_by(.updatedAt | fromdateiso8601))
           else (.value | sort_by(.number))
         end)
         | (if $dir == "desc" then reverse else . end)
        )[]
        | "__PR__\t\(.author)\t\(.avatar)\t\(.url)\t\(.repo)\t\(.number)\t\(.updatedAt)\t\(.comments)\t\(.prefix)\(.title)\t\(.isInMergeQueue)\t\(.reviewDecision)\t\(.viewerReacted)" )
  ')

  # First pass: collect all non-duplicate PRs and count them by repo
  TMP_FILTERED=$(mktemp)
  TMP_COUNTS=$(mktemp)

  while IFS= read -r line; do
    if [[ "$line" == $'__PR__\t'* ]]; then
      IFS=$'\t' read -r _ login avatar url repo number updated comments title in_queue review_decision viewer_reacted <<<"$line"

      # Skip if this PR has already been displayed in a previous section
      if [ -n "${SEEN_PRS_FILE:-}" ] && [ -f "$SEEN_PRS_FILE" ] && grep -q -F -x "$url" "$SEEN_PRS_FILE" 2>/dev/null; then
        continue
      fi

      # Skip if this PR is in the hidden list
      if [ -n "${HIDDEN_PRS_FILE:-}" ] && [ -f "$HIDDEN_PRS_FILE" ] && grep -q -F -x "$url" "$HIDDEN_PRS_FILE" 2>/dev/null; then
        continue
      fi

      # Mark this PR as seen
      if [ -n "${SEEN_PRS_FILE:-}" ]; then
        echo "$url" >>"$SEEN_PRS_FILE"
      fi

      # Track URL for "Remove All" functionality
      if [ -n "${SECTION_URLS_FILE:-}" ]; then
        echo "$url" >>"$SECTION_URLS_FILE"
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
          # Sanitize title: replace tabs and newlines with spaces for safe TSV storage
          # Use original title (not decorated label) for notifications
          clean_title=$(echo "$title" | tr '\t\n\r' '   ')
          # Sanitize comment data for TSV storage
          clean_comment_id=$(echo "$comment_id" | tr '\t\n\r' '   ')
          clean_comment_author=$(echo "$comment_author" | tr '\t\n\r' '   ')
          clean_comment_body=$(echo "$comment_body" | tr '\t\n\r' '   ')
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$repo" "$number" "$clean_title" "$url" "$conv" "$in_queue" "$assigned_flag" "$clean_comment_id" "$clean_comment_author" "$clean_comment_body" >>"$CURRENT_OPEN_FILE"
        fi

        # Prepare remove command (ensure dir exists; append URL; log for debugging)
        _remove_cmd="mkdir -p \"$SWIFTBAR_PLUGIN_CACHE_PATH\"; printf \"%s\\n\" \"$url\" >> \"$HIDDEN_PRS_FILE\"; echo \"REMOVE: $url -> $HIDDEN_PRS_FILE\" >> /tmp/xtv-debug.log"

        if [[ -n "$b64" ]]; then
          if [ "${marked_rereq:-0}" -eq 1 ]; then
            _click_cmd="grep -v -F -- \"$needle\" \"$REREQ_HITS_FILE\" >\"$REREQ_HITS_FILE.tmp\" || true; mv \"$REREQ_HITS_FILE.tmp\" \"$REREQ_HITS_FILE\" || true; open \"$url\""
            printf "%s\t-- %s%s | bash=/bin/bash param1=-lc param2=%q terminal=false refresh=true image=%s\n" \
              "$local_idx" "$label" "$suffix" "$_click_cmd" "$b64"
          else
            printf "%s\t-- %s%s | href=%s image=%s\n" "$local_idx" "$label" "$suffix" "$url" "$b64"
          fi
          # Add Remove submenu item
          printf "%s\t---- Remove | bash=/bin/bash param1=-lc param2=%q terminal=false refresh=true\n" \
            "$local_idx" "$_remove_cmd"
        else
          if [ "${marked_rereq:-0}" -eq 1 ]; then
            _click_cmd="grep -v -F -- \"$needle\" \"$REREQ_HITS_FILE\" >\"$REREQ_HITS_FILE.tmp\" || true; mv \"$REREQ_HITS_FILE.tmp\" \"$REREQ_HITS_FILE\" || true; open \"$url\""
            printf "%s\t-- %s%s | bash=/bin/bash param1=-lc param2=%q terminal=false refresh=true sfimage=person.crop.circle\n" \
              "$local_idx" "$label" "$suffix" "$_click_cmd"
          else
            printf "%s\t-- %s%s | href=%s sfimage=person.crop.circle\n" "$local_idx" "$label" "$suffix" "$url"
          fi
          # Add Remove submenu item
          printf "%s\t---- Remove | bash=/bin/bash param1=-lc param2=%q terminal=false refresh=true\n" \
            "$local_idx" "$_remove_cmd"
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
      # Update the count in the header line
      # Extract repo name from header (format: "REPO: COUNT | href=...")
      if [[ "$line" =~ ^([^:]+):[[:space:]]*[0-9]+[[:space:]]*\|(.*)$ ]]; then
        repo_name="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        # Count occurrences of this repo in TMP_COUNTS file
        corrected_count=$(grep -c -F -x "$repo_name" "$TMP_COUNTS" 2>/dev/null || echo "0")
        # Ensure corrected_count is a valid integer
        if ! [[ "$corrected_count" =~ ^[0-9]+$ ]]; then
          corrected_count=0
        fi
        # Only output the header if there are PRs to show
        if [ "$corrected_count" -gt 0 ]; then
          echo "-- $repo_name: $corrected_count |$rest"
        fi
      else
        echo "-- $line"
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
