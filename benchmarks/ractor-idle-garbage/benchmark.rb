# Multiple ractors each build a large live set, drop all references, then park
# on Ractor.receive without allocating again. Their garbage cannot be swept by
# the main Ractor's GC while they idle, so it is retained until each worker
# is released. The scenario returns a cleanup proc that the harness calls
# after the retention measurement.

Warning[:experimental] = false

require_relative "../../harness/loader"

IDLE_GARBAGE_ITEMS = Integer(ENV.fetch("RACTOR_IDLE_GARBAGE_ITEMS", 100_000))

run_benchmark(3) do |num_ractors|
  drained = Ractor.new(num_ractors) do |count|
    count.times { Ractor.receive }
    :all_drained
  end

  workers = num_ractors.times.map do |worker|
    Ractor.new(drained, worker, IDLE_GARBAGE_ITEMS) do |ack, worker_id, items|
      keep = []
      i = 0
      while i < items
        keep << "worker #{worker_id} garbage #{i} " + ("y" * 100)
        i += 1
      end
      keep = nil
      ack.send :drained
      Ractor.receive
      :worker_done
    end
  end

  raise "unexpected drain barrier result" unless drained.value == :all_drained

  proc do
    workers.each do |worker|
      worker.send :stop
      raise "unexpected worker result" unless worker.value == :worker_done
    end
  end
end
