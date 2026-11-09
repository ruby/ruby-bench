# frozen_string_literal: true

source "https://rubygems.org"

gem "csv"
gem "minitest", "~> 5.0"
gem "minitest-mock"
gem "rake"

# Windows CI skips this group because rmagick does not build against MSYS2's ImageMagick.
group :graph do
  gem "gruff"
  gem "rmagick"
end
