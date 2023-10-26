# frozen_string_literal: true

RSpec.describe Selective::Ruby::Core::NamedPipe do
  let!(:named_pipe) { dirty_dirty_unprivate_class(described_class).new("/tmp/test_read_pipe", "/tmp/test_write_pipe", skip_reset: true) }
  let!(:reverse_pipe) { dirty_dirty_unprivate_class(described_class).new("/tmp/test_write_pipe", "/tmp/test_read_pipe", skip_reset: true) }

  before { sleep(0.1) }

  after do
    named_pipe.delete_pipes
    reverse_pipe.delete_pipes
  end

  describe "#read" do
    it "raises an error when the pipe has been closed" do
      reverse_pipe.write_pipe.close
      expect { named_pipe.read }.to raise_error(described_class::PipeClosedError)
    end

    it "raises NoMethodError if not chomp" do
      allow(named_pipe.read_pipe).to receive(:gets).and_raise(NoMethodError.new("Foobar"))
      expect { named_pipe.read }.to raise_error(NoMethodError, "Foobar")
    end
  end

  describe "#write" do
    it "raises an error when the pipe has been closed" do
      reverse_pipe.read_pipe.close
      expect { named_pipe.write("hello") }.to raise_error(described_class::PipeClosedError)
    end
  end

  describe "#reset!" do
    it "empties messages on the pipe" do
      reverse_pipe.write("foo")
      named_pipe.reset!
      reverse_pipe.initialize_pipes
      sleep(0.1)
      reverse_pipe.write("bar")
      expect(named_pipe.read_pipe.read_nonblock(4096)).to eq("bar\n")
    end
  end
end
