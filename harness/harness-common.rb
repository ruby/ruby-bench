require 'rbconfig'

# Ensure the ruby in PATH is the ruby running this, so we can safely shell out to other commands
ruby_in_path = `ruby -e 'print RbConfig.ruby'`
unless ruby_in_path == RbConfig.ruby
  ENV["PATH"] = "#{File.dirname(RbConfig.ruby)}:#{ENV["PATH"]}"
  ENV.merge!("GEM_HOME" => nil, "GEM_PATH" => nil) # avoid installing gems to chruby-ed Ruby
end

# Support enabling GC auto-compaction via environment variable
GC.auto_compact = !!ENV["RUBY_GC_AUTO_COMPACT"]

# Seed the global random number generator for repeatability between runs
Random.srand(1337)

if !Ractor.respond_to?(:make_shareable)
  class Ractor
    #noop
    def make_shareable(obj, copy: false); obj; end
  end
end

def format_number(num)
  num.to_s.split(".").tap do |a|
    # Insert comma separators but only in the whole number portion (a[0]).
    # Look for "-?" at the end to preserve any leading minus sign that may be on the beginning.
    a[0] = a[0].reverse.scan(/\d{1,3}-?/).join(",").reverse

    # Add a space when positive so that if there is ever a negative
    # the first digit will line up.
    a[0].prepend(" ") unless a[0].start_with?("-")
  end.join(".")
end

def run_cmd(*args)
  puts "Command: #{args.join(" ")}"
  system(*args)
end

def setup_cmds(c)
  c.each do |cmd|
    success = run_cmd(cmd)
    raise "Couldn't run setup command for benchmark in #{Dir.pwd.inspect}!" unless success
  end
end

# Set up a Gemfile, install gems and do extra setup
def use_gemfile(extra_setup_cmd: nil)
  # Benchmarks should normally set their current directory and then call this method.

  setup_cmds(["bundle check 2> /dev/null || bundle install", extra_setup_cmd].compact)

  # Need to be in the appropriate directory for this...
  require "bundler"
  # Use Bundler.setup instead of require 'bundler/setup' to avoid bundler's autoswitch restarting the
  # process and messing with LOAD_PATH. Autoswitching occurs when the BUNDLED_WITH in the Gemfile.lock
  # is a different version than the loaded version of bundler. This can happen in development when
  # switching between ruby versions.
  Bundler.setup
end

# This returns its best estimate of the Resident Set Size in bytes.
# That's roughly the amount of memory the process takes, including shareable resources.
# RSS reference: https://stackoverflow.com/questions/7880784/what-is-rss-and-vsz-in-linux-memory-management
def get_rss
  mem_rollup_file = "/proc/#{Process.pid}/smaps_rollup"
  if File.exist?(mem_rollup_file)
    # First, grab a line like "62796 kB". Checking the Linux kernel source, Rss will always be in kB.
    rss_desc = File.read(mem_rollup_file).lines.detect { |line| line.start_with?("Rss") }.split(":", 2)[1][/(\d+)/, 1]
    1024 * Integer(rss_desc)
  else
    # Collect our own peak mem usage as soon as reasonable after finishing the last iteration.
    # This method is only accurate to kilobytes, but is nicely portable and doesn't require
    # any extra gems/dependencies.
    mem = `ps -o rss= -p #{Process.pid}`
    1024 * Integer(mem)
  end
end

def is_macos
  RUBY_PLATFORM.match?(/darwin/)
end

