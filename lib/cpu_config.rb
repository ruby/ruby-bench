require_relative 'benchmark_runner'

# Manages CPU frequency and turbo boost configuration for benchmark consistency
class CPUConfig
  class << self
    # Configure CPU for benchmarking: disable frequency scaling and verify settings
    def configure_for_benchmarking(turbo:)
      build.configure_for_benchmarking(turbo: turbo)
    end

    def build
      if File.exist?('/sys/devices/system/cpu/intel_pstate')
        IntelCPUConfig.new
      elsif File.exist?('/sys/devices/system/cpu/cpufreq/boost')
        AMDCPUConfig.new
      else
        NullCPUConfig.new
      end
    end
  end

  def configure_for_benchmarking(turbo:)
    disable_frequency_scaling(turbo: turbo)
    check_pstate(turbo: turbo)
  end

  private

  def disable_frequency_scaling(turbo:)
    disable_turbo_boost unless turbo || turbo_disabled?
    maximize_frequency unless frequency_maximized?
  end

  def turbo_disabled?
    # Override in subclasses
    false
  end

  def frequency_maximized?
    # Override in subclasses
    false
  end

  def disable_turbo_boost
    # Override in subclasses
  end

  def maximize_frequency
    # Override in subclasses
  end

  def check_pstate(turbo:)
    # Override in subclasses
  end
end

# Intel CPU configuration
class IntelCPUConfig < CPUConfig
  private

  def disable_turbo_boost
    # sudo requires the flag '-S' in order to take input from stdin
    BenchmarkRunner.check_call("sudo -S sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
    at_exit { BenchmarkRunner.check_call("sudo -S sh -c 'echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo'", quiet: true) }
  end

  def maximize_frequency
    # Disabling Turbo Boost reduces the CPU frequency, so this should be run after that.
    BenchmarkRunner.check_call("sudo -S sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'")
  end

  def turbo_disabled?
    @turbo_disabled ||= File.exist?('/sys/devices/system/cpu/intel_pstate/no_turbo') &&
      File.read('/sys/devices/system/cpu/intel_pstate/no_turbo').strip == '1'
  end

  def frequency_maximized?
    @frequency_maximized ||= File.exist?('/sys/devices/system/cpu/intel_pstate/min_perf_pct') &&
      File.read('/sys/devices/system/cpu/intel_pstate/min_perf_pct').strip == '100'
  end

  def check_pstate(turbo:)
    unless turbo || turbo_disabled?
      puts("You forgot to disable turbo:")
      puts("  sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
      exit(-1)
    end

    unless frequency_maximized?
      puts("You forgot to set the min perf percentage to 100:")
      puts("  sudo sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'")
      exit(-1)
    end
  end
end

# AMD CPU configuration
class AMDCPUConfig < CPUConfig
  private

  def disable_turbo_boost
    # sudo requires the flag '-S' in order to take input from stdin
    BenchmarkRunner.check_call("sudo -S sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'")
    at_exit { BenchmarkRunner.check_call("sudo -S sh -c 'echo 1 > /sys/devices/system/cpu/cpufreq/boost'", quiet: true) }
  end

  def maximize_frequency
    BenchmarkRunner.check_call("sudo -S cpupower frequency-set -g performance")
  end

  def turbo_disabled?
    @turbo_disabled ||= File.exist?('/sys/devices/system/cpu/cpufreq/boost') &&
      File.read('/sys/devices/system/cpu/cpufreq/boost').strip == '0'
  end

  def frequency_maximized?
    @frequency_maximized ||= Dir.glob('/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor').all? do |governor|
      File.read(governor).strip == 'performance'
    end
  end

  def check_pstate(turbo:)
    unless turbo || turbo_disabled?
      puts("You forgot to disable boost:")
      puts("  sudo sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'")
      exit(-1)
    end

    unless frequency_maximized?
      puts("You forgot to set the performance governor:")
      puts("  sudo cpupower frequency-set -g performance")
      exit(-1)
    end
  end
end

# Null object for unsupported CPUs
class NullCPUConfig < CPUConfig
  private

  def disable_frequency_scaling(turbo:)
    # Do nothing
  end

  def check_pstate(turbo:)
    # Do nothing
  end
end
