# frozen_string_literal: true

require_relative "test_helper"
require "repology_index"

# Tests for {RepologyIndex}.
class RepologyIndexTest < Minitest::Test
  def recording_fetcher(pages_by_path)
    calls = []
    fetcher = lambda do |path|
      calls << path
      pages_by_path.fetch(path) { flunk "unexpected fetch: #{path}" }
    end
    [fetcher, calls]
  end

  def new_index(fetcher:, **opts)
    RepologyIndex.new(fetcher:, sleeper: ->(_) {}, logger: nil, **opts)
  end

  def full_page(base)
    padding = (1..(RepologyIndex::PAGE_SIZE - base.size)).to_h { |i| ["~pad#{i}", []] }
    base.merge(padding)
  end

  def test_osv_distro_maps_known_prefixes
    {
      "debian_12"           => "Debian",
      "ubuntu_24_04"        => "Ubuntu",
      "alpine_edge"         => "Alpine",
      "opensuse_tumbleweed" => "openSUSE",
      "rocky_9"             => "Rocky Linux",
      "almalinux_9"         => "AlmaLinux",
      "mageia_cauldron"     => "Mageia",
      "openeuler_24_03"     => "openEuler",
      "ubi_8"               => "Red Hat",
      "freebsd"             => "FreeBSD",
    }.each do |repo, eco|
      assert_equal eco, RepologyIndex.osv_distro(repo).fetch(:ecosystem), "repo=#{repo}"
    end
  end

  def test_osv_distro_nil_for_unmapped_repo
    %w[scoop homebrew fedora_44 centos_8].each do |repo|
      assert_nil RepologyIndex.osv_distro(repo)
    end
  end

  def test_osv_distro_rejects_opensuse_addon_repos
    assert_nil RepologyIndex.osv_distro("opensuse_games_tumbleweed")
    assert_nil RepologyIndex.osv_distro("opensuse_network_tumbleweed")
    assert_equal "openSUSE", RepologyIndex.osv_distro("opensuse_leap_15_6").fetch(:ecosystem)
  end

  def test_homebrew_entries_returns_name_to_preferred_flag
    entries = fixture("repology_page1.json")["apache-ant"]
    assert_equal({ "ant" => true, "ant@1.9" => true }, RepologyIndex.homebrew_entries(entries))
  end

  def test_homebrew_entries_marks_rolling_as_not_preferred
    entries = [
      { "repo" => "homebrew", "srcname" => "allegro", "status" => "rolling" },
      { "repo" => "homebrew", "srcname" => "allegro", "status" => "legacy" },
    ]
    assert_equal({ "allegro" => false }, RepologyIndex.homebrew_entries(entries))
  end

  def test_ambiguous_homebrew_set_false_for_versioned_variants
    refute RepologyIndex.ambiguous_homebrew_set?(["ant", "ant@1.9"])
    refute RepologyIndex.ambiguous_homebrew_set?(["postgresql@16", "postgresql@17"])
    refute RepologyIndex.ambiguous_homebrew_set?(["curl"])
  end

  def test_ambiguous_homebrew_set_true_for_distinct_upstreams
    assert RepologyIndex.ambiguous_homebrew_set?(["antlr", "antlr4-cpp-runtime"])
    assert RepologyIndex.ambiguous_homebrew_set?(["ansible", "ansible-lint"])
  end

  def test_build_resolves_cross_project_collision_via_preferred_status
    page = {
      "allegro"  => [{ "repo" => "homebrew", "srcname" => "allegro", "status" => "newest" },
                     { "repo" => "debian_12", "srcname" => "allegro5" }],
      "allegro4" => [{ "repo" => "homebrew", "srcname" => "allegro", "status" => "rolling" },
                     { "repo" => "debian_12", "srcname" => "allegro4.4" }],
    }
    fetcher, = recording_fetcher("/projects/?inrepo=homebrew" => page)
    result = new_index(fetcher:).build
    assert_equal({ "Debian" => ["allegro5"] }, result["formulae"]["allegro"])
    assert_empty result["meta"]["colliding_formulae"]
  end

  def test_build_dedups_boundary_project_by_name_even_when_payload_differs
    boundary = "~z-boundary"
    page1 = full_page(boundary => [{ "repo" => "homebrew", "srcname" => "foo", "status" => "newest" },
                                   { "repo" => "debian_12", "srcname" => "foo" }])
    page2 = { boundary => [{ "repo" => "homebrew", "srcname" => "foo", "status" => "newest" },
                           { "repo" => "debian_12", "srcname" => "foo" },
                           { "repo" => "alpine_3_22", "srcname" => "foo" }] }
    fetcher, = recording_fetcher(
      "/projects/?inrepo=homebrew"                                       => page1,
      "/projects/#{URI.encode_uri_component(boundary)}/?inrepo=homebrew" => page2,
    )
    result = new_index(fetcher:).build
    assert_equal({ "Debian" => ["foo"] }, result["formulae"]["foo"])
    assert_empty result["meta"]["colliding_formulae"]
  end

  def test_build_records_unresolvable_cross_project_collision
    page = {
      "p1" => [{ "repo" => "homebrew", "srcname" => "foo", "status" => "newest" },
               { "repo" => "debian_12", "srcname" => "foo1" }],
      "p2" => [{ "repo" => "homebrew", "srcname" => "foo", "status" => "outdated" },
               { "repo" => "debian_12", "srcname" => "foo2" }],
    }
    fetcher, = recording_fetcher("/projects/?inrepo=homebrew" => page)
    result = new_index(fetcher:).build
    refute_includes result["formulae"], "foo"
    assert_equal({ "foo" => ["p1", "p2"] }, result["meta"]["colliding_formulae"])
  end

  def test_homebrew_entries_empty_without_homebrew_entry
    entries = [{ "repo" => "debian_12", "srcname" => "foo" }]
    assert_empty RepologyIndex.homebrew_entries(entries)
  end

  def test_distil_collapses_versioned_repos_to_sorted_arrays_per_ecosystem
    entries = fixture("repology_page1.json")["curl"]
    result = RepologyIndex.distil(entries)
    assert_equal(
      {
        "Alpine"    => ["curl"],
        "Debian"    => ["curl"],
        "FreeBSD"   => ["curl"],
        "Red Hat"   => ["curl"],
        "Ubuntu"    => ["curl"],
        "openEuler" => ["curl"],
        "openSUSE"  => ["curl"],
      },
      result,
    )
    assert_equal result.keys.sort, result.keys
  end

  def test_distil_freebsd_uses_binname
    entries = [{ "repo" => "freebsd", "srcname" => "ftp/curl", "binname" => "curl" }]
    assert_equal({ "FreeBSD" => ["curl"] }, RepologyIndex.distil(entries))
  end

  def test_distil_collects_all_distinct_srcnames_per_ecosystem
    entries = fixture("repology_page1.json")["ack"]
    assert_equal({ "Ubuntu" => ["ack", "ack-grep"] }, RepologyIndex.distil(entries))
  end

  def test_distil_drops_legacy_status
    entries = [
      { "repo" => "alpine_3_17", "srcname" => "old-name", "status" => "legacy" },
      { "repo" => "alpine_3_22", "srcname" => "curl", "status" => "newest" },
    ]
    assert_equal({ "Alpine" => ["curl"] }, RepologyIndex.distil(entries))
  end

  def test_distil_falls_back_to_binname_when_srcname_absent
    entries = fixture("repology_page2.json")["zstd"]
    assert_equal ["zstd"], RepologyIndex.distil(entries)["Mageia"]
  end

  def test_distil_uses_distro_specific_srcname
    entries = fixture("repology_page1.json")["libgee"]
    assert_equal(
      { "Alpine" => ["libgee"], "Debian" => ["libgee-0.8"] },
      RepologyIndex.distil(entries),
    )
  end

  def test_distil_skips_entries_without_a_name
    entries = [{ "repo" => "debian_12", "status" => "newest" }]
    assert_empty RepologyIndex.distil(entries)
  end

  def test_build_paginates_by_max_key_and_aggregates_all_homebrew_names
    page1 = full_page(fixture("repology_page1.json"))
    page2 = fixture("repology_page2.json")
    max_key = page1.keys.max
    fetcher, calls = recording_fetcher(
      "/projects/?inrepo=homebrew"                                      => page1,
      "/projects/#{URI.encode_uri_component(max_key)}/?inrepo=homebrew" => page2,
    )

    result = new_index(fetcher:).build

    assert_equal(
      ["/projects/?inrepo=homebrew",
       "/projects/#{URI.encode_uri_component(max_key)}/?inrepo=homebrew"],
      calls,
    )
    assert_equal ["ack", "ant", "ant@1.9", "curl", "libgee", "zstd"], result["formulae"].keys
    assert_equal result["formulae"]["ant"], result["formulae"]["ant@1.9"]
    assert_equal(
      { "AlmaLinux" => ["zstd"], "Mageia" => ["zstd"], "Rocky Linux" => ["zstd"] },
      result["formulae"]["zstd"],
    )
  end

  def test_build_stops_on_first_short_page
    fetcher, calls = recording_fetcher("/projects/?inrepo=homebrew" => fixture("repology_page1.json"))
    result = new_index(fetcher:).build
    assert_equal 1, calls.size
    assert_equal ["ack", "ant", "ant@1.9", "curl", "libgee"], result["formulae"].keys
  end

  def test_build_respects_page_limit
    page = full_page("only" => [{ "repo" => "homebrew", "srcname" => "only" },
                                { "repo" => "debian_12", "srcname" => "only" }])
    fetcher, calls = recording_fetcher("/projects/?inrepo=homebrew" => page)
    new_index(fetcher:, page_limit: 1).build
    assert_equal 1, calls.size
  end

  def test_build_omits_formulae_with_no_mapped_distros
    fetcher, = recording_fetcher("/projects/?inrepo=homebrew" => fixture("repology_page1.json"))
    refute_includes new_index(fetcher:).build["formulae"], "brew-only-tool"
  end

  def test_build_records_ambiguous_projects_and_omits_their_formulae
    fetcher, = recording_fetcher("/projects/?inrepo=homebrew" => fixture("repology_page1.json"))
    result = new_index(fetcher:).build
    refute_includes result["formulae"], "antlr"
    refute_includes result["formulae"], "antlr4-cpp-runtime"
    assert_equal({ "antlr" => ["antlr", "antlr4-cpp-runtime"] }, result["meta"]["ambiguous_projects"])
  end

  def test_build_logs_ambiguous_and_colliding_skips
    logger = StringIO.new
    page = fixture("repology_page1.json").merge(
      "p1" => [{ "repo" => "homebrew", "srcname" => "foo", "status" => "newest" },
               { "repo" => "debian_12", "srcname" => "foo1" }],
      "p2" => [{ "repo" => "homebrew", "srcname" => "foo", "status" => "newest" },
               { "repo" => "debian_12", "srcname" => "foo2" }],
    )
    fetcher, = recording_fetcher("/projects/?inrepo=homebrew" => page)
    RepologyIndex.new(fetcher:, sleeper: ->(_) {}, logger:).build
    assert_match(/skipped 1 ambiguous project .*repology-rules.*: antlr\b/, logger.string)
    assert_match(/skipped 1 cross-project formula .*: foo\b/, logger.string)
  end

  def test_build_meta_is_deterministic
    fetcher, = recording_fetcher("/projects/?inrepo=homebrew" => fixture("repology_page1.json"))
    meta = new_index(fetcher:).build["meta"]
    assert_equal RepologyIndex::API_BASE, meta["source"]
    assert_equal RepologyIndex::OSV_DISTROS.map { |_, v| v[:ecosystem] }.uniq.sort, meta["osv_distros"]
    assert_equal %w[ambiguous_projects colliding_formulae osv_distros source], meta.keys.sort
  end

  def test_write_creates_output_directory_and_emits_pretty_json
    Dir.mktmpdir do |dir|
      out = File.join(dir, "sub", "repology.json")
      fetcher, = recording_fetcher("/projects/?inrepo=homebrew" => fixture("repology_page1.json"))
      new_index(fetcher:).write(out)
      parsed = JSON.parse(File.read(out))
      assert_equal ["ack", "ant", "ant@1.9", "curl", "libgee"], parsed["formulae"].keys
      assert File.read(out).end_with?("\n")
    end
  end

  # Test double replacing {RepologyIndex#http_request} with a scripted
  # sequence so retry behaviour is exercised without touching the network.
  class ScriptedIndex < RepologyIndex
    attr_reader :attempts

    def initialize(responses:)
      super(sleeper: ->(_) {}, logger: nil)
      @responses = responses
      @attempts = 0
    end

    def http_request(_uri)
      @attempts += 1
      action = @responses.shift
      raise "scripted responses exhausted" unless action

      action.respond_to?(:call) ? action.call : action
    end
  end

  def ok(body)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |r|
      r.instance_variable_set(:@body, body)
      r.instance_variable_set(:@read, true)
    end
  end

  def test_retries_server_error_then_succeeds
    idx = ScriptedIndex.new(responses: [
      Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable"),
      ok("{}"),
    ])
    assert_equal "{}", idx.http_get("/x")
    assert_equal 2, idx.attempts
  end

  def test_retries_transient_network_error_then_succeeds
    idx = ScriptedIndex.new(responses: [-> { raise EOFError }, ok("{}")])
    assert_equal "{}", idx.http_get("/x")
    assert_equal 2, idx.attempts
  end

  def test_raises_after_exhausting_retries
    responses = Array.new(RepologyIndex::MAX_ATTEMPTS) { -> { raise Errno::ETIMEDOUT } }
    idx = ScriptedIndex.new(responses:)
    err = assert_raises(RepologyIndex::Error) { idx.http_get("/x") }
    assert_match(/Errno::ETIMEDOUT/, err.message)
    assert_equal RepologyIndex::MAX_ATTEMPTS, idx.attempts
  end

  def test_does_not_retry_client_errors
    idx = ScriptedIndex.new(responses: [Net::HTTPForbidden.new("1.1", "403", "Forbidden")])
    assert_raises(RepologyIndex::Error) { idx.http_get("/x") }
    assert_equal 1, idx.attempts
  end
end
