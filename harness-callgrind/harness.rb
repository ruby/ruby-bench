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
#   CALLGRIND_COLLECT_JUMPS   — when set, pass --collect-jumps=yes to
#                                valgrind for branch prediction data
#   CALLGRIND_COLLECT_SYSTIME — when set, pass --collect-systime=nsec to
#                                valgrind for system call time data
#   CALLGRIND_CACHE_SIM       — when set, pass --cache-sim=yes to valgrind
#                                for cache simulation (I1/D1/LL misses)
#   CALLGRIND_BRANCH_SIM      — when set, pass --branch-sim=yes to valgrind
#                                for branch prediction simulation
#   WARMUP_ITRS               — warmup iterations (default: 15)
#   MIN_BENCH_ITRS            — benchmark iterations (default: num_itrs_hint)
#
# JIT symbol resolution:
#
# After valgrind exits, the harness automatically looks for a perf
# map file and resolves JIT hex addresses in the callgrind output.
# This replaces opaque addresses like fn=(123) 0x00000000216ce765
# with the symbolic names from the perf map (e.g., the Ruby method
# name that YJIT compiled).
#
# The perf map is located by extracting the guest PID from the
# callgrind output and checking /tmp/perf-<pid>.map. To generate
# a perf map, pass --yjit-perf to Ruby (e.g., via RUBYOPT).
#
# If no perf map is found, this step is silently skipped.
#
# Analyze with:
#   callgrind_annotate callgrind.out
#   kcachegrind callgrind.out
#
# For additional analysis, enable cache or branch simulation via
# the environment variables above. These add overhead but provide
# detailed cache miss (I1/D1/LL) and branch misprediction data,
# which can be especially insightful for JIT-compiled code whose
# cache and branch behavior may differ from interpreted code.
#
# Use low iteration counts — callgrind imposes ~20-50x slowdown
# on instrumented phases. Without profile_warmup, warmup runs at
# near-native speed since instrumentation is off.
#
# Note on timing: callgrind_control communicates with valgrind
# asynchronously. With very low iteration counts (e.g., 1), the
# very beginning of the first benchmark iteration may execute
# before instrumentation is fully enabled. In practice this is
# negligible for multi-iteration runs.

require_relative "../harness/harness-common"
require_relative "callgrind-symbol-resolver"

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

# Resolve JIT hex addresses in a callgrind output file using a perf map.
# Streams through a temp file to avoid loading the entire file into memory.
def resolve_jit_symbols(callgrind_file)
  return unless File.exist?(callgrind_file)

  perf_map_path = find_perf_map(callgrind_file)
  return unless perf_map_path

  entries = parse_perf_map(perf_map_path)
  if entries.empty?
    warn "harness-callgrind: perf map #{perf_map_path} is empty, skipping symbol resolution."
    return
  end

  starts = entries.map { |e| e[0] }
  resolved, unresolved = resolve_callgrind_file(callgrind_file, entries, starts)
  warn "harness-callgrind: Resolved #{resolved} JIT symbols in #{callgrind_file} (#{unresolved} unresolved) using #{perf_map_path}."
  if resolved == 0 && unresolved > 0
    perf_min = entries.first[0]
    perf_max = entries.last[1]
    warn "harness-callgrind: WARNING: No symbols resolved. Perf map covers 0x#{perf_min.to_s(16)}..0x#{perf_max.to_s(16)}."
    warn "harness-callgrind: This may indicate an address space mismatch between valgrind and the JIT perf map."
  end
end

