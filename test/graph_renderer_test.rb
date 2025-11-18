require_relative 'test_helper'
require_relative '../lib/graph_renderer'
require 'tempfile'
require 'tmpdir'
require 'json'

describe GraphRenderer do
  describe '.render' do
    it 'creates a PNG file from JSON data' do
      Dir.mktmpdir do |dir|
        json_path = File.join(dir, 'test.json')
        png_path = File.join(dir, 'test.png')

        # Create test JSON file with minimal benchmark data
        json_data = {
          metadata: {
            'ruby-a' => 'version A'
          },
          raw_data: {
            'ruby-a' => {
              'bench1' => {
                'bench' => [1.0, 1.1, 0.9]
              }
            }
          }
        }
        File.write(json_path, JSON.generate(json_data))

        result = GraphRenderer.render(json_path, png_path)

        assert_equal png_path, result
        assert File.exist?(png_path), 'PNG file should be created'
        assert File.size(png_path) > 0, 'PNG file should not be empty'
      end
    end

    it 'returns the png_path' do
      Dir.mktmpdir do |dir|
        json_path = File.join(dir, 'test.json')
        png_path = File.join(dir, 'test.png')

        json_data = {
          metadata: { 'ruby-a' => 'version A' },
          raw_data: { 'ruby-a' => { 'bench1' => { 'bench' => [1.0] } } }
        }
        File.write(json_path, JSON.generate(json_data))

        result = GraphRenderer.render(json_path, png_path)

        assert_equal png_path, result
      end
    end

    it 'handles multiple rubies and benchmarks' do
      Dir.mktmpdir do |dir|
        json_path = File.join(dir, 'test.json')
        png_path = File.join(dir, 'test.png')

        json_data = {
          metadata: {
            'ruby-a' => 'version A',
            'ruby-b' => 'version B'
          },
          raw_data: {
            'ruby-a' => {
              'bench1' => { 'bench' => [1.0, 1.1] },
              'bench2' => { 'bench' => [2.0, 2.1] }
            },
            'ruby-b' => {
              'bench1' => { 'bench' => [0.9, 1.0] },
              'bench2' => { 'bench' => [1.8, 1.9] }
            }
          }
        }
        File.write(json_path, JSON.generate(json_data))

        GraphRenderer.render(json_path, png_path)

        assert File.exist?(png_path)
        assert File.size(png_path) > 0
      end
    end
  end
end
