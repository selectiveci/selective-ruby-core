# frozen_string_literal: true

require "set"

module Selective
  module Ruby
    module Core
      module TestMap
        # Ruby face of the native tracer: decides which paths count as the
        # project's own code, and turns what the tracer saw into sorted,
        # repo-relative paths that line up with `git ls-tree`.
        class Tracer
          attr_reader :repo_root

          def initialize(allocations: true, repo_root: Tree.repo_root, pwd: Dir.pwd)
            @repo_root = repo_root || File.realpath(pwd)
            @roots = unique_dirs([@repo_root, pwd])
            # Only directories *inside* a root need ignoring (everything else is
            # outside the roots already). An ancestor would ignore the whole
            # project, e.g. GEM_HOME=/work with the repo at /work/app.
            @ignored = unique_dirs(ignored_dirs).select do |dir|
              @roots.any? { |root| dir.start_with?("#{root}/") }
            end
            @native = NativeTracer.new(roots: @roots, ignored: @ignored, allocations: allocations)
            @relative_paths = {}
            @class_files = {}.compare_by_identity
          end

          # Runs the block with tracing on and returns [result, files], where
          # files is a Set of repo-relative paths.
          def trace
            @native.start
            begin
              result = yield
            ensure
              files, klasses = @native.stop
            end
            [result, collect(files, klasses)]
          end

          private

          def collect(files, klasses)
            paths = Set.new
            files.each_key do |path|
              rel = relative(path)
              paths << rel if rel
            end
            klasses.each do |klass|
              files_for_class(klass).each { |rel| paths << rel }
            end
            paths
          end

          # A class's own file, plus those of its project-defined ancestors: a
          # test that builds a `User` depends on `ApplicationRecord` too.
          def files_for_class(klass)
            @class_files[klass] ||= klass.ancestors.filter_map do |mod|
              name = mod.name
              next if name.nil?

              location = Object.const_source_location(name)&.first
              location && relative(location)
            rescue NameError, ArgumentError, TypeError
              nil
            end.uniq.freeze
          end

          def relative(path)
            return @relative_paths[path] if @relative_paths.key?(path)

            @relative_paths[path] = compute_relative(path)
          end

          def compute_relative(path)
            abs = File.expand_path(path)
            return nil if ignored?(abs)

            rel = strip_root(abs)
            if rel.nil? && File.exist?(abs)
              real = File.realpath(abs)
              rel = strip_root(real) unless ignored?(real)
            end
            rel
          end

          def strip_root(abs)
            prefix = "#{@repo_root}/"
            abs.start_with?(prefix) ? abs.delete_prefix(prefix) : nil
          end

          def ignored?(abs)
            @ignored.any? { |dir| abs == dir || abs.start_with?("#{dir}/") }
          end

          # Code the project runs but doesn't own: installed gems (including a
          # vendored bundle inside the repo) and Selective's own gems, which
          # live inside the repo when developed through path/symlinks.
          def ignored_dirs
            dirs = [Gem.dir, *Gem.path]
            dirs << Bundler.bundle_path.to_s if defined?(Bundler) && Bundler.respond_to?(:bundle_path)
            Gem.loaded_specs.each do |name, spec|
              dirs << spec.full_gem_path if name.start_with?("selective-ruby-")
            end
            extra = ENV["SELECTIVE_TEST_MAP_IGNORE"].to_s.split(",").map(&:strip).reject(&:empty?)
            dirs.concat(extra.map { |d| File.expand_path(d) })
          end

          def unique_dirs(dirs)
            dirs.compact.flat_map do |dir|
              expanded = File.expand_path(dir.to_s)
              real = File.exist?(expanded) ? File.realpath(expanded) : expanded
              [expanded, real]
            end.map { |d| d.chomp("/") }.reject(&:empty?).uniq
          end
        end
      end
    end
  end
end
