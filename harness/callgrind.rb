# frozen_string_literal: true

# Profile only the measured iterations with Callgrind (not setup or warmup).
# Usage:
# WARMUP_ITRS=10 MIN_BENCH_ITRS=1 HARNESS=callgrind \
#   valgrind --tool=callgrind --instr-atstart=no ruby benchmarks/fib.rb
# Use --callgrind-out-file=/absolute/path/callgrind.out.%p to choose the output.

require_relative "../lib/harness"
require_relative "../lib/harness/extra"

# Resolve the harness dependency from the root Gemfile without activating that
# whole bundle: benchmarks may set up a different Gemfile later. Load it early
# so benchmark Bundler setup cannot hide it, including vendor/bundle installs.
require "bundler"
begin
  Bundler.with_unbundled_env do
    gemfile = File.expand_path('../Gemfile', __dir__)
    ENV['BUNDLE_GEMFILE'] = gemfile
    Bundler.reset!
    begin
      definition = Bundler::Definition.build(gemfile, "#{gemfile}.lock", nil)
      specs = definition.specs_for([:callgrind])
    rescue Bundler::GemNotFound
      warn 'Installing the Callgrind bundle...'
      installed = system({ 'BUNDLE_WITH' => 'callgrind' }, RbConfig.ruby, '-S', 'bundle', 'install')
      raise LoadError, 'bundle install failed' unless installed

      Bundler.reset!
      definition = Bundler::Definition.build(gemfile, "#{gemfile}.lock", nil)
      specs = definition.specs_for([:callgrind])
    end
    specs.each { |spec| $LOAD_PATH.unshift(*spec.full_require_paths) }
    require "valgrind"
  end
rescue Bundler::BundlerError, LoadError => error
  raise LoadError, "Cannot load the Callgrind bundle: #{error.message}\n" \
                  "Run BUNDLE_WITH=callgrind bundle install with the benchmark Ruby."
ensure
  # Do not let root-bundle settings leak into a benchmark's own Bundler setup.
  Bundler.reset!
end

# Also exclude setup when the caller forgot --instr-atstart=no.
Valgrind.callgrind_stop_instrumentation

def run_benchmark(num_itrs_hint, **, &block)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 10))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  raise ArgumentError, 'WARMUP_ITRS must be non-negative' if warmup_itrs < 0
  raise ArgumentError, 'MIN_BENCH_ITRS must be positive' if bench_itrs <= 0

  warmup = []
  bench = []
  Valgrind.callgrind_stop_instrumentation
  warmup_itrs.times do
    start = get_time
    block.call
    warmup << get_time - start
  end

  begin
    Valgrind.callgrind_start_instrumentation
    Valgrind.callgrind_zero_stats
    bench_itrs.times do
      start = get_time
      block.call
      bench << get_time - start
    end
  ensure
    # Preserve a partial profile on failure, but never leave instrumentation on.
    Valgrind.callgrind_stop_instrumentation
    Valgrind.callgrind_dump_stats(benchmark_name)
  end

  puts "Callgrind stats dumped for #{benchmark_name} (output controlled by --callgrind-out-file)."
  return_results(warmup, bench) if ENV['RESULT_JSON_PATH']
end
