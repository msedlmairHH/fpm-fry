require 'simplecov'
require 'coveralls'
SimpleCov.start do
  formatter SimpleCov::Formatter::MultiFormatter[
    SimpleCov::Formatter::HTMLFormatter,
    Coveralls::SimpleCov::Formatter
  ]
  add_filter "/spec"
  add_filter "lib/fpm/dockery/os_db.rb"
  maximum_coverage_drop 5
end
RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

