require_relative '../../harness/loader'

# Protoboeuf decoder
require_relative 'benchmark_pb'

Dir.chdir __dir__
fake_msg_bins = Marshal.load(File.binread('encoded_msgs.bin'))
LOTS = Ractor.make_shareable(fake_msg_bins.map { |bin| ProtoBoeuf::ParkingLot.decode bin })

run_benchmark(20) do
  LOTS.each { |lot| ProtoBoeuf::ParkingLot.encode lot }
end
