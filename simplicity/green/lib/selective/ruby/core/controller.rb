# frozen_string_literal: true

def wait_for_connectivity
  @pending_commands = []
  watchdog = Thread.new do
    Kernel.sleep(30)
    puts "Transport process failed to start. Exiting..."
    kill_transport
    exit(1)
  end

  loop do
    message = pipe.read
    next sleep(0.1) if message.nil?

    response = JSON.parse(message, symbolize_names: true)
    break if response[:command] == "connected"

    @pending_commands << response
  end
ensure
  watchdog&.kill
end
