# Debate Club

A multi-agent code review system that uses adversarial debate to evaluate PR comments. When someone posts `/debate` in a GitHub PR thread, Debate Club triggers two AI debaters to argue for and against the request, a moderator to render a verdict, and a master agent to execute the decision.

## How it works

```
/debate in PR thread
        |
        v
  ACCEPT Debater (Sonnet) ──┐
        |                    ├── N rounds of back-and-forth
  REJECT Debater (Sonnet) ──┘
        |
        v
  Moderator (Opus) ── renders ACCEPT / REJECT / CLARIFY / DEFER
        |
        v
  Master (Opus) ── executes the decision (code changes, PR reply)
        |
        v
  Posts "**Debate Results:**" to the PR thread
```

The full comment thread is passed to every agent so they have complete context. The master posts a reply starting with `**Debate Results:**` which marks the debate as resolved. If `/debate` is invoked again after a resolved debate, a new debate is triggered with the full updated thread.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [GitHub CLI](https://cli.github.com/) (`gh`) authenticated with access to your repos
- Python 3
- `jq`

## Usage

### Monitor mode

Watch a PR for `/debate` triggers and run the pipeline automatically:

```bash
./monitor-pr.sh <pr_url> <repo_path> [poll_interval_seconds]
```

Example:

```bash
./monitor-pr.sh https://github.com/owner/repo/pull/42 ~/Projects/repo 30
```

This polls the PR every 30 seconds (default), scans for unresolved `/debate` triggers, and runs the full pipeline for each one. Debates run one at a time.

### Direct mode

Run the pipeline directly against a comment or thread:

```bash
./debate-club.sh <pr_url> "comment text" --repo-path <path> [options]
```

Or pass a thread context file:

```bash
./debate-club.sh <pr_url> --comment-file thread.md --repo-path <path> [options]
```

Options:

| Flag | Description | Default |
|------|-------------|---------|
| `--repo-path <path>` | Path to local repo checkout (required) | |
| `--comment-file <path>` | Read thread context from file | |
| `--reply-comment-id <id>` | GitHub comment ID to reply to | |
| `--reply-type <type>` | `review` or `issue` | `issue` |
| `--rounds <n>` | Number of debate rounds | `1` |
| `--dry-run` | Run debate + moderator but skip execution | |

### Triggering a debate

Post a comment containing `/debate` anywhere in a PR thread. The monitor will pick it up and run the pipeline. The debate considers the entire thread for context.

A debate is resolved when the master posts a reply starting with `**Debate Results:**`. Posting `/debate` again after a resolved debate triggers a fresh one.

## Customization

### Prompts

All agent prompts live in `prompts/` and use `{{PLACEHOLDER}}` template variables:

| File | Agent | Purpose |
|------|-------|---------|
| `debater-accept.md` | ACCEPT Debater | Argues in favor of the request |
| `debater-reject.md` | REJECT Debater | Argues against the request |
| `moderator.md` | Moderator | Renders a verdict with rationale |
| `master.md` | Master | Executes the decision |

Available placeholders: `{{REPO}}`, `{{PR}}`, `{{PR_URL}}`, `{{PR_BRANCH}}`, `{{COMMENT_AUTHOR}}`, `{{COMMENT_BODY}}`, `{{TRANSCRIPT}}`, `{{ROUNDS}}`, `{{MODERATOR_OUTPUT}}`, `{{REPLY_COMMENT_ID}}`, `{{REPLY_TYPE}}`.

### Models

Models are set in `debate-club.sh` via `call_claude`:

- Debaters use `sonnet` for speed and token efficiency
- Moderator and master use `opus` for decision quality

Change the model name in the `call_claude` calls to swap models.

### Tools

Each agent gets a specific set of tools passed to `call_claude`. The debaters and moderator get `Read Glob Grep Bash` for codebase exploration. The master gets `Read Glob Grep Bash Edit Write` for making changes. Adjust these in `debate-club.sh` to grant or restrict capabilities.

### Debate trigger

The `/debate` keyword and `**Debate Results:**` marker are checked in `scan-threads.py`. Modify `find_unresolved_debates()` to change the trigger pattern or resolution marker.

## Run artifacts

Each debate run saves artifacts to `.debate-runs/<timestamp>-pr<N>/`:

```
transcript.md            # Full debate transcript
accept-r1.md             # ACCEPT debater's arguments per round
reject-r1.md             # REJECT debater's arguments per round
moderator-decision.md    # Moderator's verdict
master-output.md         # Master's execution log
prompt-*.md              # Rendered prompts sent to each agent
comment.txt              # Thread context
```

This directory is gitignored.
