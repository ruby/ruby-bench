#!/usr/bin/env ruby
# frozen_string_literal: true

# First argument is the json output file created by run_benchmarks.rb:
#   misc/zjit_diff.rb data/output_001.json
# By default some categories limit how many entries are shown
# and some results only appear when the comparison passes a threshold.
# Pass --help to see options.

require 'json'

class ZjitDiff
  DEFAULT_THRESHOLD_PCT = 5.0   # Percentage change to highlight
  DEFAULT_MINIMUM_DIFF = 100    # Minimum absolute difference to report
  DEFAULT_LIMIT = nil           # Show all by default (nil = no limit)

  # Categories matching zjit.rb stats_string output order
  STAT_CATEGORIES = [
    { prefix: 'not_inlined_cfuncs_', prompt: 'not inlined C methods', limit: 10 },
    { prefix: 'ccall_', prompt: 'calls to C functions from JIT code', limit: 10 },
    { prefix: 'unspecialized_send_def_type_', prompt: 'not optimized method types for send' },
    { prefix: 'unspecialized_send_without_block_def_type_', prompt: 'not optimized method types for send_without_block' },
    { prefix: 'unspecialized_super_def_type_', prompt: 'not optimized method types for super' },
    { prefix: 'uncategorized_fallback_yarv_insn_', prompt: 'instructions with uncategorized fallback reason' },
    { prefix: 'send_fallback_', prompt: 'send fallback reasons' },
    { prefix: 'setivar_fallback_', prompt: 'setivar fallback reasons' },
    { prefix: 'getivar_fallback_', prompt: 'getivar fallback reasons' },
    { prefix: 'definedivar_fallback_', prompt: 'definedivar fallback reasons' },
    { prefix: 'invokeblock_handler_', prompt: 'invokeblock handler' },
    { prefix: 'getblockparamproxy_handler_', prompt: 'getblockparamproxy handler' },
    { prefix: 'complex_arg_pass_', prompt: 'complex argument-parameter features' },
    { prefix: 'compile_error_', prompt: 'compile error reasons' },
    { prefix: 'unhandled_yarv_insn_', prompt: 'unhandled YARV insns' },
    { prefix: 'unhandled_hir_insn_', prompt: 'unhandled HIR insns' },
    { prefix: 'exit_', prompt: 'side exit reasons' },
    { prefix: 'not_annotated_cfuncs_', prompt: 'not annotated C methods', limit: 10 },
  ].freeze

  SEND_COUNTERS = %i[
    send_count
    dynamic_send_count
    optimized_send_count
    dynamic_setivar_count
    dynamic_getivar_count
    dynamic_definedivar_count
    iseq_optimized_send_count
    inline_cfunc_optimized_send_count
    inline_iseq_optimized_send_count
    non_variadic_cfunc_optimized_send_count
    variadic_cfunc_optimized_send_count
  ].freeze

  SUMMARY_COUNTERS = %i[
    compiled_iseq_count
    failed_iseq_count
    compile_time_ns
    profile_time_ns
    gc_time_ns
    invalidation_time_ns
    vm_write_pc_count
    vm_write_sp_count
    vm_write_locals_count
    vm_write_stack_count
    vm_write_to_parent_iseq_local_count
    vm_read_from_parent_iseq_local_count
    guard_type_count
    guard_shape_count
    code_region_bytes
    zjit_alloc_bytes
    total_mem_bytes
    side_exit_count
    total_insn_count
    vm_insn_count
    zjit_insn_count
    ratio_in_zjit
  ].freeze

  def initialize(path, threshold_pct: DEFAULT_THRESHOLD_PCT, minimum_diff: DEFAULT_MINIMUM_DIFF, limit: DEFAULT_LIMIT, benchmarks: nil)
    @data = JSON.parse(File.read(path))
    @metadata = @data['metadata']
    @raw_data = @data['raw_data']
    @ruby_names = @raw_data.keys
    @threshold_pct = threshold_pct
    @minimum_diff = minimum_diff
    @limit = limit
    @benchmark_filter = benchmarks
    normalize_zjit_stats!
  end

  def run
    if @ruby_names.size < 2
      puts "Need at least 2 Ruby builds to compare"
      exit 1
    end

    print_header
    print_benchmark_timings
    print_memory_usage
    print_send_counters
    print_summary_counters

    STAT_CATEGORIES.each do |cat|
      print_category_diff(cat[:prefix], cat[:prompt], @limit || cat[:limit])
    end

    print_uncategorized_stats
  end

  def known_prefixes
    @known_prefixes ||= STAT_CATEGORIES.map { |cat| cat[:prefix] }
  end

  def known_stat?(key)
    return true if SEND_COUNTERS.map(&:to_s).include?(key)
    return true if SUMMARY_COUNTERS.map(&:to_s).include?(key)
    known_prefixes.any? { |prefix| key.start_with?(prefix) }
  end

  def print_uncategorized_stats
    any_printed = false

    benchmarks.each do |bench_name|
      stats_by_ruby = @ruby_names.map { |r| [@raw_data.dig(r, bench_name, 'zjit_stats'), r] }
      next if stats_by_ruby.any? { |s, _| s.nil? }

      all_keys = stats_by_ruby.flat_map { |s, _| s.keys }.uniq
      unknown_keys = all_keys.select do |k|
        stats_by_ruby.any? { |s, _| s[k].is_a?(Numeric) } && !known_stat?(k)
      end

      significant = filter_significant_keys(stats_by_ruby, unknown_keys)
      next if significant.empty?

      unless any_printed
        puts "OTHER/NEW STATS (showing differences > #{@threshold_pct}%)"
        puts "-" * 80
        any_printed = true
      end

      puts "  #{bench_name}:"
      limit = @limit
      display_keys = limit ? significant[0..limit] : significant
      print_stat_comparison(stats_by_ruby, display_keys, key_width: max_key_width(display_keys))
      puts "    ... and #{significant.size - limit} more" if limit&.positive? && significant.size > limit
    end
    puts if any_printed
  end

  private

  def print_header
    puts "=" * 80
    puts "ZJIT Stats Comparison"
    puts "=" * 80
    puts
    @ruby_names.each_with_index do |name, i|
      desc = @metadata[name] || name
      baseline_note = i == 0 ? ' (baseline)' : ''
      puts "  #{name}#{baseline_note}:"
      puts "    #{desc}"
    end
    puts
  end

  def benchmarks
    @benchmarks ||= begin
      all = @raw_data.values.first.keys
      @benchmark_filter ? all & @benchmark_filter : all
    end
  end

  def print_benchmark_timings
    puts "BENCHMARK TIMINGS (lower is better)"
    puts "-" * 80

    benchmarks.each do |bench_name|
      puts "  #{bench_name}:"

      stats = @ruby_names.map do |ruby|
        times = @raw_data.dig(ruby, bench_name, 'bench') || []
        next nil if times.empty?
        { ruby: ruby, times: times, avg: times.sum / times.size, min: times.min }
      end.compact

      next if stats.empty?

      baseline = stats.first
      fastest = stats.min_by { |s| s[:avg] }

      stats.each do |s|
        diff_pct = ((s[:avg] - baseline[:avg]) / baseline[:avg] * 100)
        is_fastest = s == fastest && stats.size > 1
        marker = is_fastest ? '★' : ' '
        if s == baseline
          printf "    %-20s avg: %7.3fs  min: %7.3fs  %s (baseline)\n",
                 s[:ruby], s[:avg], s[:min], marker
        else
          slower_faster = diff_pct > 0 ? 'slower' : 'faster'
          printf "    %-20s avg: %7.3fs  min: %7.3fs  %s %+7.1f%% (%s)\n",
                 s[:ruby], s[:avg], s[:min], marker, diff_pct, slower_faster
        end
      end
    end
    puts
  end

  def print_memory_usage
    puts "MEMORY USAGE"
    puts "-" * 80

    benchmarks.each do |bench_name|
      puts "  #{bench_name}:"

      @ruby_names.each do |ruby|
        bench_data = @raw_data.dig(ruby, bench_name) || {}
        maxrss = bench_data['maxrss']
        zjit_mem = bench_data.dig('zjit_stats', 'total_mem_bytes')

        maxrss_str = maxrss ? format_bytes(maxrss) : 'N/A'
        zjit_str = zjit_mem ? format_bytes(zjit_mem) : 'N/A'

        printf "    %-20s maxrss: %10s  zjit_mem: %10s\n", ruby, maxrss_str, zjit_str
      end
    end
    puts
  end

  def print_send_counters
    any_printed = false

    benchmarks.each do |bench_name|
      stats_by_ruby = @ruby_names.map { |r| [@raw_data.dig(r, bench_name, 'zjit_stats'), r] }
      next if stats_by_ruby.any? { |s, _| s.nil? }

      keys = SEND_COUNTERS.map(&:to_s).select { |k| stats_by_ruby.any? { |s, _| s.key?(k) } }
      significant = filter_significant_keys(stats_by_ruby, keys)
      next if significant.empty?

      unless any_printed
        puts "SEND COUNTERS (showing differences > #{@threshold_pct}%)"
        puts "-" * 80
        any_printed = true
      end

      puts "  #{bench_name}:"
      print_stat_comparison(stats_by_ruby, significant, base_key: 'send_count', key_width: max_key_width(significant))
    end
    puts if any_printed
  end

  def print_summary_counters
    any_printed = false

    benchmarks.each do |bench_name|
      stats_by_ruby = @ruby_names.map { |r| [@raw_data.dig(r, bench_name, 'zjit_stats'), r] }
      next if stats_by_ruby.any? { |s, _| s.nil? }

      keys = SUMMARY_COUNTERS.map(&:to_s).select { |k| stats_by_ruby.any? { |s, _| s.key?(k) } }
      significant = filter_significant_keys(stats_by_ruby, keys)
      next if significant.empty?

      unless any_printed
        puts "SUMMARY COUNTERS (showing differences > #{@threshold_pct}%)"
        puts "-" * 80
        any_printed = true
      end

      puts "  #{bench_name}:"
      print_stat_comparison(stats_by_ruby, significant, key_width: max_key_width(significant))
    end
    puts if any_printed
  end

  MIN_KEY_WIDTH = 35

  def max_key_width(keys, strip_prefix: nil)
    width = keys.map { |k| (strip_prefix ? k.delete_prefix(strip_prefix) : k).sub(/_time_ns$/, '_time').size }.max || 0
    [MIN_KEY_WIDTH, width].max
  end

  def print_category_diff(prefix, prompt, limit = nil)
    any_printed = false

    benchmarks.each do |bench_name|
      stats_by_ruby = @ruby_names.map { |r| [@raw_data.dig(r, bench_name, 'zjit_stats'), r] }
      next if stats_by_ruby.any? { |s, _| s.nil? }

      keys = stats_by_ruby.flat_map { |s, _| s.keys }.uniq.select { |k| k.start_with?(prefix) }
      significant = filter_significant_keys(stats_by_ruby, keys)

      next if significant.empty?

      unless any_printed
        puts "#{prompt.upcase} (showing differences > #{@threshold_pct}%)"
        puts "-" * 80
        any_printed = true
      end

      puts "  #{bench_name}:"
      display_keys = limit ? significant[0..limit-1] : significant
      print_stat_comparison(stats_by_ruby, display_keys, strip_prefix: prefix, key_width: max_key_width(display_keys, strip_prefix: prefix))
      puts "    ... and #{significant.size - limit} more" if limit&.positive? && significant.size > limit
    end
    puts if any_printed
  end

  def filter_significant_keys(stats_by_ruby, keys)
    baseline_stats = stats_by_ruby.first[0]

    keys.select do |key|
      baseline_val = baseline_stats[key] || 0
      stats_by_ruby[1..].any? do |other_stats, _|
        other_val = other_stats[key] || 0
        diff = other_val - baseline_val
        next false if diff.abs <= @minimum_diff
        # If baseline is 0 and other is not, it's significant (new)
        next true if baseline_val == 0 && other_val != 0
        pct = (diff.to_f / baseline_val * 100).abs
        pct > @threshold_pct
      end
    end.sort_by do |key|
      baseline_val = baseline_stats[key] || 0
      other_val = stats_by_ruby[1][0][key] || 0
      diff = other_val - baseline_val
      # Sort "new" items (baseline 0) to the end, otherwise by percentage
      baseline_val == 0 ? 0 : -(diff.to_f / baseline_val * 100).abs
    end
  end

  def print_stat_comparison(stats_by_ruby, keys, strip_prefix: nil, base_key: nil, key_width: nil)
    baseline_stats, _ = stats_by_ruby.first
    base_val = base_key ? baseline_stats[base_key] : nil
    key_width ||= max_key_width(keys, strip_prefix: strip_prefix)

    keys.each do |key|
      baseline_val = baseline_stats[key] || 0
      display_key = strip_prefix ? key.delete_prefix(strip_prefix) : key
      display_key = display_key.sub(/_time_ns$/, '_time')

      values = stats_by_ruby.map do |s, name|
        val = s[key] || 0
        diff = val - baseline_val
        pct = baseline_val != 0 ? (diff.to_f / baseline_val * 100) : nil
        { val: val, diff: diff, pct: pct, name: name }
      end

      print "    %-*s" % [key_width, display_key]
      values.each_with_index do |v, i|
        formatted_val = format_value(key, v[:val])
        base_pct = base_val && base_val != 0 ? " (%5.1f%%)" % (100.0 * v[:val] / base_val) : ""

        if i == 0
          printf "%14s%s", formatted_val, base_pct
        else
          if v[:pct].nil?
            # baseline was 0, can't calculate percentage
            if v[:val] > 0
              printf " → %14s%s ▲    new", formatted_val, base_pct
            else
              printf " → %14s%s        ", formatted_val, base_pct
            end
          else
            marker = v[:pct].abs > @threshold_pct ? (v[:pct] > 0 ? '▲' : '▼') : ' '
            printf " → %14s%s %s%+7.1f%%", formatted_val, base_pct, marker, v[:pct]
          end
        end
      end
      puts
    end
  end

  def format_value(key, val)
    return 'N/A' if val.nil?
    if key.end_with?('_time_ns')
      "#{format_number(val / 10**6)}ms"
    elsif key == 'ratio_in_zjit'
      "%.1f%%" % val
    else
      format_number(val)
    end
  end

  def format_number(n)
    return 'N/A' if n.nil?
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
  end

  def format_bytes(bytes)
    return 'N/A' if bytes.nil?
    if bytes >= 1024 * 1024 * 1024
      format("%.1fGB", bytes.to_f / (1024 * 1024 * 1024))
    elsif bytes >= 1024 * 1024
      format("%.1fMB", bytes.to_f / (1024 * 1024))
    elsif bytes >= 1024
      format("%.1fKB", bytes.to_f / 1024)
    else
      "#{bytes}B"
    end
  end

  # Strip hex addresses from stat keys so that entries like
  # "#<Module:0x00007f1a>#foo" and "#<Module:0x00007f2b>#foo"
  # collapse into one. Numeric values are summed when keys merge.
  def normalize_zjit_stats!
    @raw_data.each_value do |benchmarks|
      benchmarks.each_value do |bench_data|
        next unless bench_data.is_a?(Hash) && bench_data['zjit_stats'].is_a?(Hash)
        stats = bench_data['zjit_stats']
        normalized = {}
        stats.each do |key, value|
          nkey = key.gsub(/0x\h+/, '0x…')
          if normalized.key?(nkey) && value.is_a?(Numeric) && normalized[nkey].is_a?(Numeric)
            normalized[nkey] += value
          else
            normalized[nkey] = value
          end
        end
        bench_data['zjit_stats'] = normalized
      end
    end
  end
end

if __FILE__ == $0
  require 'optparse'

  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options] <output.json> [benchmark ...]"

    opts.on("-t", "--threshold PCT", Float, "Percentage threshold for highlighting (default: #{ZjitDiff::DEFAULT_THRESHOLD_PCT})") do |v|
      options[:threshold_pct] = v
    end

    opts.on("-m", "--minimum DIFF", Integer, "Minimum absolute difference to report (default: #{ZjitDiff::DEFAULT_MINIMUM_DIFF})") do |v|
      options[:minimum_diff] = v
    end

    opts.on("-l", "--limit N", Integer, "Limit each category to N items") do |v|
      options[:limit] = v
    end

    opts.on("-a", "--all", "Show all stats (sets threshold and minimum to 0, no limit)") do
      options[:threshold_pct] = 0
      options[:minimum_diff] = 0
      options[:limit] = 0
    end

    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit
    end
  end.parse!

  if ARGV.empty?
    puts "Usage: #{$0} [options] <output.json> [benchmark ...]"
    puts "Use --help for options"
    exit 1
  end

  json_file = ARGV.shift
  benchmark_filter = ARGV.empty? ? nil : ARGV
  ZjitDiff.new(json_file, benchmarks: benchmark_filter, **options).run
end
