#!/usr/bin/env bash
# shellcheck disable=SC2016

# =============================================================================
# NOTIFICATION FUNCTIONS
# =============================================================================
# Functions for sending macOS notifications about PR events
# Simple notification ledger helpers (eventKey -> last_ts)
# Format per line: key<TAB>timestamp, where key is like "new:owner/repo#123"

# Logging shims (no-op if main script hasn't defined log_* yet)
if ! declare -F log_info >/dev/null 2>&1; then log_info() { :; }; fi
if ! declare -F log_warn >/dev/null 2>&1; then log_warn() { :; }; fi
if ! declare -F log_debug >/dev/null 2>&1; then log_debug() { :; }; fi

# Return success only if the timestamp looks like ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ)
_is_iso_utc() {
  case "$1" in
  ????-??-??T??:??:??Z) return 0 ;;
  *) return 1 ;;
  esac
}

ledger_get_ts() {
  local key="$1"
  local file="${NOTIFY_LEDGER_FILE:-}"
  [ -n "$file" ] && [ -f "$file" ] || {
    echo ""
    return 1
  }
  # Only consider well-formed rows; ignore garbage
  awk -F'\t' -v k="$key" '($1==k) && ($2 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/) {print $2; found=1} END{if(!found) exit 1}' "$file" 2>/dev/null || echo ""
}

