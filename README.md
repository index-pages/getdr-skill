# getdr-skill

`getdr-skill` is an agent skill by [Index Pages](https://index-pages.com) that answers one question:
what is the Ahrefs Domain Rating (DR) of these domains. It wraps [getdr](https://index-pages.com/getdr)
and works without it too: with a getdr server, with the getdr binary, or straight against the official
free Ahrefs endpoint with your own key. The output is the same NDJSON in every case.

## Install the skill

The skill is a folder with a `SKILL.md`, so it works with any agent that loads Agent Skills.
For Claude Code:

```sh
git clone https://github.com/index-pages/getdr-skill ~/.claude/skills/getdr
```

Or per project, in `.claude/skills/getdr`. Other agents: put the folder where they look for skills.

Requirements: bash, curl and jq. With the getdr binary on `PATH`, only bash.

Optional: install the getdr binary for a local cache and DR history. `scripts/install.sh` downloads the
release archive for your OS and CPU, verifies its SHA-256 against `checksums.txt` and copies the binary
to `~/.local/bin` (or `$PREFIX/bin`); it runs nothing it downloads. Other ways to install:
[index-pages.com/getdr](https://index-pages.com/getdr).

## Use

```sh
scripts/dr.sh saas.com
scripts/dr.sh https://www.example.com/page a.com b.com
scripts/dr.sh -f domains.txt
printf '%s\n' a.com b.com | scripts/dr.sh
scripts/dr.sh --version dr4 --fresh saas.com
```

Flags: `-f FILE` (one target per line, blank and `#` lines skipped, `-` for stdin), `--version dr3|dr4`
(default `dr3`), `--fresh` (bypass caches), `--raw` (no target normalization), `-h`.

Targets are normalized exactly like getdr does: a URL becomes its host, userinfo and port are dropped,
`www.` is removed, everything is lower-cased and duplicates are removed, keeping the first occurrence.

## Backends

`scripts/dr.sh` uses the first one that applies:

1. `GETDR_API` is set – one `POST $GETDR_API/dr` to a [getdr server](https://index-pages.com/getdr#api).
   `GETDR_SERVE_TOKEN`, when set, is sent as `Authorization: Bearer …` (the same variable the getdr CLI
   uses).
2. `getdr` is on `PATH` – `getdr --format json -q`, with the binary's own config and cache.
3. `GETDR_KEY` or `AHREFS_KEY` is set (`GETDR_KEY` wins) – `POST https://api.ahrefs.com/v3/public/domain-rating-free`
   in batches of up to 1000 targets, 1.5 s apart, with a 30 s timeout per request and up to 3 retries with
   exponential backoff on 429, 5xx and network errors. After the results, one line on stderr suggests
   installing the getdr binary.
4. None of these – exit code 3 and a pointer to [getting a free key](https://index-pages.com/getdr#key).

## Output

One JSON object per target on stdout, the same object as `getdr --format json`, `getdr serve` and
the getdr MCP server:

```json
{"target":"saas.com","dr":49,"version":"dr3","checked_at":"2026-10-28T12:00:00Z","cached":false}
```

| field | |
|---|---|
| `target` | normalized target (as given with `--raw`) |
| `dr` | number, or `null` when Ahrefs has no data or did not answer; `0` is a value |
| `version` | `dr3` or `dr4`; the two formulas give values that are not comparable |
| `checked_at` | RFC 3339 UTC; `null` only when there was no response |
| `cached` | `true` when served from a getdr cache; always `false` on the direct path |

Exit codes: `0` ok, `2` error or targets without a response (still printed, with `dr` and `checked_at`
`null`), `3` Ahrefs API key missing or rejected (nothing on stdout).

## Attribution

Domain Rating data comes from [Ahrefs](https://ahrefs.com/) and is subject to the
[Domain Rating License](https://ahrefs.com/legal/domain-rating-license), which requires the attribution
"Domain Rating by Ahrefs". `scripts/dr.sh` prints `Domain Rating by Ahrefs – https://ahrefs.com/` once
per run on stderr, never on stdout. Keep it when you publish the numbers.

getdr is not affiliated with Ahrefs.

## No telemetry

`scripts/dr.sh` connects to `GETDR_API` or `api.ahrefs.com` and nowhere else; `scripts/install.sh` only
to the release download URL. No telemetry, no update checks, no analytics. Requests carry the User-Agent
`getdr/0.1.0 (+https://index-pages.com/getdr)`. Keys and tokens are passed to curl in a temporary file
(mode 600), never on the command line.

## Tests

```sh
GETDR_SRC=/path/to/getdr tests/run.sh
```

Builds getdr and its mock server from a checkout of the [getdr repo](https://github.com/index-pages/getdr)
and runs every backend against local mocks: no key and no network. With `AHREFS_KEY` set, a short live
check runs as well.

## License

MIT, see [LICENSE](LICENSE). Made by [Index Pages](https://index-pages.com).
