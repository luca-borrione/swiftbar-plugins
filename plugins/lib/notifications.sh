#!/usr/bin/env bash
# shellcheck disable=SC2016

# ============================================================================
# NOTIFICATION FUNCTIONS
# ============================================================================
# Functions for sending macOS notifications about PR events

# Notify about new PRs
notify_new_prs() {
  local current_file="$1"
  local prev_file="$2"
  local notified_file="$3"

  [ "${NOTIFY_NEW_PR:-1}" != "1" ] && return 0

  { join -t $'\t' -v1 -1 1 -2 1 <(cut -f1,2 "$current_file" | awk '{print $1"#"$2}' | sort -u) <(cut -f1,2 "$prev_file" | awk '{print $1"#"$2}' | sort -u) || true; } |
    while IFS= read -r key; do
      repo="${key%%#*}"
      num="${key##*#}"
      notif_key="new:${repo}#${num}"
      # Skip if already notified
      if grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
        continue
      fi
      # Lookup full row in CURRENT_OPEN_FILE
      row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
      [ -z "$row" ] && continue
      title=$(echo "$row" | cut -f3)
      url=$(echo "$row" | cut -f4)
      gid="xtv-pr-${repo//\//-}-${num}"
      notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "New PR" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
      echo "$notif_key" >>"$notified_file"
    done
}

# Notify about newly assigned PRs
notify_newly_assigned() {
  local current_file="$1"
  local prev_file="$2"
  local notified_file="$3"
  local state_dir="$4"

  [ "${NOTIFY_NEWLY_ASSIGNED:-1}" != "1" ] && return 0

  awk -F'\t' '{a=$7; if (a=="") a="0"; printf "%s#%s\t%s\n",$1,$2,a}' "$prev_file" | sort >"${state_dir}/prev_assigned.tsv"
  awk -F'\t' '{a=$7; if (a=="") a="0"; printf "%s#%s\t%s\n",$1,$2,a}' "$current_file" | sort >"${state_dir}/curr_assigned.tsv"
  { join -t $'\t' -1 1 -2 1 "${state_dir}/prev_assigned.tsv" "${state_dir}/curr_assigned.tsv" || true; } |
    while IFS=$'\t' read -r key prev_a curr_a; do
      if [ "$prev_a" != "1" ] && [ "$curr_a" = "1" ]; then
        repo="${key%%#*}"
        num="${key##*#}"
        notif_key="assigned:${repo}#${num}"
        # Skip if already notified
        if grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
          continue
        fi
        row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
        [ -z "$row" ] && continue
        title=$(echo "$row" | cut -f3)
        url=$(echo "$row" | cut -f4)
        gid="xtv-pr-${repo//\//-}-${num}"
        notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Assigned to your team" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
        echo "$notif_key" >>"$notified_file"
      fi
    done
}

