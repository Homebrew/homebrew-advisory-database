# Homebrew Advisory Database

OSV-format vulnerability records for Homebrew packages. Each record describes a CVE that affected a homebrew-core formula and the Homebrew version+revision at which it was fixed by an applied patch.

This is an early demo. It currently covers only CVEs that a formula's `patch` block declares (or infers) as resolved, derived from `patches[].resolves` in `brew info --json=v2` (Homebrew 6.0.4+). See [Homebrew/discussions#6869](https://github.com/orgs/Homebrew/discussions/6869) for background and [Homebrew/homebrew-brew-vulns#95](https://github.com/Homebrew/homebrew-brew-vulns/issues/95) for the annotation backfill.

## Record format

Records follow the [OSV schema](https://ossf.github.io/osv-schema/) under a `Homebrew` ecosystem with `pkg:brew/<name>` purls and `BREW-<formula>-<CVE>` ids. The `upstream` field links to the source CVE; summary, details, severity and references are copied from the upstream OSV record where available. `affected[].ecosystem_specific` carries the URL and applied-file list of the resolving patch.

```json
{
  "schema_version": "1.7.3",
  "id": "BREW-lrzsz-CVE-2018-10195",
  "upstream": ["CVE-2018-10195"],
  "affected": [{
    "package": {"ecosystem": "Homebrew", "name": "lrzsz", "purl": "pkg:brew/lrzsz"},
    "ranges": [{"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "0.12.20_1"}]}],
    "ecosystem_specific": {"fix": "patch", "patches": [{"url": "..."}]}
  }]
}
```

The `fixed` boundary is currently the version+revision shipped at generation time, not necessarily the revision that introduced the patch. Tightening that requires git archaeology on homebrew-core and will come later.

Homebrew versions are the upstream version with an optional `_N` revision suffix; `1.81.6_5` < `1.81.6_6` < `1.82.0`.

## Generation

Records are produced by `brew generate-vulns-advisories` (Homebrew/brew#23106) and regenerated daily by the `Regenerate` workflow. Every push is validated against the OSV JSON schema.

## Status

The `Homebrew` ecosystem and `BREW-` id prefix are registered in the OSV schema ([ossf/osv-schema#576](https://github.com/ossf/osv-schema/pull/576)) and `pkg:brew` is a registered purl type ([package-url/purl-spec#796](https://github.com/package-url/purl-spec/pull/796)).

Not yet ingested by osv.dev. Remaining before opening a [new data source](https://google.github.io/osv.dev/data/new) request:

- `pkg:brew` handling in osv.dev's `purl_helpers.py` and a Homebrew version comparator in `_ecosystems.py`

## License

Advisory data is released under [CC0 1.0](LICENSE).
