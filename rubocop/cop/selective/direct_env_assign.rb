# frozen_string_literal: true

module RuboCop
  module Cop
    module Selective
      class DirectEnvAssign < Base
        MSG = "Assign ENV only through with_env (spec/helper_methods.rb). " \
          "Do not write ENV directly in specs."

        RESTRICT_ON_SEND = %i[[]= store update delete clear replace].freeze

        def on_send(node)
          return unless spec_file?
          return unless env_const?(node.receiver)
          return unless RESTRICT_ON_SEND.include?(node.method_name)
          return if inside_with_env?(node)

          add_offense(node)
        end

        def on_op_asgn(node)
          lhs = node.assignment_node
          return unless spec_file?
          return unless lhs.call_type? && lhs.method?(:[]) && env_const?(lhs.receiver)
          return if inside_with_env?(node)

          add_offense(node)
        end

        private

        def spec_file?
          processed_source.file_path.to_s.split(File::SEPARATOR).include?("spec")
        end

        def env_const?(node)
          node&.const_type? && node.short_name == :ENV
        end

        def inside_with_env?(node)
          node.each_ancestor(:def, :defs).any? { |ancestor| ancestor.method_name == :with_env }
        end
      end
    end
  end
end