# Notify about re-requested reviews
notify_rerequested() {
  local current_file="$1"
  local notified_file="$2"
  local state_dir="$3"
  local state_rereq_file="$4"
  local rereq_hits_file="$5"

  [ "${NOTIFY_REREQUESTED:-1}" != "1" ] && return 0

  CURR_REREQ_FILE="${state_dir}/curr_rereq.tsv"
  : >"$CURR_REREQ_FILE"
  REREQ_HITS_TMP="${state_dir}/rereq_hits.tmp"
  : >"$REREQ_HITS_TMP"

  while IFS=$'\t' read -r repo num title url conv in_queue _assigned_in_team; do
    owner="${repo%%/*}"
    rname="${repo#*/}"
    last_ts=$(gh api graphql -F owner="$owner" -F name="$rname" -F number="$num" -f query='
      query($owner:String!,$name:String!,$number:Int!){
        repository(owner:$owner,name:$name){
          pullRequest(number:$number){
            timelineItems(last:100,itemTypes:[REVIEW_REQUESTED_EVENT]){
              nodes{... on ReviewRequestedEvent{createdAt}}
            }
          }
        }
      }' 2>/dev/null | jq -r '.data.repository.pullRequest.timelineItems.nodes[-1].createdAt // empty' 2>/dev/null)
    if [ -n "$last_ts" ]; then
      printf "%s#%s\t%s\n" "$repo" "$num" "$last_ts" >>"$CURR_REREQ_FILE"
    fi
  done <"$current_file"

  # Compare to previous map and notify only when timestamp increased
  if [ -s "$state_rereq_file" ]; then
    { join -t $'\t' -1 1 -2 1 <(sort "$state_rereq_file") <(sort "$CURR_REREQ_FILE") || true; } |
      while IFS=$'\t' read -r key prev_ts curr_ts; do
        if [ "$curr_ts" \> "$prev_ts" ]; then
          repo="${key%%#*}"
          num="${key##*#}"
          notif_key="rereq:${repo}#${num}:${curr_ts}"
          if grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
            continue
          fi
          row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
          [ -z "$row" ] && continue
          # record marker for next menu render
          printf "%s\t%s\n" "$repo" "$num" >>"$REREQ_HITS_TMP"
          title=$(echo "$row" | cut -f3)
          url=$(echo "$row" | cut -f4)
          gid="xtv-pr-${repo//\//-}-${num}-rereq"
          notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Review re-requested" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
          echo "$notif_key" >>"$notified_file"
        fi
      done
  fi

  # Persist re-request hits for next run's menu
  mv "$REREQ_HITS_TMP" "$rereq_hits_file" 2>/dev/null || cp "$REREQ_HITS_TMP" "$rereq_hits_file" 2>/dev/null || true
  mv "$CURR_REREQ_FILE" "$state_rereq_file" 2>/dev/null || cp "$CURR_REREQ_FILE" "$state_rereq_file" 2>/dev/null || true
}

# Notify about new comments
notify_new_comments() {
  local current_file="$1"
  local notified_file="$2"

  [ "${NOTIFY_NEW_COMMENT:-1}" != "1" ] && return 0

  while IFS=$'\t' read -r repo num title url conv in_queue _assigned_in_team comment_id author body; do
    pr_key="${repo}#${num}"

    # Skip if no comment data
    [ -z "$comment_id" ] && continue

    # Get the last notified comment ID for this PR
    last_comment_id=$(grep -E "^comment:${pr_key}:" "$notified_file" 2>/dev/null | tail -1 | cut -d: -f3)

    # Check if this is a NEW comment (different ID from last notified)
    if [ -n "$last_comment_id" ] && [ "$comment_id" != "$last_comment_id" ]; then
      # NEW comment - send notification
      comment_preview=$(echo "$body" | head -c 200 | tr '\n\r\t' '   ' | sed 's/"/\\"/g')
      [ ${#body} -gt 200 ] && comment_preview="${comment_preview}..."

      gid="xtv-pr-${repo//\//-}-${num}-comment-${comment_id}"
      notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "New comment by $author" -subtitle "$repo #$num" -message "$comment_preview" -open "$url" -sound default
    fi

    # Save the comment ID (whether we notified or not)
    NOTIFIED_TMP="${notified_file}.tmp.$$"
    grep -v -E "^comment:${pr_key}:" "$notified_file" 2>/dev/null >"$NOTIFIED_TMP" || : >"$NOTIFIED_TMP"
    echo "comment:${pr_key}:${comment_id}" >>"$NOTIFIED_TMP"
    mv "$NOTIFIED_TMP" "$notified_file" 2>/dev/null || cp "$NOTIFIED_TMP" "$notified_file"
    rm -f "$NOTIFIED_TMP" 2>/dev/null || true
  done <"$current_file"
}

# Notify about PRs pushed to merge queue
notify_queue() {
  local current_file="$1"
  local prev_file="$2"
  local notified_file="$3"
  local state_dir="$4"

  [ "${NOTIFY_QUEUE:-1}" != "1" ] && return 0

  awk -F'\t' '{print $1"#"$2"\t"$6}' "$prev_file" | sort >"$state_dir/prev_q.tsv"
  awk -F'\t' '{print $1"#"$2"\t"$6}' "$current_file" | sort >"$state_dir/curr_q.tsv"
  { join -t $'\t' -1 1 -2 1 "${state_dir}/prev_q.tsv" "${state_dir}/curr_q.tsv" || true; } |
    while IFS=$'\t' read -r key prev_q curr_q; do
      if [ "$prev_q" != "true" ] && [ "$curr_q" = "true" ]; then
        repo="${key%%#*}"
        num="${key##*#}"
        notif_key="queue:${repo}#${num}"
        if grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
          continue
        fi
        row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
        [ -z "$row" ] && continue
        title=$(echo "$row" | cut -f3)
        url=$(echo "$row" | cut -f4)
        gid="xtv-pr-${repo//\//-}-${num}"
        notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Pushed to merge queue" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
        echo "$notif_key" >>"$notified_file"
      fi
    done
}

# Notify about merged PRs
notify_merged() {
  local current_file="$1"
  local prev_file="$2"
  local notified_file="$3"

  [ "${NOTIFY_MERGED:-1}" != "1" ] && return 0

  { join -t $'\t' -v2 -1 1 -2 1 <(cut -f1,2 "$current_file" | awk '{print $1"#"$2}' | sort -u) <(cut -f1,2 "$prev_file" | awk '{print $1"#"$2}' | sort -u) || true; } |
    while IFS= read -r key; do
      repo="${key%%#*}"
      num="${key##*#}"
      notif_key="merged:${repo}#${num}"
      if grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
        continue
      fi
      # Verify it was merged (not just closed)
      state=$(gh api "repos/$repo/pulls/$num" --jq '.state + ":" + (.merged_at // "null")' 2>/dev/null || echo "unknown:null")
      if [[ "$state" == closed:* ]] && [[ "$state" != *:null ]]; then
        title=$(gh api "repos/$repo/pulls/$num" --jq '.title' 2>/dev/null || echo "PR #$num")
        url="https://github.com/$repo/pull/$num"
        gid="xtv-pr-${repo//\//-}-${num}"
        notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "PR Merged" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
        echo "$notif_key" >>"$notified_file"
      fi
    done
}
