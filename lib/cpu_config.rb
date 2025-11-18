require_relative 'benchmark_runner'

# Manages CPU frequency and turbo boost configuration for benchmark consistency
class CPUConfig
  class << self
    # Configure CPU for benchmarking: disable frequency scaling and verify settings
    def configure_for_benchmarking(turbo:)
      disable_frequency_scaling(turbo: turbo)
      check_pstate(turbo: turbo)
    end

    private

    # Disable Turbo Boost while running benchmarks. Maximize the CPU frequency.
    def disable_frequency_scaling(turbo:)
      # sudo requires the flag '-S' in order to take input from stdin
      if File.exist?('/sys/devices/system/cpu/intel_pstate') # Intel
        unless intel_no_turbo? || turbo
          BenchmarkRunner.check_call("sudo -S sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
          at_exit { BenchmarkRunner.check_call("sudo -S sh -c 'echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo'", quiet: true) }
        end
        # Disabling Turbo Boost reduces the CPU frequency, so this should be run after that.
        BenchmarkRunner.check_call("sudo -S sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'") unless intel_perf_100pct?
      elsif File.exist?('/sys/devices/system/cpu/cpufreq/boost') # AMD
        unless amd_no_boost? || turbo
          BenchmarkRunner.check_call("sudo -S sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'")
          at_exit { BenchmarkRunner.check_call("sudo -S sh -c 'echo 1 > /sys/devices/system/cpu/cpufreq/boost'", quiet: true) }
        end
        BenchmarkRunner.check_call("sudo -S cpupower frequency-set -g performance") unless performance_governor?
      end
    end

    def intel_no_turbo?
      File.exist?('/sys/devices/system/cpu/intel_pstate/no_turbo') &&
        File.read('/sys/devices/system/cpu/intel_pstate/no_turbo').strip == '1'
    end

    def intel_perf_100pct?
      File.exist?('/sys/devices/system/cpu/intel_pstate/min_perf_pct') &&
        File.read('/sys/devices/system/cpu/intel_pstate/min_perf_pct').strip == '100'
    end

    def amd_no_boost?
      File.exist?('/sys/devices/system/cpu/cpufreq/boost') &&
        File.read('/sys/devices/system/cpu/cpufreq/boost').strip == '0'
    end

    def performance_governor?
      Dir.glob('/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor').all? do |governor|
        File.read(governor).strip == 'performance'
      end
    end

    # Verify that CPU frequency settings have been configured correctly
    def check_pstate(turbo:)
      if File.exist?('/sys/devices/system/cpu/intel_pstate') # Intel
        unless turbo || intel_no_turbo?
          puts("You forgot to disable turbo:")
          puts("  sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
          exit(-1)
        end

        unless intel_perf_100pct?
          puts("You forgot to set the min perf percentage to 100:")
          puts("  sudo sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'")
          exit(-1)
        end
      elsif File.exist?('/sys/devices/system/cpu/cpufreq/boost') # AMD
        unless turbo || amd_no_boost?
          puts("You forgot to disable boost:")
          puts("  sudo sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'")
          exit(-1)
        end

        unless performance_governor?
          puts("You forgot to set the performance governor:")
          puts("  sudo cpupower frequency-set -g performance")
          exit(-1)
        end
      end
    end
  end
end
