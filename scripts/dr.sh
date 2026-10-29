#!/usr/bin/env bash
# dr.sh – Ahrefs Domain Rating (DR) for domains or URLs, one JSON object per
# target on stdout. Part of the getdr skill by Index Pages:
# https://index-pages.com/getdr
#
# Usage: dr.sh [--version dr3|dr4] [--fresh] [--raw] [-f FILE] [TARGET...]
#        printf '%s\n' a.com b.com | dr.sh
#
# Backends, the first one that applies is used:
#   1. GETDR_API is set: POST $GETDR_API/dr to a getdr server
#      (Authorization: Bearer $GETDR_SERVE_TOKEN when that is set).
#   2. getdr is on PATH: getdr --format json -q.
#   3. GETDR_KEY or AHREFS_KEY is set (GETDR_KEY wins): POST to
#      https://api.ahrefs.com/v3/public/domain-rating-free in batches of 1000.
#   4. None of these: exit 3 with a link to https://index-pages.com/getdr#key.
#
# Output (every backend): NDJSON, in input order after normalization and
# de-duplication, exactly like getdr --format json:
#   {"target":"x.com","dr":49,"version":"dr3","checked_at":"2026-10-28T12:00:00Z","cached":false}
# dr is null for an invalid target, no response or no data; checked_at is
# null only for an invalid target or no response; an invalid target also gets
# "error":"invalid target". stderr gets only error lines ("getdr: invalid
# target: X" for each invalid one).
#
# Exit codes: 0 ok, 2 error, invalid targets or targets without a response,
# 3 Ahrefs API key missing or rejected (nothing on stdout).
#
# Needs bash, curl and jq 1.6 or newer; with the getdr binary (backend 2)
# only bash.
# Network: only $GETDR_API and api.ahrefs.com. No telemetry.

set -eu

VERSION=0.2.0
USER_AGENT="getdr/$VERSION (+https://index-pages.com/getdr)"
AHREFS_URL=https://api.ahrefs.com/v3/public/domain-rating-free
KEY_HELP=https://index-pages.com/getdr#key
BATCH=1000
TIMEOUT=30
RETRIES=3

usage() {
	cat <<'EOF'
dr.sh – Ahrefs Domain Rating (DR) for domains, as NDJSON.

Usage:
  dr.sh [flags] <domain|url>...
  dr.sh [flags] -f FILE        one target per line, # comments; "-" = stdin
  printf '%s\n' a.com b.com | dr.sh [flags]

Flags:
  -f, --file FILE    read targets from FILE ("-" for stdin, like a bare -)
      --version V    DR version dr3 or dr4, values are not comparable;
                     default: the getdr server's or binary's config, else dr3
      --fresh        bypass caches (getdr binary or server) and refetch
      --raw          send targets as given, without normalization
  -h, --help         show this help

Backends: GETDR_API (getdr server), getdr on PATH, GETDR_KEY / AHREFS_KEY.
Exit codes: 0 ok, 2 error, invalid targets or targets without a response,
3 key missing or rejected.

Docs: https://index-pages.com/getdr
EOF
}

die() {
	code=$1
	shift
	printf 'getdr: %s\n' "$*" >&2
	exit "$code"
}

need() {
	command -v "$1" >/dev/null 2>&1 ||
		die 2 "dr.sh needs $1 ($2); install it, or install the getdr binary"
}

# --- arguments --------------------------------------------------------------

