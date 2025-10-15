# Solves a board using Lee but sequentially.

# Note: we probably do not *want* to set up Bundler here, for roughly the same reason
# we don't run "bundle install" above.

require_relative 'lib/lee'

#board_filename, output_filename, expansions_dir, *rest = ARGV
#raise 'no input filename' unless board_filename
#raise 'too many arguments' unless rest.empty?
board_filename = File.dirname(__FILE__) + "/inputs/testBoard.txt"
output_filename = "/tmp/testBoard.svg"
expansions_dir = nil

if expansions_dir
  system 'rm', '-rf', expansions_dir
  Dir.mkdir expansions_dir
end

board = Lee.read_board(board_filename)

obstructed = Lee::Matrix.new(board.height, board.width)
board.pads.each do |pad|
  obstructed[pad.y, pad.x] = 1
end

def expand(board, obstructed, depth, route)
  start_point = route.a
  end_point = route.b

  # From benchmarking - we're better of allocating a new cost-matrix each time rather than zeroing
  cost = Lee::Matrix.new(board.height, board.width)
  cost[start_point.y, start_point.x] = 1

  wavefront = [start_point]

  loop do
    new_wavefront = []

    wavefront.each do |point|
      point_cost = cost[point.y, point.x]
      Lee.adjacent(board, point).each do |adjacent|
        next if obstructed[adjacent.y, adjacent.x] == 1 && adjacent != route.b
        current_cost = cost[adjacent.y, adjacent.x]
        new_cost = point_cost + Lee.cost(depth[adjacent.y, adjacent.x])
        if current_cost == 0 || new_cost < current_cost
          cost[adjacent.y, adjacent.x] = new_cost
          new_wavefront.push adjacent
        end
      end
    end

    raise 'stuck' if new_wavefront.empty?
    break if cost[end_point.y, end_point.x] > 0 && cost[end_point.y, end_point.x] < new_wavefront.map { |marked| cost[marked.y, marked.x] }.min

    wavefront = new_wavefront
  end

  cost
end

def solve(board, route, cost)
  start_point = route.b
  end_point = route.a

  solution = [start_point]

  loop do
    adjacent = Lee.adjacent(board, solution.last)
    lowest_cost = adjacent
      .reject { |a| cost[a.y, a.x].zero? }
      .min_by { |a| cost[a.y, a.x] }
    solution.push lowest_cost
    break if lowest_cost == end_point
  end

  solution.reverse
end

def lay(depth, solution)
  solution.each do |point|
    depth[point.y, point.x] += 1
  end
end

require_relative "../../harness/loader"
Dir.chdir __dir__
use_gemfile

BOARD = Ractor.make_shareable(board)
OBSTRUCTED = Ractor.make_shareable(obstructed)
OUTPUT_FILENAME = Ractor.make_shareable(output_filename)
EXPANSIONS_DIR = Ractor.make_shareable(expansions_dir)

run_benchmark(10) do
  depth = Lee::Matrix.new(BOARD.height, BOARD.width)

  solutions = {}

  BOARD.routes.each do |route|
    cost = expand(BOARD, OBSTRUCTED, depth, route)
    solution = solve(BOARD, route, cost)

    if EXPANSIONS_DIR
      Lee.draw BOARD, solutions.values, [[cost.keys, solution]], File.join(EXPANSIONS_DIR, "expansion-#{route.object_id}.svg")
    end

    lay depth, solution
    solutions[route] = solution
  end

  raise 'invalid solution' unless Lee.solution_valid?(BOARD, solutions)

  cost, depth = Lee.cost_solutions(BOARD, solutions)
  #puts "routes: #{BOARD.routes.size}"
  #puts "cost:   #{cost}"
  #puts "depth:  #{depth}"

  Lee.draw BOARD, solutions.values, OUTPUT_FILENAME if OUTPUT_FILENAME
end
