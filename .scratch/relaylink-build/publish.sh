#!/bin/bash
# Publishes all tickets to GitHub Issues
# Run from repo root

set -e

for f in .scratch/relaylink-build/issues/*.md; do
  num=$(basename "$f" .md | cut -d'-' -f1)
  title=$(head -1 "$f" | sed 's/^# [0-9]* — //')
  # Build body: skip the H1 title line, take everything else
  body=$(tail -n +2 "$f")

  echo "Publishing #$num: $title"
  gh issue create \
    --repo Azm1ne/July-2026-hackathon \
    --title "[$num] $title" \
    --body "$body" \
    --label "ready-for-agent" \
    > /dev/null
done

echo "Done. All tickets published."