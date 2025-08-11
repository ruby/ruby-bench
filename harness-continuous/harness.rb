require_relative "../harness/harness-common"

puts RUBY_DESCRIPTION

def run_benchmark(n, **, &blk)
  iterations = 1
  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  loop do
    iterations.times(&blk)

    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    round_time = end_time - start_time

    if round_time < 0.1
      # If the round time was very low, don't try to do anything clever with
      # the result - just immediately run twice as many iterations to quickly
      # get up to a sensible base number.
      iterations *= 2
    else
      ips = iterations / round_time
      puts ips

      # Next time, run that many iterations, so that we're sampling the clock
      # about once a second.
      iterations = ips.to_i
    end

    # Always run at least one iteartion.
    iterations = 1 if iterations.zero?

    start_time = end_time
  end
end
