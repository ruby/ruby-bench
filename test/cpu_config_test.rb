require_relative 'test_helper'
require_relative '../lib/cpu_config'
require_relative '../lib/benchmark_runner'

describe CPUConfig do
  describe '.build' do
    it 'returns IntelCPUConfig when Intel pstate files exist' do
      File.stub :exist?, ->(path) { path.include?('intel_pstate') } do
        config = CPUConfig.build
        assert_instance_of IntelCPUConfig, config
      end
    end

    it 'returns AMDCPUConfig when AMD cpufreq files exist' do
      File.stub :exist?, ->(path) { path.include?('cpufreq/boost') } do
        config = CPUConfig.build
        assert_instance_of AMDCPUConfig, config
      end
    end

    it 'returns NullCPUConfig when no CPU files exist' do
      File.stub :exist?, false do
        config = CPUConfig.build
        assert_instance_of NullCPUConfig, config
      end
    end
  end
end

describe NullCPUConfig do
  describe '#configure_for_benchmarking' do
    it 'does nothing when CPU frequency files do not exist' do
      call_count = 0
      at_exit_called = false
      exit_called = false

      File.stub :exist?, false do
        cpu_config = NullCPUConfig.new
        cpu_config.stub :at_exit, ->(&block) { at_exit_called = true } do
          cpu_config.stub :exit, ->(code) { exit_called = true } do
            BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) { call_count += 1 } do
              capture_io do
                cpu_config.configure_for_benchmarking(turbo: false)
              end
              assert_equal 0, call_count, "Should not call check_call when files don't exist"
              refute at_exit_called, "Should not call at_exit when CPU frequency files don't exist"
              refute exit_called, "Should not exit when files don't exist"
            end
          end
        end
      end
    end
  end
end