orig=("$@")
targets=()
version=
dash=false
fresh=false
raw=false
file=
have_file=false
while [ $# -gt 0 ]; do
	case $1 in
	--)
		shift
		for a in "$@"; do targets+=("$a"); done
		break
		;;
	-h | --help)
		usage
		exit 0
		;;
	-f | --file)
		[ $# -ge 2 ] || die 2 "$1 needs a value"
		file=$2
		have_file=true
		shift
		;;
	--file=*) file=${1#--file=} have_file=true ;;
	-f?*) file=${1#-f} have_file=true ;;
	--version)
		[ $# -ge 2 ] || die 2 "--version needs dr3 or dr4 (the DR version)"
		version=$2
		shift
		;;
	--version=*) version=${1#--version=} ;;
	--fresh) fresh=true ;;
	--raw) raw=true ;;
	-)
		targets+=(-)
		dash=true
		;;
	-?*) die 2 "unknown flag $1 (see dr.sh --help)" ;;
	*) targets+=("$1") ;;
	esac
	shift
done
case $version in
"" | dr3 | dr4) ;;
*) die 2 "--version: \"$version\" is not dr3 or dr4" ;;
esac

# --- backend 2: the getdr binary does everything itself ---------------------

api=$(printf '%s' "${GETDR_API:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's:/*$::')
case $api in
"" | http://* | https://*) ;;
*) die 2 "GETDR_API must start with http:// or https://" ;;
esac
if [ -z "$api" ] && command -v getdr >/dev/null 2>&1; then
	rc=0
	out=$(getdr --format json -q ${orig[@]+"${orig[@]}"}) || rc=$?
	if [ -n "$out" ]; then printf '%s\n' "$out"; fi
	exit "$rc"
fi

# --- shared jq code ---------------------------------------------------------

# Target normalization, identical to getdr's internal/target: URL -> host,
# userinfo and port dropped, lower-case, one trailing dot and one leading
# "www." removed, xn-- labels decoded (RFC 3492). gotrim matches Go's strings.TrimSpace, golower Go's
# strings.ToLower for ASCII, Latin-1, Latin Extended-A and Additional, Greek,
# Cyrillic, Armenian and fullwidth Latin. Upper-case letters of other scripts
# (e.g. Latin Extended-B, Georgian) are not lower-cased here, unlike in getdr.
# shellcheck disable=SC2016 # jq code, not shell
JQ_LIB='
def gows: "[\t\n\u000b\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]";
def gotrim: sub("\\A" + gows + "+"; "") | sub(gows + "+\\z"; "");
def even_up: if . % 2 == 0 then . + 1 else . end;
def odd_up: if . % 2 == 1 then . + 1 else . end;
def lcp:
  if . < 65 then .
  elif . <= 90 then . + 32
  elif . < 192 then .
  elif . <= 222 then (if . == 215 then . else . + 32 end)
  elif . < 256 then .
  elif . <= 311 then (if . == 304 then 105 else even_up end)
  elif . <= 328 then odd_up
  elif . <= 375 then (if . == 329 then . else even_up end)
  elif . == 376 then 255
  elif . <= 382 then odd_up
  elif . < 880 then .
  elif . <= 1023 then
    if . == 880 or . == 882 or . == 886 or . == 1018 then . + 1
    elif . == 895 then 1011
    elif . == 902 then 940
    elif . >= 904 and . <= 906 then . + 37
    elif . == 908 then 972
    elif . == 910 or . == 911 then . + 63
    elif . >= 913 and . <= 939 and . != 930 then . + 32
    elif . == 975 then 983
    elif . >= 984 and . <= 1006 then even_up
    elif . == 1012 then 952
    elif . == 1015 then 1016
    elif . == 1017 then 1010
    elif . >= 1021 then . - 130
    else . end
  elif . <= 1039 then . + 80
  elif . <= 1071 then . + 32
  elif . < 1120 then .
  elif . <= 1153 then even_up
  elif . < 1162 then .
  elif . <= 1215 then even_up
  elif . == 1216 then 1231
  elif . <= 1230 then odd_up
  elif . < 1232 then .
  elif . <= 1327 then even_up
  elif . < 1329 then .
  elif . <= 1366 then . + 48
  elif . < 7680 then .
  elif . <= 7829 then even_up
  elif . == 7838 then 223
  elif . < 7840 then .
  elif . <= 7935 then even_up
  elif . >= 65313 and . <= 65338 then . + 32
  else . end;
