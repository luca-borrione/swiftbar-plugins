#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034

# ============================================================================
# PR FETCHING FUNCTIONS (section-level)
# Formerly plugins/xtv-tango/fetch.sh
# ============================================================================

# Fetch PRs (single page, no pagination) and render to output file
# Args: query, header_link_query, collect_team_flag, output_file
fetch_and_render_prs() {
  local query="$1"
  local header_link_q="$2"
  local output_file="$3"

  # Set global variables for render function
  export HEADER_LINK_Q="$header_link_q"

  # Single GraphQL search call (no pagination). Max 100 items per GitHub API.
  local _attempt=1
  local _max_attempts=2
  while :; do
    RESP=$(gh api graphql -F q="$query" -F n="100" -f query='
      query($q:String!,$n:Int!){
        search(query:$q,type:ISSUE,first:$n){
          pageInfo{hasNextPage endCursor}
          edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted} reviewThreads(first:100){nodes{comments{totalCount}}} reviewRequests(first:100){nodes{requestedReviewer{... on User{login} ... on Team{slug}}}}}}}
        }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
    # Ensure valid JSON
    if ! echo "$RESP" | jq -e . >/dev/null 2>&1; then
      RESP='{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
    fi
    local _edges
    _edges=$(echo "$RESP" | jq '((.data.search.edges // []) | length)' 2>/dev/null || echo 0)
    if [ "${_edges:-0}" -eq 0 ] && [ "$_attempt" -lt "$_max_attempts" ]; then
      log_warn "retry: empty search; header=${header_link_q}"
      sleep 0.3
      _attempt=$((_attempt + 1))
      continue
    fi
    render_and_update_pagination >>"$output_file"
    break
  done
}

# Build repo allowlist qualifier
build_repo_qualifier() {
  local repo_q=""
  for r in "${WATCHED_ARR[@]}"; do
    repo_q+=" repo:${r}"
  done
  echo "$repo_q"
}

# Fetch "Requested to Me" PRs (direct review requests only)
fetch_requested_to_me() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)

  export COLLECT_REQUESTED_TO_ME="1"
  # Direct-to-you review requests only (includes PRs also requested to your teams)
  export FILTER_INDIVIDUAL_REVIEWS="false"
  local query="is:pr is:open user-review-requested:@me${repo_q}"
  local header_link="is:pr is:open user-review-requested:@me"
  fetch_and_render_prs "$query" "$header_link" "$output_file"
  export COLLECT_REQUESTED_TO_ME="0"
}

# Fetch "Raised by Me" PRs
fetch_raised_by_me() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)
  local query="is:pr is:open author:@me${repo_q}"

  fetch_and_render_prs "$query" "is:pr is:open author:@me" "$output_file"
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

  local query="is:pr is:merged author:@me${merged_q}${repo_q}"
  fetch_and_render_prs "$query" "is:pr is:merged author:@me" "$output_file"
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

  # Accumulate all pages of search results
  local edges_tmp
  edges_tmp="$(mktemp)"

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
  fetch_and_render_prs "$q_mentions" "is:pr is:open mentions:@me${AUTHOR_EXCL}" "$output_file"
}

# -----------------------------------------------------------------------------
# Participated section
#
# What is included
# - Your comments on the PR (top-level)
# - You review (approve/changes required/comments)
# - You react to the PR body (thumbs up, etc.)
#
# What is NOT included
# -Reactions to COMMENTS are NOT counted (GitHub’s viewerHasReacted exposes
#   reactions only for the PR body in this context)
# - Mentions (mentions:@me) are NOT included — they’re passive, not your action
# -----------------------------------------------------------------------------