# Locate and rename the warmup dump file produced by callgrind_control -d.
# Callgrind typically writes the dump as <outfile>.1, but the naming depends
# on an internal counter. This method tries the expected name first, then
# falls back to any numbered dump file it can find.
def rename_warmup_dump(out_file, warmup_itrs)
  dump_file = "#{out_file}.1"
  warmup_file = out_file.sub(/\.out\z/, "-warmup.out")

  if File.exist?(dump_file)
    File.rename(dump_file, warmup_file)
    warn "harness-callgrind: Warmup data dumped to #{warmup_file} after #{warmup_itrs} iterations."
    return
  end

  # Search for any dump files callgrind may have created with a
  # different naming convention and use the most recent one.
  candidates = Dir.glob("#{out_file}.*").select { |f| f.match?(/\.\d+\z/) }
  if candidates.length == 1
    File.rename(candidates[0], warmup_file)
    warn "harness-callgrind: Warmup data dumped to #{warmup_file} after #{warmup_itrs} iterations (renamed from #{candidates[0]})."
  elsif candidates.length > 1
    # Pick the highest-numbered dump (most recently created).
    best = candidates.max_by { |f| Integer(f[/\.(\d+)\z/, 1]) }
    File.rename(best, warmup_file)
    warn "harness-callgrind: Warmup data dumped to #{warmup_file} after #{warmup_itrs} iterations (renamed from #{best}; other candidates: #{(candidates - [best]).inspect})."
  else
    warn "harness-callgrind: Warmup data dumped after #{warmup_itrs} iterations (could not find dump file to rename)."
  end
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

  # Re-launch under valgrind/callgrind if not already running under it.
  # Detection: use a sentinel env var set just before exec, since
  # `callgrind_control -s` exits 0 even when the process is NOT under
  # callgrind (it prints an error but does not use a non-zero exit code).
  unless ENV['CALLGRIND_HARNESS_LAUNCHED']
    unless system("which", "valgrind", out: File::NULL, err: File::NULL)
      abort "harness-callgrind: valgrind not found in PATH. Please install valgrind first."
    end

    ruby_cmd = current_ruby_cmdline
    warn "harness-callgrind: Launching under valgrind..."
    # Restore original cwd so relative paths in ruby_cmd (the script path
    # and any -I flags) resolve correctly. Benchmarks may have called
    # Dir.chdir before run_benchmark, which would break the re-exec.
    Dir.chdir(CALLGRIND_HARNESS_ORIGINAL_CWD)

    extra_valgrind_args = []
    extra_valgrind_args << "--collect-jumps=yes" if ENV['CALLGRIND_COLLECT_JUMPS']
    extra_valgrind_args << "--collect-systime=nsec" if ENV['CALLGRIND_COLLECT_SYSTIME']
    extra_valgrind_args << "--cache-sim=yes" if ENV['CALLGRIND_CACHE_SIM']
    extra_valgrind_args << "--branch-sim=yes" if ENV['CALLGRIND_BRANCH_SIM']

    system({"CALLGRIND_HARNESS_LAUNCHED" => "1"},
           "valgrind", "--tool=callgrind",
           "--instr-atstart=no",
           "--callgrind-out-file=#{out_file}",
           *extra_valgrind_args,
           *ruby_cmd)
    valgrind_status = $?

    # Resolve JIT hex addresses using the perf map, if available.
    resolve_jit_symbols(out_file)
    warmup_file = out_file.sub(/\.out\z/, "-warmup.out")
    resolve_jit_symbols(warmup_file) if File.exist?(warmup_file)

    if valgrind_status.signaled?
      Process.kill(valgrind_status.termsig, Process.pid)
    end
    exit(valgrind_status.exitstatus || 1)
  end

  # Running inside valgrind — capture the guest PID for callgrind_control.
  pid = Process.pid.to_s

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
    # Turn instrumentation off before dumping so that the dump operation
    # itself and any Ruby code between here and the benchmark loop are
    # not captured in the benchmark profile.
    callgrind_control("-i", "off", pid)

    # Dump warmup data — counters are automatically zeroed so the
    # benchmark phase starts with a clean slate. Don't suppress stderr
    # here so dump failures are visible.
    ok = system("callgrind_control", "-d", pid, out: File::NULL)
    unless ok
      warn "harness-callgrind: callgrind_control -d failed (exit status: #{$?.exitstatus})."
    end

    rename_warmup_dump(out_file, warmup_itrs)
  end

  # Turn instrumentation on for the benchmark phase.
  ok = callgrind_control("-i", "on", pid)
  unless ok
    abort "harness-callgrind: callgrind_control failed (not running under callgrind?)."
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
