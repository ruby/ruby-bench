# frozen_string_literal: true

# A quantity measured once per benchmark iteration, and how to show and compare
# it. Results compare on wall time unless the harness reports another metric:
#
#   return_results(warmup, bench,
#                  metrics: { "name" => { "warmup" => [...], "bench" => [...] } },
#                  primary_metric: "name")
#
# with values in the metric's raw unit, one per iteration ("warmup" may be left
# out when warmup is not measured). Top-level "warmup" and "bench" stay wall time
# in seconds. Every metric is lower-is-better, so base/exp above 1 favors exp.
class Metric
  attr_reader :name, :noun, :unit, :scale, :better, :ratio_title

  # unit and scale are for display: raw value * scale is shown in unit. better
  # completes "Above 1 represents ..." and ratio_title names the graph.
  def initialize(name, noun:, unit:, scale:, better:, ratio_title:)
    @name = name
    @noun = noun
    @unit = unit
    @scale = scale
    @better = better
    @ratio_title = ratio_title
  end

  REGISTRY = {}

  def self.register(name, **options)
    REGISTRY[name] = new(name, **options)
  end

  # Metrics nobody registered still compare, shown in their raw unit.
  def self.[](name)
    REGISTRY.fetch(name) do
      new(name, noun: name, unit: name, scale: 1, better: "a lower #{name}", ratio_title: "#{name} ratio")
    end
  end

  TIME = register("time", noun: "time", unit: "ms", scale: 1000.0, better: "a speedup", ratio_title: "Speedup ratio")

  # The metric to compare results on: their primary metric when they all agree,
  # otherwise wall time, which every result has.
  def self.for(results)
    names = results.map { |data| data['primary_metric'] || TIME.name }.uniq
    names.size == 1 ? self[names.first] : TIME
  end

  # Values per measured iteration, in display units.
  def bench(data)
    series(data, 'bench')
  end

  # Values per warmup iteration, in display units, or nil if warmup was not measured.
  def warmup(data)
    series(data, 'warmup')
  end

  # The first iteration's value: the first warmup iteration, or the first
  # measured one when there was no warmup. nil if warmup was not measured.
  def first_iteration(data)
    warmup = warmup(data)
    return nil if warmup.nil?

    warmup.first || bench(data).first
  end

  private

  def series(data, key)
    values = name == TIME.name ? data[key] : data.dig('metrics', name, key)
    values&.map { |value| value * scale }
  end
end
