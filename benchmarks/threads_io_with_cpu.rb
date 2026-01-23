require_relative '../harness/loader'

require "socket"
num_cpu_threads = 1
num_io_threads = 1

server_started = false

def start_tcp_server(&started)
  Thread.new do
    server = TCPServer.new('localhost', 0) # random open port
    started.call(server.local_address.ip_port)

    loop do
      client = server.accept
      client.close
      # Don't get request or generate response, it makes the benchmark take too long
    end
  end
end

def open_tcp_connection(host, port)
  TCPSocket.open(host, port) { }
end

def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end

server_started = false
port = nil
start_tcp_server do |server_port|
  server_started = true
  port = server_port
end
loop until server_started

io_requests_threshold = 5 # per thread

run_benchmark(5) do
  io_threads = num_io_threads.times.map do
    Thread.new do
      io_requests_made = 0
      loop do
        open_tcp_connection("localhost", port)
        io_requests_made += 1
        if io_requests_made >= io_requests_threshold
          break
        end
      end
    end
  end

  stop_looping = false

  cpu_threads = num_cpu_threads.times.map do
    Thread.new do
      loop do
        fib(30)
        break if stop_looping
      end
    end
  end

  io_threads.each(&:join)
  stop_looping = true
  cpu_threads.join
end
