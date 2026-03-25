#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <github_pr_url> <repo_path> [poll_interval_seconds]" >&2
    exit 1
fi

if ! [[ "$1" =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
    echo "Error: Invalid PR URL format." >&2
    exit 1
fi

PR_URL="$1"
REPO="${BASH_REMATCH[1]}"
PR="${BASH_REMATCH[2]}"
REPO_PATH="$(cd "$2" && pwd)"
INTERVAL="${3:-30}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Monitoring ${REPO}#${PR} for /debate triggers every ${INTERVAL}s (Ctrl+C to stop)"

scan_for_debates() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Fetch all review comments (inline code comments with threads)
    gh api "repos/${REPO}/pulls/${PR}/comments" --paginate 2>/dev/null \
        | jq -s 'add // []' > "${tmpdir}/review_comments.json"

    # Fetch all issue comments (top-level PR conversation)
    gh api "repos/${REPO}/issues/${PR}/comments" --paginate 2>/dev/null \
        | jq -s 'add // []' > "${tmpdir}/issue_comments.json"

    # Scan for unresolved /debate triggers
    python3 "${SCRIPT_DIR}/scan-threads.py" \
        "${tmpdir}/review_comments.json" \
        "${tmpdir}/issue_comments.json" \
        "$tmpdir"

    # Trigger debate-club for each unresolved debate
    for debate_file in "${tmpdir}"/debate-*.json; do
        [[ -f "$debate_file" ]] || continue

        local debate_comment_id reply_comment_id reply_type thread_file
        debate_comment_id=$(jq -r '.debate_comment_id' "$debate_file")
        reply_comment_id=$(jq -r '.reply_comment_id' "$debate_file")
        reply_type=$(jq -r '.reply_type' "$debate_file")
        thread_file="${tmpdir}/thread-${debate_comment_id}.md"

        jq -r '.thread_text' "$debate_file" > "$thread_file"

        echo ">>> Triggering debate-club for /debate in comment ${debate_comment_id}..."

        "${SCRIPT_DIR}/debate-club.sh" "$PR_URL" \
            --comment-file "$thread_file" \
            --repo-path "$REPO_PATH" \
            --reply-comment-id "$reply_comment_id" \
            --reply-type "$reply_type"

    done

    rm -rf "$tmpdir"
}

# Initial scan
scan_for_debates

# Poll loop
while true; do
    sleep "$INTERVAL"
    scan_for_debates
done
