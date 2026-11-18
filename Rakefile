# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# Builds the optional test map tracer into lib/ for development and CI.
# Installed gems build it through `spec.extensions` instead.
desc "Compile the native test map tracer"
task :compile do
  require "fileutils"
  require "rbconfig"
  ext_dir = File.expand_path("ext/selective_tracer", __dir__)
  build_dir = File.expand_path("tmp/selective_tracer", __dir__)
  FileUtils.mkdir_p(build_dir)
  Dir.chdir(build_dir) do
    # extconf must not inherit this process's bundle; it only needs mkmf.
    Bundler.with_unbundled_env do
      sh RbConfig.ruby, File.join(ext_dir, "extconf.rb")
      sh "make"
    end
    built = Dir["selective_tracer.{#{RbConfig::CONFIG["DLEXT"]},bundle,so}"].first
    FileUtils.cp(built, File.expand_path("lib", __dir__)) if built
  end
end

require "standard/rake"

task default: %i[spec standard]
