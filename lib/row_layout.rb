# frozen_string_literal: true

require_relative 'ractor_breakdown'

Entry = Struct.new(:data_key, :label_cells, keyword_init: true)

class FlatRowLayout
  def extra_header_columns = []
  def extra_format_columns = []

  def entries(bench_names)
    bench_names.map { |name| Entry.new(data_key: name, label_cells: [name]) }
  end

  def base_name(data_key) = data_key
end

class RactorRowLayout
  # groups :: [[base_name, [[data_key, count_int], ...]], ...]
  def initialize(groups:)
    @groups_by_base_name = groups.to_h
  end

  def extra_header_columns = ['ractors']
  def extra_format_columns = ['%s']

  def entries(bench_names)
    seen = {}
    bench_names.flat_map do |data_key|
      base_name = base_name(data_key)
      next [] if seen[base_name]

      seen[base_name] = true
      members = @groups_by_base_name[base_name]
      next [] unless members

      members.each_with_index.map do |(member_key, count), i|
        name_cell = i.zero? ? base_name : ''
        Entry.new(data_key: member_key, label_cells: [name_cell, count.to_s])
      end
    end
  end

  def base_name(data_key) = RactorBreakdown.base_name(data_key)
end
