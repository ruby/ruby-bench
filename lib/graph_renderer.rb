# frozen_string_literal: true

require_relative '../misc/stats'
require 'json'
begin
  require 'gruff'
rescue LoadError
  Gem.install('gruff')
  gem 'gruff'
  require 'gruff'
end

# Renders benchmark data as a graph
class GraphRenderer
  DEFAULT_WIDTH = 1600
  COLOR_PALETTE = %w[#3285e1 #489d32 #e2c13e #8A6EAF #D1695E].freeze
  THEME = {
    colors: COLOR_PALETTE,
    marker_color: '#dddddd',
    font_color: 'black',
    background_colors: 'white'
  }.freeze
  DEFAULT_BOTTOM_MARGIN = 30.0
  DEFAULT_LEGEND_MARGIN = 4.0

  def self.render(json_path, png_path, title_font_size: 16.0, legend_font_size: 12.0, marker_font_size: 10.0)
    ruby_descriptions, data, baseline, bench_names = load_benchmark_data(json_path)

    graph = Gruff::Bar.new(DEFAULT_WIDTH)
    configure_graph(graph, ruby_descriptions, bench_names, title_font_size, legend_font_size, marker_font_size)

    ruby_descriptions.each do |ruby, description|
      speedups = bench_names.map { |bench|
        baseline_times = data.fetch(baseline).fetch(bench).fetch("bench")
        times = data.fetch(ruby).fetch(bench).fetch("bench")
        Stats.new(baseline_times).mean / Stats.new(times).mean
      }
      graph.data "#{ruby}: #{description}", speedups
    end
    graph.write(png_path)
    png_path
  end

  def self.load_benchmark_data(json_path)
    json = JSON.load_file(json_path)
    ruby_descriptions = json.fetch("metadata")
    data = json.fetch("raw_data")
    baseline = ruby_descriptions.first.first
    bench_names = data.first.last.keys

    [ruby_descriptions, data, baseline, bench_names]
  end

  def self.configure_graph(graph, ruby_descriptions, bench_names, title_font_size, legend_font_size, marker_font_size)
    graph.title = "Speedup ratio relative to #{ruby_descriptions.keys.first}"
    graph.title_font_size = title_font_size
    graph.theme = THEME
    graph.labels = bench_names.map.with_index { |bench, index| [index, bench] }.to_h
    graph.show_labels_for_bar_values = true
    graph.bottom_margin = DEFAULT_BOTTOM_MARGIN
    graph.legend_margin = DEFAULT_LEGEND_MARGIN
    graph.legend_font_size = legend_font_size
    graph.marker_font_size = marker_font_size
  end
end
