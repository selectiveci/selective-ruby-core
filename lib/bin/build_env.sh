#!/bin/bash

# Detect the platform (only GitHub Actions in this case)
if [ -n "$GITHUB_ACTIONS" ]; then
  platform=github_actions
  branch=${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}
  target_branch=$GITHUB_BASE_REF
  actor=$GITHUB_ACTOR
  sha=$GITHUB_SHA
  run_id=$GITHUB_RUN_ID
  run_attempt=$GITHUB_RUN_ATTEMPT
  runner_id=$SELECTIVE_RUNNER_ID
elif [ -n "$CIRCLECI" ]; then
  platform=circleci
  branch=$CIRCLE_BRANCH
  actor=${CIRCLE_USERNAME:-$CIRCLE_PR_USERNAME}
  sha=$CIRCLE_SHA1
  run_attempt=$CIRCLE_BUILD_NUM
  runner_id=$CIRCLE_NODE_INDEX
elif [ -n "$SEMAPHORE" ]; then
  platform=semaphore
  branch=${SEMAPHORE_GIT_PR_BRANCH:-$SEMAPHORE_GIT_BRANCH}
  if [ -n "$SEMAPHORE_GIT_PR_BRANCH" ]; then
    target_branch=$SEMAPHORE_GIT_BRANCH
  fi
  actor=$SEMAPHORE_GIT_COMMITTER
  sha=$SEMAPHORE_GIT_SHA
  run_id=$SEMAPHORE_WORKFLOW_ID
  runner_id=$SEMAPHORE_JOB_ID
  pr_title=$SEMAPHORE_GIT_PR_NAME
fi

# Output the JSON
cat <<EOF
  {
    "api_key": "$SELECTIVE_API_KEY",
    "host": "${SELECTIVE_HOST:-wss://app.selective.ci}",
    "platform": "${SELECTIVE_PLATFORM:-$platform}",
    "branch": "${SELECTIVE_BRANCH:-$branch}",
    "pr_title": "${SELECTIVE_PR_TITLE:-$pr_title}",
    "target_branch": "${SELECTIVE_TARGET_BRANCH:-$target_branch}",
    "actor": "${SELECTIVE_ACTOR:-$actor}",
    "sha": "${SELECTIVE_SHA:-$sha}",
    "run_id": "${SELECTIVE_RUN_ID:-$run_id}",
    "run_attempt": "${SELECTIVE_RUN_ATTEMPT:-$run_attempt}",
    "runner_id": "${SELECTIVE_RUNNER_ID:-$runner_id}",
    "commit_message": "$(git log --format=%s -n 1 $sha)",
    "committer_name": "$(git show -s --format='%an' -n 1 $sha)",
    "committer_email": "$(git show -s --format='%ae' -n 1 $sha)"
  }
EOF