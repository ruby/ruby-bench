require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

# Based on https://github.com/wvanbergen/chunky_png/blob/master/benchmarks/
require "chunky_png"

image = ChunkyPNG::Image.new(240, 180, ChunkyPNG::Color::TRANSPARENT)

# set some random pixels

image[10, 20] = ChunkyPNG::Color.rgba(255,   0,   0, 255)
image[50, 87] = ChunkyPNG::Color.rgba(  0, 255,   0, 255)
image[33, 99] = ChunkyPNG::Color.rgba(  0,   0, 255, 255)

run_benchmark(10) do
  10.times do |i|
    image.to_blob(:no_compression)
    image.to_blob(:fast_rgba)
    image.to_blob(:fast_rgb)
    image.to_blob(:good_compression)
    image.to_blob(:best_compression)

    image.to_blob(color_mode: ChunkyPNG::COLOR_TRUECOLOR)
    image.to_blob(color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA)
    image.to_blob(color_mode: ChunkyPNG::COLOR_INDEXED)
    image.to_blob(interlaced: true)

    image.to_rgba_stream
    image.to_rgb_stream
  end
end
