require_relative '../harness/harness-common'

CHAIN = ENV['HARNESS_CHAIN'].to_s.split(',')
CHAIN.reject! { |el| el.to_s.strip.empty? }
if CHAIN.size < 2
  $stderr.puts "You need to chain at least 2 harnesses. Exiting."
  exit 1
end

def run_benchmark(n, **kwargs, &block)
  CHAIN.each do |h|
    begin
      path = "../harness-#{h}/harness"
      require_relative path
    rescue LoadError => e
      if e.path == path
        $stderr.puts "Can't find harness harness-#{h}/harness.rb. Exiting."
        exit 1
      end
      raise
    end
  end
end
