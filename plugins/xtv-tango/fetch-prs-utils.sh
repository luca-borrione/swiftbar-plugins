#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034

# ============================================================================
# PR FETCHING FUNCTIONS (section-level)
# Formerly plugins/xtv-tango/fetch.sh
# ============================================================================

# Fetch PRs (single page, no pagination) and render to output file
# Args: query, header_link_query, output_file
fetch_and_render_prs() {
  local query="$1"
  local header_link_q="$2"
  local output_file="$3"

  # Set global variables for render function
  export HEADER_LINK_Q="$header_link_q"

  # Single GraphQL search call (no pagination). Max 100 items per GitHub API.
  RESP=$(gh api graphql -F q="$query" -F n="100" -f query='
    query($q:String!,$n:Int!){
      search(query:$q,type:ISSUE,first:$n){
        pageInfo{hasNextPage endCursor}
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
        }}}}
    }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')

  # Ensure valid JSON
  if ! echo "$RESP" | jq -e . >/dev/null 2>&1; then
    RESP='{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
  fi

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

# Fetch "Requested to Me" PRs (direct review requests only)
fetch_requested_to_me() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)

  # Direct-to-you review requests only (includes PRs also requested to your teams)
  local query="is:pr is:open user-review-requested:@me${repo_q}"
  local header_link="is:pr is:open user-review-requested:@me"
  fetch_and_render_prs "$query" "$header_link" "$output_file"
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

  # First page (up to 100 PRs)
  RESP=$(gh api graphql -F q="$query" -F n="100" -f query='
    query($q:String!,$n:Int!){
      search(query:$q,type:ISSUE,first:$n){
        pageInfo{hasNextPage endCursor}
        edges{node{... on PullRequest{
          number
          title
          url
          updatedAt
          isDraft
          isInMergeQueue
          repository{nameWithOwner}
          author{login avatarUrl(size:28)}
          labels(first:20){nodes{name}}
        }}}
      }
    }' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')

  # Ensure valid JSON for the first page
  if ! echo "$RESP" | jq -e . >/dev/null 2>&1; then
    RESP='{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
  fi

  # If there are more pages, fetch them sequentially and append their edges
  while true; do
    local has_next cursor page
    has_next=$(echo "$RESP" | jq -r '.data.search.pageInfo.hasNextPage // false' 2>/dev/null || echo "false")
    cursor=$(echo "$RESP" | jq -r '.data.search.pageInfo.endCursor // ""' 2>/dev/null || echo "")
    if [ "$has_next" != "true" ] || [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
      break
    fi

    page=$(gh api graphql -F q="$query" -F n="100" -F cursor="$cursor" -f query='
      query($q:String!,$n:Int!,$cursor:String!){
        search(query:$q,type:ISSUE,first:$n,after:$cursor){
          pageInfo{hasNextPage endCursor}
          edges{node{... on PullRequest{
            number
            title
            url
            updatedAt
            isDraft
            isInMergeQueue
            repository{nameWithOwner}
            author{login avatarUrl(size:28)}
            labels(first:20){nodes{name}}
          }}}
        }
      }' 2>/dev/null || echo '')

    # Stop if we failed to get a valid JSON page
    if ! echo "$page" | jq -e . >/dev/null 2>&1; then
      break
    fi

    # Append new edges and update pageInfo on RESP; if merge fails, keep previous RESP
    RESP=$(jq -s '
      def merge(a;b):
        a as $a | b as $b |
        $a
        | .data.search.edges += ($b.data.search.edges // [])
        | .data.search.pageInfo.hasNextPage = ($b.data.search.pageInfo.hasNextPage // false)
        | .data.search.pageInfo.endCursor = ($b.data.search.pageInfo.endCursor // null);
      (.[0] as $a | .[1] as $b | merge($a;$b))
    ' <(echo "$RESP") <(echo "$page") 2>/dev/null || echo "$RESP")
  done

  render_and_update_pagination >>"$output_file"
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
# Includes PRs where you commented or reviewed (commenter:@me).
# Mentions (mentions:@me) are NOT included — they’re passive, not your action.
# -----------------------------------------------------------------------------

# Fetch PRs I participated in (my activity only: comments/reviews via commenter:@me)
# Header link reflects commenter:@me only.
fetch_participated() {
  local output_file="$1"

  local repo_q
  repo_q=$(build_repo_qualifier)

  local query="is:pr is:open commenter:@me${AUTHOR_EXCL}${repo_q}"
  local header_link="is:pr is:open commenter:@me${AUTHOR_EXCL}"
  fetch_and_render_prs "$query" "$header_link" "$output_file"
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

# Initialize indexes (team-requested dedupe)
init_indexes() {
  # Index of PRs already listed in REQUESTED_TO_TEAMS (repo\tnumber)
  REQUESTED_FILE="$(mktemp)"
}
