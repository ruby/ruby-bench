# frozen_string_literal: true

source "https://rubygems.org"

gem "csv"
gem "minitest", "~> 5.0"
gem "minitest-mock"
gem "rake"

# Opt in with BUNDLE_WITH=callgrind bundle install (requires Valgrind headers).
group :callgrind, optional: true do
  gem "valgrind", "~> 0.0.1"
end

# Windows CI skips this group because rmagick does not build against MSYS2's ImageMagick.
group :graph do
  gem "gruff"
  gem "rmagick"
end