describe IntelCPUConfig do
  describe '#configure_for_benchmarking' do
    it 'does not call commands or exit when Intel CPU is already properly configured with turbo disabled' do
      call_count = 0
      at_exit_called = false
      exit_called = false

      File.stub :exist?, ->(path) { path.include?('intel_pstate') } do
        cpu_config = IntelCPUConfig.new
        cpu_config.stub :at_exit, ->(&block) { at_exit_called = true } do
          cpu_config.stub :exit, ->(code) { exit_called = true } do
            BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) { call_count += 1 } do
              File.stub :read, lambda { |path|
                if path.include?('no_turbo')
                  "1\n"
                elsif path.include?('min_perf_pct')
                  "100\n"
                end
              } do
                capture_io do
                  cpu_config.configure_for_benchmarking(turbo: false)
                end
                assert_equal 0, call_count, "Should not call check_call when Intel CPU is properly configured"
                refute at_exit_called, "Should not call at_exit when Intel CPU already configured"
                refute exit_called, "Should not exit when Intel CPU is properly configured"
              end
            end
          end
        end
      end
    end

    it 'does not call commands or exit when Intel CPU allows turbo and min_perf is 100%' do
      call_count = 0
      at_exit_called = false
      exit_called = false

      File.stub :exist?, ->(path) { path.include?('intel_pstate') } do
        cpu_config = IntelCPUConfig.new
        cpu_config.stub :at_exit, ->(&block) { at_exit_called = true } do
          cpu_config.stub :exit, ->(code) { exit_called = true } do
            BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) { call_count += 1 } do
              File.stub :read, lambda { |path|
                if path.include?('no_turbo')
                  "0\n"
                elsif path.include?('min_perf_pct')
                  "100\n"
                end
              } do
                capture_io do
                  cpu_config.configure_for_benchmarking(turbo: true)
                end
                assert_equal 0, call_count, "Should not call check_call when turbo is true and min_perf is correct"
                refute at_exit_called, "Should not call at_exit when turbo is true and CPU already configured"
                refute exit_called, "Should not exit when turbo is true and performance is correct"
              end
            end
          end
        end
      end
    end

    it 'configures Intel CPU and registers cleanup when turbo needs to be disabled' do
      call_count = 0
      at_exit_called = false
      at_exit_block = nil
      exit_called = false
      read_count = 0

      File.stub :exist?, ->(path) { path.include?('intel_pstate') } do
        cpu_config = IntelCPUConfig.new
        cpu_config.stub :at_exit, ->(&block) { at_exit_called = true; at_exit_block = block } do
          cpu_config.stub :exit, ->(code) { exit_called = true } do
            BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) { call_count += 1 } do
              File.stub :read, lambda { |path|
                if path.include?('no_turbo')
                  read_count += 1
                  # First read checks if turbo is disabled (for disable_frequency_scaling)
                  # Second read checks if turbo is disabled (for check_pstate)
                  # After the first check_call, we simulate that turbo is now disabled
                  read_count <= 1 ? "0\n" : "1\n"
                elsif path.include?('min_perf_pct')
                  # After check_call sets it, simulate it's now 100%
                  "100\n"
                end
              } do
                capture_io do
                  cpu_config.configure_for_benchmarking(turbo: false)
                end
                assert_operator call_count, :>, 0, "Should call check_call to configure Intel CPU"
                assert at_exit_called, "Should register at_exit handler to restore CPU settings"
                assert_instance_of Proc, at_exit_block, "at_exit should be called with a block"
                refute exit_called, "Should not exit when Intel CPU gets properly configured"
              end
            end
          end
        end
      end

      # Verify at_exit block restores Intel turbo settings
      cleanup_commands = []
      BenchmarkRunner.stub :check_call, ->(cmd, **opts) { cleanup_commands << { cmd: cmd, opts: opts } } do
        at_exit_block.call
      end

      assert_equal 1, cleanup_commands.length, "at_exit block should call check_call once"
      assert_equal "sudo -S sh -c 'echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo'", cleanup_commands[0][:cmd]
      assert_equal({ quiet: true }, cleanup_commands[0][:opts])
    end

    it 'exits when Intel turbo is not disabled and turbo flag is false' do
      exit_code = nil
      output = capture_io do
        File.stub :exist?, ->(path) { path.include?('intel_pstate') } do
          cpu_config = IntelCPUConfig.new
          cpu_config.stub :at_exit, ->(&block) {} do
            cpu_config.stub :exit, ->(code) { exit_code = code } do
              BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) {} do
                File.stub :read, lambda { |path|
                  if path.include?('no_turbo')
                    "0\n"
                  elsif path.include?('min_perf_pct')
                    "100\n"
                  end
                } do
                  cpu_config.configure_for_benchmarking(turbo: false)
                end
              end
            end
          end
        end
      end

      assert_equal(-1, exit_code)
      assert_includes output[0], "You forgot to disable turbo"
      assert_includes output[0], "sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'"
    end

    it 'exits when Intel min perf is not 100%' do
      exit_code = nil
      output = capture_io do
        File.stub :exist?, ->(path) { path.include?('intel_pstate') } do
          cpu_config = IntelCPUConfig.new
          cpu_config.stub :at_exit, ->(&block) {} do
            cpu_config.stub :exit, ->(code) { exit_code = code } do
              BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) {} do
                File.stub :read, lambda { |path|
                  if path.include?('no_turbo')
                    "1\n"
                  elsif path.include?('min_perf_pct')
                    "50\n"
                  end
                } do
                  cpu_config.configure_for_benchmarking(turbo: false)
                end
              end
            end
          end
        end
      end

      assert_equal(-1, exit_code)
      assert_includes output[0], "You forgot to set the min perf percentage to 100"
      assert_includes output[0], "sudo sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'"
    end
  end
end

