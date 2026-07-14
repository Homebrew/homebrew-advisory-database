# Contributing

Advisories in this repository come from two places: records generated from `resolves` annotations on `homebrew/core` formula patches, and records contributed directly by pull request. Both live under `advisories/` as [OSV-schema](https://ossf.github.io/osv-schema/) JSON and are validated against that schema on every push.

## Reporting a fixed vulnerability

If a `homebrew/core` formula already ships a patch that fixes a CVE, the simplest route is to annotate the patch. Open a pull request against [Homebrew/homebrew-core](https://github.com/Homebrew/homebrew-core) adding `resolves "CVE-YYYY-NNNNN"` to the relevant `patch do` block; see [`libquicktime.rb`](https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/lib/libquicktime.rb) for an example. CVE identifiers appearing in the patch URL or applied file paths are picked up automatically without an explicit `resolves`. The daily `Regenerate` workflow will pick it up and write a `BREW-<formula>-<CVE>` record here automatically. Generated records carry `"database_specific": {"source": "generated"}`. The workflow refreshes their upstream-derived fields (`summary`, `severity`, `references`, `ecosystem_specific.patches`) on each run but preserves `published` and `affected[].ranges` from whatever is on disk, so a hand-corrected `fixed` boundary will not be overwritten.

## Contributing an advisory directly

Open a pull request adding a file under `advisories/` when you want to record something the generated path cannot express, most commonly that a formula version is affected and Homebrew has not yet applied a fix.

Before opening the PR, report the issue upstream according to the project's security policy and wait for it to be acknowledged. If you believe the vulnerability is being actively exploited against Homebrew users, or the upstream project is unresponsive after a reasonable disclosure window, open a [private security advisory](https://github.com/Homebrew/advisory-database/security/advisories/new) on this repository instead of a public PR.

Name the file `BREW-0000-0000.json`; a maintainer assigns the final id on merge. The record must validate against the OSV schema and use the `Homebrew` ecosystem with a `pkg:brew/<formula>` purl. A minimal example:

```json
{
  "schema_version": "1.7.3",
  "id": "BREW-0000-0000",
  "modified": "2026-01-01T00:00:00Z",
  "upstream": ["CVE-YYYY-NNNNN"],
  "summary": "One-line description",
  "affected": [{
    "package": {"ecosystem": "Homebrew", "name": "example", "purl": "pkg:brew/example"},
    "ranges": [{"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "1.2.3"}]}]
  }],
  "references": [{"type": "ADVISORY", "url": "https://..."}]
}
```

Use `{"introduced": "0"}` if every shipped version is affected. Omit the `fixed` event if there is no fixed version yet; add it in a follow-up PR once one exists. Versions are the formula version as `brew info` reports it, with an `_N` suffix when the revision is nonzero. Link the upstream CVE, GHSA or advisory in `upstream` and `references`.

## Scope

Records here describe vulnerabilities in software Homebrew distributes, scoped to the Homebrew formula name and version. They are not a substitute for the upstream project's own advisory; the purpose is to let tools that read `pkg:brew` purls or `Homebrew` OSV queries answer "is this installed formula affected". Casks are out of scope for now.

## Code of Conduct

This project follows the [Homebrew Code of Conduct](https://github.com/Homebrew/.github/blob/HEAD/CODE_OF_CONDUCT.md).