def golower: if test("[^\\x00-\\x7f]") then explode | map(lcp) | implode else ascii_downcase end;
def splithost:
  if test("\\A[^\\[\\]:]*:[^\\[\\]:]*\\z") then sub(":[^\\[\\]:]*\\z"; "")
  elif test("\\A\\[[^\\[\\]]*\\]:[^\\[\\]:]*\\z") then sub("\\A\\[(?<h>[^\\[\\]]*)\\]:[^\\[\\]:]*\\z"; "\(.h)")
  else . end;
def pdigit: if . >= 48 and . <= 57 then . - 22 elif . >= 65 and . <= 90 then . - 65
  elif . >= 97 and . <= 122 then . - 97 else -1 end;
def padapt($delta; $points; $first):
  (if $first then $delta / 700 else $delta / 2 end | floor) as $d
  | [$d + ($d / $points | floor), 0]
  | until(.[0] <= 455; [(.[0] / 35 | floor), .[1] + 36])
  | .[1] + (36 * .[0] / (.[0] + 38) | floor);
def pstep($in):
  .oldi = .i | .w = 1 | .k = 36 | .done = false
  | until(.done or .fail;
      if .pos >= ($in | length) then .fail = true
      else ($in[.pos] | pdigit) as $d
        | .pos += 1
        | if $d < 0 or $d > ((2147483647 - .i) / .w | floor) then .fail = true
          else .i += $d * .w
            | (.k - .bias | if . < 1 then 1 elif . > 26 then 26 else . end) as $t
            | if $d < $t then .done = true
              elif .w > (2147483647 / (36 - $t) | floor) then .fail = true
              else .w *= 36 - $t | .k += 36 end
          end
      end)
  | if .fail then .
    else (.out | length + 1) as $np
      | .bias = padapt(.i - .oldi; $np; .oldi == 0)
      | if (.i / $np | floor) > 2147483647 - .n then .fail = true
        else .n += (.i / $np | floor) | .i %= $np
          | if .n > 1114111 or (.n >= 55296 and .n <= 57343) then .fail = true
            else .out = .out[:.i] + [.n] + .out[.i:] | .i += 1 end
        end
    end;
def punydecode:
  explode as $cs
  | ([range($cs | length) as $x | select($cs[$x] == 45) | $x] | last) as $b
  | (if $b == null then [[], $cs] else [$cs[:$b], $cs[$b + 1:]] end) as [$basic, $in]
  | if any($basic[]; . >= 128) then null
    else {out: $basic, n: 128, i: 0, bias: 72, pos: 0, fail: false}
      | until(.fail or .pos >= ($in | length); pstep($in))
      | if .fail then null else .out | implode end
    end;
def tounicode:
  if test("xn--") | not then .
  else split(".")
    | map(if length > 4 and (.[:4] | ascii_downcase) == "xn--"
          then (.[4:] | punydecode) as $u | if $u == null or $u == "" then . else $u | golower end
          else . end)
    | join(".")
  end;
def norm:
  gotrim
  | if test("://") then sub("\\A[\\s\\S]*?://"; "") else sub("\\A//"; "") end
  | sub("[/?#][\\s\\S]*\\z"; "")
  | sub("\\A[\\s\\S]*@"; "")
  | splithost
  | golower
  | sub("\\.\\z"; "")
  | tounicode
  | sub("\\Awww\\."; "");
def badchar: explode | any(.[]; . <= 32 or (. >= 127 and . <= 160) or . == 5760
  or (. >= 8192 and . <= 8202) or . == 8232 or . == 8233 or . == 8239 or . == 8287 or . == 12288);
def valid: (norm != "") and (badchar | not);
def dedup:
  reduce .[] as $t ({seen: {}, out: []};
    if $t == "" or .seen[$t] then . else .seen[$t] = true | .out += [$t] end)
  | .out;
