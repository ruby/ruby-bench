# The main Ractor floods the incoming queues of multiple gated consumer
# ractors with unshareable string payloads. The copies made on send pile up
# in the queues while the consumers sleep, which duplicates the payload data
# per consumer and drives peak RSS. Measured retention after the queues are
# drained shows how much of the copied memory a full GC fails to reclaim.
# This file intentionally omits frozen_string_literal: frozen payloads are
# shareable and would not be copied on send.

Warning[:experimental] = false

require_relative "../../harness/loader"

BACKLOG_MESSAGES = Integer(ENV.fetch("RACTOR_BACKLOG_MESSAGES", 20_000))
BACKLOG_GATE_SLEEP = Float(ENV.fetch("RACTOR_BACKLOG_GATE_SLEEP", 1.0))

run_benchmark(3) do |num_ractors|
  consumers = num_ractors.times.map do |consumer|
    Ractor.new(consumer, BACKLOG_GATE_SLEEP) do |consumer_id, gate|
      sleep gate
      taken = 0
      loop do
        message = Ractor.receive
        break if message == :done
        taken += 1
      end
      [consumer_id, taken]
    end
  end

  consumers.each_with_index do |consumer, consumer_id|
    i = 0
    while i < BACKLOG_MESSAGES
      consumer.send "consumer #{consumer_id} message #{i} " + ("x" * 200)
      i += 1
    end
    consumer.send :done
  end

  results = consumers.map(&:value)
  raise "unexpected backlog drain" unless results.sum { |_, taken| taken } == num_ractors * BACKLOG_MESSAGES
  nil
end
