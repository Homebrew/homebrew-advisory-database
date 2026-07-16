# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "openssl"
require "uri"

# Builds `data/repology.json` by paginating the Repology API for every
# project tracked in the `homebrew` repository and distilling each project's
# per-distro package entries into `{formula_name => {osv_ecosystem =>
# [srcname, ...]}}`. Consumed by `Homebrew::Vulns::Repology` in Homebrew/brew.
#
# The API returns rows without ordering guarantees, one Repology project can
# map to several Homebrew formulae (e.g. `ant`, `ant@1.9`) and to several
# distinct source packages within the same distro release, so all candidate
# names are kept per ecosystem rather than picking one.
class RepologyIndex
  API_BASE = "https://repology.org/api/v1"
  USER_AGENT = "Homebrew/advisory-database repology-index " \
               "(+https://github.com/Homebrew/advisory-database)"
  PAGE_SIZE = 200
  THROTTLE_SECONDS = 1.0
  MAX_ATTEMPTS = 3

  # Repology repo-name prefix => OSV.dev ecosystem string.
  # https://osv-vulnerabilities.storage.googleapis.com/ecosystems.txt
  #
  # FreeBSD uses `binname` because Repology's ports `srcname` is the category
  # path (`ftp/curl`) whereas OSV keys on the package name (`curl`).
  OSV_DISTROS = {
    "debian_"             => { ecosystem: "Debian" },
    "ubuntu_"             => { ecosystem: "Ubuntu" },
    "alpine_"             => { ecosystem: "Alpine" },
    # openSUSE is limited to the official Leap/Tumbleweed repos; Repology
    # also tracks community add-on repos (`opensuse_games_*` etc.) whose
    # package names are not OSV `openSUSE` packages.
    "opensuse_leap_"      => { ecosystem: "openSUSE" },
    "opensuse_tumbleweed" => { ecosystem: "openSUSE" },
    "rocky_"              => { ecosystem: "Rocky Linux" },
    "almalinux_"          => { ecosystem: "AlmaLinux" },
    "mageia_"             => { ecosystem: "Mageia" },
    "openeuler_"          => { ecosystem: "openEuler" },
    "ubi_"                => { ecosystem: "Red Hat" },
    "freebsd"             => { ecosystem: "FreeBSD", name_field: "binname" },
  }.freeze

  # `SystemCallError` covers all `Errno::*` (ECONNRESET, ENETUNREACH, EPIPE,
  # ETIMEDOUT, ...) so any syscall failure during the HTTP request is retried.
  RETRYABLE_NET_ERRORS = [
    EOFError, IOError, SocketError, SystemCallError, Timeout::Error,
    Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
  ].freeze

  # Raised on unrecoverable API failures.
  class Error < RuntimeError; end

  # Raised for transient failures that {#http_get} will retry.
  class RetryableError < Error; end

  # `fetcher` receives an API path (e.g. `/projects/?inrepo=homebrew`) and
  # must return the parsed JSON body. Defaults to {#http_get} + `JSON.parse`.
  def initialize(page_limit: nil, fetcher: nil, sleeper: ->(s) { sleep s }, logger: $stderr)
    @page_limit = page_limit
    @fetcher = fetcher || ->(path) { JSON.parse(http_get(path)) }
    @sleeper = sleeper
    @logger = logger
  end

  PREFERRED_STATUSES = %w[newest outdated devel unique noscheme].freeze

  Contribution = Struct.new(:project, :preferred, :distros, keyword_init: true)

  def build
    # Keyed on `[formula][project]` so the boundary project (which the
    # inclusive cursor returns on two consecutive pages) contributes once
    # even if its payload differs slightly between fetches.
    contributions = Hash.new { |h, k| h[k] = {} }
    ambiguous = {}
    each_project do |project, entries|
      brew_entries = self.class.homebrew_entries(entries)
      next if brew_entries.empty?

      distros = self.class.distil(entries)
      next if distros.empty?

      names = brew_entries.keys
      if self.class.ambiguous_homebrew_set?(names)
        ambiguous[project] = names.sort
        next
      end
      brew_entries.each do |formula, preferred|
        contributions[formula][project] ||= Contribution.new(project:, preferred:, distros:)
      end
    end

    formulae, colliding = resolve(contributions)

    log_skipped("ambiguous project", ambiguous.keys) unless ambiguous.empty?
    log_skipped("cross-project formula", colliding.keys) unless colliding.empty?

    {
      "meta"     => {
        "source"             => API_BASE,
        "osv_distros"        => OSV_DISTROS.map { |_, v| v.fetch(:ecosystem) }.uniq.sort,
        "ambiguous_projects" => ambiguous.sort.to_h,
        "colliding_formulae" => colliding.sort.to_h,
      },
      "formulae" => formulae.sort.to_h,
    }
  end

  def each_project(&block)
    cursor = nil
    page = 0
    loop do
      page += 1
      projects = fetch_page(cursor)
      log "page #{page}: #{projects.size} projects (cursor=#{cursor.inspect})"
      break if projects.empty?

      projects.each(&block)

      break if projects.size < PAGE_SIZE
      break if @page_limit && page >= @page_limit

      # Repology serialises pages from an unordered HashMap and the cursor
      # bound is inclusive (`effname >= cursor`), so advance by the maximum
      # key. The boundary project reappears on the next page harmlessly.
      cursor = projects.keys.max
      @sleeper.call(THROTTLE_SECONDS)
    end
  end

  # A single Homebrew formula can appear in more than one Repology project
  # (e.g. `allegro` in both `allegro` at 5.x/newest and `allegro4` as
  # HEAD/rolling). Prefer the project where Homebrew's status is one of
  # {PREFERRED_STATUSES}. If zero or more than one qualifies the collision
  # cannot be resolved automatically and the formula is omitted; the fix is a
  # PR to https://github.com/repology/repology-rules, not a local override.
  def resolve(contributions)
    formulae = {}
    colliding = {}
    contributions.each do |formula, by_project|
      cs = by_project.values
      chosen = cs.one? ? cs : cs.select(&:preferred)
      if chosen.one?
        formulae[formula] = chosen.first.distros
      else
        colliding[formula] = by_project.keys.sort
      end
    end
    [formulae, colliding]
  end

  def log_skipped(kind, names)
    log "skipped #{names.size} #{kind}#{"s" unless names.one?} " \
        "(fix via repology-rules PR): #{names.sort.join(", ")}"
  end

  def write(path)
    result = build
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(result)}\n")
    log "wrote #{result["formulae"].size} formulae to #{path} (#{File.size(path)} bytes)"
    result
  end

  def fetch_page(cursor)
    path = if cursor
      "/projects/#{URI.encode_uri_component(cursor)}/?inrepo=homebrew"
    else
      "/projects/?inrepo=homebrew"
    end
    @fetcher.call(path)
  end

  def http_get(path)
    uri = URI("#{API_BASE}#{path}")
    attempt = 0
    begin
      attempt += 1
      res = http_request(uri)
      case res
      when Net::HTTPSuccess
        res.body
      when Net::HTTPTooManyRequests, Net::HTTPServerError
        raise RetryableError, "Repology API #{path} returned HTTP #{res.code}"
      else
        raise Error, "Repology API #{path} returned HTTP #{res.code}"
      end
    rescue RetryableError, *RETRYABLE_NET_ERRORS => e
      raise Error, "#{e.class}: #{e.message}" if attempt >= MAX_ATTEMPTS

      backoff = THROTTLE_SECONDS * (2**attempt)
      log "retry #{attempt}/#{MAX_ATTEMPTS - 1} after #{e.class}: #{e.message} (sleeping #{backoff}s)"
      @sleeper.call(backoff)
      retry
    end
  end

  def http_request(uri)
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = USER_AGENT
    req["Accept"] = "application/json"
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 60) do |http|
      # Net::HTTP retries idempotent requests once by default; disable so
      # {#http_get}'s explicit backoff is the only retry path.
      http.max_retries = 0
      http.request(req)
    end
  end

  def log(message)
    @logger&.puts "[repology] #{message}"
  end

  def self.osv_distro(repo)
    OSV_DISTROS.each { |prefix, spec| return spec if repo.start_with?(prefix) }
    nil
  end

  # Returns `{srcname => preferred?}` for each Homebrew entry in the project.
  def self.homebrew_entries(entries)
    result = {}
    entries.each do |e|
      next if e["repo"] != "homebrew"

      name = e["srcname"] || e["binname"]
      next unless name

      result[name] ||= false
      result[name] = true if PREFERRED_STATUSES.include?(e["status"])
    end
    result
  end

  # A Repology project can group unrelated Homebrew formulae (e.g. `antlr` and
  # `antlr4-cpp-runtime`) whose distro packages must not be cross-attributed.
  # Versioned variants of one formula (`ant`, `ant@1.9`) are the same upstream
  # and are safe to fan out. Ambiguous projects are recorded in
  # `meta.ambiguous_projects`; the fix is a repology-rules PR upstream.
  def self.ambiguous_homebrew_set?(names)
    names.map { |n| n.sub(/@.+\z/, "") }.uniq.size > 1
  end

  # Collapse a project's array of per-repo entries into
  # `{osv_ecosystem => [name, ...]}`, sorted and deduplicated. Drops
  # `status: legacy` entries. Uses `srcname` by default and `binname` where
  # {OSV_DISTROS} says so.
  def self.distil(entries)
    result = Hash.new { |h, k| h[k] = [] }
    entries.each do |entry|
      repo = entry["repo"]
      next unless repo

      distro = osv_distro(repo)
      next unless distro
      next if entry["status"] == "legacy"

      name = entry[distro.fetch(:name_field, "srcname")] || entry["binname"]
      next unless name

      result[distro.fetch(:ecosystem)] << name
    end
    result.transform_values! { |names| names.uniq.sort }
    result.default = nil
    result.sort.to_h
  end
end
