require_relative "../../harness/loader"

Dir.chdir __dir__
use_gemfile

require "graphql"

DATA = Ractor.make_shareable(File.read "negotiate.gql")

if ENV["YJIT_BENCH_RACTOR_HARNESS"]
  GraphQL.default_parser
  Ractor.make_shareable(GraphQL::Tracing::NullTrace)
  GraphQL::Language::Lexer.constants.each do |constant|
    Ractor.make_shareable(GraphQL::Language::Lexer.const_get(constant))
  end
  GraphQL::Language::Parser.constants.each do |constant|
    Ractor.make_shareable(GraphQL::Language::Parser.const_get(constant))
  end
end

run_benchmark(10) do
  10.times do |i|
    GraphQL.parse DATA
  end
end
