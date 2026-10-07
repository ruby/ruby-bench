require_relative '../misc/stats'
require_relative 'row_layout'
require 'yaml'

class ResultsTableBuilder
  SECONDS_TO_MS = 1000.0
  BYTES_TO_MIB = 1024.0 * 1024.0

  attr_reader :bench_names

  def initialize(executable_names:, bench_data:, include_rss: false, include_pvalue: false, zjit_stats: [], row_layout: FlatRowLayout.new)
    @executable_names = executable_names
    @bench_data = bench_data
    @include_rss = include_rss
    @include_pvalue = include_pvalue
    @zjit_stats = zjit_stats || []
    @include_gc = detect_gc_data(bench_data)
    @rss_has_samples = @include_rss && detect_rss_samples(bench_data)
    @base_name = executable_names.first
    @other_names = executable_names[1..]
    @row_layout = row_layout
    @bench_names = compute_bench_names
  end

  def include_gc?
    @include_gc
  end

  def self.ractor_gc_data?(bench_data)
    bench_data.values.any? do |benchmarks|
      benchmarks.values.any? { |d| d.is_a?(Hash) && d['gc_scope'] == 'ractor-local-workload' }
    end
  end

  def build
    table = [build_header]
    format = build_format

    @row_layout.entries(@bench_names).each do |entry|
      next unless has_complete_data?(entry.data_key)

      table << (entry.label_cells + build_stat_cells(entry.data_key))
    end

    [table, format, build_gc_tables]
  end

  private

  def has_complete_data?(bench_name)
    @bench_data.all? { |(_k, v)| v[bench_name] }
  end

  def build_header
    header = ["bench", *@row_layout.extra_header_columns]

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
    format = ["%s", *@row_layout.extra_format_columns]

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

  GC_SERIES_KEYS = %w[
    gc_count_bench
    gc_major_count_bench
    gc_minor_count_bench
    gc_marking_time_bench
    gc_sweeping_time_bench
    gc_total_time_bench
    gc_global_count_bench
    gc_controller_compact_count_bench
  ].freeze

  def build_gc_tables
    return nil unless @include_gc

    label_header = ["bench", *@row_layout.extra_header_columns]
    tables = @other_names.empty? ? [build_gc_absolute_table(label_header)] : build_gc_comparison_tables(label_header)
    tables.compact!
    tables.empty? ? nil : tables
  end

  def build_gc_comparison_tables(label_header)
    label_header += ["comparison"] if include_gc_comparison_name?
    rows = []
    gc_entries.each do |entry|
      series_by_exe = @executable_names.map do |name|
        data = bench_data_for(name, entry.data_key)
        {
          total: data['gc_total_time_bench'],
          mark: data['gc_marking_time_bench'],
          sweep: data['gc_sweeping_time_bench'],
          major: data['gc_major_count_bench'],
          minor: data['gc_minor_count_bench'],
          count: gc_count_series(data),
          global: data['gc_global_count_bench'],
          compact: data['gc_controller_compact_count_bench'],
        }
      end

      base, *others = series_by_exe
      others.each_with_index do |other, i|
        next unless gc_activity?(*base.values, *other.values)

        labels = gc_label_cells(entry)
        labels << @other_names[i] if include_gc_comparison_name?
        rows << [labels, [base, other]]
      end
    end

    [
      assemble_gc_table("GC time ratios", label_header, rows, gc_ratio_columns),
      assemble_gc_table("GC counts", label_header, rows, gc_count_columns),
    ]
  end

  def gc_ratio_columns
    columns = []
    if include_gc_total_time?
      columns << ["gc/iter", ->(base, other) { ratio_cell(gc_ratio(base[:total], other[:total])) }]
      columns << ["gc/GC", ->(base, other) { ratio_cell(per_gc_ratio(base, other, :total)) }]
    end
    columns << ["mark/iter", ->(base, other) { ratio_cell(gc_ratio(base[:mark], other[:mark])) }]
    columns << ["sweep/iter", ->(base, other) { ratio_cell(gc_ratio(base[:sweep], other[:sweep])) }]
    columns << ["mark/GC", ->(base, other) { ratio_cell(per_gc_ratio(base, other, :mark)) }]
    columns << ["sweep/GC", ->(base, other) { ratio_cell(per_gc_ratio(base, other, :sweep)) }]
    columns
  end

  def gc_count_columns
    columns = [
      ["GCs/iter", ->(base, other) { count_cell(base[:count], other[:count]) }],
      ["major/iter", ->(base, other) { count_cell(base[:major], other[:major]) }],
      ["minor/iter", ->(base, other) { count_cell(base[:minor], other[:minor]) }],
    ]
    if gc_series_present?('gc_global_count_bench')
      columns << ["global/iter", ->(base, other) { count_cell(base[:global], other[:global]) }]
    end
    if gc_series_present?('gc_controller_compact_count_bench')
      columns << ["compacts*", ->(base, other) { count_cell(base[:compact], other[:compact]) }]
    end
    columns << ["minor GC %", ->(base, other) { minor_percent_cell(base, other) }]
    columns
  end

  def build_gc_absolute_table(label_header)
    rows = gc_entries.filter_map do |entry|
      data = bench_data_for(@base_name, entry.data_key)
      [gc_label_cells(entry), [data]] if GC_SERIES_KEYS.any? { |key| data.key?(key) }
    end
    assemble_gc_table("GC summary", label_header, rows, gc_absolute_columns)
  end

  def gc_absolute_columns
    columns = [["GC ms/iter", ->(data) { mean_cell(data['gc_total_time_bench'], precise: true) }]]
    columns << ["GC ms/worker", ->(data) { ms_per_worker_cell(data) }] if ractor_gc_table?
    columns += [
      ["mark ms/iter", ->(data) { mean_cell(data['gc_marking_time_bench'], precise: true) }],
      ["sweep ms/iter", ->(data) { mean_cell(data['gc_sweeping_time_bench'], precise: true) }],
      ["GCs/iter", ->(data) { mean_cell(gc_count_series(data)) }],
      ["major/iter", ->(data) { mean_cell(data['gc_major_count_bench']) }],
      ["minor/iter", ->(data) { mean_cell(data['gc_minor_count_bench']) }],
    ]
    if gc_series_present?('gc_global_count_bench')
      columns << ["global/iter", ->(data) { mean_cell(data['gc_global_count_bench']) }]
    end
    if gc_series_present?('gc_controller_compact_count_bench')
      columns << ["compacts*", ->(data) { mean_cell(data['gc_controller_compact_count_bench']) }]
    end
    columns
  end

  def assemble_gc_table(name, label_header, rows, columns)
    return nil if rows.empty?

    cells = rows.map { |(_labels, args)| columns.map { |(_header, cell)| cell.call(*args) } }
    shown = columns.each_index.select { |i| cells.any? { |row_cells| row_cells[i][1] } }

    body = rows.each_with_index.map { |(labels, _args), r| labels + shown.map { |i| cells[r][i][0] } }
    {
      name: name,
      scope: ractor_gc_table? ? "worker sum" : nil,
      rows: [label_header + shown.map { |i| columns[i][0] }] + body,
      hidden: (columns.each_index.to_a - shown).map { |i| columns[i][0] },
    }
  end

  def ratio_cell(text)
    [text, text != "N/A"]
  end

  def count_cell(base, other)
    [gc_count_cell(base, other), mean_positive?(base) || mean_positive?(other)]
  end

  def minor_percent_cell(base, other)
    data = [gc_minor_percent(base[:minor], base[:count]), gc_minor_percent(other[:minor], other[:count])].any? { |pct| pct&.positive? }
    [gc_minor_percent_cell(base, other), data]
  end

  def mean_cell(values, precise: false)
    text = precise ? format_gc_series_mean_precise(values) : format_gc_series_mean(values)
    [text, mean_positive?(values)]
  end

  def ms_per_worker_cell(data)
    text = gc_ms_per_worker_cell(data['gc_total_time_bench'], data['gc_worker_samples'])
    [text, text != "N/A" && mean_positive?(data['gc_total_time_bench'])]
  end

  def mean_positive?(values)
    numeric_series?(values) && mean(values) > 0.0
  end

  def per_gc_ratio(base, other, key)
    scalar_ratio(gc_time_per_gc(base[key], base[:count]), gc_time_per_gc(other[key], other[:count]))
  end

  def gc_series_present?(key)
    @gc_series_present ||= {}
    unless @gc_series_present.key?(key)
      @gc_series_present[key] = @bench_data.values.any? do |benchmarks|
        benchmarks.values.any? { |d| d.is_a?(Hash) && d.key?(key) }
      end
    end
    @gc_series_present[key]
  end

  def ractor_gc_table?
    return @ractor_gc_table if defined?(@ractor_gc_table)

    @ractor_gc_table = ResultsTableBuilder.ractor_gc_data?(@bench_data)
  end

  def gc_entries
    @row_layout.entries(@bench_names).select { |entry| has_complete_data?(entry.data_key) }
  end

  def gc_label_cells(entry)
    [@row_layout.base_name(entry.data_key), *entry.label_cells.drop(1)]
  end

  def include_gc_total_time?
    return @include_gc_total_time if defined?(@include_gc_total_time)

    @include_gc_total_time = @bench_data.values.any? do |benchmarks|
      benchmarks.values.any? { |d| d.is_a?(Hash) && d.key?('gc_total_time_bench') }
    end
  end

  def build_stat_cells(bench_name)
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

    row = []
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

  def numeric_series?(values)
    values.is_a?(Array) && !values.empty? && values.all? { |v| v.is_a?(Numeric) }
  end

  def gc_count_series(data)
    return data['gc_count_bench'] if data.key?('gc_count_bench')

    major = data['gc_major_count_bench']
    minor = data['gc_minor_count_bench']
    return nil unless numeric_series?(major) && numeric_series?(minor) && major.length == minor.length

    major.zip(minor).map { |a, b| a + b }
  end

  def gc_time_per_gc(time, count)
    return nil unless numeric_series?(time) && numeric_series?(count) && time.length == count.length

    count_mean = mean(count)
    return nil if count_mean == 0.0

    mean(time) / count_mean
  end

  def gc_activity?(*series)
    series.any? do |values|
      values.is_a?(Array) && values.any? { |v| v.is_a?(Numeric) && v > 0.0 }
    end
  end

  def gc_ms_per_worker_cell(totals, worker_samples)
    return "N/A" unless totals.is_a?(Array) && worker_samples.is_a?(Array) && totals.length == worker_samples.length

    pairs = totals.zip(worker_samples)
    return "N/A" unless pairs.all? { |total, workers| total.is_a?(Numeric) && workers.is_a?(Array) && !workers.empty? }

    "%.3f" % mean(pairs.map { |total, workers| total.fdiv(workers.length) })
  end

  def gc_count_cell(base, other)
    "%4s  →  %4s" % [format_gc_series_mean(base), format_gc_series_mean(other)]
  end

  def gc_minor_percent_cell(base, other)
    "%4s  →  %4s" % [
      format_gc_percent(gc_minor_percent(base[:minor], base[:count])),
      format_gc_percent(gc_minor_percent(other[:minor], other[:count]))
    ]
  end

  def gc_minor_percent(minor, count)
    return nil unless numeric_series?(minor) && numeric_series?(count) && minor.length == count.length

    total = count.sum
    return nil if total == 0.0

    minor.sum.to_f / total
  end

  def format_gc_series_mean(values)
    return "N/A" unless numeric_series?(values)

    "%.1f" % mean(values)
  end

  def format_gc_percent(value)
    return "N/A" if value.nil?

    "%.0f%%" % (100.0 * value)
  end

  def format_gc_series_mean_precise(values)
    return "N/A" unless numeric_series?(values)

    "%.3f" % mean(values)
  end

  def scalar_ratio(base, other)
    return "N/A" if base.nil? || other.nil? || other == 0.0

    format_ratio(base / other, nil)
  end

  def gc_ratio(base, other)
    return "N/A" unless numeric_series?(base) && numeric_series?(other)
    return "N/A" if mean(other) == 0.0

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

  def detect_gc_data(bench_data)
    bench_data.values.any? do |benchmarks|
      benchmarks.values.any? { |d| d.is_a?(Hash) && GC_SERIES_KEYS.any? { |key| d.key?(key) } }
    end
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
    category = metadata.dig(@row_layout.base_name(bench_name), 'category') || 'other'
    case category
    when 'headline' then 0
    when 'micro' then 2
    else 1
    end
  end
end
