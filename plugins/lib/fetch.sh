#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# ============================================================================
# PR FETCHING FUNCTIONS
# ============================================================================
# Functions for fetching PRs from GitHub and building indexes

# Fetch PRs with pagination and render to output file
# Args: query, header_link_query, collect_assigned_flag, output_file
fetch_and_render_prs() {
  local query="$1"
  local header_link_q="$2"
  local collect_assigned="$3"
  local output_file="$4"

  # Set global variables for render function (used in utils.sh)
  export HEADER_LINK_Q="$header_link_q"
  export COLLECT_ASSIGNED="$collect_assigned"

  # First page
  RESP=$(gh api graphql -F q="$query" -F n="50" -f query='
    query($q:String!,$n:Int!){
      search(query:$q,type:ISSUE,first:$n){
        pageInfo{hasNextPage endCursor}
        edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted} reviewThreads{nodes{comments{totalCount}}}}}}
      }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
  render_and_update_pagination >>"$output_file"

  # Paginate through remaining pages
  while [ "$HAS_NEXT" = "true" ]; do
    RESP=$(gh api graphql -F q="$query" -F n="50" -F cursor="$CURSOR" -f query='
      query($q:String!,$n:Int!,$cursor:String!){
        search(query:$q,type:ISSUE,first:$n,after:$cursor){
          pageInfo{hasNextPage endCursor}
          edges{node{... on PullRequest{number title url updatedAt isDraft isInMergeQueue repository{nameWithOwner} author{login avatarUrl(size:28)} comments{totalCount} reviewDecision reactionGroups{viewerHasReacted} reviewThreads{nodes{comments{totalCount}}}}}}
        }}' 2>/dev/null || echo '{"data":{"search":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}')
    render_and_update_pagination >>"$output_file"
  done
}

# Build repo allowlist qualifier
build_repo_qualifier() {
  local repo_q=""
  if [ "${#WATCHED_ARR[@]}" -gt 0 ]; then
    for r in "${WATCHED_ARR[@]}"; do
      repo_q+=" repo:${r}"
    done
  fi
  echo "$repo_q"
}

# Fetch "Assigned to Me" PRs
fetch_assigned_to_me() {
  local output_file="$1"
  local repo_q
  repo_q=$(build_repo_qualifier)

  local query
  if [ -n "$repo_q" ]; then
    query="is:pr is:open review-requested:@me${repo_q}"
  else
    query="is:pr is:open review-requested:@me"
  fi

  fetch_and_render_prs "$query" "is%3Apr+is%3Aopen+review-requested%3A%40me" 0 "$output_file"
}

# Fetch "Raised by Me" PRs
fetch_raised_by_me() {
  local output_file="$1"
  local repo_q
  repo_q=$(build_repo_qualifier)

  local query
  if [ -n "$repo_q" ]; then
    query="is:pr is:open author:@me${repo_q}"
  else
    query="is:pr is:open author:@me"
  fi

  fetch_and_render_prs "$query" "is%3Apr+is%3Aopen+author%3A%40me" 0 "$output_file"
}

# Fetch PRs for a specific team
fetch_team_prs() {
  local team_slug="$1"
  local output_file="$2"
  local repo_q
  repo_q=$(build_repo_qualifier)

  local query
  if [ -n "$repo_q" ]; then
    query="is:pr is:open team-review-requested:${team_slug}${repo_q}"
  else
    query="is:pr is:open team-review-requested:${team_slug}"
  fi

  local encoded_team="${team_slug//\//%2F}"
  fetch_and_render_prs "$query" "is%3Apr+is%3Aopen+team-review-requested%3A${encoded_team}" 1 "$output_file"
}

# Initialize indexes (unread, involves, assigned)
init_indexes() {
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

  # Index of PRs already listed in ASSIGNED_TO_TEAMS (repo\tnumber)
  ASSIGNED_FILE="$(mktemp)"
  : >"$ASSIGNED_FILE"
}
