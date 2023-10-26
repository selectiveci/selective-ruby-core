#!/bin/bash

# Detect the platform (only GitHub Actions in this case)
if [ -n "$GITHUB_ACTIONS" ]; then
  # Get environment variables
  platform="github_actions"
  branch="${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}"
  pr_title="$PR_TITLE"
  target_branch="${GITHUB_BASE_REF}"
  actor="$GITHUB_ACTOR"
  sha="$GITHUB_SHA"
  commit_message=$(git log --format=%s -n 1 $sha)
else
  platform="$SELECTIVE_PLATFORM"
  branch="$SELECTIVE_BRANCH"
  pr_title="$SELECTIVE_PR_TITLE"
  target_branch="$SELECTIVE_TARGET_BRANCH"
  actor="$SELECTIVE_ACTOR"
  sha="$SELECTIVE_SHA"
  commit_message=$(git log --format=%s -n 1 $sha)
fi

# Output the JSON
cat <<EOF
  {
    "platform": "$platform",
    "branch": "$branch",
    "pr_title": "$pr_title",
    "target_branch": "$target_branch",
    "actor": "$actor",
    "sha": "$sha",
    "commit_message": "$commit_message"
  }
EOF