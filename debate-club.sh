#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPTS_DIR="${SCRIPT_DIR}/prompts"
WORK_DIR="${SCRIPT_DIR}/.debate-runs"

usage() {
    echo "Usage: $0 <pr_url> <comment_body|--comment-file path> --repo-path <path> [options]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --repo-path          Path to the local checkout of the repository (required)" >&2
    echo "  --comment-file PATH  Read thread context from a file instead of positional arg" >&2
    echo "  --reply-comment-id   Comment ID to reply to (for threading)" >&2
    echo "  --reply-type         Reply type: 'review' or 'issue' (default: issue)" >&2
    echo "  --rounds N           Number of debate rounds (default: 2)" >&2
    echo "  --dry-run            Run debate and moderator but skip master execution" >&2
    exit 1
}

# --- Parse args ---
PR_URL=""
COMMENT_BODY=""
COMMENT_FILE=""
REPO_PATH=""
REPLY_COMMENT_ID=""
REPLY_TYPE="issue"
ROUNDS=1
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        --comment-file) COMMENT_FILE="$2"; shift 2 ;;
        --reply-comment-id) REPLY_COMMENT_ID="$2"; shift 2 ;;
        --reply-type) REPLY_TYPE="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage ;;
        *)
            if [[ -z "$PR_URL" ]]; then
                PR_URL="$1"
            elif [[ -z "$COMMENT_BODY" ]]; then
                COMMENT_BODY="$1"
            else
                echo "Error: unexpected argument '$1'" >&2
                usage
            fi
            shift
            ;;
    esac
done

# Read comment body from file if --comment-file was given
if [[ -n "$COMMENT_FILE" ]]; then
    if [[ ! -f "$COMMENT_FILE" ]]; then
        echo "Error: comment file not found: ${COMMENT_FILE}" >&2
        exit 1
    fi
    COMMENT_BODY="$(cat "$COMMENT_FILE")"
fi

if [[ -z "$PR_URL" ]] || [[ -z "$COMMENT_BODY" ]] || [[ -z "$REPO_PATH" ]]; then
    usage
fi

REPO_PATH="$(cd "$REPO_PATH" && pwd)"
if [[ ! -d "${REPO_PATH}/.git" ]]; then
    echo "Error: ${REPO_PATH} is not a git repository." >&2
    exit 1
fi