def record($v): {target: ., dr: null, version: $v, checked_at: null, cached: false};
def num: if type == "number" then . + 0 else null end;
def errtext:
  (try fromjson catch null) as $j
  | if ($j | type) == "object" and ($j.error | type) == "string" and $j.error != "" then $j.error
    elif ($j | type) == "array" and ($j | length) > 0 and ($j[-1] | type) == "string" then $j[-1]
    else gotrim | if length > 200 then .[:200] + "…" elif . == "" then "empty response" else . end
    end;
'

# --- targets ----------------------------------------------------------------

need jq "https://jqlang.org/"
jq_version=$(jq --version 2>/dev/null || true)
case $jq_version in
jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
*) die 2 "dr.sh needs jq 1.6 or newer, found ${jq_version:-an unknown version}; update jq (https://jqlang.org/), or install the getdr binary" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/getdr-skill.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Arguments are taken as they are; file and stdin lines are trimmed, and blank
# and # lines skipped, like getdr does. A bare - argument is replaced by the
# stdin lines, -f lines follow the arguments. Arguments go to jq NUL-separated,
# so a target that looks like a jq flag stays a target.
# shellcheck disable=SC2016
prepare='
  def lines: split("\n") | map(gotrim | select(. != "" and (startswith("#") | not)));
  (lines) as $stdin
  | ($args | split("\u0000") | .[:-1]) as $a
  | ($a | index("-")) as $d
  | ((if $d == null then $a else $a[:$d] + $stdin + ($a[$d + 1:] | map(select(. != "-"))) end)
     + (if $file_stdin then (if $d == null then $stdin else [] end) else ($ftext | lines) end)) as $in
  | {n: ($in | length),
     t: ($in | map(gotrim | select(. != "") | if $raw then . else (norm as $n | if $n == "" then . else $n end) end)
          | dedup)}
  | .v = (.t | map(select(valid)))
  | .bad = [.t[] | select(valid | not)]'
file_stdin=false
ftext=/dev/null
if $have_file; then
	if [ "$file" = - ]; then
		file_stdin=true
	elif [ ! -f "$file" ] || [ ! -r "$file" ]; then
		die 2 "open $file: no such readable file"
	else
		ftext=$file
	fi
