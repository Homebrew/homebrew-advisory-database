# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"

# Shared test helpers for the advisory-database test suite.
module TestHelpers
  FIXTURE_DIR = File.expand_path("fixtures", __dir__).freeze

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURE_DIR, name)))
  end
end

Minitest::Test.include TestHelpers
