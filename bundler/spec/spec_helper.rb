# frozen_string_literal: true

require "psych"
require "bundler/vendored_fileutils"
require "bundler/vendored_uri"
require "digest"

if File.expand_path(__FILE__) =~ %r{([^\w/\.:\-])}
  abort "The bundler specs cannot be run from a path that contains special characters (particularly #{$1.inspect})"
end

require "bundler"
require "rspec/core"
require "rspec/expectations"
require "rspec/mocks"
require "rspec/support/differ"

require_relative "support/builders"
require_relative "support/build_metadata"
require_relative "support/filters"
require_relative "support/helpers"
require_relative "support/indexes"
require_relative "support/matchers"
require_relative "support/permissions"
require_relative "support/platforms"
require_relative "support/sudo"

$debug = false

module Gem
  def self.ruby=(ruby)
    @ruby = ruby
  end
end

RSpec.configure do |config|
  config.include Spec::Builders
  config.include Spec::Helpers
  config.include Spec::Indexes
  config.include Spec::Matchers
  config.include Spec::Path
  config.include Spec::Platforms
  config.include Spec::Sudo
  config.include Spec::Permissions

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  config.silence_filter_announcements = !ENV["TEST_ENV_NUMBER"].nil?

  config.disable_monkey_patching!

  # Since failures cause us to keep a bunch of long strings in memory, stop
  # once we have a large number of failures (indicative of core pieces of
  # bundler being broken) so that running the full test suite doesn't take
  # forever due to memory constraints
  config.fail_fast ||= 25 if ENV["CI"]

  config.bisect_runner = :shell

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.allow_message_expectations_on_nil = false
  end

  config.before :suite do
    Gem.ruby = ENV["RUBY"] if ENV["RUBY"]

    require_relative "support/rubygems_ext"
    Spec::Rubygems.test_setup
    ENV["BUNDLER_SPEC_RUN"] = "true"
    ENV["BUNDLER_NO_OLD_RUBYGEMS_WARNING"] = "true"
    ENV["BUNDLE_USER_CONFIG"] = ENV["BUNDLE_USER_CACHE"] = ENV["BUNDLE_USER_PLUGIN"] = nil
    ENV["RUBYGEMS_GEMDEPS"] = nil
    ENV["XDG_CONFIG_HOME"] = nil
    ENV["GEMRC"] = nil

    extend(Spec::Helpers)

    # Ruby-core needs RUBYLIB set, leave any "internal" RUBYLIB entries to avoid
    # resetting that, but reset anything else to avoid external stuff like asdf
    # hooks from interfering with our specs

    rubylib = ENV["RUBYLIB"]
    rubylib = rubylib.split(File::PATH_SEPARATOR).select {|p| p.start_with?(git_root.to_s) }.join(File::PATH_SEPARATOR) if rubylib
    ENV["RUBYLIB"] = rubylib

    # Don't wrap output in tests
    ENV["THOR_COLUMNS"] = "10000"

    system_gems :bundler, :path => pristine_system_gem_path
  end

  config.before :all do
    check_test_gems!

    build_repo1

    reset_paths!
  end

  config.around :each do |example|
    begin
      FileUtils.cp_r pristine_system_gem_path, system_gem_path

      with_gem_path_as(system_gem_path) do
        Bundler.ui.silence { example.run }

        all_output = all_commands_output
        if example.exception && !all_output.empty?
          message = all_output + "\n" + example.exception.message
          (class << example.exception; self; end).send(:define_method, :message) do
            message
          end
        end
      end
    ensure
      reset!
    end
  end

  config.before :each, :sudo => true do
    Spec::Sudo.write_safe_config
  end

  config.after :suite do
    FileUtils.rm_r Spec::Path.pristine_system_gem_path
  end
end
