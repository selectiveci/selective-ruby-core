# frozen_string_literal: true

module RuboCop
  module Cop
    module Selective
      class SleepPollTimer < Base
        MSG = "Sleep-polling a monotonic clock is not a timer. " \
          "Sleep the full duration in one call (Kernel.sleep(seconds) on a thread) " \
          "and cancel that thread with Thread#kill."

        TIMER_BLOCKS = %i[loop times upto downto].freeze

        def on_while(node)
          flag_timer(node)
        end

        def on_until(node)
          flag_timer(node)
        end

        def on_block(node)
          flag_timer(node) if TIMER_BLOCKS.include?(node.method_name)
        end

        def on_numblock(node)
          on_block(node)
        end

        def on_itblock(node)
          on_block(node)
        end

        private

        def flag_timer(node)
          return unless sleeps?(node) && monotonic_clock?(node)

          add_offense(node)
        end

        def sleeps?(node)
          node.each_node(:send).any? { |child| child.method?(:sleep) }
        end

        def monotonic_clock?(node)
          node.each_node(:send, :const).any? { |child|
            (child.send_type? && child.method?(:clock_gettime)) ||
              (child.const_type? && child.short_name == :CLOCK_MONOTONIC)
          }
        end
      end
    end
  end
end
