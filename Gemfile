source "https://rubygems.org"

gemspec

gem "rake-compiler"

gem "json", "~> 2.3"
gem "nio4r", "~> 2.0"
gem "minitest", "~> 5.11"
gem "minitest-retry"
gem "minitest-proveit"
gem "minitest-stub-const"
gem "concurrent-ruby", "~> 1.3"

case ENV['PUMA_CI_RACK']&.strip
when 'rack2'
  gem "rackup", '~> 1.0'
  gem "rack"  , '~> 2.2'
when 'rack1'
  gem "rack"  , '~> 1.6'
else
  gem "rackup", '>= 2.0'
  if RUBY_PATCHLEVEL == -1
    gem "rack", git: "https://github.com/rack/rack", ref: "main"
  else
    gem "rack"  , '>= 2.2'
  end
end

gem "jruby-openssl", :platform => "jruby"

unless ENV['PUMA_NO_RUBOCOP'] || RUBY_PLATFORM.include?('mswin')
  gem "rubocop"
  gem 'rubocop-performance', require: false
end

if RUBY_VERSION >= '3.5' && ::Bundler::WINDOWS
  gem "fiddle"
end

if RUBY_VERSION == '2.4.1'
  gem "stopgap_13632", "~> 1.0", :platforms => ["mri", "mingw", "x64_mingw"]
elsif Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.5")
  gem "logger"
end

gem 'm'
gem "localhost", require: false
