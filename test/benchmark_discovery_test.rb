require_relative 'test_helper'
require_relative '../lib/benchmark_discovery'
require 'tmpdir'
require 'fileutils'

describe BenchmarkDiscovery do
  before do
    @original_dir = Dir.pwd
    @temp_dir = Dir.mktmpdir
    Dir.chdir(@temp_dir)
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(@temp_dir)
  end

  describe '#discover' do
    it 'returns empty array when directory does not exist' do
      discovery = BenchmarkDiscovery.new('nonexistent')
      entries = discovery.discover

      assert_equal [], entries
    end

    it 'returns empty array when directory is empty' do
      bench_dir = File.join(@temp_dir, 'benchmarks')
      FileUtils.mkdir_p(bench_dir)

      discovery = BenchmarkDiscovery.new(bench_dir)
      entries = discovery.discover

      assert_equal [], entries
    end

    describe 'Pattern 1: Standalone .rb files' do
      it 'discovers standalone .rb files in directory' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(bench_dir)

        # Create standalone .rb files
        File.write(File.join(bench_dir, 'fib.rb'), '# fib benchmark')
        File.write(File.join(bench_dir, 'matmul.rb'), '# matmul benchmark')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 2, entries.length

        assert_equal 'fib', entries[0].name
        assert_equal File.join(bench_dir, 'fib.rb'), entries[0].script_path

        assert_equal 'matmul', entries[1].name
        assert_equal File.join(bench_dir, 'matmul.rb'), entries[1].script_path
      end

      it 'ignores non-.rb files' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(bench_dir)

        File.write(File.join(bench_dir, 'fib.rb'), '# fib benchmark')
        File.write(File.join(bench_dir, 'README.md'), '# README')
        File.write(File.join(bench_dir, 'data.txt'), 'data')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 1, entries.length
        assert_equal 'fib', entries[0].name
      end

      it 'handles files with hyphens and underscores in names' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(bench_dir)

        File.write(File.join(bench_dir, '30k_ifelse.rb'), '# benchmark')
        File.write(File.join(bench_dir, 'ruby-xor.rb'), '# benchmark')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 2, entries.length
        assert_equal '30k_ifelse', entries[0].name
        assert_equal 'ruby-xor', entries[1].name
      end
    end

    describe 'Pattern 2: Single benchmark.rb in directory' do
      it 'discovers benchmark.rb in subdirectory' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'erubi'))

        File.write(File.join(bench_dir, 'erubi', 'benchmark.rb'), '# erubi benchmark')
        File.write(File.join(bench_dir, 'erubi', 'Gemfile'), 'source "https://rubygems.org"')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 1, entries.length
        assert_equal 'erubi', entries[0].name
        assert_equal File.join(bench_dir, 'erubi', 'benchmark.rb'), entries[0].script_path
      end

      it 'uses directory name as benchmark name' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'my-complex-benchmark'))

        File.write(File.join(bench_dir, 'my-complex-benchmark', 'benchmark.rb'), '# benchmark')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 1, entries.length
        assert_equal 'my-complex-benchmark', entries[0].name
      end

      it 'discovers multiple directories with benchmark.rb' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'erubi'))
        FileUtils.mkdir_p(File.join(bench_dir, 'liquid-render'))

        File.write(File.join(bench_dir, 'erubi', 'benchmark.rb'), '# erubi')
        File.write(File.join(bench_dir, 'liquid-render', 'benchmark.rb'), '# liquid')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 2, entries.length
        assert_equal 'erubi', entries[0].name
        assert_equal 'liquid-render', entries[1].name
      end

      it 'ignores directories without benchmark.rb' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'empty-dir'))
        FileUtils.mkdir_p(File.join(bench_dir, 'data-dir'))

        File.write(File.join(bench_dir, 'data-dir', 'data.json'), '{}')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 0, entries.length
      end
    end

    describe 'Pattern 3: Multiple .rb files in directory' do
      it 'discovers multiple .rb files in directory' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'addressable'))

        File.write(File.join(bench_dir, 'addressable', 'equality.rb'), '# equality')
        File.write(File.join(bench_dir, 'addressable', 'join.rb'), '# join')
        File.write(File.join(bench_dir, 'addressable', 'parse.rb'), '# parse')
        File.write(File.join(bench_dir, 'addressable', 'Gemfile'), 'source')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 3, entries.length

        # Results should be sorted alphabetically
        assert_equal 'addressable-equality', entries[0].name
        assert_equal File.join(bench_dir, 'addressable', 'equality.rb'), entries[0].script_path

        assert_equal 'addressable-join', entries[1].name
        assert_equal File.join(bench_dir, 'addressable', 'join.rb'), entries[1].script_path

        assert_equal 'addressable-parse', entries[2].name
        assert_equal File.join(bench_dir, 'addressable', 'parse.rb'), entries[2].script_path
      end

      it 'handles .rb files with complex names' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'test'))

        File.write(File.join(bench_dir, 'test', 'multi-word-suffix.rb'), '# test')
        File.write(File.join(bench_dir, 'test', 'with_underscore.rb'), '# test')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 2, entries.length
        assert_equal 'test-multi-word-suffix', entries[0].name
        assert_equal 'test-with_underscore', entries[1].name
      end

      it 'discovers all .rb files except benchmark.rb' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'addressable'))

        File.write(File.join(bench_dir, 'addressable', 'equality.rb'), '# benchmark')
        File.write(File.join(bench_dir, 'addressable', 'helper.rb'), '# helper')
        File.write(File.join(bench_dir, 'addressable', 'lib.rb'), '# lib')
        File.write(File.join(bench_dir, 'addressable', 'Gemfile'), 'source')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 3, entries.length
        assert_equal 'addressable-equality', entries[0].name
        assert_equal 'addressable-helper', entries[1].name
        assert_equal 'addressable-lib', entries[2].name
      end
    end

    describe 'Mixed patterns' do
      it 'discovers all three patterns together' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(bench_dir)
        FileUtils.mkdir_p(File.join(bench_dir, 'erubi'))
        FileUtils.mkdir_p(File.join(bench_dir, 'addressable'))

        # Pattern 1: Standalone files
        File.write(File.join(bench_dir, 'fib.rb'), '# fib')
        File.write(File.join(bench_dir, 'matmul.rb'), '# matmul')

        # Pattern 2: Single benchmark.rb
        File.write(File.join(bench_dir, 'erubi', 'benchmark.rb'), '# erubi')

        # Pattern 3: Multiple .rb files
        File.write(File.join(bench_dir, 'addressable', 'equality.rb'), '# eq')
        File.write(File.join(bench_dir, 'addressable', 'join.rb'), '# join')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 5, entries.length

        # Should be sorted: addressable-* comes first, then erubi, then fib, then matmul
        names = entries.map(&:name)
        assert_equal ['addressable-equality', 'addressable-join', 'erubi', 'fib', 'matmul'], names
      end

      it 'handles directories with both benchmark.rb and other .rb files' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'mixed'))

        File.write(File.join(bench_dir, 'mixed', 'benchmark.rb'), '# default')
        File.write(File.join(bench_dir, 'mixed', 'variant.rb'), '# variant')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 1, entries.length
        assert_equal 'mixed', entries[0].name
      end
    end

    describe 'Sorting' do
      it 'returns entries sorted alphabetically' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(bench_dir)

        # Create files in non-alphabetical order
        File.write(File.join(bench_dir, 'zebra.rb'), '# z')
        File.write(File.join(bench_dir, 'apple.rb'), '# a')
        File.write(File.join(bench_dir, 'monkey.rb'), '# m')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        names = entries.map(&:name)
        assert_equal ['apple', 'monkey', 'zebra'], names
      end

      it 'sorts directories and files together alphabetically' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(bench_dir)
        FileUtils.mkdir_p(File.join(bench_dir, 'bdir'))
        FileUtils.mkdir_p(File.join(bench_dir, 'ddir'))

        File.write(File.join(bench_dir, 'afile.rb'), '# a')
        File.write(File.join(bench_dir, 'cfile.rb'), '# c')
        File.write(File.join(bench_dir, 'bdir', 'benchmark.rb'), '# b')
        File.write(File.join(bench_dir, 'ddir', 'benchmark.rb'), '# d')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        names = entries.map(&:name)
        assert_equal ['afile', 'bdir', 'cfile', 'ddir'], names
      end

      it 'sorts .rb files within a directory alphabetically' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'test'))

        # Create in non-alphabetical order
        File.write(File.join(bench_dir, 'test', 'zebra.rb'), '# z')
        File.write(File.join(bench_dir, 'test', 'apple.rb'), '# a')
        File.write(File.join(bench_dir, 'test', 'monkey.rb'), '# m')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        names = entries.map(&:name)
        assert_equal ['test-apple', 'test-monkey', 'test-zebra'], names
      end
    end

    describe 'Edge cases' do
      it 'handles empty subdirectories' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'empty'))

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 0, entries.length
      end

      it 'handles deeply nested benchmark files' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        # Note: The discovery only looks one level deep
        FileUtils.mkdir_p(File.join(bench_dir, 'outer', 'inner'))

        File.write(File.join(bench_dir, 'outer', 'benchmark.rb'), '# outer')
        File.write(File.join(bench_dir, 'outer', 'inner', 'benchmark.rb'), '# inner')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        # Should only find the outer benchmark
        assert_equal 1, entries.length
        assert_equal 'outer', entries[0].name
      end

      it 'handles special characters in directory names' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(File.join(bench_dir, 'my-special_bench.mark'))

        File.write(File.join(bench_dir, 'my-special_bench.mark', 'benchmark.rb'), '# test')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 1, entries.length
        assert_equal 'my-special_bench.mark', entries[0].name
      end

      it 'returns BenchmarkEntry objects with correct attributes' do
        bench_dir = File.join(@temp_dir, 'benchmarks')
        FileUtils.mkdir_p(bench_dir)

        File.write(File.join(bench_dir, 'test.rb'), '# test')

        discovery = BenchmarkDiscovery.new(bench_dir)
        entries = discovery.discover

        assert_equal 1, entries.length

        entry = entries[0]
        assert_instance_of BenchmarkDiscovery::BenchmarkEntry, entry
        assert_respond_to entry, :name
        assert_respond_to entry, :script_path
        assert_equal 'test', entry.name
        assert_equal File.join(bench_dir, 'test.rb'), entry.script_path
      end
    end
  end

  describe 'Real-world examples' do
    it 'matches the addressable directory structure' do
      bench_dir = File.join(@temp_dir, 'benchmarks')
      FileUtils.mkdir_p(File.join(bench_dir, 'addressable'))

      # Simulate actual addressable benchmarks
      [
        'equality.rb',
        'getters.rb',
        'join.rb',
        'merge.rb',
        'new.rb',
        'normalize.rb',
        'parse.rb',
        'setters.rb',
        'to-s.rb'
      ].each do |file|
        File.write(File.join(bench_dir, 'addressable', file), '# benchmark')
      end

      File.write(File.join(bench_dir, 'addressable', 'Gemfile'), 'source')

      discovery = BenchmarkDiscovery.new(bench_dir)
      entries = discovery.discover

      assert_equal 9, entries.length

      expected_names = [
        'addressable-equality',
        'addressable-getters',
        'addressable-join',
        'addressable-merge',
        'addressable-new',
        'addressable-normalize',
        'addressable-parse',
        'addressable-setters',
        'addressable-to-s'
      ]

      assert_equal expected_names, entries.map(&:name)
    end

    it 'matches a typical benchmarks directory structure' do
      bench_dir = File.join(@temp_dir, 'benchmarks')
      FileUtils.mkdir_p(bench_dir)

      # Pattern 1: Standalone files
      File.write(File.join(bench_dir, 'fib.rb'), '# fib')
      File.write(File.join(bench_dir, '30k_ifelse.rb'), '# ifelse')

      # Pattern 2: Single benchmark.rb
      FileUtils.mkdir_p(File.join(bench_dir, 'erubi'))
      File.write(File.join(bench_dir, 'erubi', 'benchmark.rb'), '# erubi')

      FileUtils.mkdir_p(File.join(bench_dir, 'liquid-render'))
      File.write(File.join(bench_dir, 'liquid-render', 'benchmark.rb'), '# liquid')

      # Pattern 3: Multiple benchmarks
      FileUtils.mkdir_p(File.join(bench_dir, 'addressable'))
      File.write(File.join(bench_dir, 'addressable', 'parse.rb'), '# parse')
      File.write(File.join(bench_dir, 'addressable', 'join.rb'), '# join')

      discovery = BenchmarkDiscovery.new(bench_dir)
      entries = discovery.discover

      assert_equal 6, entries.length

      names = entries.map(&:name)
      assert_equal [
        '30k_ifelse',
        'addressable-join',
        'addressable-parse',
        'erubi',
        'fib',
        'liquid-render'
      ], names
    end
  end
end
