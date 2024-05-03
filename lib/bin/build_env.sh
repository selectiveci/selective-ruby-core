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
  commit_message=$(git log --format=%s -n 1 $sha)
  committer_name=$(git show -s --format='%an' -n 1 $sha)
  committer_email=$(git show -s --format='%ae' -n 1 $sha)
elif [ -n "$CIRCLECI" ]; then
  platform=circleci
  branch=$CIRCLE_BRANCH
  actor=${CIRCLE_USERNAME:-$CIRCLE_PR_USERNAME}
  sha=$CIRCLE_SHA1
  run_attempt=$CIRCLE_BUILD_NUM
  runner_id=$CIRCLE_NODE_INDEX
  commit_message=$(git log --format=%s -n 1 $sha)
  committer_name=$(git show -s --format='%an' -n 1 $sha)
  committer_email=$(git show -s --format='%ae' -n 1 $sha)
elif [ -n "$SEMAPHORE" ]; then
  platform=semaphore
  branch=${SEMAPHORE_GIT_PR_BRANCH:-$SEMAPHORE_GIT_BRANCH}
  if [ -n "$SEMAPHORE_GIT_PR_BRANCH" ]; then
    target_branch=$SEMAPHORE_GIT_BRANCH
  fi
  actor=$SEMAPHORE_GIT_COMMITTER
  sha=$SEMAPHORE_GIT_SHA
  run_id=$SEMAPHORE_WORKFLOW_ID
  run_attempt=1
  runner_id=$SEMAPHORE_JOB_ID
  pr_title=$SEMAPHORE_GIT_PR_NAME
  commit_message=$(git log --format=%s -n 1 $sha)
  committer_name=$(git show -s --format='%an' -n 1 $sha)
  committer_email=$(git show -s --format='%ae' -n 1 $sha)
elif [ -n "$MINT" ]; then
  platform=mint
  branch="${MINT_GIT_REF_NAME}"
  actor="${MINT_ACTOR}"
  sha="${MINT_GIT_COMMIT_SHA}"
  run_id="${MINT_RUN_ID}"
  run_attempt="${MINT_TASK_ATTEMPT_NUMBER}"
  runner_id="${MINT_PARALLEL_INDEX}"
  # Mint does not preserve the .git directory by default to improve the likelihood of cache hits. Instead
  # of asking git for commit information, then, we rely on the mint/git-clone leaf to populate the necessary
  # metadata in environment variables.
  commit_message="${MINT_GIT_COMMIT_SUMMARY}"
  committer_name="${MINT_GIT_COMMITTER_NAME}"
  committer_email="${MINT_GIT_COMMITTER_EMAIL}"
fi

function escape() {
  echo -n "$1" | sed 's/"/\\"/g'
}

# Output the JSON
cat <<EOF
  {
    "api_key": "$(escape "${SELECTIVE_API_KEY}")",
    "host": "$(escape "${SELECTIVE_HOST:-wss://app.selective.ci}")",
    "platform": "$(escape "${SELECTIVE_PLATFORM:-$platform}")",
    "branch": "$(escape "${SELECTIVE_BRANCH:-$branch}")",
    "pr_title": "$(escape "${SELECTIVE_PR_TITLE:-$pr_title}")",
    "target_branch": "$(escape "${SELECTIVE_TARGET_BRANCH:-$target_branch}")",
    "actor": "$(escape "${SELECTIVE_ACTOR:-$actor}")",
    "sha": "$(escape "${SELECTIVE_SHA:-$sha}")",
    "run_id": "$(escape "${SELECTIVE_RUN_ID:-$run_id}")",
    "run_attempt": "$(escape "${SELECTIVE_RUN_ATTEMPT:-$run_attempt}")",
    "runner_id": "$(escape "${SELECTIVE_RUNNER_ID:-$runner_id}")",
    "commit_message": "$(escape "${SELECTIVE_COMMIT_MESSAGE:-$commit_message}")",
    "committer_name": "$(escape "${SELECTIVE_COMMITTER_NAME:-$committer_name}")",
    "committer_email": "$(escape "${SELECTIVE_COMMITTER_EMAIL:-$committer_email}")"
  }
EOF
