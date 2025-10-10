require_relative '../harness/harness'

# Using Module#prepend to enable TracePoint right before #run_benchmark
# while also reusing the original implementation.
self.singleton_class.prepend Module.new {
  def run_benchmark(n, **, &block)
    frames = []
    c_calls = Hash.new { 0 }
    c_blocks = Hash.new { 0 }
    rb_calls = Hash.new { 0 }
    rb_blocks = Hash.new { 0 }

    method_trace = TracePoint.new(:call, :c_call, :return, :c_return) do |tp|
      # Keep track of call frames to get the caller of :b_call
      case tp.event
      when :call, :c_call
        method_name = "#{tp.defined_class}##{tp.method_id}"
        frames.push([tp.event, method_name])
      when :return, :c_return
        frames.pop
      end

      # Count method calls
      case tp.event
      when :c_call
        c_calls[method_name] += 1
      when :call
        rb_calls[method_name] += 1
      end
    end

    block_trace = TracePoint.new(:b_call) do |tp|
      caller_event, caller_method = frames.last

      # Count block calls
      case caller_event
      when :c_call
        c_blocks[caller_method] += 1
      when :call
        rb_blocks[caller_method] += 1
      end
    end

    method_trace.enable
    block_trace.enable
    super(n, &block)
  ensure
    block_trace.disable
    method_trace.disable

    show_distribution = proc do |all_counts, subject: nil, header: nil|
      all_total = all_counts.sum(&:last)
      top_counts = all_counts.sort_by { |_method, count| -count }.first(100)
      top_ratio = 100.0 * top_counts.sum(&:last) / all_total

      puts "#{header || "Top #{top_counts.size} #{subject} (#{'%.1f' % top_ratio}% of all #{all_total} calls)"}:"
      top_counts.each do |method, count|
        puts '%8d (%4.1f%%) %s' % [count, 100.0 * count / all_total, method]
      end
      puts
    end

    show_distribution.call({
      'C method calls'        => c_calls.sum(&:last),
      'Ruby method calls'     => rb_calls.sum(&:last),
      'block calls from C'    => c_blocks.sum(&:last),
      'block calls from Ruby' => rb_blocks.sum(&:last),
    }, header: 'The overall breakdown of each call type')

    show_distribution.call(c_calls,   subject: 'C method calls')
    show_distribution.call(rb_calls,  subject: 'Ruby method calls')
    show_distribution.call(c_blocks,  subject: 'block calls from C')
    show_distribution.call(rb_blocks, subject: 'block calls from Ruby')
  end
}
