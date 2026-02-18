require_relative '../misc/stats'
require 'yaml'

class ResultsTableBuilder
  SECONDS_TO_MS = 1000.0
  BYTES_TO_MIB = 1024.0 * 1024.0

  def initialize(executable_names:, bench_data:, include_rss: false, include_pvalue: false)
    @executable_names = executable_names
    @bench_data = bench_data
    @include_rss = include_rss
    @include_pvalue = include_pvalue
    @base_name = executable_names.first
    @other_names = executable_names[1..]
    @bench_names = compute_bench_names
  end

  def build
    table = [build_header]
    format = build_format

    @bench_names.each do |bench_name|
      next unless has_complete_data?(bench_name)

      row = build_row(bench_name)
      table << row
    end

    [table, format]
  end

  private

  def has_complete_data?(bench_name)
    @bench_data.all? { |(_k, v)| v[bench_name] }
  end

  def build_header
    header = ["bench"]

    @executable_names.each do |name|
      header << "#{name} (ms)"
      header << "RSS (MiB)" if @include_rss
    end

    @other_names.each do |name|
      header << "#{name} 1st itr"
    end

    @other_names.each do |name|
      header << "#{@base_name}/#{name}"
      if @include_pvalue
        header << "p-value" << "sig"
      end
    end

    if @include_rss
      @other_names.each do |name|
        header << "RSS #{@base_name}/#{name}"
      end
    end

    header
  end

  def build_format
    format = ["%s"]

    @executable_names.each do |_name|
      format << "%s"
      format << "%.1f" if @include_rss
    end

    @other_names.each do |_name|
      format << "%.3f"
    end

    @other_names.each do |_name|
      format << "%s"
      if @include_pvalue
        format << "%s" << "%s"
      end
    end

    if @include_rss
      @other_names.each do |_name|
        format << "%.3f"
      end
    end

    format
  end

  def build_row(bench_name)
    t0s = extract_first_iteration_times(bench_name)
    times_no_warmup = extract_benchmark_times(bench_name)
    rsss = extract_rss_values(bench_name)

    base_t0, *other_t0s = t0s
    base_t, *other_ts = times_no_warmup
    base_rss, *other_rsss = rsss

    row = [bench_name]
    build_base_columns(row, base_t, base_rss)
    build_comparison_columns(row, other_ts, other_rsss)
    build_ratio_columns(row, base_t0, other_t0s, base_t, other_ts)
    build_rss_ratio_columns(row, base_rss, other_rsss)

    row
  end

  def build_base_columns(row, base_t, base_rss)
    row << format_time_with_stddev(base_t)
    row << base_rss if @include_rss
  end

  def build_comparison_columns(row, other_ts, other_rsss)
    other_ts.zip(other_rsss).each do |other_t, other_rss|
      row << format_time_with_stddev(other_t)
      row << other_rss if @include_rss
    end
  end

  def format_time_with_stddev(values)
    "%.1f ± %.1f%%" % [mean(values), stddev_percent(values)]
  end

  def build_ratio_columns(row, base_t0, other_t0s, base_t, other_ts)
    ratio_1sts = other_t0s.map { |other_t0| base_t0 / other_t0 }
    row.concat(ratio_1sts)

    other_ts.each do |other_t|
      pval = Stats.welch_p_value(base_t, other_t)
      row << format_ratio(mean(base_t) / mean(other_t), pval)
      if @include_pvalue
        row << format_p_value(pval)
        row << significance_level(pval)
      end
    end
  end

  def build_rss_ratio_columns(row, base_rss, other_rsss)
    return unless @include_rss

    other_rsss.each do |other_rss|
      row << base_rss / other_rss
    end
  end

  def format_ratio(ratio, pval)
    sym = significance_symbol(pval)
    formatted = "%.3f" % ratio
    suffix = sym.empty? ? "" : " (#{sym})"
    (formatted + suffix).ljust(formatted.length + 6)
  end

  def format_p_value(pval)
    return "N/A" if pval.nil?

    if pval >= 0.001
      "%.3f" % pval
    else
      "%.1e" % pval
    end
  end

  def significance_symbol(pval)
    return "" if pval.nil?

    if pval < 0.001
      "***"
    elsif pval < 0.01
      "**"
    elsif pval < 0.05
      "*"
    else
      ""
    end
  end

  def significance_level(pval)
    return "" if pval.nil?

    if pval < 0.001
      "p < 0.001"
    elsif pval < 0.01
      "p < 0.01"
    elsif pval < 0.05
      "p < 0.05"
    else
      ""
    end
  end

  def extract_first_iteration_times(bench_name)
    @executable_names.map do |name|
      data = bench_data_for(name, bench_name)
      (data['warmup'][0] || data['bench'][0]) * SECONDS_TO_MS
    end
  end

  def extract_benchmark_times(bench_name)
    @executable_names.map do |name|
      bench_data_for(name, bench_name)['bench'].map { |v| v * SECONDS_TO_MS }
    end
  end

  def extract_rss_values(bench_name)
    @executable_names.map do |name|
      bench_data_for(name, bench_name)['rss'] / BYTES_TO_MIB
    end
  end

  def bench_data_for(name, bench_name)
    @bench_data[name][bench_name]
  end

  def mean(values)
    Stats.new(values).mean
  end

  def stddev(values)
    Stats.new(values).stddev
  end

  def stddev_percent(values)
    100 * stddev(values) / mean(values)
  end

  def compute_bench_names
    benchmarks_metadata = YAML.load_file('benchmarks.yml')
    sort_benchmarks(all_benchmark_names, benchmarks_metadata)
  end

  def all_benchmark_names
    @bench_data.values.flat_map(&:keys).uniq
  end

  # Sort benchmarks with headlines first, then others, then micro
  def sort_benchmarks(bench_names, metadata)
    bench_names.sort_by { |name| [category_priority(name, metadata), name] }
  end

  def category_priority(bench_name, metadata)
    category = metadata.dig(bench_name, 'category') || 'other'
    case category
    when 'headline' then 0
    when 'micro' then 2
    else 1
    end
  end
end