# Fetch PRs I participated in (my activity only: comments/reviews via commenter:@me, plus PR-body reactions)
# Header link reflects commenter:@me only; reactions are merged client-side via viewerHasReacted
fetch_participated() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)

  # Queries
  local q_commenter="is:pr is:open commenter:@me${AUTHOR_EXCL}${repo_q}"
  local q_reacted="is:pr is:open reactions:>=1${AUTHOR_EXCL}${repo_q}"

  # Fetch both result sets (same GraphQL selection as other sections)
  local empty='{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
  local _attempt=1
  local _max_attempts=2
  local J1 J2
  while :; do
    J1=$(gh api graphql -F q="$q_commenter" -F n="100" -f query='
      query($q:String!,$n:Int!){
        search(query:$q,type:ISSUE,first:$n){
          pageInfo{hasNextPage endCursor}
          edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted} reviewThreads(first:100){nodes{comments{totalCount}}} reviewRequests(first:100){nodes{requestedReviewer{... on User{login} ... on Team{slug}}}}}}}
      }}' 2>/dev/null || echo "$empty")
    J2=$(gh api graphql -F q="$q_reacted" -F n="100" -f query='
      query($q:String!,$n:Int!){
        search(query:$q,type:ISSUE,first:$n){
          pageInfo{hasNextPage endCursor}
          edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted} reviewThreads(first:100){nodes{comments{totalCount}}} reviewRequests(first:100){nodes{requestedReviewer{... on User{login} ... on Team{slug}}}}}}}
      }}' 2>/dev/null || echo "$empty")

    # Combine and keep only reaction-only items where viewerHasReacted==true; then unique by repo+number
    RESP=$(jq -s '{data:{search:{edges:((.[0].data.search.edges // [])
            + ((.[1].data.search.edges // [])
               | map(select(((.node.reactionGroups // []) | map(.viewerHasReacted) | any) == true))
              )), pageInfo:{hasNextPage:false,endCursor:null}}}}
          | .data.search.edges |= unique_by(.node.repository.nameWithOwner + "#" + (.node.number|tostring))' \
      <(echo "${J1:-$empty}") <(echo "${J2:-$empty}") 2>/dev/null || echo "$empty")

    local _edges
    _edges=$(echo "$RESP" | jq '((.data.search.edges // []) | length)' 2>/dev/null || echo 0)
    if [ "${_edges:-0}" -eq 0 ] && [ "$_attempt" -lt "$_max_attempts" ]; then
      log_warn "retry: empty participated search; header=is:pr is:open commenter:@me"
      sleep 0.3
      _attempt=$((_attempt + 1))
      continue
    fi
    break
  done

  # Decorations apply to the unified set
  export CHECK_MY_REVIEW_DISMISSED="1"
  export CHECK_MY_APPROVAL="1"
  export HEADER_LINK_Q="is:pr is:open commenter:@me${AUTHOR_EXCL}"
  render_and_update_pagination >>"$output_file"

  # Reset flags
  export CHECK_MY_REVIEW_DISMISSED="0"
  export CHECK_MY_APPROVAL="0"
}

# Fetch PRs for a specific team (team review requests only)
fetch_team_prs() {
  local team_slug="$1"
  local output_file="$2"

  local repo_q
  repo_q=$(build_repo_qualifier)
  local query
  query="is:pr is:open team-review-requested:${team_slug}${repo_q}"
  # Mark rows as belonging to the team section (used for state/notifications)
  export COLLECT_REQUESTED_TO_TEAM="1"
  fetch_and_render_prs "$query" "is:pr is:open team-review-requested:${team_slug}" "$output_file"
  export COLLECT_REQUESTED_TO_TEAM="0"
}

# Initialize indexes (unread, involves, requested)
init_indexes() {
  # Build index of unread PR notifications (requires notifications scope)
  UNREAD_FILE="$(mktemp)"
  if ! gh api -H "Accept: application/vnd.github+json" 'notifications?per_page=100' \
    --jq '.[] | select(.unread == true and .subject.type == "PullRequest") | [.repository.full_name, (.subject.url | sub(".*/pulls/"; ""))] | @tsv' \
    >"$UNREAD_FILE" 2>/dev/null; then
    : >"$UNREAD_FILE"
  fi

  # Index of PRs already listed in REQUESTED_TO_TEAMS (repo\tnumber)
  REQUESTED_FILE="$(mktemp)"

}
