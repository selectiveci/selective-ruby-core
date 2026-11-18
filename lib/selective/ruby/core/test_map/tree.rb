# frozen_string_literal: true

require "open3"

module Selective
  module Ruby
    module Core
      module TestMap
        # A content-hash snapshot of the repository: every file's git blob id.
        #
        # This is what makes selection independent of diffs. The server
        # compares these hashes with the ones stored alongside the map, so there
        # is no base commit to pick, no merge-base to compute and no fetch depth
        # to get right. It works in a depth-1 clone, and for uncommitted edits
        # (a developer or an agent running locally) it hashes what is actually
        # on disk rather than what HEAD says.
        module Tree
          module_function

          def repo_root
            out, status = Open3.capture2e("git", "rev-parse", "--show-toplevel")
            status.success? ? out.strip : nil
          rescue SystemCallError
            nil
          end

          # => {sha:, prefix:, files: {path => blob}, dirty: [paths]} or nil
          # when the working directory isn't a git checkout.
          def snapshot(pwd: Dir.pwd)
            root = repo_root
            return nil if root.nil?

            files = committed_files(root)
            return nil if files.nil?

            dirty = apply_working_tree_changes(root, files)
            {
              sha: head_sha(root),
              prefix: prefix_for(root, pwd),
              files: files,
              dirty: dirty
            }
          end

          # Where the test command runs, relative to the repository root, e.g.
          # "services/api/" in a monorepo. The server uses it to line manifest
          # paths (relative to the command) up with tree paths (relative to the
          # root).
          def prefix_for(root, pwd)
            real = File.realpath(pwd)
            return "" if real == root

            real.start_with?("#{root}/") ? "#{real.delete_prefix("#{root}/")}/" : ""
          end

          def head_sha(root)
            git(root, "rev-parse", "HEAD")&.strip
          end

          def committed_files(root)
            out = git(root, "ls-tree", "-r", "-z", "--full-tree", "HEAD")
            return nil if out.nil?

            out.split("\0").each_with_object({}) do |entry, files|
              meta, path = entry.split("\t", 2)
              next if path.nil?

              _mode, _type, blob = meta.split(" ")
              files[path] = blob
            end
          end

          # Folds uncommitted edits to tracked files into the snapshot. Returns
          # the dirty paths so the server can report that the run used a
          # working tree.
          #
          # Untracked files are deliberately left out. They add nothing — a new
          # test file is "new" to the map through the manifest, and a new app
          # file can't be a recorded dependency — and they churn: runner logs,
          # tmp/, coverage output. Hashing them made a local log file look like
          # a changed file no test uses, which runs the whole suite.
          def apply_working_tree_changes(root, files)
            out = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=no", "--no-renames")
            return [] if out.nil? || out.empty?

            changed = []
            deleted = []
            out.split("\0").each do |entry|
              next if entry.length < 4

              status = entry[0, 2]
              path = entry[3..]
              if status.include?("D") && !File.exist?(File.join(root, path))
                files.delete(path)
                deleted << path
              else
                changed << path
              end
            end

            hash_objects(root, changed).each { |path, blob| files[path] = blob }
            changed + deleted
          end

          def hash_objects(root, paths)
            existing = paths.select { |p| File.file?(File.join(root, p)) }
            return {} if existing.empty?

            out, status = Open3.capture2("git", "-C", root, "hash-object", "--stdin-paths", stdin_data: existing.join("\n") + "\n")
            return {} unless status.success?

            existing.zip(out.split("\n")).to_h
          end

          def git(root, *args)
            out, status = Open3.capture2("git", "-C", root, *args)
            status.success? ? out : nil
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