describe AMDCPUConfig do
  describe '#configure_for_benchmarking' do
    it 'does not call commands or exit when AMD CPU is already properly configured with turbo disabled' do
      call_count = 0
      at_exit_called = false
      exit_called = false

      File.stub :exist?, ->(path) { path.include?('cpufreq/boost') } do
        cpu_config = AMDCPUConfig.new
        cpu_config.stub :at_exit, ->(&block) { at_exit_called = true } do
          cpu_config.stub :exit, ->(code) { exit_called = true } do
            BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) { call_count += 1 } do
              File.stub :read, ->(path) {
                if path.include?('boost')
                  "0\n"
                else
                  "performance\n"
                end
              } do
                Dir.stub :glob, ->(pattern) { ['/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'] } do
                  capture_io do
                    cpu_config.configure_for_benchmarking(turbo: false)
                  end
                  assert_equal 0, call_count, "Should not call check_call when AMD CPU is properly configured"
                  refute at_exit_called, "Should not call at_exit when AMD CPU already configured"
                  refute exit_called, "Should not exit when AMD CPU is properly configured"
                end
              end
            end
          end
        end
      end
    end

    it 'configures AMD CPU and registers cleanup when boost needs to be disabled' do
      call_count = 0
      at_exit_called = false
      at_exit_block = nil
      exit_called = false
      read_count = 0

      File.stub :exist?, ->(path) { path.include?('cpufreq/boost') } do
        cpu_config = AMDCPUConfig.new
        cpu_config.stub :at_exit, ->(&block) { at_exit_called = true; at_exit_block = block } do
          cpu_config.stub :exit, ->(code) { exit_called = true } do
            BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) { call_count += 1 } do
              File.stub :read, lambda { |path|
                if path.include?('boost')
                  read_count += 1
                  # First read checks if boost is disabled, second read is after we disable it
                  read_count == 1 ? "1\n" : "0\n"
                else
                  "performance\n"
                end
              } do
                Dir.stub :glob, ->(pattern) { ['/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'] } do
                  capture_io do
                    cpu_config.configure_for_benchmarking(turbo: false)
                  end
                  assert_operator call_count, :>, 0, "Should call check_call to configure AMD CPU"
                  assert at_exit_called, "Should register at_exit handler to restore CPU settings"
                  assert_instance_of Proc, at_exit_block, "at_exit should be called with a block"
                  refute exit_called, "Should not exit when AMD CPU gets properly configured"
                end
              end
            end
          end
        end
      end

      # Verify at_exit block restores AMD boost settings
      cleanup_commands = []
      BenchmarkRunner.stub :check_call, ->(cmd, **opts) { cleanup_commands << { cmd: cmd, opts: opts } } do
        at_exit_block.call
      end

      assert_equal 1, cleanup_commands.length, "at_exit block should call check_call once"
      assert_equal "sudo -S sh -c 'echo 1 > /sys/devices/system/cpu/cpufreq/boost'", cleanup_commands[0][:cmd]
      assert_equal({ quiet: true }, cleanup_commands[0][:opts])
    end

    it 'exits when AMD boost is not disabled and turbo flag is false' do
      exit_code = nil
      output = capture_io do
        File.stub :exist?, ->(path) { path.include?('cpufreq/boost') } do
          cpu_config = AMDCPUConfig.new
          cpu_config.stub :at_exit, ->(&block) {} do
            cpu_config.stub :exit, ->(code) { exit_code = code } do
              BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) {} do
                File.stub :read, ->(path) {
                  if path.include?('boost')
                    "1\n"
                  else
                    "performance\n"
                  end
                } do
                  Dir.stub :glob, ->(pattern) { ['/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'] } do
                    cpu_config.configure_for_benchmarking(turbo: false)
                  end
                end
              end
            end
          end
        end
      end

      assert_equal(-1, exit_code)
      assert_includes output[0], "You forgot to disable boost"
      assert_includes output[0], "sudo sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'"
    end

    it 'exits when AMD performance governor is not set' do
      exit_code = nil
      output = capture_io do
        File.stub :exist?, ->(path) { path.include?('cpufreq/boost') } do
          cpu_config = AMDCPUConfig.new
          cpu_config.stub :at_exit, ->(&block) {} do
            cpu_config.stub :exit, ->(code) { exit_code = code } do
              BenchmarkRunner.stub :check_call, ->(*_args, **_kwargs) {} do
                File.stub :read, lambda { |path|
                  if path.include?('boost')
                    "0\n"
                  else
                    "powersave\n"
                  end
                } do
                  Dir.stub :glob, ->(pattern) { ['/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'] } do
                    cpu_config.configure_for_benchmarking(turbo: false)
                  end
                end
              end
            end
          end
        end
      end

      assert_equal(-1, exit_code)
      assert_includes output[0], "You forgot to set the performance governor"
      assert_includes output[0], "sudo cpupower frequency-set -g performance"
    end
  end
end
