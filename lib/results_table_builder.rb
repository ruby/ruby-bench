require_relative '../misc/stats'
require 'yaml'

class ResultsTableBuilder
  SECONDS_TO_MS = 1000.0
  BYTES_TO_MIB = 1024.0 * 1024.0

  def initialize(executable_names:, bench_data:, include_rss: false)
    @executable_names = executable_names
    @bench_data = bench_data
    @include_rss = include_rss
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
      header << "#{name} (ms)" << "stddev (%)"
      header << "RSS (MiB)" if @include_rss
    end

    @other_names.each do |name|
      header << "#{name} 1st itr"
    end

    @other_names.each do |name|
      header << "#{@base_name}/#{name}"
    end

    header
  end

  def build_format
    format = ["%s"]

    @executable_names.each do |_name|
      format << "%.1f" << "%.1f"
      format << "%.1f" if @include_rss
    end

    @other_names.each do |_name|
      format << "%.3f"
    end

    @other_names.each do |_name|
      format << "%.3f"
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

    row
  end

  def build_base_columns(row, base_t, base_rss)
    row << mean(base_t)
    row << stddev_percent(base_t)
    row << base_rss if @include_rss
  end

  def build_comparison_columns(row, other_ts, other_rsss)
    other_ts.zip(other_rsss).each do |other_t, other_rss|
      row << mean(other_t)
      row << stddev_percent(other_t)
      row << other_rss if @include_rss
    end
  end

  def build_ratio_columns(row, base_t0, other_t0s, base_t, other_ts)
    ratio_1sts = other_t0s.map { |other_t0| base_t0 / other_t0 }
    ratios = other_ts.map { |other_t| mean(base_t) / mean(other_t) }
    row.concat(ratio_1sts)
    row.concat(ratios)
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
    # Get keys from all rows in case a benchmark failed for only some executables
    all_bench_names = @bench_data.map { |k, v| v.keys }.flatten.uniq
    benchmarks_metadata = YAML.load_file('benchmarks.yml')
    sort_benchmarks(all_bench_names, benchmarks_metadata)
  end

  # Sort benchmarks with headlines first, then others, then micro
  def sort_benchmarks(bench_names, metadata)
    headline_benchmarks = metadata.select { |_, meta| meta['category'] == 'headline' }.keys
    micro_benchmarks = metadata.select { |_, meta| meta['category'] == 'micro' }.keys

    headline_names, bench_names = bench_names.partition { |name| headline_benchmarks.include?(name) }
    micro_names, other_names = bench_names.partition { |name| micro_benchmarks.include?(name) }
    headline_names.sort + other_names.sort + micro_names.sort
  end
end
