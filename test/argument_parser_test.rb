require_relative 'test_helper'
require_relative '../lib/argument_parser'
require 'tmpdir'
require 'fileutils'

describe ArgumentParser do
  before do
    @original_env = {}
    ['WARMUP_ITRS', 'MIN_BENCH_ITRS', 'MIN_BENCH_TIME', 'YJIT_BENCH_STATS',
     'ZJIT_BENCH_STATS', 'RUBIES_DIR', 'HOME'].each do |key|
      @original_env[key] = ENV[key]
    end
  end

  after do
    @original_env.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end

    if @temp_home && Dir.exist?(@temp_home)
      FileUtils.rm_rf(@temp_home)
    end
  end

  def setup_mock_ruby(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\necho 'mock ruby'\n")
    File.chmod(0755, path)
  end

  describe '#parse' do
    it 'returns default values when no arguments provided' do
      mock_ruby = '/usr/bin/ruby'
      parser = ArgumentParser.new(ruby_executable: mock_ruby)

      # Stub to return false so we get a single 'ruby' executable
      parser.stub :have_yjit?, false do
        args = parser.parse([])

        assert_equal({ 'ruby' => [mock_ruby] }, args.executables)
        assert_equal File.expand_path("./data"), args.out_path
        assert_nil args.out_override
        assert_equal "harness", args.harness
        assert_equal "", args.yjit_opts
        assert_equal [], args.categories
        assert_equal [], args.name_filters
        assert_equal false, args.rss
        assert_equal false, args.pvalue
        assert_equal false, args.interleave
        assert_equal false, args.graph
        assert_equal false, args.no_pinning
        assert_equal false, args.turbo
        assert_equal false, args.no_sudo
        assert_equal false, args.skip_yjit
      end
    end

    describe '-e option' do
      it 'parses single executable' do
        parser = ArgumentParser.new
        args = parser.parse(['-e', 'test::ruby'])

        assert_equal({ 'test' => ['ruby'] }, args.executables)
      end

      it 'parses executable with options' do
        parser = ArgumentParser.new
        args = parser.parse(['-e', 'yjit::ruby --yjit'])

        assert_equal({ 'yjit' => ['ruby', '--yjit'] }, args.executables)
      end

      it 'parses multiple executables with semicolon' do
        parser = ArgumentParser.new
        args = parser.parse(['-e', 'interp::ruby;yjit::ruby --yjit'])

        expected = {
          'interp' => ['ruby'],
          'yjit' => ['ruby', '--yjit']
        }
        assert_equal expected, args.executables
      end

      it 'allows skipping NAME:: prefix' do
        parser = ArgumentParser.new
        args = parser.parse(['-e', 'ruby'])

        assert_equal({ 'ruby' => ['ruby'] }, args.executables)
      end

      it 'parses complex options with quotes' do
        parser = ArgumentParser.new
        args = parser.parse(['-e', 'test::ruby --yjit-call-threshold=10'])

        assert_equal({ 'test' => ['ruby', '--yjit-call-threshold=10'] }, args.executables)
      end
    end

    describe '--chruby option' do
      it 'finds ruby in /opt/rubies' do
        Dir.mktmpdir do |tmpdir|
          ruby_path = File.join(tmpdir, 'opt/rubies/3.2.0/bin/ruby')
          setup_mock_ruby(ruby_path)

          parser = ArgumentParser.new
          parser.stub :chruby_search_paths, ->(version, rubies_dir) { [ruby_path] } do
            args = parser.parse(['--chruby=ruby-3.2.0::3.2.0'])

            assert_equal ruby_path, args.executables['ruby-3.2.0'].first
          end
        end
      end

      it 'finds ruby in RUBIES_DIR' do
        Dir.mktmpdir do |tmpdir|
          @temp_home = tmpdir
          rubies_dir = File.join(tmpdir, '.rubies')
          ruby_path = File.join(rubies_dir, '3.3.0/bin/ruby')
          setup_mock_ruby(ruby_path)

          ENV['HOME'] = tmpdir

          parser = ArgumentParser.new
          parser.stub :chruby_search_paths, ->(version, rd) { ["#{rd}/#{version}/bin/ruby"] } do
            args = parser.parse(['--chruby=my-ruby::3.3.0'])

            assert_equal ruby_path, args.executables['my-ruby'].first
          end
        end
      end

      it 'prefers /opt/rubies over RUBIES_DIR' do
        Dir.mktmpdir do |tmpdir|
          @temp_home = tmpdir

          opt_ruby = File.join(tmpdir, 'opt/rubies/3.2.0/bin/ruby')
          home_ruby = File.join(tmpdir, '.rubies/3.2.0/bin/ruby')
          setup_mock_ruby(opt_ruby)
          setup_mock_ruby(home_ruby)

          ENV['HOME'] = tmpdir

          parser = ArgumentParser.new
          parser.stub :chruby_search_paths, ->(version, rd) { [opt_ruby, home_ruby] } do
            args = parser.parse(['--chruby=test::3.2.0'])

            assert_equal opt_ruby, args.executables['test'].first
          end
        end
      end

      it 'uses RUBIES_DIR environment variable when set' do
        Dir.mktmpdir do |tmpdir|
          @temp_home = tmpdir
          custom_rubies = File.join(tmpdir, 'custom_rubies')
          ruby_path = File.join(custom_rubies, '3.4.0/bin/ruby')
          setup_mock_ruby(ruby_path)

          ENV['RUBIES_DIR'] = custom_rubies

          parser = ArgumentParser.new
          parser.stub :chruby_search_paths, ->(version, rd) { ["#{rd}/#{version}/bin/ruby"] } do
            args = parser.parse(['--chruby=custom::3.4.0'])

            assert_equal ruby_path, args.executables['custom'].first
          end
        end
      end

      it 'aborts when ruby version not found' do
        Dir.mktmpdir do |tmpdir|
          @temp_home = tmpdir
          ENV['HOME'] = tmpdir

          parser = ArgumentParser.new
          parser.stub :chruby_search_paths, ->(version, rd) { ["#{rd}/#{version}/bin/ruby"] } do
            assert_raises(SystemExit) do
              capture_io do
                parser.parse(['--chruby=nonexistent::nonexistent-version-999'])
              end
            end
          end
        end
      end

      it 'parses version with options' do
        Dir.mktmpdir do |tmpdir|
          @temp_home = tmpdir
          rubies_dir = File.join(tmpdir, '.rubies')
          ruby_path = File.join(rubies_dir, '3.2.0/bin/ruby')
          setup_mock_ruby(ruby_path)

          ENV['HOME'] = tmpdir

          parser = ArgumentParser.new
          parser.stub :chruby_search_paths, ->(version, rd) { ["#{rd}/#{version}/bin/ruby"] } do
            args = parser.parse(['--chruby=yjit::3.2.0 --yjit'])

            assert_equal ruby_path, args.executables['yjit'].first
            assert_equal '--yjit', args.executables['yjit'].last
          end
        end
      end

      it 'allows skipping NAME:: prefix and uses first word as name' do
        Dir.mktmpdir do |tmpdir|
          @temp_home = tmpdir
          rubies_dir = File.join(tmpdir, '.rubies')
          ruby_path = File.join(rubies_dir, '3.2.0/bin/ruby')
          setup_mock_ruby(ruby_path)

          ENV['HOME'] = tmpdir

          parser = ArgumentParser.new
          parser.stub :chruby_search_paths, ->(version, rd) { ["#{rd}/#{version}/bin/ruby"] } do
            args = parser.parse(['--chruby=3.2.0 --yjit'])

            assert args.executables.key?('3.2.0')
            assert_equal ruby_path, args.executables['3.2.0'].first
          end
        end
      end

      it 'handles semicolon-separated multiple versions' do
        Dir.mktmpdir do |tmpdir|
          @temp_home = tmpdir
          rubies_dir = File.join(tmpdir, '.rubies')
          ruby_path_32 = File.join(rubies_dir, '3.2.0/bin/ruby')
          ruby_path_33 = File.join(rubies_dir, '3.3.0/bin/ruby')
          setup_mock_ruby(ruby_path_32)
          setup_mock_ruby(ruby_path_33)

          ENV['HOME'] = tmpdir

          parser = ArgumentParser.new
          parser.stub :chruby_search_paths, ->(version, rd) { ["#{rd}/#{version}/bin/ruby"] } do
            args = parser.parse(['--chruby=ruby32::3.2.0;ruby33::3.3.0 --yjit'])

            assert_equal 2, args.executables.size
            assert_equal ruby_path_32, args.executables['ruby32'].first
            assert_equal ruby_path_33, args.executables['ruby33'].first
            assert_equal '--yjit', args.executables['ruby33'].last
          end
        end
      end
    end

    describe '--out_path option' do
      it 'sets output path' do
        parser = ArgumentParser.new
        args = parser.parse(['--out_path=/tmp/results'])

        assert_equal '/tmp/results', args.out_path
      end
    end

    describe '--out-name option' do
      it 'sets output override name' do
        parser = ArgumentParser.new
        args = parser.parse(['--out-name=my_results'])

        assert_equal 'my_results', args.out_override
      end
    end

    describe '--category option' do
      it 'parses single category' do
        parser = ArgumentParser.new
        args = parser.parse(['--category=headline'])

        assert_equal ['headline'], args.categories
      end

      it 'parses multiple categories' do
        parser = ArgumentParser.new
        args = parser.parse(['--category=headline,micro'])

        assert_equal ['headline', 'micro'], args.categories
      end

      it 'sets harness to harness-ractor when category is ractor' do
        parser = ArgumentParser.new
        args = parser.parse(['--category=ractor'])

        assert_equal ['ractor'], args.categories
        assert_equal 'harness-ractor', args.harness
      end

      it 'allows multiple category flags' do
        parser = ArgumentParser.new
        args = parser.parse(['--category=headline', '--category=micro'])

        assert_equal ['headline', 'micro'], args.categories
      end
    end

    describe '--headline option' do
      it 'adds headline to categories' do
        parser = ArgumentParser.new
        args = parser.parse(['--headline'])

        assert_equal ['headline'], args.categories
      end

      it 'can be combined with other categories' do
        parser = ArgumentParser.new
        args = parser.parse(['--headline', '--category=micro'])

        assert_equal ['headline', 'micro'], args.categories
      end
    end

    describe '--name_filters option' do
      it 'parses single filter' do
        parser = ArgumentParser.new
        args = parser.parse(['--name_filters=fib'])

        assert_equal ['fib'], args.name_filters
      end

      it 'parses multiple filters' do
        parser = ArgumentParser.new
        args = parser.parse(['--name_filters=fib,railsbench,optcarrot'])

        assert_equal ['fib', 'railsbench', 'optcarrot'], args.name_filters
      end
    end

    describe '--skip-yjit option' do
      it 'sets skip_yjit flag' do
        parser = ArgumentParser.new
        args = parser.parse(['--skip-yjit'])

        assert_equal true, args.skip_yjit
      end
    end

    describe '--harness option' do
      it 'sets harness directory' do
        parser = ArgumentParser.new
        args = parser.parse(['--harness=once'])

        assert_equal 'harness-once', args.harness
      end

      it 'accepts harness- prefix' do
        parser = ArgumentParser.new
        args = parser.parse(['--harness=harness-stats'])

        assert_equal 'harness-stats', args.harness
      end
    end

    describe '--warmup option' do
      it 'sets WARMUP_ITRS environment variable' do
        parser = ArgumentParser.new
        parser.parse(['--warmup=20'])

        assert_equal '20', ENV['WARMUP_ITRS']
      end
    end

    describe '--bench option' do
      it 'sets MIN_BENCH_ITRS and MIN_BENCH_TIME environment variables' do
        parser = ArgumentParser.new
        parser.parse(['--bench=5'])

        assert_equal '5', ENV['MIN_BENCH_ITRS']
        assert_equal '0', ENV['MIN_BENCH_TIME']
      end
    end

    describe '--once option' do
      it 'sets environment variables for single iteration' do
        parser = ArgumentParser.new
        parser.parse(['--once'])

        assert_equal '0', ENV['WARMUP_ITRS']
        assert_equal '1', ENV['MIN_BENCH_ITRS']
        assert_equal '0', ENV['MIN_BENCH_TIME']
      end
    end

    describe '--yjit-stats option' do
      it 'sets YJIT_BENCH_STATS environment variable' do
        parser = ArgumentParser.new
        parser.parse(['--yjit-stats=all'])

        assert_equal 'all', ENV['YJIT_BENCH_STATS']
      end
    end

    describe '--zjit-stats option' do
      it 'sets ZJIT_BENCH_STATS environment variable' do
        parser = ArgumentParser.new
        parser.parse(['--zjit-stats=all'])

        assert_equal 'all', ENV['ZJIT_BENCH_STATS']
      end
    end

    describe '--yjit_opts option' do
      it 'sets yjit_opts' do
        parser = ArgumentParser.new
        args = parser.parse(['--yjit_opts=--yjit-call-threshold=10'])

        assert_equal '--yjit-call-threshold=10', args.yjit_opts
      end
    end

    describe '--with_pre-init option' do
      it 'sets with_pre_init' do
        parser = ArgumentParser.new
        args = parser.parse(['--with_pre-init=/path/to/init.rb'])

        assert_equal '/path/to/init.rb', args.with_pre_init
      end
    end

    describe '--rss option' do
      it 'sets rss flag' do
        parser = ArgumentParser.new
        args = parser.parse(['--rss'])

        assert_equal true, args.rss
      end
    end

    describe '--pvalue option' do
      it 'sets pvalue flag' do
        parser = ArgumentParser.new
        args = parser.parse(['--pvalue'])

        assert_equal true, args.pvalue
      end
    end

    describe '--interleave option' do
      it 'sets interleave flag' do
        parser = ArgumentParser.new
        args = parser.parse(['--interleave'])

        assert_equal true, args.interleave
      end
    end

    describe '--graph option' do
      it 'sets graph flag' do
        parser = ArgumentParser.new
        args = parser.parse(['--graph'])

        assert_equal true, args.graph
      end
    end

    describe '--no-pinning option' do
      it 'sets no_pinning flag' do
        parser = ArgumentParser.new
        args = parser.parse(['--no-pinning'])

        assert_equal true, args.no_pinning
      end
    end

    describe '--turbo option' do
      it 'sets turbo flag' do
        parser = ArgumentParser.new
        args = parser.parse(['--turbo'])

        assert_equal true, args.turbo
      end
    end

    describe '--no-sudo option' do
      it 'sets no_sudo flag' do
        parser = ArgumentParser.new
        args = parser.parse(['--no-sudo'])

        assert_equal true, args.no_sudo
      end
    end

    describe 'remaining arguments' do
      it 'treats remaining arguments as name filters' do
        parser = ArgumentParser.new
        args = parser.parse(['fib', 'railsbench'])

        assert_equal ['fib', 'railsbench'], args.name_filters
      end

      it 'combines with --name_filters option' do
        parser = ArgumentParser.new
        args = parser.parse(['--name_filters=optcarrot', 'fib', 'railsbench'])

        assert_equal ['optcarrot', 'fib', 'railsbench'], args.name_filters
      end
    end

    describe 'combined options' do
      it 'parses complex combination of options' do
        parser = ArgumentParser.new
        args = parser.parse([
          '-e=interp::ruby;yjit::ruby --yjit',
          '--category=headline',
          '--name_filters=rails',
          '--out_path=/tmp',
          '--rss',
          '--graph',
          '--no-pinning',
          '--warmup=5',
          '--bench=3',
          'optcarrot'
        ])

        assert_equal 2, args.executables.size
        assert_equal ['headline'], args.categories
        assert_equal ['rails', 'optcarrot'], args.name_filters
        assert_equal '/tmp', args.out_path
        assert_equal true, args.rss
        assert_equal true, args.graph
        assert_equal true, args.no_pinning
        assert_equal '5', ENV['WARMUP_ITRS']
        assert_equal '3', ENV['MIN_BENCH_ITRS']
      end
    end

    describe '.parse class method' do
      it 'provides convenient shorthand' do
        args = ArgumentParser.parse(['--rss'])

        assert_equal true, args.rss
      end
    end

    describe 'default executables' do
      it 'sets ruby executable when no -e option and no YJIT' do
        mock_ruby = '/usr/bin/ruby'

        parser = ArgumentParser.new(ruby_executable: mock_ruby)

        parser.stub :have_yjit?, false do
          args = parser.parse([])

          assert_equal 1, args.executables.size
          assert_equal [mock_ruby], args.executables['ruby']
        end
      end

      it 'sets interp and yjit executables when no -e option and YJIT available' do
        mock_ruby = '/usr/bin/ruby'

        parser = ArgumentParser.new(ruby_executable: mock_ruby)

        parser.stub :have_yjit?, true do
          args = parser.parse([])

          assert_equal 2, args.executables.size
          assert_equal [mock_ruby], args.executables['interp']
          assert_equal [mock_ruby, '--yjit'], args.executables['yjit']
        end
      end

      it 'includes yjit_opts in default yjit executable' do
        mock_ruby = '/usr/bin/ruby'

        parser = ArgumentParser.new(ruby_executable: mock_ruby)

        parser.stub :have_yjit?, true do
          args = parser.parse(['--yjit_opts=--yjit-call-threshold=10'])

          assert_equal 2, args.executables.size
          assert_equal [mock_ruby], args.executables['interp']
          assert_equal [mock_ruby, '--yjit', '--yjit-call-threshold=10'], args.executables['yjit']
        end
      end

      it 'respects --skip-yjit flag when YJIT is available' do
        mock_ruby = '/usr/bin/ruby'

        parser = ArgumentParser.new(ruby_executable: mock_ruby)

        parser.stub :have_yjit?, true do
          args = parser.parse(['--skip-yjit'])

          assert_equal 1, args.executables.size
          assert_equal [mock_ruby], args.executables['ruby']
        end
      end

      it 'does not set default executables when -e option is provided' do
        mock_ruby = '/usr/bin/ruby'

        parser = ArgumentParser.new(ruby_executable: mock_ruby)

        parser.stub :have_yjit?, true do
          args = parser.parse(['-e', 'custom::custom-ruby'])

          assert_equal 1, args.executables.size
          assert_equal ['custom-ruby'], args.executables['custom']
        end
      end

      it 'does not set default executables when --chruby option is provided' do
        Dir.mktmpdir do |tmpdir|
          @temp_home = tmpdir
          rubies_dir = File.join(tmpdir, '.rubies')
          ruby_path = File.join(rubies_dir, '3.2.0/bin/ruby')
          setup_mock_ruby(ruby_path)

          ENV['HOME'] = tmpdir
          mock_ruby = '/usr/bin/ruby'

          parser = ArgumentParser.new(ruby_executable: mock_ruby)

          parser.stub :have_yjit?, true do
            parser.stub :chruby_search_paths, ->(version, rd) { ["#{rd}/#{version}/bin/ruby"] } do
              args = parser.parse(['--chruby=test::3.2.0'])

              assert_equal 1, args.executables.size
              assert_equal ruby_path, args.executables['test'].first
            end
          end
        end
      end
    end
  end
end
