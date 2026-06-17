require_relative '../misc/stats'
require 'yaml'

class ResultsTableBuilder
  SECONDS_TO_MS = 1000.0
  BYTES_TO_MIB = 1024.0 * 1024.0

  def initialize(executable_names:, bench_data:, include_rss: false, include_pvalue: false, zjit_stats: [])
    @executable_names = executable_names
    @bench_data = bench_data
    @include_rss = include_rss
    @include_pvalue = include_pvalue
    @zjit_stats = zjit_stats || []
    @include_gc = detect_gc_data(bench_data)
    @rss_has_samples = @include_rss && detect_rss_samples(bench_data)
    @base_name = executable_names.first
    @other_names = executable_names[1..]
    @bench_names = compute_bench_names
  end

  def include_gc?
    @include_gc
  end

  def build
    table = [build_header]
    format = build_format

    @bench_names.each do |bench_name|
      next unless has_complete_data?(bench_name)

      row = build_row(bench_name)
      table << row
    end

    gc_table = build_gc_summary_table

    [table, format, gc_table, build_gc_summary_format(gc_table)]
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
      @zjit_stats.each { |stat| header << stat }
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
      format << (@rss_has_samples ? "%s" : "%.1f") if @include_rss
      @zjit_stats.each { format << "%s" }
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

  def build_gc_summary_table
    return nil unless @include_gc && !@other_names.empty?

    rows = [["bench", *(["comparison"] if include_gc_comparison_name?), "mark/iter ratio", "sweep/iter ratio", "mark/GC ratio", "sweep/GC ratio", "major/iter", "minor/iter", "minor GC %"]]

    @bench_names.each do |bench_name|
      next unless has_complete_data?(bench_name)

      marking_times = extract_gc_times(bench_name, 'gc_marking_time_bench')
      sweeping_times = extract_gc_times(bench_name, 'gc_sweeping_time_bench')
      major_counts = extract_gc_times(bench_name, 'gc_major_count_bench')
      minor_counts = extract_gc_times(bench_name, 'gc_minor_count_bench')
      base_mark, *other_marks = marking_times
      base_sweep, *other_sweeps = sweeping_times
      base_major, *other_majors = major_counts
      base_minor, *other_minors = minor_counts

      @other_names.each_with_index do |name, i|
        next unless gc_activity?(base_mark, other_marks[i], base_sweep, other_sweeps[i], base_major, other_majors[i], base_minor, other_minors[i])

        rows << gc_summary_row(bench_name, name, base_mark, other_marks[i], base_sweep, other_sweeps[i], base_major, other_majors[i], base_minor, other_minors[i])
      end
    end

    rows.size == 1 ? nil : rows
  end

  def build_gc_summary_format(gc_table)
    return nil unless gc_table

    Array.new(gc_table.first.size, "%s")
  end

  def build_row(bench_name)
    t0s = extract_first_iteration_times(bench_name)
    times_no_warmup = extract_benchmark_times(bench_name)
    rsss = extract_rss_values(bench_name)
    rss_series = @rss_has_samples ? extract_rss_series(bench_name) : nil

    base_t0, *other_t0s = t0s
    base_t, *other_ts = times_no_warmup
    base_rss, *other_rsss = rsss

    base_rss_cell = rss_cell(base_rss, rss_series && rss_series[0])
    other_rss_cells = other_rsss.each_index.map { |i| rss_cell(other_rsss[i], rss_series && rss_series[i + 1]) }

    # Extract zjit stats: { stat_name => [base_val, other1_val, ...] }
    zjit_stat_values = @zjit_stats.map do |stat|
      [stat, extract_zjit_stat(bench_name, stat)]
    end

    row = [bench_name]
    build_base_columns(row, base_t, base_rss_cell, zjit_stat_values, 0)
    build_comparison_columns(row, other_ts, other_rss_cells, zjit_stat_values)
    build_ratio_columns(row, base_t0, other_t0s, base_t, other_ts)
    build_rss_ratio_columns(row, base_rss, other_rsss)

    row
  end

  def build_base_columns(row, base_t, base_rss, zjit_stat_values, exe_index)
    row << format_time_with_stddev(base_t)
    row << base_rss if @include_rss
    zjit_stat_values.each { |_stat, values| row << format_stat(values[exe_index]) }
  end

  def build_comparison_columns(row, other_ts, other_rss_cells, zjit_stat_values)
    other_ts.each_with_index do |other_t, i|
      row << format_time_with_stddev(other_t)
      row << other_rss_cells[i] if @include_rss
      zjit_stat_values.each { |_stat, values| row << format_stat(values[i + 1]) }
    end
  end

  def format_stat(value)
    return "N/A" if value.nil?
    value.to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\1,')
  end

  def format_time_with_stddev(values)
    return "N/A" if values.nil? || values.empty?
    "%.1f ± %.1f%%" % [mean(values), stddev_percent(values)]
  end

  def build_ratio_columns(row, base_t0, other_t0s, base_t, other_ts)
    ratio_1sts = other_t0s.map { |other_t0| base_t0 / other_t0 }
    row.concat(ratio_1sts)

    other_ts.each do |other_t|
      pval = @include_pvalue ? Stats.welch_p_value(base_t, other_t) : nil
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

  def include_gc_comparison_name?
    @other_names.size > 1
  end

  def gc_summary_row(bench_name, name, base_mark, other_mark, base_sweep, other_sweep, base_major, other_major, base_minor, other_minor)
    row = [bench_name]
    row << name if include_gc_comparison_name?
    row.concat([
      gc_ratio(base_mark, other_mark),
      gc_ratio(base_sweep, other_sweep),
      scalar_ratio(gc_time_per_gc(base_mark, base_major, base_minor), gc_time_per_gc(other_mark, other_major, other_minor)),
      scalar_ratio(gc_time_per_gc(base_sweep, base_major, base_minor), gc_time_per_gc(other_sweep, other_major, other_minor)),
      gc_count_cell(base_major, other_major),
      gc_count_cell(base_minor, other_minor),
      gc_minor_percent_cell(base_major, base_minor, other_major, other_minor),
    ])
    row
  end

  def gc_time_per_gc(time, major, minor)
    return nil if time.nil? || time.empty? || major.nil? || major.empty? || minor.nil? || minor.empty?

    count = mean(major) + mean(minor)
    return nil if count == 0.0

    mean(time) / count
  end

  def gc_activity?(*series)
    series.any? { |values| values && values.sum > 0.0 }
  end

  def gc_count_cell(base, other)
    "%4s  →  %4s" % [format_gc_series_mean(base), format_gc_series_mean(other)]
  end

  def gc_minor_percent_cell(base_major, base_minor, other_major, other_minor)
    "%4s  →  %4s" % [format_gc_percent(gc_minor_percent(base_major, base_minor)), format_gc_percent(gc_minor_percent(other_major, other_minor))]
  end

  def gc_minor_percent(major, minor)
    return nil if major.nil? || major.empty? || minor.nil? || minor.empty?

    total = major.sum + minor.sum
    return nil if total == 0.0

    minor.sum.to_f / total
  end

  def format_gc_series_mean(values)
    return "N/A" if values.nil? || values.empty?

    "%.1f" % mean(values)
  end

  def format_gc_scalar(value)
    return "N/A" if value.nil?

    "%.3f" % value
  end

  def format_gc_percent(value)
    return "N/A" if value.nil?

    "%.0f%%" % (100.0 * value)
  end

  def scalar_ratio(base, other)
    return "N/A" if base.nil? || other.nil? || other == 0.0

    format_ratio(base / other, nil)
  end

  def gc_ratio(base, other)
    if base.nil? || base.empty? || other.nil? || other.empty? ||
        mean(other) == 0.0
      return "N/A"
    end
    pval = @include_pvalue ? Stats.welch_p_value(base, other) : nil
    format_ratio(mean(base) / mean(other), pval)
  end

  def format_ratio(ratio, pval)
    sym = significance_symbol(pval)
    formatted = "%.3f" % ratio
    sym.empty? ? formatted : "#{formatted} (#{sym})"
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

  # Numeric RSS (MiB) per executable, used for the RSS ratio. When per-iteration
  # samples are present we use their mean so the ratio matches the displayed value.
  def extract_rss_values(bench_name)
    @executable_names.map do |name|
      data = bench_data_for(name, bench_name)
      samples = data['rss_samples']
      if samples.is_a?(Array) && !samples.empty?
        mean(samples) / BYTES_TO_MIB
      else
        data['rss'] / BYTES_TO_MIB
      end
    end
  end

  # Per-iteration RSS samples (MiB) per executable, or nil when a run lacks them.
  def extract_rss_series(bench_name)
    @executable_names.map do |name|
      samples = bench_data_for(name, bench_name)['rss_samples']
      next nil unless samples.is_a?(Array) && !samples.empty?
      samples.map { |bytes| bytes / BYTES_TO_MIB }
    end
  end

  # Display value for an RSS column: mean ± stddev% when samples exist (matching
  # the timing columns), otherwise a plain MiB value. Returns a Float when no run
  # in the suite has samples, preserving the legacy "%.1f" formatting.
  def rss_cell(mean_value, series)
    return mean_value unless @rss_has_samples
    if series && !series.empty?
      format_time_with_stddev(series)
    else
      "%.1f" % mean_value
    end
  end

  def extract_zjit_stat(bench_name, key)
    @executable_names.map do |name|
      bench_data_for(name, bench_name).dig('zjit_stats', key)
    end
  end

  def extract_gc_times(bench_name, key)
    @executable_names.map do |name|
      bench_data_for(name, bench_name)[key] || []
    end
  end

  def detect_gc_data(bench_data)
    bench_data.values.any? { |benchmarks| benchmarks.values.any? { |d| d.is_a?(Hash) && d.key?('gc_marking_time_bench') } }
  end

  def detect_rss_samples(bench_data)
    bench_data.values.any? do |benchmarks|
      benchmarks.values.any? { |d| d.is_a?(Hash) && d['rss_samples'].is_a?(Array) && !d['rss_samples'].empty? }
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
    values_mean = mean(values)
    return 0.0 if values_mean == 0.0

    100 * stddev(values) / values_mean
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
