#!/usr/bin/env python3
"""Scan PR comment threads for /debate triggers that need processing."""

import json
import sys


def load_comments(filepath):
    """Load comments from gh api JSON output (handles paginated output)."""
    with open(filepath) as f:
        text = f.read().strip()
    if not text:
        return []
    # gh --paginate may concatenate multiple JSON arrays
    # Try parsing as single array first, then handle concatenated arrays
    try:
        data = json.loads(text)
        if isinstance(data, list):
            if data and isinstance(data[0], list):
                return [c for page in data for c in page]
            return data
        return [data]
    except json.JSONDecodeError:
        # Try parsing as newline-separated JSON arrays
        results = []
        for line in text.split("\n"):
            line = line.strip()
            if line:
                try:
                    chunk = json.loads(line)
                    if isinstance(chunk, list):
                        results.extend(chunk)
                    else:
                        results.append(chunk)
                except json.JSONDecodeError:
                    continue
        return results


def group_review_threads(comments):
    """Group review comments into threads by in_reply_to_id."""
    threads = {}
    for c in comments:
        reply_to = c.get("in_reply_to_id")
        if reply_to:
            thread_key = reply_to
        else:
            thread_key = c["id"]

        if thread_key not in threads:
            threads[thread_key] = []
        threads[thread_key].append(c)

    for tid in threads:
        threads[tid].sort(key=lambda c: c["created_at"])

    return threads


def format_thread(comments):
    """Format a list of comments into readable thread text."""
    parts = []
    for c in comments:
        user = c.get("user", {}).get("login", "unknown")
        created = c.get("created_at", "")
        body = c.get("body", "")
        parts.append(f"**@{user}** ({created}):\n{body}")
    return "\n\n---\n\n".join(parts)


def find_unresolved_debates(comments):
    """Find /debate triggers without a subsequent **Debate Results:** response.

    Returns a list of unresolved debate descriptors. Each /debate summon is
    tracked independently — a new /debate after a **Debate Results:** triggers
    a fresh debate. The ONLY thing that resolves a debate is the presence of
    **Debate Results:** in a follow-up comment.
    """
    results = []

    last_debate_idx = None
    last_debate_comment_id = None

    for i, c in enumerate(comments):
        body = (c.get("body") or "").strip()

        if "/debate" in body:
            last_debate_idx = i
            last_debate_comment_id = str(c["id"])
        elif body.startswith("**Debate Results:**"):
            # Resolves the most recent /debate
            last_debate_idx = None
            last_debate_comment_id = None

    if last_debate_idx is not None:
        results.append(
            {
                "debate_comment_id": last_debate_comment_id,
                "reply_comment_id": str(comments[0]["id"]),  # root of thread
                "thread_text": format_thread(comments),
            }
        )

    return results


def main():
    if len(sys.argv) != 4:
        print(
            "Usage: scan-threads.py <review_comments.json> <issue_comments.json> <output_dir>",
            file=sys.stderr,
        )
        sys.exit(1)

    review_file = sys.argv[1]
    issue_file = sys.argv[2]
    output_dir = sys.argv[3]

    review_comments = load_comments(review_file)
    issue_comments = load_comments(issue_file)

    debates = []

    # Process review comment threads
    threads = group_review_threads(review_comments)
    for thread_id, thread_comments in threads.items():
        for debate in find_unresolved_debates(thread_comments):
            debate["reply_type"] = "review"
            debate["thread_id"] = str(thread_id)
            debates.append(debate)

    # Process issue comments as a flat thread
    if issue_comments:
        for debate in find_unresolved_debates(issue_comments):
            debate["reply_type"] = "issue"
            debate["thread_id"] = f"issue-{debate['debate_comment_id']}"
            debates.append(debate)

    # Write results
    for i, debate in enumerate(debates):
        output_file = f"{output_dir}/debate-{i}.json"
        with open(output_file, "w") as f:
            json.dump(debate, f, indent=2)

    print(f"Found {len(debates)} unresolved debate(s)")


if __name__ == "__main__":
    main()
