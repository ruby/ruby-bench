require_relative '../harness/harness-common'

# Ex: HARNESS_CHAIN="vernier,ractor"
# Wraps the ractor harness in ther vernier harness
CHAIN = ENV['HARNESS_CHAIN'].to_s.split(',')
CHAIN.reject! { |el| el.to_s.strip.empty? }
if CHAIN.size < 2
  $stderr.puts "You need to chain at least 2 harnesses. Exiting."
  exit 1
end

if CHAIN.include?("vernier") && CHAIN.last != "vernier"
  require_relative "../harness/harness-extra"
  def run_enough_to_profile(n, **kwargs, &block)
    block.call
  end
end

$current_harness = nil
$benchmark_methods = []

class Object
  def self.method_added(name)
    if name ==  :run_benchmark && $current_harness
      $benchmark_methods << [$current_harness, Object.instance_method(name)]
    end
  end
end

def run_benchmark(n, **kwargs, &block)
  CHAIN.each do |h|
    begin
      path = "../harness-#{h}/harness"
      $current_harness = h
      require_relative path
    rescue LoadError => e
      if e.path == path
        $stderr.puts "Can't find harness harness-#{h}/harness.rb. Exiting."
        exit 1
      end
      raise
    end
  end
  procs = [block]
  $benchmark_methods.reverse_each do |harness_name, harness_method|
    prok = procs.pop
    procs << proc { harness_method.bind(self).call(n, **kwargs, &prok) }
  end
  raise "Bad logic: #{procs.size}" unless procs.size == 1
  result = procs.last.call
  result || return_results([0], [1.0])
end