ledger_set_ts() {
  local key="$1"
  local ts="$2"
  local file="${NOTIFY_LEDGER_FILE:-}"
  # Basic validation: non-empty, key contains repo#num, ts is ISO
  [[ -n "$file" && -n "$key" && "$key" == *:*#* ]] || return 1
  if ! _is_iso_utc "$ts"; then
    log_warn "ledger_set_ts: skip invalid ts '$ts' for key '$key'"
    return 0
  fi
  # Avoid obviously bad keys like null#null
  case "$key" in *null#null* | *#null* | null*)
    log_warn "ledger_set_ts: skip invalid key '$key'"
    return 0
    ;;
  esac

  local tmp="${file}.tmp.$$"
  if [ -f "$file" ]; then
    awk -F'\t' -v k="$key" -v v="$ts" 'BEGIN{u=0} $1==k {print k"\t"v; u=1; next} {if($0!="") print} END{if(u==0) print k"\t"v}' "$file" 2>/dev/null >"$tmp" || echo -e "$key\t$ts" >"$tmp"
  else
    echo -e "$key\t$ts" >"$tmp"
  fi
  mv "$tmp" "$file" 2>/dev/null || cp "$tmp" "$file"
}

# Garbage-collect ledger entries.
# Keep ONLY entries for PRs that are currently open (no time-based retention).
ledger_gc() {
  local current_file="$1"
  local file="${NOTIFY_LEDGER_FILE:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0

  # Build set of current PR keys (repo#num)
  local curkeys
  curkeys=$(mktemp 2>/dev/null || echo "/tmp/xtv-ledger-curkeys.$$")
  if [ -n "$current_file" ] && [ -s "$current_file" ]; then
    awk -F'\t' '{print $1"#"$2}' "$current_file" | sort -u >"$curkeys"
  else
    : >"$curkeys"
  fi

  # Keep only rows with a valid key and ISO timestamp where PR is open now
  local tmp="${file}.gc.$$"
  before=$(wc -l <"$file" 2>/dev/null || echo 0)
  awk -F'\t' -v cur="$curkeys" '
    BEGIN{ while ((getline k < cur) > 0) { seen[k]=1 } close(cur) }
    {
      key=$1; ts=$2;
      if (key=="" || ts=="") next
      if (ts !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/) next
      pr=key; sub(/^[^:]*:/, "", pr)
      if (seen[pr]) print key"\t"ts
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file" 2>/dev/null || cp "$tmp" "$file"
  open_count=$(wc -l <"$curkeys" 2>/dev/null || echo 0)
  after=$(wc -l <"$file" 2>/dev/null || echo 0)
  log_info "ledger_gc: open_now=${open_count} kept=${after}/${before} file=$file"
  rm -f "$curkeys"
}

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
      # Determine event timestamp from PR creation time
      created_at=$(gh api "repos/$repo/pulls/$num" --jq '.created_at // empty' 2>/dev/null || echo "")
      event_ts="${created_at:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
      if ! _is_iso_utc "$event_ts"; then
        event_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      fi

      ledger_key="new:${repo}#${num}"
      last_sent=$(ledger_get_ts "$ledger_key")
      if [ -n "$last_sent" ] && { [ "$last_sent" = "$event_ts" ] || [ "$last_sent" \> "$event_ts" ]; }; then
        continue
      fi
      # Lookup full row in CURRENT_OPEN_FILE
      row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
      [ -z "$row" ] && continue
      title=$(echo "$row" | cut -f3 | tr '\n\r\t' '   ' | sed 's/"/\\"/g')
      url=$(echo "$row" | cut -f4)
      author=$(echo "$row" | awk -F'\t' '{print $NF}')
      [ -z "$author" ] && author="unknown"
      gid="xtv-pr-new-${repo//\//-}-${num}"
      notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "New PR by $author" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
      ledger_set_ts "$ledger_key" "$event_ts"
    done
}

# Notify about newly requested PRs
notify_newly_requested() {
  local current_file="$1"
  local prev_file="$2"
  local notified_file="$3"
  local state_dir="$4"

  [ "${NOTIFY_NEWLY_REQUESTED:-1}" != "1" ] && return 0

  # Team review requests (column 7)
  awk -F'\t' '{a=$7; if (a=="") a="0"; printf "%s#%s\t%s\n",$1,$2,a}' "$prev_file" | sort >"${state_dir}/prev_requested.tsv"
  awk -F'\t' '{a=$7; if (a=="") a="0"; printf "%s#%s\t%s\n",$1,$2,a}' "$current_file" | sort >"${state_dir}/curr_requested.tsv"
  { join -t $'\t' -1 1 -2 1 "${state_dir}/prev_requested.tsv" "${state_dir}/curr_requested.tsv" || true; } |
    while IFS=$'\t' read -r key prev_a curr_a; do
      if [ "$prev_a" != "1" ] && [ "$curr_a" = "1" ]; then
        repo="${key%%#*}"
        num="${key##*#}"
        notif_key="requested-team:${repo}#${num}"
        # Skip if already notified
        if grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
          continue
        fi
        row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
        [ -z "$row" ] && continue
        title=$(echo "$row" | cut -f3)
        url=$(echo "$row" | cut -f4)
        gid="xtv-pr-${repo//\//-}-${num}"
        notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Review requested to your team" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
        echo "$notif_key" >>"$notified_file"
      fi
    done

  # Direct review requests to me (column 11)
  awk -F'\t' '{m=$11; if (m=="") m="0"; printf "%s#%s\t%s\n",$1,$2,m}' "$prev_file" | sort >"${state_dir}/prev_requested_me.tsv"
  awk -F'\t' '{m=$11; if (m=="") m="0"; printf "%s#%s\t%s\n",$1,$2,m}' "$current_file" | sort >"${state_dir}/curr_requested_me.tsv"
  { join -t $'\t' -1 1 -2 1 "${state_dir}/prev_requested_me.tsv" "${state_dir}/curr_requested_me.tsv" || true; } |
    while IFS=$'\t' read -r key prev_m curr_m; do
      if [ "$prev_m" != "1" ] && [ "$curr_m" = "1" ]; then
        repo="${key%%#*}"
        num="${key##*#}"
        notif_key="requested-me:${repo}#${num}"
        # Skip if already notified
        if grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
          continue
        fi
        row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
        [ -z "$row" ] && continue
        title=$(echo "$row" | cut -f3)
        url=$(echo "$row" | cut -f4)
        gid="xtv-pr-${repo//\//-}-${num}"
        notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Review requested" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
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

  while IFS=$'\t' read -r repo num title url conv in_queue _requested_in_team; do
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
      }' 2>/dev/null | jq -r '.data.repository.pullRequest.timelineItems.nodes[-1].createdAt // empty' 2>/dev/null || echo "")
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
          ledger_key="rereq:${repo}#${num}"
          last_sent=$(ledger_get_ts "$ledger_key")
          if [ -n "$last_sent" ] && { [ "$last_sent" = "$curr_ts" ] || [ "$last_sent" \> "$curr_ts" ]; }; then
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
          ledger_set_ts "$ledger_key" "$curr_ts"
        fi
      done
  fi

  # Persist re-request hits for next run's menu
  mv "$REREQ_HITS_TMP" "$rereq_hits_file" 2>/dev/null || cp "$REREQ_HITS_TMP" "$rereq_hits_file" 2>/dev/null || true
  mv "$CURR_REREQ_FILE" "$state_rereq_file" 2>/dev/null || cp "$CURR_REREQ_FILE" "$state_rereq_file" 2>/dev/null || true
}

# Notify when my approval was dismissed (deduped by timestamp)
notify_approval_dismissed() {
  local current_file="$1"  # CURRENT_OPEN_FILE (for title/url lookup)
  local notified_file="$2" # NOTIFIED_FILE
  local hits_file="$3"     # DISMISSED_HITS_FILE (repo\tnum\tts per line)

  [ "${NOTIFY_APPROVAL_DISMISSED:-1}" != "1" ] && return 0
  [ -n "$hits_file" ] || return 0
  [ -s "$hits_file" ] || return 0

  while IFS=$'\t' read -r repo num ts; do
    [ -n "$repo" ] && [ -n "$num" ] && [ -n "$ts" ] || continue

    local ledger_key="approval-dismissed:${repo}#${num}"
    local last_sent
    last_sent=$(ledger_get_ts "$ledger_key")
    if [ -n "$last_sent" ] && { [ "$last_sent" = "$ts" ] || [ "$last_sent" \> "$ts" ]; }; then
      continue
    fi
    # Lookup title/url from current index; fallback to constructing URL
    local row title url
    row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
    if [ -n "$row" ]; then
      title=$(echo "$row" | cut -f3)
      url=$(echo "$row" | cut -f4)
    else
      title="PR #$num"
      url="https://github.com/$repo/pull/$num"
    fi
    local gid="xtv-pr-${repo//\//-}-${num}-approval-dismissed"
    notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "Your approval was dismissed" -subtitle "$repo #$num" -message "${title//\"/\\\"}" -open "$url" -sound default
    ledger_set_ts "$ledger_key" "$ts"
  done <"$hits_file"

  # Clear hits once processed (NOTIFIED_FILE prevents duplicates across runs)
  : >"$hits_file"
}

# Notify about new comments
notify_new_comments() {
  local current_file="$1"
  local notified_file="$2"

  [ "${NOTIFY_NEW_COMMENT:-1}" != "1" ] && return 0

  while IFS=$'\t' read -r repo num title url conv in_queue _requested_in_team comment_id author body _requested_me_flag _pr_author; do
    pr_key="${repo}#${num}"

    # Skip if no comment data
    [ -z "$comment_id" ] && continue

    # Get the last notified comment ID for this PR
    last_comment_id=$(awk -F: -v k="comment:${pr_key}:" '$0 ~ "^"k { id=$3 } END{ if(id!="") print id }' "$notified_file" 2>/dev/null || true)

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

# Notify about PRs entering or leaving the merge queue (filtered by knobs)
notify_queue() {
  local current_file="$1"
  local prev_file="$2"
  local notified_file="$3"
  local state_dir="$4"

  [ "${NOTIFY_QUEUE:-1}" != "1" ] && return 0

  # Resolve my login for raised-by-me filtering (cached via MY_LOGIN if provided)
  local my_login="${MY_LOGIN:-}"
  if [ -z "$my_login" ]; then
    my_login=$(gh api graphql -f query='query{viewer{login}}' --jq '.data.viewer.login' 2>/dev/null || gh api user --jq '.login' 2>/dev/null || echo "")
  fi

  awk -F'\t' '{print $1"#"$2"\t"$6}' "$prev_file" | sort >"$state_dir/prev_q.tsv"
  awk -F'\t' '{print $1"#"$2"\t"$6}' "$current_file" | sort >"$state_dir/curr_q.tsv"
  { join -t $'\t' -1 1 -2 1 "$state_dir/prev_q.tsv" "$state_dir/curr_q.tsv" || true; } |
    while IFS=$'\t' read -r key prev_q curr_q; do
      repo="${key%%#*}"
      num="${key##*#}"

      # Lookup full row for author/url/title
      row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
      [ -z "$row" ] && continue
      title=$(echo "$row" | cut -f3)
      url=$(echo "$row" | cut -f4)
      author_login=$(echo "$row" | awk -F'\t' '{print $NF}')

      # Filters
      raised_by_me=0
      if [ -n "$my_login" ] && [ "$author_login" = "$my_login" ]; then raised_by_me=1; fi

      participated=0
      if [ -n "${PARTICIPATED_FILE:-}" ] && [ -s "${PARTICIPATED_FILE}" ]; then
        if grep -q -F -x "$repo\t$num" "${PARTICIPATED_FILE}" 2>/dev/null; then
          participated=1
        fi
      fi

      allowed=0
      if [ "${NOTIFY_QUEUE_RAISED_BY_ME:-0}" = "1" ] && [ "$raised_by_me" -eq 1 ]; then allowed=1; fi
      if [ "${NOTIFY_QUEUE_PARTICIPATED:-0}" = "1" ] && [ "$participated" -eq 1 ]; then allowed=1; fi
      [ "$allowed" -eq 1 ] || continue

      gid="xtv-pr-${repo//\//-}-${num}-queue"

      # Entered queue
      if [ "$prev_q" != "true" ] && [ "$curr_q" = "true" ]; then
        notif_key="queue-enter:${repo}#${num}"
        if ! grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
          msg="author $author_login"$'\n'"$title"
          notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "${QUEUE_MARK:-} Pushed to merge queue" -subtitle "$repo #$num" -message "$msg" -open "$url" -sound default
          echo "$notif_key" >>"$notified_file"
        fi
      fi

      # Left queue
      if [ "$prev_q" = "true" ] && [ "$curr_q" != "true" ]; then
        notif_key="queue-leave:${repo}#${num}"
        if ! grep -q -F -x "$notif_key" "$notified_file" 2>/dev/null; then
          msg="author $author_login"$'\n'"$title"
          notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "${QUEUE_LEFT_MARK:-} Removed from merge queue" -subtitle "$repo #$num" -message "$msg" -open "$url" -sound default
          echo "$notif_key" >>"$notified_file"
        fi
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
      # Check merged timestamp and use ledger for dedupe
      merged_at=$(gh api "repos/$repo/pulls/$num" --jq '.merged_at // empty' 2>/dev/null || echo "")
      if [ -z "$merged_at" ] || ! _is_iso_utc "$merged_at"; then
        continue
      fi

      ledger_key="merged:${repo}#${num}"
      last_sent=$(ledger_get_ts "$ledger_key")
      if [ -n "$last_sent" ] && { [ "$last_sent" = "$merged_at" ] || [ "$last_sent" \> "$merged_at" ]; }; then
        continue
      fi
      # Fetch and sanitize title; escape quotes for notify
      title_raw=$(gh api "repos/$repo/pulls/$num" --jq '.title' 2>/dev/null || true)
      [ -z "$title_raw" ] && title_raw="PR #$num"
      title=$(echo "$title_raw" | tr '\n\r\t' '   ' | sed 's/"/\\"/g')
      url="https://github.com/$repo/pull/$num"
      gid="xtv-pr-merged-${repo//\//-}-${num}"
      notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "PR Merged" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
      ledger_set_ts "$ledger_key" "$merged_at"
    done
}

# Notify when newly mentioned (PR enters the Mentioned list)
notify_mentions() {
  local current_file="$1"       # CURRENT_OPEN_FILE (tsv with repo, num, title, url, ...)
  local prev_mentions_file="$2" # state file to persist prev mentioned keys
  local curr_mentions_file="$3" # file with current mentioned keys (repo#num per line)
  local notified_file="$4"      # NOTIFIED_FILE (unused for mentions; kept for symmetry)

  [ "${NOTIFY_MENTIONED:-1}" != "1" ] && return 0

  # If previous file is missing, skip (first run)
  if [ ! -f "$prev_mentions_file" ]; then
    return 0
  fi

  # Compute newly mentioned: in current but not in previous (handles empty current as well)
  { join -t $'\t' -v1 -1 1 -2 1 <(sed 's/\t/#/' "$curr_mentions_file" 2>/dev/null | sort -u) <(sed 's/\t/#/' "$prev_mentions_file" 2>/dev/null | sort -u) || true; } |
    while IFS= read -r key; do
      local repo="${key%%#*}"
      local num="${key##*#}"

      # Lookup full row in CURRENT_OPEN_FILE for title/url
      local row
      row=$(awk -F'\t' -v r="$repo" -v n="$num" '$1==r && $2==n {print; exit}' "$current_file")
      [ -z "$row" ] && continue
      local title url
      title=$(echo "$row" | cut -f3)
      url=$(echo "$row" | cut -f4)

      local gid="xtv-pr-${repo//\//-}-${num}-mentioned"
      notify -ignoreDnD YES -group "$gid" -sender com.ameba.SwiftBar -title "You were mentioned" -subtitle "$repo #$num" -message "$title" -open "$url" -sound default
    done

  # Persist current as previous for next run (even if empty)
  if [ -n "${curr_mentions_file:-}" ] && [ -f "$curr_mentions_file" ]; then
    cp "$curr_mentions_file" "$prev_mentions_file" 2>/dev/null || : >"$prev_mentions_file"
  else
    : >"$prev_mentions_file"
  fi
}
