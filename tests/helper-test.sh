#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/omarchy-github-fetch"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_jq() { jq -e "$1" <<<"$2" >/dev/null || fail "$3"; }

bash -n "$HELPER"
"$HELPER" --help >/dev/null
if "$HELPER" --action-scan invalid >/dev/null 2>&1; then fail "invalid scan mode succeeded"; fi
if "$HELPER" --failed-days 0 >/dev/null 2>&1; then fail "invalid failed window succeeded"; fi
if "$HELPER" --mark-notification-read nope >/dev/null 2>&1; then fail "invalid notification id succeeded"; fi

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
export GH_TEST_LOG="$sandbox/gh-calls"
: >"$GH_TEST_LOG"
ln -s "$(command -v jq)" "$sandbox/jq"
ln -s "$(command -v bash)" "$sandbox/bash"
out=$(PATH="$sandbox" "$HELPER")
assert_jq '.state == "gh-not-installed" and (.reviewRequests|length) == 0' "$out" "missing-gh state"

cat >"$sandbox/gh" <<'GH'
#!/usr/bin/env bash
if [[ $1 == auth ]]; then exit 1; fi
exit 1
GH
chmod +x "$sandbox/gh"
out=$(PATH="$sandbox" "$HELPER")
assert_jq '.state == "logged-out" and (.repositories|length) == 0' "$out" "logged-out state"

cat >"$sandbox/gh" <<'GH'
#!/usr/bin/env bash
if [[ $1 == auth ]]; then exit 0; fi
if [[ $1 == api && $2 == --method && $3 == PATCH ]]; then
  [[ $4 == /notifications/threads/123 ]] || exit 9
  printf '%s\n' '{}'; exit 0
fi
if [[ $1 == api && $2 == graphql ]]; then
  cat <<'JSON'
{"data":{"viewer":{"login":"octocat","repositories":{"nodes":[{"name":"hello","nameWithOwner":"octocat/hello","url":"https://github.com/octocat/hello","isArchived":false,"isFork":false,"stargazerCount":42,"updatedAt":"2026-01-01T00:00:00Z","issues":{"totalCount":3},"pullRequests":{"totalCount":2}},{"name":"old","nameWithOwner":"octocat/old","url":"https://github.com/octocat/old","isArchived":true,"isFork":false,"stargazerCount":1,"updatedAt":"2020-01-01T00:00:00Z","issues":{"totalCount":0},"pullRequests":{"totalCount":0}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"remaining":4999,"resetAt":"2026-01-01T01:00:00Z","cost":1}}}
JSON
  exit 0
fi
endpoint=${*: -1}
printf '%s\n' "$*" >>"$GH_TEST_LOG"
if [[ $endpoint == /notifications* ]]; then
  cat <<'JSON'
[{"id":"123","unread":true,"reason":"mention","updated_at":"2026-01-03T00:00:00Z","repository":{"full_name":"octocat/hello","html_url":"https://github.com/octocat/hello"},"subject":{"title":"Review this","type":"PullRequest","url":"https://api.github.com/repos/octocat/hello/pulls/7","latest_comment_url":null}},{"id":"124","unread":true,"reason":"subscribed","updated_at":"2026-01-02T00:00:00Z","repository":{"full_name":"octocat/hello","html_url":"https://github.com/octocat/hello"},"subject":{"title":"Unknown subject","type":"RepositoryVulnerabilityAlert","url":"https://api.github.com/repos/octocat/hello/private-vulnerability-reporting/1","latest_comment_url":"https://api.github.com/repos/octocat/hello/comments/1"}}]
JSON
  exit 0
fi
if [[ $endpoint == /search/issues\?q=is%3Aopen+is%3Apr* ]]; then
  cat <<'JSON'
{"items":[{"id":71,"number":7,"title":"Please review","repository_url":"https://api.github.com/repos/octocat/hello","html_url":"https://github.com/octocat/hello/pull/7","updated_at":"2026-01-02T00:00:00Z","user":{"login":"friend"}}]}
JSON
  exit 0
fi
if [[ $endpoint == /search/issues\?q=is%3Aopen+is%3Aissue* ]]; then
  cat <<'JSON'
{"items":[{"id":81,"number":8,"title":"Fix it","repository_url":"https://api.github.com/repos/octocat/hello","html_url":"https://github.com/octocat/hello/issues/8","updated_at":"2026-01-02T00:00:00Z","user":{"login":"friend"}}]}
JSON
  exit 0
fi
if [[ $endpoint == /repos/octocat/hello/actions/runs* ]]; then
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ $endpoint == *status=queued* ]]; then
    # Simulate a paginated response where the active run is beyond the first
    # 100 records. A non-paginated or unfiltered implementation misses id 10.
    jq -n --arg now "$now" '{workflow_runs:[range(100)|{id:(1000+.),name:"Old",status:"completed",conclusion:"success",created_at:$now,updated_at:$now}]}'
    cat <<JSON
{"workflow_runs":[{"id":10,"name":"CI","display_title":"Build","status":"queued","conclusion":null,"head_branch":"main","html_url":"https://github.com/octocat/hello/actions/runs/10","created_at":"$now","updated_at":"$now"}]}
JSON
  elif [[ $endpoint == *status=completed* ]]; then
    jq -n --arg now "$now" '{workflow_runs:[range(100)|{id:(2000+.),name:"Passed",status:"completed",conclusion:"success",created_at:$now,updated_at:$now}]}'
    cat <<JSON
{"workflow_runs":[{"id":11,"name":"Test","status":"completed","conclusion":"failure","head_branch":"main","html_url":"https://github.com/octocat/hello/actions/runs/11","created_at":"$now","updated_at":"$now"}]}
JSON
  else
    printf '%s\n' '{"workflow_runs":[]}'
  fi
  exit 0
fi
exit 1
GH
chmod +x "$sandbox/gh"
out=$(PATH="$sandbox:$PATH" "$HELPER" --action-scan all --failed-days 7 --failed-limit 5)
assert_jq '.state == "ready" and .login == "octocat"' "$out" "ready state"
assert_jq '.repositories|length == 1 and .[0].issues == 3 and .[0].prs == 2 and .[0].stars == 42 and .[0].activeActions == 1' "$out" "repository metrics"
assert_jq '.notifications|length == 2 and .[0].url == "https://github.com/octocat/hello/pull/7" and .[1].url == "https://github.com/octocat/hello"' "$out" "type-aware notification conversion and fallback"
assert_jq '.reviewRequests|length == 1 and .[0].repository == "octocat/hello"' "$out" "review requests"
assert_jq '(.assignedIssues|length == 1) and (.assignedIssues[0].url|endswith("/issues/8"))' "$out" "assigned issues"
assert_jq '(.actions|length == 1) and (.failedActions|length == 1)' "$out" "active and failed actions separated"
assert_jq '.rateLimit.remaining == 4999 and (.warnings|length) == 0' "$out" "rate limit and warnings"
grep -q -- '--paginate.*status=queued' "$GH_TEST_LOG" || fail "queued Actions request was not paginated"
grep -q 'status=completed.*created=%3E%3D' "$GH_TEST_LOG" || fail "completed Actions request was not date bounded"
mark=$(PATH="$sandbox:$PATH" "$HELPER" --mark-notification-read 123)
assert_jq '.state == "ready" and .notificationId == "123"' "$mark" "mark notification read"

echo "helper tests passed"
