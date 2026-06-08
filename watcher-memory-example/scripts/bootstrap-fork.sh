#!/usr/bin/env bash
#
# One-time setup on the ecommerce fork. Idempotent.
# Usage: ./bootstrap-fork.sh [OWNER/REPO]
#
set -euo pipefail

REPO="${1:-${GITHUB_REPO:-}}"
if [[ -z "$REPO" ]]; then
  echo "Usage: $0 OWNER/REPO" >&2
  exit 1
fi

echo "==> Setting up fork: ${REPO}"

# ── Labels ────────────────────────────────────────────────────────────
echo "==> Creating labels (idempotent)"
for label in "incident:active" "incident:investigating" "incident:fix-proposed"; do
  gh label create "$label" --repo "$REPO" --color "d73a49" --force 2>/dev/null || true
done
echo "    Note: incident-fp:<hash> labels are created on demand by gh pr create --label"

# ── docs/incidents/ ───────────────────────────────────────────────────
echo "==> Creating docs/incidents/ structure"
WORKDIR=$(mktemp -d)
git clone "https://github.com/${REPO}.git" "$WORKDIR"
cd "$WORKDIR"

mkdir -p docs/incidents

if [[ ! -f docs/incidents/README.md ]]; then
  cat > docs/incidents/README.md << 'EOF'
# Incident Reports

This directory contains auto-generated incident reports created by the
alert watcher + Claude Code runner pipeline. Each report follows the
template in `_template.md` and is linked from the corresponding draft PR.

Reports are created during Phase 2 of the incident response loop and
should be reviewed alongside the PR diff before merging.
EOF
fi

if [[ ! -f docs/incidents/_template.md ]]; then
  cp /templates/incident-report.md docs/incidents/_template.md 2>/dev/null || \
  cat > docs/incidents/_template.md << 'TMPL'
# Incident Report: ${FINGERPRINT}

| Field | Value |
|-------|-------|
| **Fingerprint** | `${FINGERPRINT}` |
| **Detected** | ${DATE} |
| **Status** | Investigating |

## Summary

_One-paragraph summary of the incident._

## Timeline

| Time (UTC) | Event |
|------------|-------|
| | Alert triggered — error rate crossed 25% threshold |
| | Phase 1 investigation started |
| | Root cause identified |
| | Phase 2 fix proposed |

## Root cause

_Detailed explanation of why the incident occurred._

## Contributing factors

- _Factor 1_
- _Factor 2_

## Detection

_How the incident was detected (alert watcher fingerprint, error rate, etc.)._

## Fix

_What was changed and why. Link to the PR diff._

## Action items

- [ ] _Action item 1_
- [ ] _Action item 2_

## Open questions

- _Any unresolved questions for post-incident review._
TMPL
fi

# ── GitHub Action ─────────────────────────────────────────────────────
echo "==> Installing incident-loop GitHub Action"
mkdir -p .github/workflows
cp /scripts/ecommerce-action.yml .github/workflows/incident-loop.yml 2>/dev/null || \
cat > .github/workflows/incident-loop.yml << 'YML'
name: Incident PR Closed

on:
  pull_request:
    types: [closed]

jobs:
  notify-watcher:
    if: contains(join(github.event.pull_request.labels.*.name, ','), 'incident-fp:')
    runs-on: ubuntu-latest
    steps:
      - name: Notify watcher
        run: |
          curl -sf -X POST "${{ secrets.WATCHER_WEBHOOK_URL }}" \
            -H "Content-Type: application/json" \
            -d '{
              "pr_number": ${{ github.event.pull_request.number }},
              "merged": ${{ github.event.pull_request.merged }},
              "merged_by": "${{ github.event.pull_request.merged_by.login }}",
              "closed_at": "${{ github.event.pull_request.closed_at }}"
            }'
YML

# Commit and push if there are changes
if [[ -n $(git status --porcelain) ]]; then
  git add -A
  git commit -m "chore: bootstrap incident response structure"
  git push origin main
  echo "==> Pushed incident structure to ${REPO}"
else
  echo "==> No changes needed, fork already bootstrapped"
fi

# ── Cleanup ───────────────────────────────────────────────────────────
rm -rf "$WORKDIR"

# ── Manual step ───────────────────────────────────────────────────────
cat << EOF

==> Done. One manual step remains:

    Enable branch protection on 'main' requiring PR review.
    Go to: https://github.com/${REPO}/settings/branches
    → Add rule → Branch name pattern: main
    → Check "Require a pull request before merging"
    → Check "Require approvals" (1)
    → Save changes

EOF
