module Selective
  module Ruby
    module Core
      module Helper
        def safe_filename(filename)
          filename
            .gsub(/[\/\\:*?"<>|\n\r]+/, '_')
            .gsub(/^\.+|\.+$/, '')
            .strip[0, 255]
        end

        def with_error_handling(include_header: true)
          yield
        rescue => e
          raise e if debug?
          header = <<~TEXT
            An error occurred. Please rerun with --debug
            and contact support at https://selective.ci/support
          TEXT

          unless $selective_banner_displayed
            header = <<~TEXT
              #{banner}

              #{header}
            TEXT
          end

          puts_indented <<~TEXT
            \e[31m
            #{header if include_header}
            #{e.message}
            \e[0m
          TEXT

          exit 1
        end

        def print_warning(message)
          puts_indented <<~TEXT
            \e[33m
            #{message}
            \e[0m
          TEXT
        end

        def print_notice(message)
          puts_indented <<~TEXT
            #{banner unless $selective_banner_displayed}
            #{message}
          TEXT
        end

        def puts_indented(text)
          puts text.gsub(/^/, "  ")
        end

        def banner
          Helper.banner
        end

        def self.banner
          $selective_banner_displayed = true
          <<~BANNER
             ____       _           _   _
            / ___|  ___| | ___  ___| |_(_)_   _____
            \\___ \\ / _ \\ |/ _ \\/ __| __| \\ \\ / / _ \\
             ___) |  __/ |  __/ (__| |_| |\\ V /  __/
            |____/ \\___|_|\\___|\\___|\\__|_| \\_/ \\___|
            ________________________________________
          BANNER
        end
      end
    end
  end
end
