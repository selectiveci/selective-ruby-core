# frozen_string_literal: true

require "digest"
require "json"
require "socket"

class MinimalWebSocketServer
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  attr_reader :port

  def initialize
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.addr[1]
  end

  def accept_and_handshake
    client = @tcp.accept
    headers = +""
    while (line = client.gets)
      headers << line
      break if line == "\r\n" || line == "\n"
    end
    key = headers[/Sec-WebSocket-Key:\s*(\S+)/i, 1]
    accept = [Digest::SHA1.digest("#{key}#{GUID}")].pack("m0")
    client.write(
      "HTTP/1.1 101 Switching Protocols\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Accept: #{accept}\r\n" \
      "\r\n"
    )
    client
  end

  def send_text(client, text)
    send_frame(client, 0x1, text)
  end

  def read_json(client)
    text = read_text(client)
    return nil if text.nil?

    JSON.parse(text)
  end

  def close
    @tcp.close
  end

  private

  def read_text(client)
    loop do
      opcode, payload = read_frame(client)
      return nil if opcode.nil? || opcode == 0x8
      return payload if opcode == 0x1

      send_frame(client, 0xA, payload) if opcode == 0x9
    end
  end

  def send_frame(client, opcode, payload)
    bytes = payload.to_s.b
    header = [0x80 | opcode].pack("C")
    length = bytes.bytesize
    header << if length < 126
      [length].pack("C")
    else
      [126, length].pack("Cn")
    end
    client.write(header)
    client.write(bytes)
  end

  def read_frame(client)
    header = client.read(2)
    return nil if header.nil? || header.bytesize < 2

    first, second = header.unpack("C2")
    opcode = first & 0x0f
    masked = (second & 0x80) != 0
    length = second & 0x7f
    if length == 126
      length = client.read(2).unpack1("n")
    elsif length == 127
      length = client.read(8).unpack1("Q>")
    end
    mask = masked ? client.read(4).bytes : nil
    payload = length.zero? ? "".b : client.read(length)
    return nil if payload.nil? || (masked && mask.nil?)

    if mask
      payload = payload.bytes.each_with_index.map { |byte, index|
        byte ^ mask[index % 4]
      }.pack("C*")
    end
    [opcode, payload]
  end
end
