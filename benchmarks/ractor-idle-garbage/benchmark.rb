# Multiple ractors each build a large live set, drop all references, then park
# on Ractor.receive without allocating again. Their garbage cannot be swept by
# the main Ractor's GC while they idle, so it is retained until each worker
# is released. The scenario returns a cleanup proc that the harness calls
# after the retention measurement.

Warning[:experimental] = false

require_relative "../../harness/loader"

IDLE_GARBAGE_ITEMS = Integer(ENV.fetch("RACTOR_IDLE_GARBAGE_ITEMS", 100_000))

run_benchmark(3, scenario: true) do |num_ractors|
  drained = Ractor.new(num_ractors) do |count|
    Array.new(count) { Ractor.receive }
  end

  workers = num_ractors.times.map do |worker|
    Ractor.new(drained, worker, IDLE_GARBAGE_ITEMS) do |ack, worker_id, items|
      keep = []
      _, sample = measure_worker_gc do
        i = 0
        while i < items
          keep << "worker #{worker_id} garbage #{i} " + ("y" * 100)
          i += 1
        end
      end
      message = Ractor.make_shareable([worker_id, sample])
      keep = nil
      ack.send message
      Ractor.receive
      :worker_done
    end
  end

  ractor, drained_workers = Ractor.select(drained, *workers)
  raise "unexpected drain barrier result" unless ractor.equal?(drained) && drained_workers.size == num_ractors
  drained_workers.each { |worker_id, sample| record_worker_gc(worker_id, sample) }

  proc do
    workers.each do |worker|
      worker.send :stop
      raise "unexpected worker result" unless worker.value == :worker_done
    end
  end
end
