# frozen_string_literal: true

module RactorBreakdown
  KEY_SEP = "\x00"
  COUNT_KEYED_KEYS = %w[gc_by_ractors ractor_mem_medians ractor_mem_samples].freeze
  MEASUREMENT_KEYS = (%w[warmup bench bench_by_ractors] + COUNT_KEYED_KEYS).freeze
  PROCESS_KEYS = %w[rss maxrss yjit_stats zjit_stats zjit_stats_string command_line ractor_mem_base_rss].freeze

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
    COUNT_KEYED_KEYS.each do |key|
      by_count = counts.filter_map do |count|
        entry = blobs_by_count[count].dig(key, count.to_s)
        [count.to_s, entry] if entry
      end.to_h
      merged[key] = by_count unless by_count.empty?
    end
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
    per_count = blob.reject { |k, _| k == 'bench_by_ractors' || k == 'results_by_ractors' || k == 'bench' || COUNT_KEYED_KEYS.include?(k) }
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
    (COUNT_KEYED_KEYS - ['gc_by_ractors']).each do |key|
      by_count = blob[key]
      per_count[key] = { count.to_s => by_count[count.to_s] } if by_count.is_a?(Hash) && by_count.key?(count.to_s)
    end
    per_count
  end
end
