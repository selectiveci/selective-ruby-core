# frozen_string_literal: true

# The tracer is optional. A customer without a C toolchain (or on an
# unsupported Ruby) must still be able to install selective-ruby-core and run
# their suite exactly as before, so any failed check writes a no-op Makefile
# instead of failing `gem install`. That includes compiling the tracer itself
# here first: an error in `make` would fail the install, so a Ruby whose
# headers the source doesn't build against must be caught before it. At
# runtime the missing library simply means "this runner can't record a test
# map".

require "mkmf"

def write_noop_makefile(reason)
  warn "selective_tracer: skipping native build (#{reason}); test map recording will be unavailable"
  File.write("Makefile", <<~MAKE)
    all:
    \t@true
    install:
    \t@true
    clean:
    \t@true
  MAKE
end

begin
  if RUBY_ENGINE != "ruby"
    write_noop_makefile("#{RUBY_ENGINE} is not supported")
  elsif !have_header("ruby/debug.h") || !have_func("rb_profile_frames", "ruby/debug.h")
    write_noop_makefile("required VM hook APIs are missing")
  else
    $CFLAGS << " -O2 -std=c99 -Wall -Wno-unused-parameter" # standard:disable Style/GlobalVars -- mkmf's interface
    if try_compile(File.read(File.expand_path("selective_tracer.c", __dir__)))
      create_makefile("selective_tracer")
    else
      write_noop_makefile("the tracer does not compile on Ruby #{RUBY_VERSION}; see mkmf.log")
    end
  end
rescue => e
  write_noop_makefile(e.message)
end
