# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

RSpec.describe "build_env.sh" do
  SCRIPT = File.expand_path("../../lib/bin/build_env.sh", __dir__)

  # The script inherits the calling environment. RSpec test processes run under
  # GitHub Actions in CI, which would cause every test to look like a GHA run
  # unless we scrub the CI-platform env first.
  PLATFORM_ENV_VARS = %w[
    GITHUB_ACTIONS CIRCLECI SEMAPHORE BUILDKITE RWX MINT
    GITHUB_REPOSITORY GITHUB_REF_NAME GITHUB_HEAD_REF GITHUB_BASE_REF
    GITHUB_ACTOR GITHUB_SHA GITHUB_RUN_ID GITHUB_RUN_ATTEMPT
    CIRCLE_BRANCH CIRCLE_USERNAME CIRCLE_PR_USERNAME CIRCLE_SHA1
    CIRCLE_BUILD_NUM CIRCLE_NODE_INDEX CIRCLE_PROJECT_USERNAME
    CIRCLE_PROJECT_REPONAME CIRCLE_REPOSITORY_URL
    SEMAPHORE_GIT_BRANCH SEMAPHORE_GIT_PR_BRANCH SEMAPHORE_GIT_COMMITTER
    SEMAPHORE_GIT_SHA SEMAPHORE_WORKFLOW_ID SEMAPHORE_JOB_ID
    SEMAPHORE_GIT_PR_NAME SEMAPHORE_GIT_PROVIDER SEMAPHORE_GIT_REPO_SLUG
    BUILDKITE_BRANCH BUILDKITE_PULL_REQUEST_BASE_BRANCH BUILDKITE_BUILD_AUTHOR
    BUILDKITE_COMMIT BUILDKITE_BUILD_ID BUILDKITE_RETRY_COUNT
    BUILDKITE_PARALLEL_JOB BUILDKITE_PULL_REQUEST_TITLE BUILDKITE_MESSAGE
    BUILDKITE_BUILD_AUTHOR_EMAIL BUILDKITE_PIPELINE_PROVIDER BUILDKITE_REPO
    RWX_GIT_REF_NAME RWX_ACTOR RWX_GIT_COMMIT_SHA RWX_RUN_ID
    RWX_TASK_ATTEMPT_NUMBER RWX_PARALLEL_INDEX RWX_GIT_COMMIT_SUMMARY
    RWX_GIT_COMMITTER_NAME RWX_GIT_COMMITTER_EMAIL RWX_GIT_REPOSITORY_NAME
    RWX_GIT_REPOSITORY_URL
    MINT_GIT_REF_NAME MINT_ACTOR MINT_GIT_COMMIT_SHA MINT_RUN_ID
    MINT_TASK_ATTEMPT_NUMBER MINT_PARALLEL_INDEX MINT_GIT_COMMIT_SUMMARY
    MINT_GIT_COMMITTER_NAME MINT_GIT_COMMITTER_EMAIL MINT_GIT_REPOSITORY_NAME
    MINT_GIT_REPOSITORY_URL
    SELECTIVE_GITHUB_REPO SELECTIVE_GIT_PROVIDER
  ].freeze

  # Run the script with a fresh environment and return parsed JSON output.
  def run_with(env)
    scrubbed = PLATFORM_ENV_VARS.each_with_object({}) { |k, h| h[k] = nil }
    # Disable git shell-outs by pointing at an empty temp dir so the fallback
    # branches are deterministic.
    Dir.mktmpdir do |tmp|
      full_env = scrubbed.merge(env).merge("PWD" => tmp)
      stdout, _stderr, status = Open3.capture3(full_env, "bash", SCRIPT, chdir: tmp)
      raise "build_env.sh failed: #{stdout}" unless status.success?
      JSON.parse(stdout)
    end
  end

  describe "github_repo_full_name detection" do
    it "reads GITHUB_REPOSITORY on GitHub Actions" do
      env = {
        "GITHUB_ACTIONS" => "true",
        "GITHUB_REPOSITORY" => "selectiveci/selective-ruby-core",
        "GITHUB_SHA" => "abc123",
        "GITHUB_REF_NAME" => "main"
      }
      out = run_with(env)
      expect(out["platform"]).to eq("github_actions")
      expect(out["github_repo_full_name"]).to eq("selectiveci/selective-ruby-core")
      expect(out["git_provider"]).to eq("github")
    end

    it "composes owner/repo from CircleCI env vars" do
      env = {
        "CIRCLECI" => "true",
        "CIRCLE_PROJECT_USERNAME" => "acme",
        "CIRCLE_PROJECT_REPONAME" => "widgets",
        "CIRCLE_REPOSITORY_URL" => "git@github.com:acme/widgets.git",
        "CIRCLE_SHA1" => "abc123"
      }
      out = run_with(env)
      expect(out["platform"]).to eq("circleci")
      expect(out["github_repo_full_name"]).to eq("acme/widgets")
      expect(out["git_provider"]).to eq("github")
    end

    it "does not emit a slug for non-GitHub CircleCI pipelines" do
      env = {
        "CIRCLECI" => "true",
        "CIRCLE_PROJECT_USERNAME" => "acme",
        "CIRCLE_PROJECT_REPONAME" => "widgets",
        "CIRCLE_REPOSITORY_URL" => "git@bitbucket.org:acme/widgets.git",
        "CIRCLE_SHA1" => "abc123"
      }
      out = run_with(env)
      expect(out["github_repo_full_name"]).to eq("")
      expect(out["git_provider"]).to eq("bitbucket")
    end

    it "reads SEMAPHORE_GIT_REPO_SLUG when the provider is github" do
      env = {
        "SEMAPHORE" => "true",
        "SEMAPHORE_GIT_PROVIDER" => "github",
        "SEMAPHORE_GIT_REPO_SLUG" => "acme/widgets",
        "SEMAPHORE_GIT_SHA" => "abc123",
        "SEMAPHORE_GIT_BRANCH" => "main",
        "SEMAPHORE_WORKFLOW_ID" => "wf1",
        "SEMAPHORE_JOB_ID" => "job1"
      }
      out = run_with(env)
      expect(out["platform"]).to eq("semaphore")
      expect(out["github_repo_full_name"]).to eq("acme/widgets")
      expect(out["git_provider"]).to eq("github")
    end

    it "does not emit a slug for Semaphore + Bitbucket" do
      env = {
        "SEMAPHORE" => "true",
        "SEMAPHORE_GIT_PROVIDER" => "bitbucket",
        "SEMAPHORE_GIT_REPO_SLUG" => "acme/widgets",
        "SEMAPHORE_GIT_SHA" => "abc123",
        "SEMAPHORE_GIT_BRANCH" => "main"
      }
      out = run_with(env)
      expect(out["github_repo_full_name"]).to eq("")
      expect(out["git_provider"]).to eq("bitbucket")
    end

    it "parses BUILDKITE_REPO for github pipelines" do
      env = {
        "BUILDKITE" => "true",
        "BUILDKITE_PIPELINE_PROVIDER" => "github",
        "BUILDKITE_REPO" => "git@github.com:acme/widgets.git",
        "BUILDKITE_COMMIT" => "abc123",
        "BUILDKITE_BRANCH" => "main"
      }
      out = run_with(env)
      expect(out["platform"]).to eq("buildkite")
      expect(out["github_repo_full_name"]).to eq("acme/widgets")
      expect(out["git_provider"]).to eq("github")
    end

    it "parses HTTPS variants of BUILDKITE_REPO" do
      env = {
        "BUILDKITE" => "true",
        "BUILDKITE_PIPELINE_PROVIDER" => "github",
        "BUILDKITE_REPO" => "https://github.com/acme/widgets.git",
        "BUILDKITE_COMMIT" => "abc123"
      }
      out = run_with(env)
      expect(out["github_repo_full_name"]).to eq("acme/widgets")
    end

    it "does not emit a slug for non-github Buildkite pipelines" do
      env = {
        "BUILDKITE" => "true",
        "BUILDKITE_PIPELINE_PROVIDER" => "gitlab",
        "BUILDKITE_REPO" => "git@gitlab.com:acme/widgets.git",
        "BUILDKITE_COMMIT" => "abc123"
      }
      out = run_with(env)
      expect(out["github_repo_full_name"]).to eq("")
      expect(out["git_provider"]).to eq("gitlab")
    end

    it "uses RWX_GIT_REPOSITORY_NAME when the URL is github" do
      env = {
        "RWX" => "true",
        "RWX_GIT_REPOSITORY_NAME" => "acme/widgets",
        "RWX_GIT_REPOSITORY_URL" => "https://github.com/acme/widgets.git",
        "RWX_GIT_COMMIT_SHA" => "abc123",
        "RWX_GIT_REF_NAME" => "main"
      }
      out = run_with(env)
      expect(out["platform"]).to eq("rwx")
      expect(out["github_repo_full_name"]).to eq("acme/widgets")
      expect(out["git_provider"]).to eq("github")
    end

    it "ignores RWX_GIT_REPOSITORY_NAME when the URL is not github" do
      env = {
        "RWX" => "true",
        "RWX_GIT_REPOSITORY_NAME" => "acme/widgets",
        "RWX_GIT_REPOSITORY_URL" => "https://gitlab.com/acme/widgets.git",
        "RWX_GIT_COMMIT_SHA" => "abc123"
      }
      out = run_with(env)
      expect(out["github_repo_full_name"]).to eq("")
      expect(out["git_provider"]).to eq("gitlab")
    end

    it "honors MINT legacy env vars when RWX is absent" do
      env = {
        "MINT" => "true",
        "MINT_GIT_REPOSITORY_NAME" => "acme/widgets",
        "MINT_GIT_REPOSITORY_URL" => "git@github.com:acme/widgets.git",
        "MINT_GIT_COMMIT_SHA" => "abc123"
      }
      out = run_with(env)
      expect(out["platform"]).to eq("rwx")
      expect(out["github_repo_full_name"]).to eq("acme/widgets")
      expect(out["git_provider"]).to eq("github")
    end

    it "lets SELECTIVE_GITHUB_REPO override everything" do
      env = {
        "GITHUB_ACTIONS" => "true",
        "GITHUB_REPOSITORY" => "detected/repo",
        "SELECTIVE_GITHUB_REPO" => "override/repo",
        "GITHUB_SHA" => "abc123"
      }
      out = run_with(env)
      expect(out["github_repo_full_name"]).to eq("override/repo")
    end

    it "emits empty strings when nothing is detectable and no CI platform is set" do
      out = run_with({})
      expect(out["github_repo_full_name"]).to eq("")
      expect(out["git_provider"]).to eq("")
      expect(out["platform"]).to eq("")
    end
  end

  describe "SSH and HTTPS URL parsing" do
    {
      "git@github.com:acme/widgets.git"     => "acme/widgets",
      "git@github.com:acme/widgets"         => "acme/widgets",
      "https://github.com/acme/widgets.git" => "acme/widgets",
      "https://github.com/acme/widgets"     => "acme/widgets",
      "http://github.com/acme/widgets.git"  => "acme/widgets",
      "ssh://git@github.com/acme/widgets.git" => "acme/widgets",
      "git://github.com/acme/widgets.git"   => "acme/widgets"
    }.each do |url, expected|
      it "parses #{url}" do
        env = {
          "BUILDKITE" => "true",
          "BUILDKITE_PIPELINE_PROVIDER" => "github",
          "BUILDKITE_REPO" => url,
          "BUILDKITE_COMMIT" => "abc"
        }
        out = run_with(env)
        expect(out["github_repo_full_name"]).to eq(expected)
      end
    end
  end
end
