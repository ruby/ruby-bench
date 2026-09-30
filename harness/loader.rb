# Use harness/harness.rb by default. You can change it with -I option.
# i.e. ruby -Iharness benchmarks/railsbench/benchmark.rb
if RUBY_ENGINE == "spinel"
  # Spinel (https://github.com/matz/spinel) compiles the whole program ahead of time and
  # rejects the CRuby-only code in harness/harness.rb (RubyVM, RbConfig, Fiddle, ...).
  # It drops the other branch of a RUBY_ENGINE check before analysis, so only this
  # harness is compiled: `spinel -E benchmarks/fib.rb` needs no -I option at all.
  require_relative "../harness-spinel/harness"
else
  retries = 0
  begin
    require "harness"
  rescue LoadError => e
    if retries == 0 && e.path == "harness"
      retries += 1
      $LOAD_PATH << File.expand_path(__dir__)
      retry
    end
    raise
  end
end
