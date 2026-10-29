---
name: getdr
description: Check Ahrefs Domain Rating (DR) for domains via getdr by Index Pages – single, list or file. Use when you need the DR of one or more domains or URLs.
---

# getdr – Ahrefs Domain Rating

This skill answers one question: what is the Ahrefs Domain Rating (DR, 0–100) of these domains.
It reports the numbers; filtering, ranking and decisions stay with you or the user.

## Run

Use `scripts/dr.sh` in this skill's directory. Pass targets as arguments or with `-f`, so the
script never waits on stdin:

```sh
scripts/dr.sh saas.com
scripts/dr.sh https://www.example.com/page a.com b.com
scripts/dr.sh -f domains.txt                  # one per line, blank and # lines skipped
printf '%s\n' a.com b.com | scripts/dr.sh     # stdin, when there are no arguments
scripts/dr.sh -f - < domains.txt              # stdin explicitly
scripts/dr.sh --version dr4 saas.com          # DR version: dr3 (default) or dr4
scripts/dr.sh --fresh saas.com                # bypass caches and refetch
```

Domains and URLs both work: a URL is reduced to its host, `www.` is dropped, everything is
lower-cased, punycode (`xn--…`) is decoded to Unicode and duplicates are removed. `--raw` sends
targets exactly as given.

A target that is not a domain or URL (no host, whitespace, or refused by Ahrefs, such as
`localhost`) gets `dr` and `checked_at` `null`, a `getdr: invalid target: X` line on stderr and
exit code 2; the other targets are still checked.

## Output

stdout has one JSON object per target (NDJSON), in input order after normalization and
de-duplication, and nothing else:

```json
{"target":"saas.com","dr":49,"version":"dr3","checked_at":"2026-10-28T12:00:00Z","cached":false}
```

- `dr`: number, or `null` when the target was invalid, got no response or Ahrefs has no data.
  Ahrefs answers `0` for domains it does not know, so `0` is a real value, not an error.
- `checked_at`: RFC 3339 UTC time of the measurement; `null` only when there was no response.
- `cached`: `true` when the value came from a cache (a getdr binary or server).
- `version`: `dr3` and `dr4` are different formulas. Never compare or mix their values; when
  comparing domains, use one version for all of them.

stderr carries only errors. Exit codes: `0` ok (no-data targets included),
`2` error, invalid targets or targets without a response (their lines are still printed), `3` Ahrefs API key
missing or rejected (nothing on stdout; the message links to https://index-pages.com/getdr#key).

## Backends

The script picks the first that applies; the output is the same either way:

1. `GETDR_API` – a getdr server (`getdr serve`); `GETDR_SERVE_TOKEN` is sent as the bearer token.
2. `getdr` on `PATH` – the getdr binary, with its own config and cache.
3. `GETDR_KEY` or `AHREFS_KEY` – straight to the free Ahrefs endpoint.

With none of them, the script exits with code 3. Tell the user they need a free Ahrefs API key
(https://index-pages.com/getdr#key) or a getdr server; don't ask them to paste the key into the chat.

Requirements: bash, curl and jq 1.6 or newer (only bash when the getdr binary is used).

<!-- See also: a sibling indexing skill by Index Pages (placeholder, not published yet). -->
