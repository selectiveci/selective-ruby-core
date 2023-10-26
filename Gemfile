# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in selective-ruby-core.gemspec
gemspec

gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "standard", "~> 1.3"

gem "irb"

gem "rspec_junit_formatter"

gem "appraisal", "~> 2.5"

gem "simplecov", require: false, group: :test

if Dir.exist?(selective_ruby_rspec_path = "../selective-ruby-rspec")
  gem "selective-ruby-rspec", path: selective_ruby_rspec_path
else
  gem "selective-ruby-rspec", git: "https://#{ENV["CLONE_PAT"]}:@github.com/selectiveci/selective-ruby-rspec.git"
end
