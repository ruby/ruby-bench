# The main Ractor floods the incoming queues of multiple gated consumer
# ractors with unshareable string payloads. The copies made on send pile up
# in the queues while the consumers sleep, which duplicates the payload data
# per consumer and drives peak RSS. Measured retention after the queues are
# drained shows how much of the copied memory a full GC fails to reclaim.

Warning[:experimental] = false

require_relative "../../harness/loader"

BACKLOG_MESSAGES = Integer(ENV.fetch("RACTOR_BACKLOG_MESSAGES", 20_000))
BACKLOG_GATE_SLEEP = Float(ENV.fetch("RACTOR_BACKLOG_GATE_SLEEP", 1.0))

run_benchmark(3, scenario: true) do |num_ractors|
  consumer_ids = {}
  num_ractors.times do |consumer_id0|
    ractor = Ractor.new(consumer_id0, BACKLOG_GATE_SLEEP) do |consumer_id, gate|
      measure_worker_gc do
        sleep gate
        taken = 0
        loop do
          message = Ractor.receive
          break if message == :done
          taken += 1
        end
        taken
      end
    end
    consumer_ids[ractor] = consumer_id0
  end

  consumer_ids.each do |consumer, consumer_id|
    i = 0
    while i < BACKLOG_MESSAGES
      consumer.send "consumer #{consumer_id} message #{i} " + ("x" * 200)
      i += 1
    end
    consumer.send :done
  end

  # Harvest in completion order, so a consumer that drains early is not held
  # alive waiting on a slower consumer ahead of it.
  total = 0
  pending = consumer_ids.keys
  until pending.empty?
    consumer, (taken, sample) = Ractor.select(*pending)
    pending.delete(consumer)
    record_worker_gc(consumer_ids.fetch(consumer), sample)
    total += taken
  end
  raise "unexpected backlog drain" unless total == num_ractors * BACKLOG_MESSAGES
  nil
end
