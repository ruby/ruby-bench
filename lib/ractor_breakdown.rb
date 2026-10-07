# frozen_string_literal: true

module RactorBreakdown
  KEY_SEP = "\x00"
  MEASUREMENT_KEYS = %w[warmup bench bench_by_ractors gc_by_ractors].freeze
  PROCESS_KEYS = %w[rss maxrss yjit_stats zjit_stats zjit_stats_string command_line].freeze

  Result = Struct.new(:bench_data, :groups)

  module_function

  def data_key(base_name, count)
    "#{base_name}#{KEY_SEP}#{count}"
  end

  def base_name(data_key)
    data_key.split(KEY_SEP, 2).first
  end

  def merge(blobs_by_count)
    counts = blobs_by_count.keys.sort
    process_data = counts.to_h do |count|
      [count.to_s, blobs_by_count[count].reject { |k, _| MEASUREMENT_KEYS.include?(k) }]
    end
    first, *rest = process_data.values
    merged = first.select do |k, v|
      !PROCESS_KEYS.include?(k) && rest.all? { |data| data.key?(k) && data[k] == v }
    end

    merged['warmup'] = []
    merged['bench'] = counts.flat_map { |count| blobs_by_count[count]['bench'] }
    merged['bench_by_ractors'] = counts.to_h { |count| [count.to_s, blobs_by_count[count]['bench']] }
    gc_by_ractors = counts.filter_map do |count|
      group = blobs_by_count[count].dig('gc_by_ractors', count.to_s)
      [count.to_s, group] if group
    end.to_h
    merged['gc_by_ractors'] = gc_by_ractors unless gc_by_ractors.empty?
    merged['results_by_ractors'] = process_data.transform_values { |data| data.reject { |k, _| merged.key?(k) } }
    merged
  end

  def expand(bench_data)
    groups = {}
    new_data = {}

    bench_data.each do |exe, benchmarks|
      new_data[exe] = {}
      benchmarks.each do |name, blob|
        breakdown = blob.is_a?(Hash) && blob['bench_by_ractors']
        unless breakdown
          new_data[exe][name] = blob
          next
        end

        counts = breakdown.keys.map { |c| Integer(c) }.sort
        groups[name] ||= counts.map { |c| [data_key(name, c), c] }

        counts.each do |count|
          key = data_key(name, count)
          new_data[exe][key] = per_count_blob(blob, breakdown, count)
        end
      end
    end

    Result.new(new_data, groups.to_a)
  end

  def per_count_blob(blob, breakdown, count)
    per_count = blob.reject { |k, _| k == 'bench_by_ractors' || k == 'gc_by_ractors' || k == 'results_by_ractors' || k == 'bench' }
    process_data = blob['results_by_ractors']
    per_count.merge!(process_data[count.to_s]) if process_data.is_a?(Hash) && process_data.key?(count.to_s)
    per_count['bench'] = breakdown[count.to_s]
    per_count['warmup'] = []
    gc_by_ractors = blob['gc_by_ractors']
    if gc_by_ractors.is_a?(Hash) && gc_by_ractors.key?(count.to_s)
      per_count.merge!(gc_by_ractors[count.to_s])
    else
      per_count.delete('gc_scope')
    end
    per_count
  end
end