elif [ ${#targets[@]} -eq 0 ]; then
	if [ -t 0 ]; then
		usage >&2
		exit 2
	fi
	file_stdin=true
fi
src=/dev/null
if $dash || $file_stdin; then src=/dev/stdin; fi
: >"$tmp/args"
if [ ${#targets[@]} -gt 0 ]; then printf '%s\0' "${targets[@]}" >"$tmp/args"; fi
jq -Rsc --argjson raw "$raw" --argjson file_stdin "$file_stdin" --rawfile args "$tmp/args" --rawfile ftext "$ftext" \
	"$JQ_LIB $prepare" <"$src" >"$tmp/prepared.json"
[ "$(jq .n "$tmp/prepared.json")" -gt 0 ] || die 2 "no targets"
jq -c .t "$tmp/prepared.json" >"$tmp/targets.json"
[ "$(jq length "$tmp/targets.json")" -gt 0 ] || die 2 "no valid targets"
# Targets without a host or with whitespace or control characters are
# invalid and never sent, like in getdr.
jq -c .v "$tmp/prepared.json" >"$tmp/valid.json"
jq -c --arg v "$version" "$JQ_LIB"'.bad[] | record($v) + {inv: true}' "$tmp/prepared.json" >"$tmp/results"
count=$(jq length "$tmp/valid.json")

key=${GETDR_KEY:-}
[ -n "$key" ] || key=${AHREFS_KEY:-}
key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# curl with ~/.curlrc ignored (-q must come first) and the secret headers in a
# file, so keys and tokens never show up in the process list.
umask 077
post() { # url body-file max-time -> sets code, crc, cerr; writes $tmp/resp, $tmp/head
	crc=0
	code=$(curl -q -sS -A "$USER_AGENT" -H @"$tmp/headers" --data-binary @"$2" \
		-D "$tmp/head" -o "$tmp/resp" -w '%{http_code}' --max-time "$3" "$1" 2>"$tmp/cerr") || crc=$?
	cerr=
	if [ "$crc" -eq 28 ]; then
		cerr="timeout after ${3}s"
	elif [ "$crc" -ne 0 ]; then
		cerr=$(head -n 1 "$tmp/cerr")
		[ -n "$cerr" ] || cerr="curl exit code $crc"
	fi
}
errtext() { jq -Rsr "$JQ_LIB errtext" "$tmp/resp"; }
noresponse() { # reason -> no-response records for all targets in $tmp/batch.json
	jq -c --arg v "$version" --arg err "$1" "$JQ_LIB"'.[] | record($v) + {err: $err}' "$tmp/batch.json"
}

# Print the records in target order, report invalid targets and targets
# without a response like getdr does, exit 0 or 2. Records made before the DR
# version was known (no --version, through a getdr server) get the version the
# server answered with, or dr3.
finish() {
	jq -cs --slurpfile t "$tmp/targets.json" '
	  ([.[].version | select(. != "")][0] // "dr3") as $dv
	  | (map({key: .target, value: (if .version == "" then .version = $dv else . end)}) | from_entries) as $m
	  | $t[0][] | $m[.]' \
		"$tmp/results" >"$tmp/ordered"
	jq -r 'select(.inv) | "getdr: invalid target: \(.target)"' "$tmp/ordered" >&2
	jq -rs '
	  [.[] | select(.err)]
	  | reduce .[] as $x ([]; if any(.[]; .r == $x.err)
	      then map(if .r == $x.err then .t += [$x.target] else . end)
	      else . + [{r: $x.err, t: [$x.target]}] end)
	  | .[]
	  | "getdr: no response for \(.t | length) target(s): \(.r): "
	    + (if (.t | length) > 10 then (.t[:10] | join(", ")) + " and \(.t | length - 10) more"
	       else .t | join(", ") end)' "$tmp/ordered" >&2
	jq -c '{target, dr, version, checked_at, cached} + (if .inv then {error: "invalid target"} else {} end)' "$tmp/ordered"
	if jq -se 'any(.[]; .err or .inv)' "$tmp/ordered" >/dev/null; then exit 2; fi
	exit 0
}

# Only invalid targets: nothing to ask, no key needed.
[ "$count" -gt 0 ] || finish
if [ -z "$api" ] && [ -z "$key" ]; then
	die 3 "no getdr server (GETDR_API), getdr binary or Ahrefs API key (GETDR_KEY, AHREFS_KEY) found. Get a free key: $KEY_HELP"
fi
need curl "https://curl.se/"

# --- backend 1: a getdr server ----------------------------------------------

if [ -n "$api" ]; then
	{
		printf 'Content-Type: application/json\nAccept: application/json\n'
		if [ -n "${GETDR_SERVE_TOKEN:-}" ]; then printf 'Authorization: Bearer %s\n' "$GETDR_SERVE_TOKEN"; fi
	} >"$tmp/headers"
	jq -c --arg v "$version" --argjson fresh "$fresh" --argjson raw "$raw" \
		'{targets: .} + (if $v == "" then {} else {version: $v} end) + {fresh: $fresh, raw: $raw}' "$tmp/valid.json" >"$tmp/body"
	cp "$tmp/valid.json" "$tmp/batch.json"
	batches=$(((count + BATCH - 1) / BATCH))
	post "$api/dr" "$tmp/body" $((TIMEOUT * (RETRIES + 1) * batches + 30))
	server="getdr server $api"
	if [ -n "$cerr" ]; then
		noresponse "$server: $cerr" >>"$tmp/results"
	elif [ "$code" = 200 ]; then
		jq -c --arg v "$version" --arg s "$server" --rawfile resp "$tmp/resp" "$JQ_LIB"'
		  ($resp | try (fromjson | [.]) catch null) as $r
		  | if $r == null or ($r[0] | type) != "object" or (($r[0].results // []) | type) != "array"
		    then .[] | record($v) + {err: "\($s): unexpected response"}
		    else
		      (reduce ($r[0].results // [])[] as $x ({};
		        if ($x | type) == "object" and ($x.target | type) == "string" then .[$x.target] = $x else . end)) as $m
		      | .[] as $t | $m[$t] as $x
		      | (if ($x.version | type) == "string" and $x.version != "" then $x.version else $v end) as $xv
		      | if $x == null then $t | record($v) + {err: "missing from getdr server response"}
		        elif $x.error == "invalid target" then $t | record($xv) + {inv: true}
		        elif $x.checked_at == null then $t | record($xv) + {err: "\($s): no response from Ahrefs"}
		        else {target: $t, dr: ($x.dr | num), version: $xv, checked_at: $x.checked_at, cached: ($x.cached == true)}
		        end
		    end' "$tmp/valid.json" >>"$tmp/results"
	elif [ "$code" = 503 ]; then
		msg="$server: $(errtext)"
		case $msg in *"$KEY_HELP"*) ;; *) msg="$msg; see $KEY_HELP" ;; esac
		die 3 "$msg"
	elif [ "$code" = 401 ]; then
		noresponse "$server: $(errtext) (set GETDR_SERVE_TOKEN)" >>"$tmp/results"
	else
		noresponse "$server: HTTP $code: $(errtext)" >>"$tmp/results"
	fi
	finish
fi

# --- backend 3: straight to Ahrefs ------------------------------------------

version=${version:-dr3}
printf 'Authorization: Bearer %s\nContent-Type: application/json\nAccept: application/json\n' "$key" >"$tmp/headers"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# One batch with retries on 429, 5xx and network errors (backoff 1s, 2s, 4s
# or Retry-After, at most 60s). Sets outcome to ok, fail, key or invalid
# (HTTP 400 naming one target of the batch, in $bad), and reason.
fetch_batch() {
	attempt=0
	while :; do
		post "$AHREFS_URL?output=json" "$tmp/body" "$TIMEOUT"
		wait_s=0
		if [ -n "$cerr" ]; then
			reason=$cerr
		else
			case $code in
			200)
				outcome=ok
				return
				;;
			401)
				outcome=key reason="Ahrefs API key rejected by Ahrefs (HTTP 401: $(errtext)); see $KEY_HELP"
				return
				;;
			403)
				outcome=key reason="Ahrefs API key refused by Ahrefs (HTTP 403: $(errtext)); see $KEY_HELP"
				return
				;;
			429 | 5??)
				reason="HTTP $code: $(errtext)"
				wait_s=$(sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$tmp/head" | tail -n 1)
				;;
			400)
				reason="HTTP $code: $(errtext)"
				bad=$(jq -jr --rawfile resp "$tmp/resp" "$JQ_LIB"'
				  . as $batch
				  | ($resp | errtext | [match("invalid domain or url: \u0027(.*)\u0027\\s*\\z").captures[0].string]) as $x
				  | $batch[] | select(. == $x[0])' "$tmp/batch.json")
				if [ -n "$bad" ]; then outcome=invalid; else outcome=fail; fi
				return
				;;
			*)
				outcome=fail reason="HTTP $code: $(errtext)"
				return
				;;
			esac
		fi
		if [ "$attempt" -ge "$RETRIES" ]; then
			if [ "$attempt" -gt 0 ]; then reason="$reason (after $attempt retries)"; fi
			outcome=fail
			return
		fi
		d=$((1 << attempt))
		if [ "${wait_s:-0}" -gt "$d" ]; then d=$wait_s; fi
		if [ "$d" -gt 60 ]; then d=60; fi
		sleep "$d"
		attempt=$((attempt + 1))
	done
}

batches=$(((count + BATCH - 1) / BATCH))
i=0
while [ "$i" -lt "$batches" ]; do
	if [ "$i" -gt 0 ]; then sleep 1.5; fi
	jq -c ".[$((i * BATCH)):$(((i + 1) * BATCH))]" "$tmp/valid.json" >"$tmp/batch.json"
	# Ahrefs fails a whole batch with HTTP 400 when one target is not a
	# domain or URL and names it: mark that one invalid and resend the rest
	# (a new request, not a retry) until the batch passes or is empty.
	outcome=empty
	while [ "$(jq length "$tmp/batch.json")" -gt 0 ]; do
		jq -c --arg v "$version" '{targets: ., version: $v}' "$tmp/batch.json" >"$tmp/body"
		fetch_batch
		[ "$outcome" = invalid ] || break
		jq -nc --arg v "$version" --arg x "$bad" "$JQ_LIB"'$x | record($v) + {inv: true}' >>"$tmp/results"
		jq -c --arg x "$bad" 'map(select(. != $x))' "$tmp/batch.json" >"$tmp/batch.next"
		mv "$tmp/batch.next" "$tmp/batch.json"
		outcome=empty
		sleep 1.5
	done
	case $outcome in
	empty) ;;
	key) die 3 "$reason" ;;
	fail) noresponse "$reason" >>"$tmp/results" ;;
	ok)
		# Same matching as getdr: each response item is used at most once.
		# First by name (exact, lower-cased, then getdr-normalized on both
		# sides, as items echo "a.com/"; the first item wins a name), then,
		# when the counts
		# match, a target without a name match takes the item at its own
		# position if no other target claimed it. An error, a null or a
		# missing rating is "no data"; 0 is a value.
		jq -c --arg v "$version" --arg now "$now" --rawfile resp "$tmp/resp" "$JQ_LIB"'
		  def opt($types): (type) as $t | any($types[]; . == $t);
		  . as $batch
		  | ($resp | try (fromjson | [.]) catch null) as $r
		  | ($r | if . == null then null else .[0] | try (.domain_rating.targets // []) catch null end) as $items
		  | if ($items | type) != "array"
		       or any($items[]; opt(["object", "null"]) | not)
		       or any($items[] // {}; (.target | opt(["string", "null"]) | not)
		            or (.domain_rating | opt(["number", "null"]) | not)
		            or (.error | opt(["string", "null"]) | not))
		    then .[] | record($v) + {err: "unexpected response from Ahrefs"}
		    else
		      ($items | map(. // {})) as $items
		      | (reduce range($items | length) as $j ({};
		          ($items[$j].target // "") as $t
		          | reduce ($t, ($t | golower), ($t | norm)) as $k (.;
		              if $k == "" or has($k) then . else .[$k] = $j end))) as $by
		      | (reduce range($batch | length) as $i ({named: [], used: {}};
		          ($by[$batch[$i]] // $by[$batch[$i] | golower] // $by[$batch[$i] | norm]) as $j
		          | if $j != null and (.used[$j | tostring] | not)
		            then .named += [$j] | .used[$j | tostring] = true
		            else .named += [null] end)) as $m
		      | $m.named as $named
		      | $m.used as $used
		      | range($batch | length) as $i
		      | $batch[$i] as $t
		      | ($named[$i]
		         // (if ($items | length) == ($batch | length) and ($used[$i | tostring] | not)
		             then $i else null end)) as $j
		      | {target: $t,
		         dr: (if $j != null and ($items[$j].error // "") == "" then $items[$j].domain_rating | num else null end),
		         version: $v, checked_at: $now, cached: false}
		    end' "$tmp/batch.json" >>"$tmp/results"
		;;
	esac
	i=$((i + 1))
done

finish