def get_maxrss
  unless $LOAD_PATH.resolve_feature_path("fiddle")
    # In Ruby 3.5+, fiddle is no longer a default gem. Load the bundled-gem fiddle instead.
    if defined?(Bundler) # benchmarks with Gemfile
      bundler_ui_level, Bundler.ui.level = Bundler.ui.level, :error if defined?(Bundler) # suppress warnings from force_activate
      Gem::BUNDLED_GEMS.force_activate("fiddle")
      Bundler.ui.level = bundler_ui_level if bundler_ui_level
    else # benchmarks without Gemfile
      gem "fiddle", ">= 1.1.8"
    end
  end
  # Suppress a warning for Ruby 3.4+ on benchmarks with Gemfile
  verbose, $VERBOSE = $VERBOSE, nil
  require 'fiddle'
  $VERBOSE = verbose

  require 'rbconfig/sizeof'

  unless Fiddle::SIZEOF_LONG == 8 and RbConfig::CONFIG["host_os"] =~ /linux|darwin/
    # The code below assumes 64-bit alignment and Linux or macOS
    return 0
  end

  libc = Fiddle.dlopen(nil)
  getrusage = Fiddle::Function.new(libc['getrusage'], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

  buffer = "\0".b * 1024 # more than enough, the actual struct is about 144 bytes
  sizeof_timeval = RbConfig::SIZEOF['time_t'] + Fiddle::SIZEOF_LONG
  offset = sizeof_timeval * 2
  rusage_self = 0
  result = getrusage.call(rusage_self, buffer)
  raise unless result.zero?
  maxrss_kb = buffer[offset, Fiddle::SIZEOF_LONG].unpack1('q')

  # On macos, this value is already in bytes
  # (and the manpage is wrong)
  if is_macos
    maxrss_kb
  else
    1024 * maxrss_kb
  end
rescue LoadError
  warn "Failed to get max RSS: #{$!.message}"
  nil
end

# Do expand_path at require-time, not when returning results, before the benchmark is likely to chdir
default_path = "data/results-#{RUBY_ENGINE}-#{RUBY_ENGINE_VERSION}-#{Time.now.strftime('%F-%H%M%S')}.json"
yb_env_var = ENV.fetch("RESULT_JSON_PATH", default_path)
YB_OUTPUT_FILE = File.expand_path yb_env_var

def return_results(warmup_iterations, bench_iterations)
  yjit_bench_results = {
    "RUBY_DESCRIPTION" => RUBY_DESCRIPTION,
    "warmup" => warmup_iterations,
    "bench" => bench_iterations,
  }

  # Collect JIT stats before loading any additional code.
  yjit_stats = RubyVM::YJIT.runtime_stats if defined?(RubyVM::YJIT.enabled?) && RubyVM::YJIT.enabled?
  zjit_stats = RubyVM::ZJIT.stats if defined?(RubyVM::ZJIT.enabled?) && RubyVM::ZJIT.enabled?

  # Collect our own peak mem usage as soon as reasonable after finishing the last iteration.
  rss = get_rss
  yjit_bench_results["rss"] = rss
  if maxrss = get_maxrss
    yjit_bench_results["maxrss"] = maxrss
  end

  # If YJIT or ZJIT is enabled, show some of its stats unless it does by itself.
  if yjit_stats && !RubyVM::YJIT.stats_enabled?
    yjit_bench_results["yjit_stats"] = yjit_stats
    stats_keys = [
      *ENV.fetch("YJIT_BENCH_STATS", "").split(",").map(&:to_sym),
      :inline_code_size,
      :outlined_code_size,
      :code_region_size,
      :yjit_alloc_size,
      :compile_time_ns,
    ].uniq
    puts "YJIT stats:"
  elsif zjit_stats && defined?(RubyVM::ZJIT.stats_enabled?) && !RubyVM::ZJIT.stats_enabled?
    yjit_bench_results["zjit_stats"] = zjit_stats
    stats_keys = [
      *ENV.fetch("ZJIT_BENCH_STATS", "").split(",").map(&:to_sym),
      :code_region_bytes,
      :zjit_alloc_bytes,
      :compile_time_ns,
      :profile_time_ns,
      :gc_time_ns,
      :invalidation_time_ns,
    ].uniq
    puts "ZJIT stats:"
  end
  if stats_keys
    jit_stats = yjit_stats || zjit_stats
    formatted_stats = proc { |key| "%11s" % format_number(jit_stats[key]) }

    stats_pads = stats_keys.map(&:size).max + 1
    stats_keys.each do |key|
      next unless jit_stats.key?(key)
      case key
      when /_time_ns\z/
        key_name = key.to_s.sub(/_time_ns\z/, '_time')
        puts "#{key_name.ljust(stats_pads)} %9.2fms" % (jit_stats[key] / 1_000_000.0).round(2)
      else
        puts "#{"#{key}:".ljust(stats_pads)} #{formatted_stats[key]}"
      end
    end
  end

  puts "RSS: %.1fMiB" % (rss / 1024.0 / 1024.0)
  if maxrss
    puts "MAXRSS: %.1fMiB" % (maxrss / 1024.0 / 1024.0)
  end

  write_json_file(yjit_bench_results)
end

def write_json_file(yjit_bench_results)
  require "json"

  out_path = YB_OUTPUT_FILE
  system('mkdir', '-p', File.dirname(out_path))

  # Using default path? Print where we put it.
  puts "Writing file #{out_path}" unless ENV["RESULT_JSON_PATH"]

  File.write(out_path, JSON.pretty_generate(yjit_bench_results))
rescue LoadError
  warn "Failed to write JSON file: #{$!.message}"
end
