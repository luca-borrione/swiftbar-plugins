#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034

# ============================================================================
# PR FETCHING FUNCTIONS (section-level)
# Formerly plugins/xtv-tango/fetch.sh
# ============================================================================

# Fetch PRs (single page, no pagination) and render to output file
# Args: query, header_link_query, collect_assigned_flag, output_file
fetch_and_render_prs() {
  local query="$1"
  local header_link_q="$2"
  local collect_assigned="$3"
  local output_file="$4"

  # Set global variables for render function
  export HEADER_LINK_Q="$header_link_q"
  export COLLECT_ASSIGNED="$collect_assigned"

  # Single GraphQL search call (no pagination). Max 100 items per GitHub API.
  RESP=$(gh api graphql -F q="$query" -F n="100" -f query='
    query($q:String!,$n:Int!){
      search(query:$q,type:ISSUE,first:$n){
        pageInfo{hasNextPage endCursor}
        edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted} reviewThreads(first:100){nodes{comments{totalCount}}} reviewRequests(first:100){nodes{requestedReviewer{... on User{login} ... on Team{slug}}}}}}}
      }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
  render_and_update_pagination >>"$output_file"
}

# Build repo allowlist qualifier
build_repo_qualifier() {
  local repo_q=""
  for r in "${WATCHED_ARR[@]}"; do
    repo_q+=" repo:${r}"
  done
  echo "$repo_q"
}

# Fetch "Assigned to Me" PRs (assignee:@me)
fetch_assigned_to_me() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)
  local query
  query="is:pr is:open assignee:@me${repo_q}"

  # Record direct assignments for notifications during rendering
  export COLLECT_ASSIGNED_ME="1"
  fetch_and_render_prs "$query" "is:pr is:open assignee:@me" 0 "$output_file"
  export COLLECT_ASSIGNED_ME="0"
}

# Fetch "Raised by Me" PRs
fetch_raised_by_me() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)
  local query
  query="is:pr is:open author:@me${repo_q}"

  fetch_and_render_prs "$query" "is:pr is:open author:@me" 0 "$output_file"
}

# Fetch "Recently Merged" PRs (authored by me, merged in the last N days)
fetch_recently_merged() {
  local output_file="$1"
  local _days="${2:-}"

  local repo_q
  repo_q=$(build_repo_qualifier)

  # Derive merged:>= from explicit days only; empty => no filter (show all)
  local merged_q=""
  local days=""
  if [[ -n "$_days" && "$_days" =~ ^[0-9]+$ ]]; then
    days="$_days"
  fi

  if [[ -n "$days" ]]; then
    local from_date
    from_date=$(date -u -v-"${days}"d +%Y-%m-%d 2>/dev/null || true)
    if [[ -n "$from_date" ]]; then
      merged_q=" merged:>=$from_date"
    fi
  fi

  local query
  query="is:pr is:merged author:@me${merged_q}${repo_q}"

  fetch_and_render_prs "$query" "is:pr is:merged author:@me" 0 "$output_file"
}

