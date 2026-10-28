# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] – 2026-10-28

### Added

- `getdr` agent skill (`SKILL.md`): Ahrefs Domain Rating for one domain, a
  list or a file.
- `scripts/dr.sh`: NDJSON output identical to `getdr --format json` from three
  backends – a getdr server (`GETDR_API`, bearer `GETDR_SERVE_TOKEN`), the
  getdr binary on `PATH`, or the free Ahrefs endpoint directly with
  `GETDR_KEY` / `AHREFS_KEY` (target normalization like getdr, batches of
  1000, retries with backoff on 429/5xx, timeouts); `--version dr3|dr4`,
  `--fresh`, `--raw`, `-f FILE`, stdin; exit codes 0, 2 and 3 as in getdr.
- `scripts/install.sh`: installs the getdr binary from GitHub Releases with
  SHA-256 verification.
- `tests/run.sh`: end-to-end tests of all backends against the getdr mock
  server.

[Unreleased]: https://github.com/index-pages/getdr-skill/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/index-pages/getdr-skill/releases/tag/v0.1.0
