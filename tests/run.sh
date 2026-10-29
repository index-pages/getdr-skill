#!/usr/bin/env bash
# tests/run.sh – end-to-end tests for scripts/dr.sh. They prove that the three
# backends (getdr server, getdr binary, direct to Ahrefs) print the same
# NDJSON, and check exit codes, stderr, batching and scripts/install.sh.
#
# Needs bash, curl, jq, Go and a checkout of the getdr binary repo
# (https://github.com/index-pages/getdr) in GETDR_SRC, default ../bin next to
# this repo. Everything runs locally against the getdr mock server
# (testdata/mockserve in that repo: the real serve handler plus a fake Ahrefs);
# no key and no network needed. All files go to a temp dir that is removed at
# the end, together with the mock servers.
#
# The direct-to-Ahrefs backend is pointed at the fake Ahrefs by a curl shim
# put first on PATH for those runs only: it rewrites https://api.ahrefs.com/
# to the local fake and logs every call. dr.sh itself has no URL override.
#
# With AHREFS_KEY in the environment a short live check against the real
# Ahrefs API runs as well; without it, it is skipped.

set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
dr=$here/scripts/dr.sh
src=${GETDR_SRC:-$here/../bin}
[ -f "$src/testdata/mockserve/main.go" ] || {
	echo "set GETDR_SRC to a checkout of the getdr repo (not found: $src)" >&2
	exit 2
}
for t in go jq curl; do
	command -v "$t" >/dev/null || {
		echo "missing $t" >&2
		exit 2
	}
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/getdr-skill-test.XXXXXX")
pids=()
cleanup() {
	for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
	for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null || true; done
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf 'ok    %s\n' "$1"
}
bad() {
	fail=$((fail + 1))
	printf 'FAIL  %s\n' "$1"
	if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/      /'; fi
}
check() { # name, then a command that must succeed (its stdout is dropped)
	local name=$1
	shift
	if "$@" >/dev/null; then ok "$name"; else bad "$name"; fi
}

# --- build and start the mocks ----------------------------------------------

echo "building getdr and mockserve from $src"
mkdir -p "$tmp/bin" "$tmp/shim"
(cd "$src" && GOTOOLCHAIN=local CGO_ENABLED=0 go build -o "$tmp/bin/getdr" . &&
	GOTOOLCHAIN=local go build -o "$tmp/mockserve" ./testdata/mockserve)

free_port() {
	while :; do
		p=$((20000 + RANDOM % 40000))
		if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
			echo "$p"
			return
		fi
	done
}
start_mock() { # log-name, mockserve flags...
	local name=$1
	shift
	"$tmp/mockserve" "$@" 2>"$tmp/$name.log" &
	pids+=($!)
}
wait_up() {
	for _ in $(seq 50); do
		curl -q -fs -m 1 "$1/healthz" >/dev/null 2>&1 && return 0
		sleep 0.1
	done
	echo "mock at $1 did not start" >&2
	exit 2
}

p_api=$(free_port)
p_ahrefs=$(free_port)
p_lock=$(free_port)
p_dead=$(free_port)
API=http://127.0.0.1:$p_api
LOCKED=http://127.0.0.1:$p_lock
DEAD=http://127.0.0.1:$p_dead
start_mock main -listen "127.0.0.1:$p_api" -ahrefs "127.0.0.1:$p_ahrefs"
start_mock locked -listen "127.0.0.1:$p_lock" -token s3cret -no-key
wait_up "$API"
wait_up "$LOCKED"

