#!/usr/bin/env ruby

require_relative '../lib/graph_renderer'

# Standalone command-line interface for rendering graphs
if __FILE__ == $0
  require 'optparse'

  args = {}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options] JSON_PATH"
    opts.on('--title SIZE', 'title font size') do |v|
      args[:title_font_size] = v.to_f
    end
    opts.on('--legend SIZE', 'legend font size') do |v|
      args[:legend_font_size] = v.to_f
    end
    opts.on('--marker SIZE', 'marker font size') do |v|
      args[:marker_font_size] = v.to_f
    end
  end
  parser.parse!

  json_path = ARGV.first
  abort parser.help if json_path.nil?

  png_path = json_path.sub(/\.json\z/, '.png')
  GraphRenderer.render(json_path, png_path, **args)

  open = %w[open xdg-open].find { |open| system("which #{open} >/dev/null 2>/dev/null") }
  system(open, png_path) if open
end
