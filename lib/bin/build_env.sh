#!/bin/bash

# Parse an "owner/repo" slug out of a git remote URL (SSH or HTTPS) that points
# at github.com. Emits an empty string when the URL is not a github.com URL.
parse_github_slug() {
  local url="$1"
  case "$url" in
    git@github.com:*|git://github.com/*|https://github.com/*|http://github.com/*|ssh://git@github.com/*)
      echo "$url" | sed -E 's#^(git@|(git|https?|ssh)://(git@)?)github\.com[:/]##; s#\.git/?$##'
      ;;
  esac
}

# Given a git remote URL, classify the provider as github|gitlab|bitbucket or
# empty when unrecognized. Used for the git_provider hint.
detect_git_provider_from_url() {
  local url="$1"
  case "$url" in
    *github.com*)    echo "github" ;;
    *gitlab.com*)    echo "gitlab" ;;
    *bitbucket.org*) echo "bitbucket" ;;
  esac
}

# Detect the platform
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
  github_repo_full_name=$GITHUB_REPOSITORY
  git_provider=github
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
  # CircleCI has no single "slug" env var. Compose from username + reponame.
  # These work for both GitHub OAuth and GitHub App pipelines. For non-GitHub
  # pipelines (GitLab, Bitbucket) the same vars exist but we gate on the repo
  # URL to avoid emitting a non-GitHub slug.
  if [ -n "$CIRCLE_PROJECT_USERNAME" ] && [ -n "$CIRCLE_PROJECT_REPONAME" ]; then
    git_provider=$(detect_git_provider_from_url "$CIRCLE_REPOSITORY_URL")
    if [ "$git_provider" = "github" ] || [ -z "$CIRCLE_REPOSITORY_URL" ]; then
      github_repo_full_name="${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
      # If we fell through the "no repo URL" path, default provider to github
      # since the slug composition path is specific to GitHub-style owner/repo.
      [ -z "$git_provider" ] && git_provider=github
    fi
  fi
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
  git_provider=$SEMAPHORE_GIT_PROVIDER
  if [ "$git_provider" = "github" ]; then
    github_repo_full_name=$SEMAPHORE_GIT_REPO_SLUG
  fi
elif [ -n "$BUILDKITE" ]; then
  platform=buildkite
  branch=$BUILDKITE_BRANCH
  target_branch=$BUILDKITE_PULL_REQUEST_BASE_BRANCH
  actor=$BUILDKITE_BUILD_AUTHOR
  sha=$BUILDKITE_COMMIT
  run_id=$BUILDKITE_BUILD_ID
  run_attempt=$BUILDKITE_RETRY_COUNT
  runner_id=$BUILDKITE_PARALLEL_JOB
  pr_title=$BUILDKITE_PULL_REQUEST_TITLE
  commit_message=$BUILDKITE_MESSAGE
  committer_name=$BUILDKITE_BUILD_AUTHOR
  committer_email=$BUILDKITE_BUILD_AUTHOR_EMAIL
  # Buildkite tells us the provider explicitly, and BUILDKITE_REPO is the URL.
  if [ "$BUILDKITE_PIPELINE_PROVIDER" = "github" ]; then
    git_provider=github
    github_repo_full_name=$(parse_github_slug "$BUILDKITE_REPO")
  else
    git_provider=$BUILDKITE_PIPELINE_PROVIDER
  fi
elif [ -n "$RWX" ]; then
  platform=rwx
  branch="${RWX_GIT_REF_NAME}"
  actor="${RWX_ACTOR}"
  sha="${RWX_GIT_COMMIT_SHA}"
  run_id="${RWX_RUN_ID}"
  run_attempt="${RWX_TASK_ATTEMPT_NUMBER}"
  runner_id="${RWX_PARALLEL_INDEX}"
  # RWX does not preserve the .git directory by default to improve the likelihood of cache hits. Instead
  # of asking git for commit information, then, we rely on the git/clone package to populate the necessary
  # metadata in environment variables.
  commit_message="${RWX_GIT_COMMIT_SUMMARY}"
  committer_name="${RWX_GIT_COMMITTER_NAME}"
  committer_email="${RWX_GIT_COMMITTER_EMAIL}"
  # RWX_GIT_REPOSITORY_NAME is extracted by the git/clone package from whatever
  # URL was cloned. For non-GitHub hosts this still looks like "owner/repo" but
  # points elsewhere, so cross-check the URL host before trusting it.
  git_provider=$(detect_git_provider_from_url "$RWX_GIT_REPOSITORY_URL")
  if [ "$git_provider" = "github" ]; then
    github_repo_full_name="${RWX_GIT_REPOSITORY_NAME}"
  fi
elif [ -n "$MINT" ]; then
  platform=rwx
  branch="${MINT_GIT_REF_NAME}"
  actor="${MINT_ACTOR}"
  sha="${MINT_GIT_COMMIT_SHA}"
  run_id="${MINT_RUN_ID}"
  run_attempt="${MINT_TASK_ATTEMPT_NUMBER}"
  runner_id="${MINT_PARALLEL_INDEX}"
  # RWX does not preserve the .git directory by default to improve the likelihood of cache hits. Instead
  # of asking git for commit information, then, we rely on the git/clone package to populate the necessary
  # metadata in environment variables.
  commit_message="${MINT_GIT_COMMIT_SUMMARY}"
  committer_name="${MINT_GIT_COMMITTER_NAME}"
  committer_email="${MINT_GIT_COMMITTER_EMAIL}"
  git_provider=$(detect_git_provider_from_url "$MINT_GIT_REPOSITORY_URL")
  if [ "$git_provider" = "github" ]; then
    github_repo_full_name="${MINT_GIT_REPOSITORY_NAME}"
  fi
fi

# Final fallbacks when we haven't resolved the GitHub slug from a known CI
# platform. Order:
#   1. Explicit SELECTIVE_GITHUB_REPO override (always wins; see below).
#   2. git config --get remote.origin.url on a local checkout.
if [ -z "$github_repo_full_name" ] && command -v git >/dev/null 2>&1; then
  origin_url=$(git config --get remote.origin.url 2>/dev/null || true)
  if [ -n "$origin_url" ]; then
    parsed_slug=$(parse_github_slug "$origin_url")
    if [ -n "$parsed_slug" ]; then
      github_repo_full_name="$parsed_slug"
      [ -z "$git_provider" ] && git_provider=github
    elif [ -z "$git_provider" ]; then
      git_provider=$(detect_git_provider_from_url "$origin_url")
    fi
  fi
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
    "committer_email": "$(escape "${SELECTIVE_COMMITTER_EMAIL:-$committer_email}")",
    "github_repo_full_name": "$(escape "${SELECTIVE_GITHUB_REPO:-$github_repo_full_name}")",
    "git_provider": "$(escape "${SELECTIVE_GIT_PROVIDER:-$git_provider}")"
  }
EOF
