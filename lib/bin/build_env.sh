#!/bin/bash

# Detect the platform (only GitHub Actions in this case)
if [ -n "$GITHUB_ACTIONS" ]; then
  # Get environment variables
  platform=github_actions
  branch=${SELECTIVE_BRANCH:-${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}}
  pr_title=$SELECTIVE_PR_TITLE
  target_branch=${SELECTIVE_TARGET_BRANCH:-$GITHUB_BASE_REF}
  actor=$GITHUB_ACTOR
  sha=${SELECTIVE_SHA:-$GITHUB_SHA}
  run_id=${SELECTIVE_RUN_ID:-$GITHUB_RUN_ID}
  run_attempt=${SELECTIVE_RUN_ATTEMPT:-$GITHUB_RUN_ATTEMPT}
  commit_message=$(git log --format=%s -n 1 $sha)
else
  platform=$SELECTIVE_PLATFORM
  branch=$SELECTIVE_BRANCH
  pr_title=$SELECTIVE_PR_TITLE
  target_branch=$SELECTIVE_TARGET_BRANCH
  actor=$SELECTIVE_ACTOR
  sha=$SELECTIVE_SHA
  run_id=$SELECTIVE_RUN_ID
  run_attempt=$SELECTIVE_RUN_ATTEMPT
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
    "run_id": "$run_id",
    "run_attempt": "$run_attempt",
    "commit_message": "$commit_message"
  }
EOF