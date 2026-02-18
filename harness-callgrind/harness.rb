# frozen_string_literal: true
#
# Harness for profiling with Valgrind's callgrind tool.
#
# The harness automatically launches the process under valgrind when
# run_benchmark is called — just run the benchmark with
# -Iharness-callgrind and the harness handles the rest.
#
# Warmup runs with instrumentation off (near-native speed), then
# callgrind instrumentation is enabled for benchmark iterations only.
#
# Example usage (steady-state only):
#
#   ruby -Iharness-callgrind benchmarks/lobsters/benchmark.rb
#
# This produces a single output file containing only benchmark
# iteration data (no warmup/compilation overhead):
#   callgrind.out
#
# To change the output filename:
#
#   CALLGRIND_OUT_FILE=lobsters.out \
#     ruby -Iharness-callgrind benchmarks/lobsters/benchmark.rb
#
# To also capture warmup/compilation activity in a separate file:
#
#   CALLGRIND_PROFILE_WARMUP=1 \
#     ruby -Iharness-callgrind benchmarks/lobsters/benchmark.rb
#
# This produces two files:
#   callgrind-warmup.out  — warmup/compilation profile
#   callgrind.out         — steady-state benchmark profile
#
# Note: warmup runs ~20-50x slower with profile_warmup because
# callgrind instrumentation is active during warmup.
#
# Benchmarks can also set defaults via run_benchmark arguments:
#
#   run_benchmark(5, out_file: 'lobsters.out', profile_warmup: true) do
#     # ...
#   end
#
# Environment variables override method arguments when set.
#
# Environment variables:
#   CALLGRIND_OUT_FILE        — output filename (default: 'callgrind.out')
#   CALLGRIND_PROFILE_WARMUP  — when set, also profile warmup phase
#   WARMUP_ITRS               — warmup iterations (default: 15)
#   MIN_BENCH_ITRS            — benchmark iterations (default: num_itrs_hint)
#
# Analyze with:
#   callgrind_annotate callgrind.out
#   kcachegrind callgrind.out
#
# Use low iteration counts — callgrind imposes ~20-50x slowdown
# on instrumented phases. Without profile_warmup, warmup runs at
# near-native speed since instrumentation is off.

require_relative "../harness/harness-common"

# Resolve to an absolute path at require time, before benchmarks chdir.
ENV['CALLGRIND_OUT_FILE'] = File.expand_path(ENV['CALLGRIND_OUT_FILE']) if ENV['CALLGRIND_OUT_FILE']

# Capture working directory before any benchmark chdir happens, so that
# relative paths in the original command line (script path, -I flags) can
# be resolved correctly when re-exec'ing under valgrind.
CALLGRIND_HARNESS_ORIGINAL_CWD = Dir.pwd

# Returns the full command line of the current process as an array.
def current_ruby_cmdline
  if File.exist?("/proc/self/cmdline")
    # Linux: null-separated args, fully reliable.
    File.read("/proc/self/cmdline").split("\0")
  else
    # macOS/other: best-effort reconstruction via ps.
    require 'shellwords'
    Shellwords.shellsplit(`ps -ww -o args= -p #{Process.pid}`.strip)
  end
end

def callgrind_control(*args, pid)
  system("callgrind_control", *args, pid,
         out: File::NULL, err: File::NULL)
end

# Run warmup then benchmark iterations under callgrind.
#
# The harness automatically launches valgrind if not already running
# under it. Instrumentation is toggled via `callgrind_control`.
#
# Options:
#   out_file:        output filename (default: 'callgrind.out')
#   profile_warmup:  when true, warmup is instrumented and dumped to
#                    a separate file (default: false)
#
# Environment variables override method arguments when set.
def run_benchmark(num_itrs_hint, out_file: 'callgrind.out', profile_warmup: false, **, &blk)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 15))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  out_file = ENV.fetch('CALLGRIND_OUT_FILE', File.expand_path(out_file))
  profile_warmup = !!ENV['CALLGRIND_PROFILE_WARMUP'] || profile_warmup

  pid = Process.pid.to_s

  # Re-launch under valgrind/callgrind if not already running under it.
  # Detection: use a sentinel env var set just before exec, since
  # `callgrind_control -s` exits 0 even when the process is NOT under
  # callgrind (it prints an error but does not use a non-zero exit code).
  unless ENV['CALLGRIND_HARNESS_LAUNCHED']
    ruby_cmd = current_ruby_cmdline
    warn "harness-callgrind: Launching under valgrind..."
    # Restore original cwd so relative paths in ruby_cmd (the script path
    # and any -I flags) resolve correctly. Benchmarks may have called
    # Dir.chdir before run_benchmark, which would break the re-exec.
    Dir.chdir(CALLGRIND_HARNESS_ORIGINAL_CWD)
    exec({"CALLGRIND_HARNESS_LAUNCHED" => "1"},
         "valgrind", "--tool=callgrind",
         "--instr-atstart=no",
         "--callgrind-out-file=#{out_file}",
         *ruby_cmd)
  end

  if profile_warmup
    # Turn instrumentation on to capture compilation/JIT activity
    # during warmup.
    ok = callgrind_control("-i", "on", pid)
    unless ok
      abort "harness-callgrind: callgrind_control failed (not running under callgrind?)."
    end
  end

  # Run warmup iterations.
  # With profile_warmup: instrumented (~20-50x slower).
  # Without: uninstrumented (near-native speed).
  i = 0
  while i < warmup_itrs
    yield
    i += 1
  end

  if profile_warmup
    # Dump warmup data — counters are automatically zeroed so the
    # benchmark phase starts with a clean slate. Don't suppress stderr
    # here so dump failures are visible.
    ok = system("callgrind_control", "-d", pid, out: File::NULL)
    unless ok
      warn "harness-callgrind: callgrind_control -d failed (exit status: #{$?.exitstatus})."
    end

    # callgrind writes the dump as <outfile>.1. Rename it so it has
    # a descriptive name and loads cleanly in tools like KCachegrind.
    dump_file = "#{out_file}.1"
    warmup_file = out_file.sub(/\.out\z/, "-warmup.out")
    if File.exist?(dump_file)
      File.rename(dump_file, warmup_file)
      warn "harness-callgrind: Warmup data dumped to #{warmup_file} after #{warmup_itrs} iterations."
    else
      # Search for any dump files callgrind may have created with a
      # different naming convention.
      candidates = Dir.glob("#{out_file}.*").select { |f| f.match?(/\.\d+\z/) }
      warn "harness-callgrind: Warmup data dumped after #{warmup_itrs} iterations (could not find #{dump_file} to rename)."
      warn "harness-callgrind: Candidates found: #{candidates.inspect}" unless candidates.empty?
    end
  else
    # Turn instrumentation on for the benchmark phase only.
    ok = callgrind_control("-i", "on", pid)
    unless ok
      abort "harness-callgrind: callgrind_control failed (not running under callgrind?)."
    end
  end

  warn "harness-callgrind: Instrumentation enabled for #{bench_itrs} benchmark iterations."

  # Run benchmark (instrumented).
  i = 0
  while i < bench_itrs
    yield
    i += 1
  end

  # Turn instrumentation off to exclude shutdown/cleanup from the
  # profile. Benchmark data is written to <outfile> at program exit.
  callgrind_control("-i", "off", pid)
end
