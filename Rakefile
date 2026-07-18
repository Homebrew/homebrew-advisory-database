# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test

namespace :repology do
  desc "Build data/repology.json from the Repology API"
  task :build do
    require_relative "lib/repology_index"
    limit = ENV["REPOLOGY_PAGE_LIMIT"]&.to_i
    RepologyIndex.new(page_limit: limit).write("data/repology.json")
  end
end