if ! [[ "$PR_URL" =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
    echo "Error: Invalid PR URL format." >&2
    exit 1
fi

REPO="${BASH_REMATCH[1]}"
PR="${BASH_REMATCH[2]}"

COMMENT_AUTHOR=$(gh api "repos/${REPO}/issues/${PR}/comments" --jq '.[-1].user.login' 2>/dev/null || echo "unknown")

# --- Checkout the PR branch ---
PR_BRANCH=$(gh api "repos/${REPO}/pulls/${PR}" --jq '.head.ref' 2>/dev/null)
if [[ -z "$PR_BRANCH" ]]; then
    echo "Error: Could not determine PR branch." >&2
    exit 1
fi

ORIGINAL_BRANCH=$(cd "$REPO_PATH" && git rev-parse --abbrev-ref HEAD)
echo "Checking out PR branch: ${PR_BRANCH} (was on: ${ORIGINAL_BRANCH})"
(cd "$REPO_PATH" && git fetch origin "$PR_BRANCH" && git checkout "$PR_BRANCH" && git pull origin "$PR_BRANCH")

# --- Setup run directory ---
RUN_ID="$(date +%Y%m%d-%H%M%S)-pr${PR}"
RUN_DIR="${WORK_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"

echo "=== Debate Club ==="
echo "PR:      ${REPO}#${PR}"
echo "Repo:    ${REPO_PATH}"
echo "Rounds:  ${ROUNDS}"
echo "Run:     ${RUN_DIR}"
echo ""

# --- Helper: build a prompt by replacing placeholders with file contents ---
# Uses python for reliable multiline substitution
build_prompt() {
    local template_file="$1"
    shift
    # Remaining args are key=filepath pairs
    python3 -c "
import sys

template = open(sys.argv[1]).read()
i = 2
while i < len(sys.argv):
    key = sys.argv[i]
    filepath = sys.argv[i+1]
    with open(filepath) as f:
        value = f.read()
    template = template.replace('{{' + key + '}}', value)
    i += 2
print(template)
" "$template_file" "$@"
}

# --- Helper: write a single-line value to a file ---
write_val() {
    echo "$2" > "${RUN_DIR}/$1"
}

# --- Save static values as files for template substitution ---
write_val "repo.txt" "$REPO"
write_val "pr.txt" "$PR"
write_val "pr_url.txt" "$PR_URL"
write_val "author.txt" "$COMMENT_AUTHOR"
write_val "rounds.txt" "$ROUNDS"
write_val "pr_branch.txt" "$PR_BRANCH"
write_val "reply_comment_id.txt" "$REPLY_COMMENT_ID"
write_val "reply_type.txt" "$REPLY_TYPE"
echo "$COMMENT_BODY" > "${RUN_DIR}/comment.txt"

# --- Helper: call claude ---
# Usage: call_claude <model> <prompt_file> <output_file> [allowed_tools...]
call_claude() {
    local model="$1"
    local prompt_file="$2"
    local output_file="$3"
    shift 3
    local tools=("$@")

    local tool_args=()
    if [[ ${#tools[@]} -gt 0 ]]; then
        tool_args=(--allowedTools "${tools[@]}")
    fi

    (cd "$REPO_PATH" && claude --print \
        --model "$model" \
        "${tool_args[@]}" \
        -p "$(cat "$prompt_file")") \
        > "$output_file" 2>"${output_file}.err"
}

# --- Debate phase ---
echo "--- Debate Phase (${ROUNDS} rounds) ---"

# Start with empty transcript
echo "" > "${RUN_DIR}/transcript.md"

for round in $(seq 1 "$ROUNDS"); do
    echo "Round ${round}/${ROUNDS}..."

    # ACCEPT debater
    echo "  ACCEPT debater arguing..."
    build_prompt "${PROMPTS_DIR}/debater-accept.md" \
        REPO "${RUN_DIR}/repo.txt" \
        PR "${RUN_DIR}/pr.txt" \
        COMMENT_AUTHOR "${RUN_DIR}/author.txt" \
        ROUNDS "${RUN_DIR}/rounds.txt" \
        COMMENT_BODY "${RUN_DIR}/comment.txt" \
        TRANSCRIPT "${RUN_DIR}/transcript.md" \
        > "${RUN_DIR}/prompt-accept-r${round}.md"

    call_claude sonnet "${RUN_DIR}/prompt-accept-r${round}.md" "${RUN_DIR}/accept-r${round}.md" Read Glob Grep Bash

    # Append to transcript
    {
        echo ""
        echo "### Round ${round} — ACCEPT Debater:"
        cat "${RUN_DIR}/accept-r${round}.md"
    } >> "${RUN_DIR}/transcript.md"

    # REJECT debater
    echo "  REJECT debater arguing..."
    build_prompt "${PROMPTS_DIR}/debater-reject.md" \
        REPO "${RUN_DIR}/repo.txt" \
        PR "${RUN_DIR}/pr.txt" \
        COMMENT_AUTHOR "${RUN_DIR}/author.txt" \
        ROUNDS "${RUN_DIR}/rounds.txt" \
        COMMENT_BODY "${RUN_DIR}/comment.txt" \
        TRANSCRIPT "${RUN_DIR}/transcript.md" \
        > "${RUN_DIR}/prompt-reject-r${round}.md"

    call_claude sonnet "${RUN_DIR}/prompt-reject-r${round}.md" "${RUN_DIR}/reject-r${round}.md" Read Glob Grep Bash

    # Append to transcript
    {
        echo ""
        echo "### Round ${round} — REJECT Debater:"
        cat "${RUN_DIR}/reject-r${round}.md"
    } >> "${RUN_DIR}/transcript.md"

    echo "  Round ${round} complete."
done

echo ""
echo "--- Debate complete. Transcript saved. ---"
echo ""

# --- Moderator phase ---
echo "--- Moderator Phase ---"

build_prompt "${PROMPTS_DIR}/moderator.md" \
    REPO "${RUN_DIR}/repo.txt" \
    PR "${RUN_DIR}/pr.txt" \
    COMMENT_AUTHOR "${RUN_DIR}/author.txt" \
    COMMENT_BODY "${RUN_DIR}/comment.txt" \
    TRANSCRIPT "${RUN_DIR}/transcript.md" \
    > "${RUN_DIR}/prompt-moderator.md"

call_claude opus "${RUN_DIR}/prompt-moderator.md" "${RUN_DIR}/moderator-decision.md" Read Glob Grep Bash

echo "Moderator decision:"
echo ""
cat "${RUN_DIR}/moderator-decision.md"
echo ""

# --- Master phase ---
if [[ "$DRY_RUN" == true ]]; then
    echo "--- Dry run: skipping master execution ---"
    echo "Restoring branch: ${ORIGINAL_BRANCH}"
    (cd "$REPO_PATH" && git checkout "$ORIGINAL_BRANCH")
    echo "Run artifacts saved to: ${RUN_DIR}"
    exit 0
fi

echo "--- Master Phase ---"

build_prompt "${PROMPTS_DIR}/master.md" \
    REPO "${RUN_DIR}/repo.txt" \
    PR "${RUN_DIR}/pr.txt" \
    PR_URL "${RUN_DIR}/pr_url.txt" \
    PR_BRANCH "${RUN_DIR}/pr_branch.txt" \
    COMMENT_AUTHOR "${RUN_DIR}/author.txt" \
    COMMENT_BODY "${RUN_DIR}/comment.txt" \
    REPLY_COMMENT_ID "${RUN_DIR}/reply_comment_id.txt" \
    REPLY_TYPE "${RUN_DIR}/reply_type.txt" \
    MODERATOR_OUTPUT "${RUN_DIR}/moderator-decision.md" \
    > "${RUN_DIR}/prompt-master.md"

call_claude opus "${RUN_DIR}/prompt-master.md" "${RUN_DIR}/master-output.md" Read Glob Grep Bash Edit Write

echo "Master output:"
echo ""
cat "${RUN_DIR}/master-output.md"
echo ""
echo "Restoring branch: ${ORIGINAL_BRANCH}"
(cd "$REPO_PATH" && git checkout "$ORIGINAL_BRANCH")
echo ""
echo "=== Debate Club complete ==="
echo "Run artifacts: ${RUN_DIR}"
