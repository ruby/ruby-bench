# frozen_string_literal: true

module RactorBreakdown
  KEY_SEP = "\x00"

  Result = Struct.new(:bench_data, :groups)

  module_function

  def data_key(base_name, count)
    "#{base_name}#{KEY_SEP}#{count}"
  end

  def base_name(data_key)
    data_key.split(KEY_SEP, 2).first
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
    per_count = blob.reject { |k, _| k == 'bench_by_ractors' || k == 'bench' }
    per_count['bench'] = breakdown[count.to_s]
    per_count['warmup'] = []
    per_count
  end
end
