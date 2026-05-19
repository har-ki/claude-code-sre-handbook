---
name: gh
description: >
  GitHub CLI — investigate commits, edit files, create issues and PRs for repos.
  Use when the user mentions github, pull request, issue, what changed, recent
  commits, fix the code, or gh.
---

# GitHub CLI Integration

PURPOSE: Clone repos, investigate commits, and create PRs to fix code issues.

WHEN TO USE (user-driven):
- User asks to "fix this in code" or "create a PR"
- User asks to "investigate recent commits" or "check what changed"
- User provides a GitHub repo and asks for code-related help

WORKFLOW: ASK_CONTEXT → READ → (EDIT → VERIFY → CONFIRM)* → PR → CLEANUP

## Availability

```sh
gh auth status
```

| Error | Action |
|-------|--------|
| "command not found" | Tell user: "Install gh: brew install gh" |
| "not logged in" | Tell user: "Run: gh auth login" |
| 404 / 403 | Ask for correct repo or inform user lacks access |

All errors are non-fatal. Continue without gh if unavailable.

## Context (REQUIRED before any operation)

ASK the user — never infer from working directory:

```
To work with GitHub, I need:
  1. Repository (e.g., org/repo):
  2. Branch (e.g., main):
```

Remember for session. If user provided in message, confirm once.

## Read Commands (no confirmation)

```sh
gh api repos/{owner}/{repo}/commits?since={iso_timestamp}&per_page=20
gh api repos/{owner}/{repo}/commits/{sha}
gh pr list --repo {owner}/{repo} --state open --json number,title
# For cloning, use Git Workflow below
```

## Write Commands (confirmation required)

**Gate 1**: Show proposed change, get confirmation
**Gate 2**: Confirm before push/PR creation

```sh
gh pr create --repo {owner}/{repo} --title "fix: {desc}" --body "..." --base {branch}
```

## Git Workflow (REQUIRED for code fixes)

**CRITICAL**: Use absolute paths with WORKDIR for ALL git and file commands.

```sh
# Step 1: Generate unique directory
WORKDIR="/tmp/gh-fix-{repo}-$(python3 -c 'import time; print(int(time.time()))')"

# Step 2: Clone (NO --depth=1 when checking out existing branches)
git clone https://github.com/{owner}/{repo}.git "$WORKDIR"

# Step 3a: For EXISTING branch
git -C "$WORKDIR" checkout {branch}

# Step 3b: For NEW fix branch
git -C "$WORKDIR" checkout -b fix/{description}

# Step 4: Edit file using absolute path
# Use the Edit tool (targeted change) or Write tool (full rewrite) with absolute path $WORKDIR/path/to/file

# Step 5: VERIFY before commit
git -C "$WORKDIR" diff
# If empty diff → edit failed, check WORKDIR path

# Step 6: Commit and push
git -C "$WORKDIR" add -A
git -C "$WORKDIR" commit -m 'fix: {description}'
git -C "$WORKDIR" push origin {branch}

# Step 7: Create PR
gh pr create --repo {owner}/{repo} --base main --head {branch} \
  --title "fix: {description}" \
  --body "## Summary
Fix description here.

## Changes
- Change 1"

# Step 8: ALWAYS cleanup
rm -rf "$WORKDIR"
```

## NEVER

| Don't Do This | What Happens | Error You'll See |
|---------------|--------------|------------------|
| `git commit` without `-C $WORKDIR` | Commits to caller's repo | "On branch [wrong-branch]" |
| `git push` without `-C $WORKDIR` | Branch doesn't exist | "error: src refspec X does not match any" |
| `sed -i 's/old/new/' file` | macOS syntax differs | "extra characters at the end of d command" |
| Skip `rm -rf $WORKDIR` | Temp dirs accumulate | Disk fills up |
| Skip `gh pr create` | No PR created | User has to create manually |
| Use relative paths for files | Wrong file edited | File not found or wrong file |
| `--depth=1` with remote branches | Shallow clone breaks checkout | "error: pathspec X did not match any file(s)" |
| Reuse existing /tmp/ dirs | Stale state | Unexpected files or conflicts |
| Infer repo from current directory | Wrong repo used | Commits to caller's repo |

## Mandatory Checklist (verify before completing)

- [ ] All git commands use `git -C $WORKDIR` pattern
- [ ] All file paths are absolute: `$WORKDIR/filename`
- [ ] `gh pr create --repo {owner}/{repo}` executed
- [ ] `rm -rf $WORKDIR` cleanup executed
- [ ] No `sed -i` used (use Write tool or heredoc instead)
