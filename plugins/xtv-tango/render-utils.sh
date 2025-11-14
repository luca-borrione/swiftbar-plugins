#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034

# ============================================================================
# RENDER UTILS
# Render RESP and update pagination variables (two-pass renderer)
# ============================================================================

# Render RESP and update pagination variables
render_and_update_pagination() {
  # Only emoji symbols can be colored; the rest of the line remains normal

  local STREAM

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
      --arg section "${CURRENT_SECTION:-}" '
    [ ((.data.search.edges // [])[] | .node)
      | {repo: .repository.nameWithOwner, number, title, url, isDraft, isInMergeQueue, updatedAt,
          author: (.author.login // "unknown"),
          avatar: (.author.avatarUrl // ""),
          comments: (.comments.totalCount // 0),
          reviewDecision: (.reviewDecision // ""),
          labels: ((.labels.nodes // []) | map(.name)),
          viewerReacted: false
        }
      | .title |= (
          (. // "") | gsub("\r";"") | gsub("\n";" ")
          | gsub("\\|";"¦")
        )
      | .prefix = (
          if .isDraft then "\($draft) DRAFT "
          else if (.isInMergeQueue and ($section != "recently_merged")) then "\($queue) QUEUED "
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
        | "__PR__\t\(.author)\t\(.avatar)\t\(.url)\t\(.repo)\t\(.number)\t\(.updatedAt)\t\(.comments)\t\(.prefix)\(.title)\t\(.isInMergeQueue)\t\(.reviewDecision)\t\(.viewerReacted)\t\(.labels | join("|"))" )
  '
  )

  # First pass: collect all non-duplicate PRs and count them by repo
  TMP_FILTERED=$(mktemp)
  TMP_COUNTS=$(mktemp)

  while IFS= read -r line; do
    if [[ "$line" == $'__PR__\t'* ]]; then
      IFS=$'\t' read -r _ login avatar url repo number updated comments title in_queue review_decision viewer_reacted labels <<<"$line"

      # Debug: log parsed PR line before dedupe

      # Skip if this PR has already been displayed in a previous section
      if [ -n "${SEEN_PRS_FILE:-}" ] && [ -f "$SEEN_PRS_FILE" ] && grep -q -F -x "$url" "$SEEN_PRS_FILE" 2>/dev/null; then

        continue
      fi

      # Mark this PR as seen (for counting across open sections); allow excluding some sections
      if [ -n "${SEEN_PRS_FILE:-}" ] && [ "${COUNT_SEEN:-1}" = "1" ]; then
        echo "$url" >>"$SEEN_PRS_FILE"

      fi

      # Track count for this repo (using a file instead of associative array for Bash 3.2 compatibility)
      echo "$repo" >>"$TMP_COUNTS"

      # Debug: count per repo

      # Save the line for second pass
      echo "$line" >>"$TMP_FILTERED"
    else
      # Save non-PR lines (headers, separators) unless we're suppressing headers for this pass
      if [ "${RENDER_NO_HEADERS:-0}" = "1" ]; then
        : # skip
      else
        echo "$line" >>"$TMP_FILTERED"
      fi
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
      IFS=$'\t' read -r _ login avatar url repo number updated comments title in_queue review_decision viewer_reacted labels <<<"$line"

      local_idx=$idx
      idx=$((idx + 1))
      (
        # Get all PR data in one call (conversation, approvals, latest comment)
        pr_data=$(get_pr_data_combined "$repo" "$number" "$updated" 2>/dev/null)
        IFS=$'\t' read -r conv appr comment_id comment_author comment_body <<<"$pr_data"
        if ! [[ "$conv" =~ ^[0-9]+$ ]]; then conv="$comments"; fi
        if ! [[ "$appr" =~ ^[0-9]+$ ]]; then appr=0; fi

        b64=$(get_avatar_b64 "$login" "$avatar" 20)
        suffix=""
        if ((conv > 0)); then suffix+="  ${COMMENT_MARK:-}${conv}"; fi
        if ((appr > 0)); then suffix+="  ${APPROVAL_MARK:-}${appr}"; fi

        # Front-of-title marks (DO_NOT_REVIEW label, CHANGES_REQUESTED, QUEUE_LEFT, APPROVED_BY_ME)
        prefix_marks=""
        # Hard stop / DO NOT REVIEW label at the very beginning
        if [[ -n "$labels" ]] && [[ "$labels" == *"DO NOT REVIEW"* ]]; then
          prefix_marks+="${DO_NOT_REVIEW_MARK:-} "
        fi
        if [ "${review_decision:-}" = "CHANGES_REQUESTED" ]; then
          prefix_marks+="${CHANGES_REQUESTED_MARK:-} "
        fi

        # key for lookups
        needle="$repo"$'\t'"$number"

        # Section label (controls where certain marks are applied)
        section="${CURRENT_SECTION:-}"

        # Track current merge-queue membership so we can detect when a PR leaves the queue
        if [ "${in_queue:-false}" = "true" ] && [ -n "${QUEUE_STATE_NEXT:-}" ]; then
          printf "%s\t%s\n" "$repo" "$number" >>"$QUEUE_STATE_NEXT" 2>/dev/null || true
        fi

        # Simple, current-run-only review marks (no notification or history state)
        if [ "$section" = "requested_to_me" ] || [ "$section" = "participated" ] || [ "$section" = "all" ]; then
          # Derive my latest review state and whether I have ever approved this PR
          rev_out=$(get_my_review_status "$repo" "$number" "$updated" 2>/dev/null || printf "\t\tfalse\n")
          IFS=$'\t' read -r my_state my_ts had_approved <<<"$rev_out"

          # Approved by me: my latest review is APPROVED
          if [ "${my_state:-}" = "APPROVED" ]; then
            prefix_marks+="${APPROVED_BY_ME_MARK:-} "
          else
            # I had approved before but my latest review is not APPROVED anymore
            if [ "${had_approved:-false}" = "true" ]; then
              if [ "${my_state:-}" = "DISMISSED" ]; then
                suffix+="  ${APPROVAL_DISMISSED_MARK:-}"
              else
                # Re-requested: I previously approved and now have a different latest state
                suffix+="  ${REREQUESTED_MARK:-}"
              fi
            fi
          fi

          # Queue-left mark: PR was in the merge queue (previous run) and is now out (regardless of approval state)
          if [ "${in_queue:-false}" != "true" ] && [ -n "${QUEUE_STATE_FILE:-}" ] && [ -f "$QUEUE_STATE_FILE" ]; then
            if grep -q -F -x "$needle" "$QUEUE_STATE_FILE" 2>/dev/null; then
              prefix_marks+="${QUEUE_LEFT_MARK:-} "
            fi
          fi

          # Unread-style mark: PR has any conversation activity (requested_to_me only)
          if [ "$section" = "requested_to_me" ] && ((conv > 0)); then
            suffix+="  ${UNREAD_MARK:-}"
          fi
        fi

        label="$title"
        if [ -n "$prefix_marks" ]; then
          label="${prefix_marks}${label}"
        fi

        # record team-requested PR to index if enabled (used to avoid duplicates in Raised by teams)
        if [ "${COLLECT_REQUESTED_TO_TEAM:-0}" = "1" ] && [ -n "$REQUESTED_FILE" ]; then
          printf "%s\t%s\n" "$repo" "$number" >>"$REQUESTED_FILE"
        fi

        if [[ -n "$b64" ]]; then
          printf "%s\t-- %s%s | href=%s image=%s\n" "$local_idx" "$label" "$suffix" "$url" "$b64"
        else
          printf "%s\t-- %s%s | href=%s sfimage=person.crop.circle\n" "$local_idx" "$label" "$suffix" "$url"
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
            if [ "${ACCUMULATE_ALL_TOTAL:-0}" = "1" ]; then
              ALL_TOTAL=$((ALL_TOTAL + orig_count))
            fi
          else
            echo "-- $repo_name: $corrected_count |$rest"
            if [ "${ACCUMULATE_ALL_TOTAL:-0}" = "1" ]; then
              ALL_TOTAL=$((ALL_TOTAL + corrected_count))
            fi
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
