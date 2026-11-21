# frozen_string_literal: true

module Selective
  module Ruby
    module Core
      class Workers
        # Gives each worker of a Rails app what Rails `parallelize` gives its
        # workers: its own test database and the app's parallelize hooks.
        module Rails
          class << self
            def install
              return if @installed
              return unless defined?(::ActiveSupport) || defined?(::ActiveRecord::Base)

              @installed = true
              Workers.before_launch do
                Databases.create_for_workers(Workers.count) if Databases.per_worker?
                parallelization_hooks(:before_fork_hooks).each(&:call)
              end
              Workers.on_start { |index| start(index) }
              Workers.on_exit { |index| parallelization_hooks(:run_cleanup_hooks).each { |hook| hook.call(index) } }
            end

            def reset!
              @installed = false
            end

            private

            # Rails' Minitest helper registers ActiveRecord's per-worker
            # database hook with the parallelize hooks; otherwise Selective
            # sets the databases up the same way.
            def start(index)
              test_case = defined?(::ActiveSupport::TestCase) && ::ActiveSupport::TestCase
              test_case.parallel_worker_id = index if test_case.respond_to?(:parallel_worker_id=)
              Databases.setup(index) if Databases.needed?
              parallelization_hooks(:after_fork_hooks).each { |hook| hook.call(index) }
            end

            def parallelization_hooks(name)
              return [] unless defined?(::ActiveSupport::Testing::Parallelization)

              parallelization = ::ActiveSupport::Testing::Parallelization
              parallelization.respond_to?(name) ? parallelization.public_send(name) : []
            end
          end

          module Databases
            class << self
              def needed?
                return false unless defined?(::ActiveRecord::Base)
                return false if $LOADED_FEATURES.any? { |path| path.end_with?("/active_record/test_databases.rb") }

                !::ActiveSupport.respond_to?(:parallelize_test_databases) || ::ActiveSupport.parallelize_test_databases
              end

              # A database.yml that already names databases by TEST_ENV_NUMBER
              # is used as is; otherwise each worker gets `<name>_<index>`.
              # Either way the database is created if missing and loaded from
              # the schema, as Rails does for parallelize.
              def setup(index, env_name: ::ActiveRecord::ConnectionHandling::DEFAULT_ENV.call)
                suffix = per_worker_config?(env_name) ? nil : "_#{index}"
                verbose, ENV["VERBOSE"] = ENV["VERBOSE"], "false"
                ::ActiveRecord::Base.connection_handler.clear_all_connections!

                configs(env_name).each do |db_config|
                  db_config._database = "#{db_config.database}#{suffix}" if suffix
                  next if db_config.respond_to?(:database_tasks?) && !db_config.database_tasks?

                  ::ActiveRecord::Tasks::DatabaseTasks.reconstruct_from_schema(db_config)
                end
              ensure
                ::ActiveRecord::Base.establish_connection
                ENV["VERBOSE"] = verbose
              end

              def per_worker?
                defined?(::ActiveRecord::Base) && per_worker_config?(::ActiveRecord::ConnectionHandling::DEFAULT_ENV.call)
              end

              def per_worker_config?(env_name)
                names = ["", "2"].map { |number| worker_configs(number, env_name)&.map(&:database) }
                !names.first.nil? && names.uniq.size > 1
              rescue
                false
              end

              # Each worker connects to its database while the app boots, so
              # worker 0 creates the missing ones before starting the others.
              def create_for_workers(count, env_name: ::ActiveRecord::ConnectionHandling::DEFAULT_ENV.call)
                verbose, ENV["VERBOSE"] = ENV["VERBOSE"], "false"
                (1...count).each do |index|
                  number = Workers.worker_env(index, count)["TEST_ENV_NUMBER"]
                  worker_configs(number, env_name).each do |db_config|
                    next if db_config.respond_to?(:database_tasks?) && !db_config.database_tasks?

                    ::ActiveRecord::Tasks::DatabaseTasks.create(db_config)
                  end
                end
              ensure
                ENV["VERBOSE"] = verbose
              end

              private

              # The app's database configs as a worker with this
              # TEST_ENV_NUMBER reads them, or nil outside a Rails app.
              def worker_configs(number, env_name)
                return unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

                with_test_env_number(number) do
                  config = ::Rails.application.config.database_configuration
                  ::ActiveRecord::DatabaseConfigurations.new(config).configs_for(env_name: env_name)
                end
              end

              def configs(env_name)
                ::ActiveRecord::Base.configurations.configs_for(env_name: env_name, include_hidden: true)
              rescue ArgumentError
                ::ActiveRecord::Base.configurations.configs_for(env_name: env_name)
              end

              def with_test_env_number(number)
                saved = ENV["TEST_ENV_NUMBER"]
                ENV["TEST_ENV_NUMBER"] = number
                yield
              ensure
                ENV["TEST_ENV_NUMBER"] = saved
              end
            end
          end
        end
      end
    end
  end
end