# Fetch all open PRs across watched repos (paginate until the very beginning)
# - Dedup against previous sections via SEEN_PRS_FILE (handled in rendering)
fetch_all() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)
  local query
  query="is:pr is:open${repo_q}"

  # We want the repo headers to link to the repo pulls search for open PRs
  export HEADER_LINK_Q="is:pr is:open"
  export COLLECT_ASSIGNED="0"

  # Accumulate all pages of search results
  local edges_tmp
  edges_tmp="$TMP_DIR/edges_tmp.jsonl"
  : >"$edges_tmp"

  local after=""
  local page_idx=0
  while :; do
    local page_resp
    page_idx=$((page_idx + 1))
    if [[ -n "$after" && "$after" != "null" ]]; then
      page_resp=$(gh api graphql -F q="$query" -F n="50" -F a="$after" -f query='
        query($q:String!,$n:Int!,$a:String){
          search(query:$q,type:ISSUE,first:$n,after:$a){
            pageInfo{hasNextPage endCursor}
            edges{node{... on PullRequest{number title url updatedAt repository{nameWithOwner} author{login avatarUrl(size:28)} isDraft isInMergeQueue}}}
        }' 2>/dev/null || echo '')
    else
      page_resp=$(gh api graphql -F q="$query" -F n="50" -f query='
        query($q:String!,$n:Int!){
          search(query:$q,type:ISSUE,first:$n){
            pageInfo{hasNextPage endCursor}
            edges{node{... on PullRequest{number title url updatedAt repository{nameWithOwner} author{login avatarUrl(size:28)} isDraft isInMergeQueue}}}
        }' 2>/dev/null || echo '')
    fi

    # If we failed to get valid JSON, stop here (and log)
    if ! echo "$page_resp" | jq -e . >/dev/null 2>&1; then

      break
    fi

    # If search payload is null (GraphQL complexity error), try a lighter fallback once
    search_null=$(echo "$page_resp" | jq -r 'if (.data.search==null) then "1" else "0" end')
    if [ "$search_null" = "1" ]; then

      if [[ -n "$after" && "$after" != "null" ]]; then
        page_resp=$(gh api graphql -F q="$query" -F n="25" -F a="$after" -f query='
          query($q:String!,$n:Int!,$a:String){
            search(query:$q,type:ISSUE,first:$n,after:$a){
              pageInfo{hasNextPage endCursor}
              edges{node{... on PullRequest{number title url updatedAt repository{nameWithOwner} author{login avatarUrl(size:28)}}}}
          }' 2>/dev/null || echo '')
      else
        page_resp=$(gh api graphql -F q="$query" -F n="25" -f query='
          query($q:String!,$n:Int!){
            search(query:$q,type:ISSUE,first:$n){
              pageInfo{hasNextPage endCursor}
              edges{node{... on PullRequest{number title url updatedAt repository{nameWithOwner} author{login avatarUrl(size:28)}}}}
          }' 2>/dev/null || echo '')
      fi
      if ! echo "$page_resp" | jq -e . >/dev/null 2>&1; then
        break
      fi
    fi

    # Page stats
    local edges_count has_next end_cursor_short
    edges_count=$(echo "$page_resp" | jq '((.data.search.edges // []) | length)')
    has_next=$(echo "$page_resp" | jq -r '.data.search.pageInfo.hasNextPage')
    after=$(echo "$page_resp" | jq -r '.data.search.pageInfo.endCursor')
    end_cursor_short="${after:0:12}"

    # Append edges from this page
    echo "$page_resp" | jq -c '(.data.search.edges // [])[]' >>"$edges_tmp"

    if [[ "$has_next" != "true" || -z "$after" || "$after" == "null" ]]; then
      break
    fi
  done

  # If no edges collected (GraphQL failed), fallback to REST per-repo listing
  if [ ! -s "$edges_tmp" ]; then
    for r in "${WATCHED_ARR[@]}"; do
      page=1
      while :; do
        resp=$(gh api -H "Accept: application/vnd.github+json" "/repos/$r/pulls?state=open&per_page=100&page=$page" 2>/dev/null || echo '')
        if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
          break
        fi
        count=$(echo "$resp" | jq 'length')
        echo "$resp" | jq -c --arg r "$r" '.[] | {node:{number:.number, title:(.title // ""), url:(.html_url // ""), updatedAt:(.updated_at // "1970-01-01T00:00:00Z"), isDraft:(.draft // false), isInMergeQueue:false, repository:{nameWithOwner:(.base.repo.full_name // $r)}, author:{login:(.user.login // "unknown"), avatarUrl:(.user.avatar_url // "")}}}' >>"$edges_tmp"
        if [ "$count" -lt 100 ]; then
          break
        fi
        page=$((page + 1))
      done
    done
  fi

  # Build a single RESP object with all edges, then render once
  RESP=$(jq -sc '{data:{search:{edges:.,pageInfo:{hasNextPage:false,endCursor:null}}}}' "$edges_tmp" 2>/dev/null)

  render_and_update_pagination >>"$output_file"

  rm -f "$edges_tmp" 2>/dev/null || true
}

# Fetch PRs where I was mentioned in comments (exclude my own PRs)
fetch_mentioned() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)
  # Primary: direct mentions (exclude my authored PRs)
  local q_mentions
  q_mentions="is:pr is:open mentions:@me${AUTHOR_EXCL}${repo_q}"
  fetch_and_render_prs "$q_mentions" "is:pr is:open mentions:@me${AUTHOR_EXCL}" 0 "$output_file"
}

# Fetch PRs I participated in (any involvement: comments, reviews, mentions, or reviews incl. dismissed)
fetch_participated() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)
  local q_involves="is:pr is:open involves:@me${AUTHOR_EXCL}${repo_q}"
  local q_reviewed="is:pr is:open reviewed-by:@me${AUTHOR_EXCL}${repo_q}"

  # Run reviewed-by first so approved PRs get decorated before dedupe, then involves
  export CHECK_MY_REVIEW_DISMISSED="1"
  export CHECK_MY_APPROVAL="1"
  fetch_and_render_prs "$q_reviewed" "is:pr is:open reviewed-by:@me${AUTHOR_EXCL}" 0 "$output_file"
  # Ensure a visual gap between the reviewed-by and involves blocks
  if [ -s "$output_file" ]; then echo "--" >>"$output_file"; fi
  export CHECK_MY_APPROVAL="0"
  export CHECK_MY_REVIEW_DISMISSED="1"
  fetch_and_render_prs "$q_involves" "is:pr is:open involves:@me${AUTHOR_EXCL}" 0 "$output_file"
  # Reset flags
  export CHECK_MY_REVIEW_DISMISSED="0"
}

# Fetch PRs for a specific team
fetch_team_prs() {
  local team_slug="$1"
  local output_file="$2"

  local repo_q
  repo_q=$(build_repo_qualifier)
  local query
  query="is:pr is:open team-review-requested:${team_slug}${repo_q}"

  fetch_and_render_prs "$query" "is:pr is:open team-review-requested:${team_slug}" 1 "$output_file"
}

# Initialize indexes (unread, involves, assigned)
init_indexes() {
  # Build index of unread PR notifications (requires notifications scope)
  UNREAD_FILE="$TMP_DIR/UNREAD_FILE.tsv"
  if ! gh api -H "Accept: application/vnd.github+json" 'notifications?per_page=100' \
    --jq '.[] | select(.unread == true and .subject.type == "PullRequest") | [.repository.full_name, (.subject.url | sub(".*/pulls/"; ""))] | @tsv' \
    >"$UNREAD_FILE" 2>/dev/null; then
    : >"$UNREAD_FILE"
  fi

  # Build index of PRs I have participated in (involves:@me). Limit to 100 for speed.
  INVOLVES_FILE="$TMP_DIR/INVOLVES_FILE.tsv"
  local repo_q
  repo_q=$(build_repo_qualifier)
  if ! gh api graphql -F q="is:pr is:open involves:@me${repo_q}" -F n="100" -f query='
    query($q:String!,$n:Int!){
      search(query:$q,type:ISSUE,first:$n){
        edges{node{... on PullRequest{ number repository{nameWithOwner} }}}
      }
    }' \
    --jq '.data.search.edges[].node | [.repository.nameWithOwner, (.number|tostring)] | @tsv' \
    >"$INVOLVES_FILE" 2>/dev/null; then
    : >"$INVOLVES_FILE"
  fi

  # Index of PRs already listed in ASSIGNED_TO_TEAMS (repo\tnumber)
  ASSIGNED_FILE="$TMP_DIR/ASSIGNED_FILE.tsv"
  : >"$ASSIGNED_FILE"
}
