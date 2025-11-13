#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034

# ============================================================================
# FETCH PR DATA UTILS (low-level)
# GraphQL/REST helpers for PR data and review state
# ============================================================================

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
    ' 2>/dev/null || echo $'0\t0\t\t\t')

  # Validate result (at minimum we need conv and appr counts)
  if [[ "$result" =~ ^[0-9]+$'\t'[0-9]+ ]]; then
    # Cache it
    printf "%s\t%s\n" "$updatedAt" "$result" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || true
    echo "$result"
  else
    # Return defaults if query failed
    echo $'0\t0\t\t\t'
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
