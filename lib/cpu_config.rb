require_relative 'benchmark_runner'

# Manages CPU frequency and turbo boost configuration for benchmark consistency
class CPUConfig
  class << self
    # Configure CPU for benchmarking: disable frequency scaling and verify settings
    def configure_for_benchmarking(turbo:)
      build.configure_for_benchmarking(turbo: turbo)
    end

    def build
      if File.exist?(IntelCPUConfig::PSTATE_DIR)
        IntelCPUConfig.new
      elsif File.exist?(AMDCPUConfig::BOOST_PATH)
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
  PSTATE_DIR = '/sys/devices/system/cpu/intel_pstate'
  NO_TURBO_PATH = "#{PSTATE_DIR}/no_turbo"
  MIN_PERF_PCT_PATH = "#{PSTATE_DIR}/min_perf_pct"
  TURBO_DISABLED_VALUE = '1'
  FREQUENCY_MAXIMIZED_VALUE = '100'

  private

  def disable_turbo_boost
    # sudo requires the flag '-S' in order to take input from stdin
    BenchmarkRunner.check_call("sudo -S sh -c 'echo #{TURBO_DISABLED_VALUE} > #{NO_TURBO_PATH}'")
    at_exit { BenchmarkRunner.check_call("sudo -S sh -c 'echo 0 > #{NO_TURBO_PATH}'", quiet: true) }
  end

  def maximize_frequency
    # Disabling Turbo Boost reduces the CPU frequency, so this should be run after that.
    BenchmarkRunner.check_call("sudo -S sh -c 'echo #{FREQUENCY_MAXIMIZED_VALUE} > #{MIN_PERF_PCT_PATH}'")
  end

  def turbo_disabled?
    @turbo_disabled ||= File.exist?(NO_TURBO_PATH) &&
      File.read(NO_TURBO_PATH).strip == TURBO_DISABLED_VALUE
  end

  def frequency_maximized?
    @frequency_maximized ||= File.exist?(MIN_PERF_PCT_PATH) &&
      File.read(MIN_PERF_PCT_PATH).strip == FREQUENCY_MAXIMIZED_VALUE
  end

  def check_pstate(turbo:)
    unless turbo || turbo_disabled?
      puts("You forgot to disable turbo:")
      puts("  sudo sh -c 'echo #{TURBO_DISABLED_VALUE} > #{NO_TURBO_PATH}'")
      exit(-1)
    end

    unless frequency_maximized?
      puts("You forgot to set the min perf percentage to 100:")
      puts("  sudo sh -c 'echo #{FREQUENCY_MAXIMIZED_VALUE} > #{MIN_PERF_PCT_PATH}'")
      exit(-1)
    end
  end
end

# AMD CPU configuration
class AMDCPUConfig < CPUConfig
  CPUFREQ_DIR = '/sys/devices/system/cpu/cpufreq'
  BOOST_PATH = "#{CPUFREQ_DIR}/boost"
  SCALING_GOVERNOR_GLOB = '/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
  TURBO_DISABLED_VALUE = '0'
  TURBO_ENABLED_VALUE = '1'
  PERFORMANCE_GOVERNOR = 'performance'

  private

  def disable_turbo_boost
    # sudo requires the flag '-S' in order to take input from stdin
    BenchmarkRunner.check_call("sudo -S sh -c 'echo #{TURBO_DISABLED_VALUE} > #{BOOST_PATH}'")
    at_exit { BenchmarkRunner.check_call("sudo -S sh -c 'echo #{TURBO_ENABLED_VALUE} > #{BOOST_PATH}'", quiet: true) }
  end

  def maximize_frequency
    BenchmarkRunner.check_call("sudo -S cpupower frequency-set -g performance")
  end

  def turbo_disabled?
    @turbo_disabled ||= File.exist?(BOOST_PATH) &&
      File.read(BOOST_PATH).strip == TURBO_DISABLED_VALUE
  end

  def frequency_maximized?
    @frequency_maximized ||= Dir.glob(SCALING_GOVERNOR_GLOB).all? do |governor|
      File.read(governor).strip == PERFORMANCE_GOVERNOR
    end
  end

  def check_pstate(turbo:)
    unless turbo || turbo_disabled?
      puts("You forgot to disable boost:")
      puts("  sudo sh -c 'echo #{TURBO_DISABLED_VALUE} > #{BOOST_PATH}'")
      exit(-1)
    end

    unless frequency_maximized?
      puts("You forgot to set the performance governor:")
      puts("  sudo cpupower frequency-set -g #{PERFORMANCE_GOVERNOR}")
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
