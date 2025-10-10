# frozen_string_literal: true

require_relative "../../harness/loader"

Dir.chdir(__dir__)
use_gemfile

# This benchmark checks the Ruby LSP indexing mechanism, which is used to keep track of all project declarations in
# every file of a project and its dependencies

require "ruby_lsp/internal"

path = File.expand_path("fixture.rb", __dir__)
INDEX_PATH = Ractor.make_shareable(RubyIndexer::IndexablePath.new(File.expand_path("../..", __dir__), path))
CONTENT = Ractor.make_shareable(File.read(path))

run_benchmark(200) do
  RubyIndexer::Index.new.index_single(INDEX_PATH, CONTENT)
end
