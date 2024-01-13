#!/bin/bash

# Detect the platform (only GitHub Actions in this case)
if [ -n "$GITHUB_ACTIONS" ]; then
  platform=github_actions
  branch=${SELECTIVE_BRANCH:-${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}}
  target_branch=${SELECTIVE_TARGET_BRANCH:-$GITHUB_BASE_REF}
  actor=$GITHUB_ACTOR
  sha=${SELECTIVE_SHA:-$GITHUB_SHA}
  run_id=${SELECTIVE_RUN_ID:-$GITHUB_RUN_ID}
  run_attempt=${SELECTIVE_RUN_ATTEMPT:-$GITHUB_RUN_ATTEMPT}
  runner_id=$SELECTIVE_RUNNER_ID
elif [ -n "$CIRCLECI" ]; then
  platform=circleci
  branch=${SELECTIVE_BRANCH:-$CIRCLE_BRANCH}
  target_branch=$SELECTIVE_TARGET_BRANCH
  actor=${SELECTIVE_ACTOR:-${CIRCLE_USERNAME:-$CIRCLE_PR_USERNAME}}
  sha=${SELECTIVE_SHA:-$CIRCLE_SHA1}
  run_id=$SELECTIVE_RUN_ID
  run_attempt=${SELECTIVE_RUN_ATTEMPT:-$CIRCLE_BUILD_NUM}
  runner_id=${SELECTIVE_RUNNER_ID:-$CIRCLE_NODE_INDEX}
elif [ -n "$SEMAPHORE" ]; then
  platform=semaphore
  branch=${SEMAPHORE_GIT_PR_BRANCH:-$SEMAPHORE_GIT_BRANCH}
  if [ -n "$SEMAPHORE_GIT_PR_BRANCH" ]; then
    target_branch=$SEMAPHORE_GIT_PR_BRANCH
  fi
  actor=$SEMAPHORE_GIT_COMMITTER
  sha=$SEMAPHORE_GIT_SHA
  run_id=$SEMAPHORE_WORKFLOW_ID
  runner_id=$SEMAPHORE_JOB_ID
else
  platform=$SELECTIVE_PLATFORM
  branch=$SELECTIVE_BRANCH
  target_branch=$SELECTIVE_TARGET_BRANCH
  actor=$SELECTIVE_ACTOR
  sha=$SELECTIVE_SHA
  run_id=$SELECTIVE_RUN_ID
  run_attempt=$SELECTIVE_RUN_ATTEMPT
  runner_id=$SELECTIVE_RUNNER_ID
fi

# Output the JSON
cat <<EOF
  {
    "api_key": "$SELECTIVE_API_KEY",
    "host": "${SELECTIVE_HOST:-wss://app.selective.ci}",
    "platform": "$platform",
    "branch": "$branch",
    "pr_title": "$SELECTIVE_PR_TITLE",
    "target_branch": "$target_branch",
    "actor": "$actor",
    "sha": "$sha",
    "run_id": "$run_id",
    "run_attempt": "$run_attempt",
    "commit_message": "$(git log --format=%s -n 1 $sha)",
    "runner_id": "$runner_id",
    "committer_name": "$(git show -s --format='%an' -n 1 $sha)",
    "committer_email": "$(git show -s --format='%ae' -n 1 $sha)"
  }
EOF