# curl shim for the direct backend: rewrite api.ahrefs.com to $AHREFS_TARGET
# (default the fake Ahrefs) and log the URL and User-Agent of each call. With
# AHREFS_CANNED set, answer 200 with that file instead of calling anything.
cat >"$tmp/shim/curl" <<EOF
#!/usr/bin/env bash
target=\${AHREFS_TARGET:-http://127.0.0.1:$p_ahrefs}
a=()
ua=
prev=
out=
head=
for x in "\$@"; do
	case \$x in https://api.ahrefs.com/*) x=\$target/\${x#https://api.ahrefs.com/} ;; esac
	[ "\$prev" = -A ] && ua=\$x
	[ "\$prev" = -o ] && out=\$x
	[ "\$prev" = -D ] && head=\$x
	case \$x in http://* | https://*) printf 'URL %s\n' "\$x" >>"$tmp/curl.log" ;; esac
	prev=\$x
	a+=("\$x")
done
printf 'UA %s\n' "\$ua" >>"$tmp/curl.log"
if [ -n "\${AHREFS_CANNED:-}" ]; then
	cp "\$AHREFS_CANNED" "\$out"
	printf 'HTTP/1.1 200 OK\r\n\r\n' >"\$head"
	printf 200
	exit 0
fi
exec "$(command -v curl)" "\${a[@]}"
EOF
chmod +x "$tmp/shim/curl"

# PATH without any getdr binary, for the server and direct backends.
clean_path=
IFS=: read -r -a dirs <<<"$PATH"
for d in "${dirs[@]}"; do
	[ -n "$d" ] && [ ! -x "$d/getdr" ] && clean_path=${clean_path:+$clean_path:}$d
done
printf 'api = "%s"\n' "$API" >"$tmp/api.toml"
printf 'api = "%s"\n' "$DEAD" >"$tmp/dead.toml"
printf 'api = "%s"\n' "$LOCKED" >"$tmp/locked.toml"

# run MODE NAME [dr.sh args...]: stdout to $tmp/NAME.out, stderr to
# $tmp/NAME.err, exit code to $tmp/NAME.rc. Stdin is passed through.
run() {
	local mode=$1 name=$2 rc=0
	shift 2
	case $mode in
	api)
		env -u GETDR_KEY -u AHREFS_KEY -u GETDR_SERVE_TOKEN PATH="$clean_path" GETDR_API="$API" \
			"$dr" "$@" >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
		;;
	bin)
		env -u GETDR_KEY -u AHREFS_KEY -u GETDR_API -u GETDR_SERVE_TOKEN PATH="$tmp/bin:$clean_path" \
			GETDR_CONFIG="$tmp/api.toml" GETDR_CACHE_PATH="$tmp/$name.db" \
			"$dr" "$@" >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
		;;
	direct)
		env -u AHREFS_KEY -u GETDR_API PATH="$tmp/shim:$clean_path" GETDR_KEY="${KEY:-test-key}" \
			"$dr" "$@" >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
		;;
	*)
		env -u GETDR_API -u GETDR_KEY -u AHREFS_KEY PATH="$clean_path" "$dr" "$@" >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
		;;
	esac
	echo "$rc" >"$tmp/$name.rc"
}
rc_is() { [ "$(cat "$tmp/$1.rc")" = "$2" ]; }
# Text-only normalization for comparisons: checked_at values become T (null
# stays null), cached becomes X. Numbers and key order stay as printed.
mask() { sed -E 's/"checked_at":"[^"]*"/"checked_at":"T"/; s/"cached":(true|false)/"cached":X/' "$tmp/$1.out"; }
same() { # name-a name-b: masked outputs identical
	if diff <(mask "$1") <(mask "$2") >"$tmp/diff" && [ -s "$tmp/$1.out" ]; then
		ok "$1 == $2 ($(wc -l <"$tmp/$1.out" | tr -d ' ') lines)"
	else
		bad "$1 == $2" "$(head -n 20 "$tmp/diff")"
	fi
}
contract() { # every stdout line is exactly the contract object
	if jq -e -s 'length > 0 and all(.[]; keys_unsorted == ["target", "dr", "version", "checked_at", "cached"]
		and (.target | type) == "string" and (.dr | type == "number" or . == null)
		and (.version == "dr3" or .version == "dr4")
		and (.checked_at == null or (.checked_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
		and (.cached | type) == "boolean")' "$tmp/$1.out" >/dev/null 2>&1; then
		ok "$1: stdout is NDJSON in the contract shape"
	else
		bad "$1: stdout is NDJSON in the contract shape" "$(head -n 5 "$tmp/$1.out")"
	fi
}
no_attribution() {
	if ! grep -q 'Ahrefs' "$tmp/$1.out" "$tmp/$1.err"; then
		ok "$1: no attribution on stdout or stderr"
	else
		bad "$1: no attribution on stdout or stderr" "$(grep -h 'Ahrefs' "$tmp/$1.out" "$tmp/$1.err" | head -n 3)"
	fi
}
errlines() { grep -v -e 'install the getdr binary' "$tmp/$1.err" || true; }
hint_count() { grep -c 'install the getdr binary' "$tmp/$1.err" || true; }

# --- inputs -----------------------------------------------------------------

cat >"$tmp/list.txt" <<'EOF'
# a comment, then a blank line

https://WWW.Saas.com/pricing?x=1#top
saas.com
ahrefs.com
index-pages.com
nodata.example
sub.nodata.example
http://user:pass@Example.ORG:8080/path
//cdn.example.net/lib.js
example.org.
  www.spaced.example
x.example?ref=http://inner.example/
[2001:db8::1]:443
2001:db8::2
ПРИМЕР.РФ
https://www.ÉCOLE.fr/
WWW.
   # indented comment
EOF
printf 'a.example\r\nb.example\r\n' >"$tmp/crlf.txt"
seq -f 'site%g.example' 1 2500 >"$tmp/big.txt"

# --- 1. same JSON from all three backends -----------------------------------

echo "== same output from all backends"
for v in dr3 dr4; do
	run api "api-$v" --version "$v" -f "$tmp/list.txt"
	run bin "bin-$v" --version "$v" -f "$tmp/list.txt"
	run direct "direct-$v" --version "$v" -f "$tmp/list.txt"
	for m in api bin direct; do
		check "$m-$v: exit 0" rc_is "$m-$v" 0
		contract "$m-$v"
		no_attribution "$m-$v"
	done
	same "api-$v" "bin-$v"
	same "api-$v" "direct-$v"
done
check "dr3 and dr4 differ" bash -c "! diff -q <(sed 's/dr4/dr3/' '$tmp/api-dr4.out') '$tmp/api-dr3.out' >/dev/null"
check "direct: checked_at set, cached false" jq -e -s 'all(.[]; .checked_at != null and .cached == false)' "$tmp/direct-dr3.out"
check "nodata.example: dr null, checked_at set" jq -e -s 'any(.[]; .target == "nodata.example" and .dr == null and .checked_at != null)' "$tmp/direct-dr3.out"
check "api: second call is served from the server cache" bash -c "
	env -u GETDR_KEY -u AHREFS_KEY PATH='$clean_path' GETDR_API='$API' '$dr' -f '$tmp/list.txt' 2>/dev/null |
	jq -e -s 'all(.[]; .cached == true)' >/dev/null"

for m in api bin direct; do
	run "$m" "$m-args" HTTPS://WWW.A.example/x a.example b.example
	printf 'a.example\nhttps://b.example/\n# skip\n' | run "$m" "$m-stdin"
	printf 'b.example\n' | run "$m" "$m-dash" a.example -f -
	run "$m" "$m-crlf" -f "$tmp/crlf.txt"
	run "$m" "$m-raw" --raw " HTTPS://WWW.Raw.example/P " raw.example
	run "$m" "$m-fresh" --fresh a.example --version=dr4
	run "$m" "$m-sep" -- a.example
done
for c in args stdin dash crlf raw fresh sep; do
	same "api-$c" "bin-$c"
	same "api-$c" "direct-$c"
done
check "--raw keeps the target as given (trimmed)" jq -e -s '.[0].target == "HTTPS://WWW.Raw.example/P"' "$tmp/direct-raw.out"

echo "== invalid targets and IDN"
# The acceptance list: whitespace (rejected locally), localhost (rejected by
# Ahrefs with HTTP 400 for the whole batch), punycode and Unicode forms of one
# IDN (one target after normalization).
acc=(ahrefs.com 'exa mple.com' localhost github.com xn--e1afmkfd.xn--p1ai 'ПРИМЕР.РФ')
: >"$tmp/curl.log"
for m in api bin direct; do run "$m" "$m-acc" "${acc[@]}"; done
same api-acc bin-acc
same api-acc direct-acc
for m in api bin direct; do check "$m-acc: exit 2" rc_is "$m-acc" 2; done
check "api-acc: same stderr as the binary" cmp -s <(errlines api-acc) <(errlines bin-acc)
check "acc: one line for the IDN, in Unicode" jq -e -s '[.[].target] == ["ahrefs.com", "exa mple.com", "localhost", "github.com", "пример.рф"]' "$tmp/direct-acc.out"
check "acc: invalid targets have dr and checked_at null" jq -e -s '[.[] | select(.target == "exa mple.com" or .target == "localhost") | select(.dr == null and .checked_at == null and .cached == false)] | length == 2' "$tmp/direct-acc.out"
check "direct-acc: invalid-target lines" cmp -s <(errlines direct-acc) <(printf 'getdr: invalid target: exa mple.com\ngetdr: invalid target: localhost\n')
check "direct-acc: 400 isolated, rest resent (2 requests)" bash -c "[ \$(grep -c '^URL ' '$tmp/curl.log') = 2 ]"
run direct direct-allbad 'exa mple.com' https://
check "only invalid targets: exit 2, no request" bash -c "rc_ok=\$(cat '$tmp/direct-allbad.rc'); [ \$rc_ok = 2 ] && [ \$(grep -c '^URL ' '$tmp/curl.log') = 2 ]"
check "only invalid targets: no key needed" bash -c "env -u GETDR_KEY -u AHREFS_KEY -u GETDR_API PATH='$clean_path' '$dr' 'exa mple.com' 2>/dev/null | jq -e '.dr == null' >/dev/null; [ \${PIPESTATUS[0]} = 2 ]"

echo "== batching (2500 targets)"
: >"$tmp/curl.log"
run direct direct-big -f "$tmp/big.txt"
run api api-big -f "$tmp/big.txt"
same api-big direct-big
check "direct: 3 POST requests for 2500 targets" bash -c "[ \$(grep -c '^URL ' '$tmp/curl.log') = 3 ]"
check "direct: only api.ahrefs.com contacted" bash -c "! grep '^URL ' '$tmp/curl.log' | grep -v '^URL http://127.0.0.1:$p_ahrefs/v3/public/domain-rating-free?output=json$'"
check "direct: User-Agent getdr/0.1.0" bash -c "! grep '^UA ' '$tmp/curl.log' | grep -v '^UA getdr/0.1.0 (+https://index-pages.com/getdr)$'"

echo "== stderr"
check "install hint only for the direct backend, once" bash -c "
	[ \"\$(grep -c 'install the getdr binary' '$tmp/direct-dr3.err')\" = 1 ] &&
	! grep -q 'install the getdr binary' '$tmp/api-dr3.err' '$tmp/bin-dr3.err'"

# --- 2. errors and exit codes -----------------------------------------------

echo "== exit codes"
run none none a.example
check "no backend: exit 3" rc_is none 3
check "no backend: link to the key page" grep -q 'https://index-pages.com/getdr#key' "$tmp/none.err"
check "no backend: nothing on stdout" test ! -s "$tmp/none.out"

# Response matching, as in getdr: each item is used at most once, names
# (also normalized) first, then position (regression: b.com used to get
# a.com's 77).
printf '%s' '{"domain_rating":{"license":"x","targets":[{"target":"https://b.com/","domain_rating":5},{"target":"a.com","domain_rating":77}]}}' >"$tmp/canned1.json"
AHREFS_CANNED=$tmp/canned1.json run direct direct-match1 a.com b.com
check "matching: normalized item names, no reuse by position" bash -c "[ \"\$(cat '$tmp/direct-match1.out' | jq -c '[.target, .dr]' | tr -d '\n')\" = '[\"a.com\",77][\"b.com\",5]' ]"
printf '%s' '{"domain_rating":{"license":"x","targets":[{"target":"zzz","domain_rating":5},{"target":"a.com","domain_rating":77}]}}' >"$tmp/canned4.json"
AHREFS_CANNED=$tmp/canned4.json run direct direct-match4 a.com b.com
check "matching: a slot claimed by name is not reused by position" bash -c "[ \"\$(cat '$tmp/direct-match4.out' | jq -c '[.target, .dr]' | tr -d '\n')\" = '[\"a.com\",77][\"b.com\",null]' ]"
printf '%s' '{"domain_rating":{"license":"x","targets":[{"target":"A.COM","domain_rating":11},{"target":"x","domain_rating":22},{"target":"c.com","domain_rating":0}]}}' >"$tmp/canned2.json"
AHREFS_CANNED=$tmp/canned2.json run direct direct-match2 a.com b.com c.com
check "matching: lower-cased name, position fallback, 0 is a value" bash -c "[ \"\$(cat '$tmp/direct-match2.out' | jq -c '[.target, .dr]' | tr -d '\n')\" = '[\"a.com\",11][\"b.com\",22][\"c.com\",0]' ]"
printf '%s' '{"domain_rating":{"license":"x","targets":[{"target":"zzz","domain_rating":9}]}}' >"$tmp/canned3.json"
AHREFS_CANNED=$tmp/canned3.json run direct direct-match3 a.com b.com
check "matching: no position fallback when the counts differ" bash -c "[ \"\$(cat '$tmp/direct-match3.out' | jq -c '[.target, .dr]' | tr -d '\n')\" = '[\"a.com\",null][\"b.com\",null]' ]"

KEY=bad run direct direct-badkey a.example
check "rejected key: exit 3, nothing on stdout" bash -c "[ \$(cat '$tmp/direct-badkey.rc') = 3 ] && [ ! -s '$tmp/direct-badkey.out' ]"
check "rejected key: message" grep -q 'Ahrefs API key rejected by Ahrefs (HTTP 401: Unauthorized); see https://index-pages.com/getdr#key' "$tmp/direct-badkey.err"
check "rejected key: no install hint" test "$(hint_count direct-badkey)" = 0

# Unreachable getdr server: every target without a response, exit 2, the
# same lines from the server backend and from the binary.
rc=0
env -u GETDR_KEY -u AHREFS_KEY PATH="$clean_path" GETDR_API="$DEAD" "$dr" a.example b.example \
	>"$tmp/api-dead.out" 2>"$tmp/api-dead.err" || rc=$?
echo "$rc" >"$tmp/api-dead.rc"
rc=0
env -u GETDR_KEY -u AHREFS_KEY -u GETDR_API PATH="$tmp/bin:$clean_path" GETDR_CONFIG="$tmp/dead.toml" \
	GETDR_CACHE_PATH="$tmp/dead.db" "$dr" a.example b.example >"$tmp/bin-dead.out" 2>"$tmp/bin-dead.err" || rc=$?
echo "$rc" >"$tmp/bin-dead.rc"
check "server down: exit 2 (server backend)" rc_is api-dead 2
check "server down: exit 2 (binary)" rc_is bin-dead 2
check "server down: identical lines" cmp -s "$tmp/api-dead.out" "$tmp/bin-dead.out"
check "server down: dr and checked_at null" jq -e -s 'length == 2 and all(.[]; .dr == null and .checked_at == null and .cached == false)' "$tmp/api-dead.out"
check "server down: no-response line on stderr" grep -q '^getdr: no response for 2 target(s): ' "$tmp/api-dead.err"

# Token-protected server without a key: 401 without the token (exit 2),
# 503 with it (exit 3), same as the binary.
for tok in "" s3cret; do
	n=locked${tok:+-tok}
	rc=0
	env -u GETDR_KEY -u AHREFS_KEY PATH="$clean_path" GETDR_API="$LOCKED" GETDR_SERVE_TOKEN="$tok" "$dr" a.example \
		>"$tmp/api-$n.out" 2>"$tmp/api-$n.err" || rc=$?
	echo "$rc" >"$tmp/api-$n.rc"
	rc=0
	env -u GETDR_KEY -u AHREFS_KEY -u GETDR_API PATH="$tmp/bin:$clean_path" GETDR_CONFIG="$tmp/locked.toml" \
		GETDR_SERVE_TOKEN="$tok" GETDR_CACHE_PATH="$tmp/$n.db" "$dr" a.example \
		>"$tmp/bin-$n.out" 2>"$tmp/bin-$n.err" || rc=$?
	echo "$rc" >"$tmp/bin-$n.rc"
	check "$n: same exit code from server backend and binary ($(cat "$tmp/api-$n.rc"))" \
		test "$(cat "$tmp/api-$n.rc")" = "$(cat "$tmp/bin-$n.rc")"
	check "$n: same stdout" cmp -s "$tmp/api-$n.out" "$tmp/bin-$n.out"
done
check "no token: exit 2" rc_is api-locked 2
check "token, server without key: exit 3, nothing on stdout" bash -c "[ \$(cat '$tmp/api-locked-tok.rc') = 3 ] && [ ! -s '$tmp/api-locked-tok.out' ]"

# Fake Ahrefs unreachable: retries with backoff (1+2+4 s), then exit 2 and
# null lines.
echo "== retries (about 7 s)"
AHREFS_TARGET=$DEAD run direct direct-dead a.example b.example
check "Ahrefs down: exit 2" rc_is direct-dead 2
check "Ahrefs down: dr and checked_at null" jq -e -s 'length == 2 and all(.[]; .dr == null and .checked_at == null)' "$tmp/direct-dead.out"
check "Ahrefs down: after 3 retries" grep -q '^getdr: no response for 2 target(s): .*(after 3 retries): a.example, b.example$' "$tmp/direct-dead.err"
check "Ahrefs down: 4 attempts" bash -c "[ \$(grep -c '^URL $DEAD/' '$tmp/curl.log') = 4 ]"

mkdir -p "$tmp/oldjq"
# shellcheck disable=SC2016 # a script for the shim, expanded there
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo jq-1.5-1-a5b5cbe; exit 0; }\nexec %s "$@"\n' "$(command -v jq)" >"$tmp/oldjq/jq"
chmod +x "$tmp/oldjq/jq"
rc=0
env -u GETDR_API PATH="$tmp/oldjq:$tmp/shim:$clean_path" GETDR_KEY=k "$dr" a.example >"$tmp/oldjq.out" 2>"$tmp/oldjq.err" || rc=$?
check "jq 1.5: exit 2 with a clear message" bash -c "[ $rc = 2 ] && grep -q 'needs jq 1.6 or newer, found jq-1.5' '$tmp/oldjq.err' && [ ! -s '$tmp/oldjq.out' ]"

for m in api bin direct; do
	run "$m" "$m-noargs" </dev/null
	run "$m" "$m-flag" --nope a.example
	run "$m" "$m-ver" --version dr9 a.example
	run "$m" "$m-novalid" "/" "#x"
done
for c in noargs flag ver novalid; do
	check "$c: exit 2 in every backend" bash -c "[ \$(cat '$tmp/api-$c.rc') = 2 ] && [ \$(cat '$tmp/bin-$c.rc') = 2 ] && [ \$(cat '$tmp/direct-$c.rc') = 2 ]"
done

# --- 3. install.sh ----------------------------------------------------------

# A fake release built from the binary above, served by a curl shim that
# copies files from $tmp/release instead of downloading them.
echo "== install.sh"
case $(uname -s) in Linux) os=linux ;; Darwin) os=darwin ;; *) os=unknown ;; esac
case $(uname -m) in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) arch=unknown ;; esac
mkdir -p "$tmp/release" "$tmp/ishim"
archive=getdr_0.1.0_${os}_${arch}.tar.gz
tar -czf "$tmp/release/$archive" -C "$tmp/bin" getdr
(cd "$tmp/release" && { sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive"; } >checksums.txt)
cat >"$tmp/ishim/curl" <<EOF
#!/usr/bin/env bash
out= url=
while [ \$# -gt 0 ]; do
	case \$1 in -o) out=\$2; shift ;; https://*) url=\$1 ;; esac
	shift
done
printf '%s\n' "\$url" >>"$tmp/install.log"
case \$url in https://github.com/index-pages/getdr/releases/download/v0.1.0/*) ;; *) exit 22 ;; esac
cp "$tmp/release/\${url##*/}" "\$out" 2>/dev/null || exit 22
EOF
chmod +x "$tmp/ishim/curl"
irun() { PATH="$tmp/ishim:$clean_path" PREFIX="$tmp/prefix" "$here/scripts/install.sh" "$@" >"$tmp/install.out" 2>&1; }
check "install.sh: installs the binary" irun
check "install.sh: binary in \$PREFIX/bin, executable, identical" bash -c "[ -x '$tmp/prefix/bin/getdr' ] && cmp -s '$tmp/prefix/bin/getdr' '$tmp/bin/getdr'"
check "install.sh: only the release URLs fetched" bash -c "[ \$(grep -vc '^https://github.com/index-pages/getdr/releases/download/v0.1.0/' '$tmp/install.log') = 0 ]"
rm -f "$tmp/prefix/bin/getdr"
echo "0000000000000000000000000000000000000000000000000000000000000000  $archive" >"$tmp/release/checksums.txt"
check "install.sh: refuses a checksum mismatch" bash -c "! PATH='$tmp/ishim:$clean_path' PREFIX='$tmp/prefix' '$here/scripts/install.sh' >/dev/null 2>&1"
check "install.sh: nothing installed after a mismatch" test ! -e "$tmp/prefix/bin/getdr"

# --- 4. live check ----------------------------------------------------------

echo "== live"
if [ -n "${AHREFS_KEY:-}" ]; then
	# The acceptance list against the real Ahrefs API: the skill and the
	# binary straight to Ahrefs, and both through a real getdr serve.
	p_live=$(free_port)
	LIVE=http://127.0.0.1:$p_live
	env -u GETDR_KEY GETDR_CONFIG=/dev/null GETDR_CACHE_PATH="$tmp/serve-live.db" \
		"$tmp/bin/getdr" serve --listen "127.0.0.1:$p_live" 2>"$tmp/serve-live.log" &
	pids+=($!)
	wait_up "$LIVE"
	printf 'api = "%s"\n' "$LIVE" >"$tmp/live.toml"
	live() { # name, then env assignments for the mode
		local name=$1 rc=0
		shift
		env -u GETDR_KEY -u GETDR_API -u GETDR_SERVE_TOKEN GETDR_CONFIG=/dev/null \
			GETDR_CACHE_PATH="$tmp/$name.db" "$@" "$dr" "${acc[@]}" >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
		echo "$rc" >"$tmp/$name.rc"
	}
	live live-direct PATH="$clean_path"
	live live-bin PATH="$tmp/bin:$clean_path"
	live live-api PATH="$clean_path" GETDR_API="$LIVE" AHREFS_KEY=
	live live-binapi PATH="$tmp/bin:$clean_path" GETDR_CONFIG="$tmp/live.toml" AHREFS_KEY=
	contract live-direct
	check "live direct: ahrefs.com and пример.рф have a DR" jq -e -s '(.[0].dr | type) == "number" and .[0].target == "ahrefs.com" and (.[4] | .target == "пример.рф" and (.dr | type) == "number")' "$tmp/live-direct.out"
	same live-direct live-bin
	same live-direct live-api
	same live-direct live-binapi
	for n in live-direct live-bin live-api live-binapi; do check "$n: exit 2" rc_is "$n" 2; done
	check "live direct: same stderr as the binary" cmp -s <(errlines live-direct) <(errlines live-bin)
	check "live api: same stderr as the binary" cmp -s <(errlines live-api) <(errlines live-binapi)
	check "live direct: invalid-target lines" cmp -s <(errlines live-direct) <(printf 'getdr: invalid target: exa mple.com\ngetdr: invalid target: localhost\n')
	for n in live-direct live-bin live-api live-binapi; do
		printf '      %s:\n' "$n"
		sed 's/^/        /' "$tmp/$n.out"
		errlines "$n" | sed 's/^/        /'
	done
else
	echo "skip  live check against api.ahrefs.com: AHREFS_KEY is not set"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
