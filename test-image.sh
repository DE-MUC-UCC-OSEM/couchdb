#!/bin/bash

# Tests the minimal runtime image:
#   - content: no bash, no coreutils, no package manager, no Erlang tools
#   - CouchDB starts, the image healthcheck reports healthy
#   - the VM runs as couchdb (5984), the release belongs to root
#   - JavaScript views and validate_doc_update (dash + QuickJS), ICU collation,
#     Mango
#   - restart keeps data and does not duplicate the runtime arguments
#   - a bind-mounted data directory is given to couchdb
#   - ERLANG_COOKIE: value used as given, default cookie plus warning when
#     unset, invalid value refused
#
# The image has no shell tools, so the checks look into the container from a
# sidecar of TOOLS_IMAGE that shares its pid namespace (/proc/1 is the VM).
#
# Usage: test-image.sh <image> <tools-image>
#
# tools-image: any image with bash and coreutils, e.g. the app stage of the
# Dockerfile (docker build --target app -t couchdb:ci-tools .).
#
# IMAGETEST_STARTUP_SECONDS (default 60) limits the wait for CouchDB.

set -euo pipefail

IMAGE="${1:?usage: $0 <image> <tools-image>}"
TOOLS_IMAGE="${2:?usage: $0 <image> <tools-image>}"
PREFIX="couchdb-imagetest-$$"
PORT="${IMAGETEST_PORT:-15985}"
PORT_B=$((PORT + 1))
URL="http://admin:imagetest@127.0.0.1:$PORT"
STARTUP="${IMAGETEST_STARTUP_SECONDS:-60}"
TMP=$(mktemp -d)

cleanup() {
  docker rm -f "$PREFIX-a" "$PREFIX-b" "$PREFIX-c" >/dev/null 2>&1 || true
  # The data directory belongs to 5984 now
  docker run --rm -v "$TMP:/t" "$TOOLS_IMAGE" rm -rf /t/data >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

FAILED=0
result() {
  if [ "$1" = ok ]; then
    printf "  PASS  %s\n" "$2"
  else
    printf "  FAIL  %s\n" "$2"
    [ -n "${3:-}" ] && printf "        %s\n" "$3"
    FAILED=1
  fi
}
check() { # check <description> <command...>
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then result ok "$desc"; else result fail "$desc"; fi
}

# Run a command in a sidecar that sees the processes of a container. With the
# uid of CouchDB, /proc/1/root is the file system of that container.
inside() { # inside <container> <bash script>
  docker run --rm --pid "container:$1" --user 5984:5984 "$TOOLS_IMAGE" bash -c "$2"
}

# has_arg <args, one per line> <flag> <value>: flag is directly followed by value
has_arg() { grep -A1 -x -- "$2" <<< "$1" | grep -qx -- "$3"; }
has_line() { grep -qE -- "$2" <<< "$1"; }
lacks_line() { ! grep -qE -- "$2" <<< "$1"; }
lacks_file() { ! grep -qE -- "$1" "$TMP/files"; }

wait_up() { # wait_up <url>
  for _ in $(seq 1 "$STARTUP"); do
    curl -sf "$1/_up" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

couch() { # couch <method> <path> [json]
  curl -s -X "$1" "$URL$2" -H 'Content-Type: application/json' ${3:+-d "$3"}
}

echo "Image content"
docker create --name "$PREFIX-c" "$IMAGE" >/dev/null
docker export "$PREFIX-c" | tar -t > "$TMP/files"
docker rm "$PREFIX-c" >/dev/null
only() { # only <directory regex> <expected names>: files directly in the directory
  local got
  got=$(sed -n -E "s#^$1/([^/]+)\$#\\1#p" "$TMP/files" | sort | tr '\n' ' ')
  [ "$got" = "$2 " ] || { echo "$1: $got"; return 1; }
}
if out=$(only 'usr/bin' 'dash df du sh'); then result ok "usr/bin: dash, df, du, sh only"; else result fail "usr/bin: dash, df, du, sh only" "$out"; fi
if out=$(only 'usr/local/bin' 'couchdb-launcher healthcheck'); then result ok "usr/local/bin: launcher and healthcheck only"; else result fail "usr/local/bin: launcher and healthcheck only" "$out"; fi
if out=$(only 'opt/couchdb/erts-[^/]+/bin' 'beam.smp epmd erl_child_setup erlexec inet_gethost'); then result ok "erts: no Erlang tools"; else result fail "erts: no Erlang tools" "$out"; fi
check "no usr/sbin, no opt/couchdb/bin scripts, no docker-entrypoint.sh" \
  lacks_file '^(usr/sbin/.|opt/couchdb/bin/.|opt/couchdb/docker-entrypoint.sh)'
check "no rpm or zypp database" lacks_file '^(usr/lib/sysimage/rpm|var/lib/rpm|var/lib/zypp|etc/zypp)/'
check "no Erlang sources and headers" lacks_file '^opt/couchdb/(lib/[^/]+|erts-[^/]+)/(src|include|c_src)/'
check "no C sources or objects" lacks_file '^opt/couchdb/.*\.(c|h|o|d|a)$'
HEALTHCHECK=$(docker image inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")
check "image declares the healthcheck" has_line "$HEALTHCHECK" '/usr/local/bin/healthcheck.*--couchdb'

echo "Single node with bind-mounted data directory"
mkdir -p "$TMP/data"
chmod 700 "$TMP/data"
docker run -d --name "$PREFIX-a" -p "127.0.0.1:$PORT:5984" --health-interval 2s \
  -e SINGLE_NODE=true -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=imagetest \
  -e NODENAME=127.0.0.1 -e ERLANG_COOKIE=imagetest \
  -v "$TMP/data:/opt/couchdb/data" \
  "$IMAGE" >/dev/null
if ! wait_up "$URL"; then
  docker logs "$PREFIX-a" 2>&1 | tail -n 50
  result fail "CouchDB comes up"
  exit 1
fi
result ok "CouchDB comes up"

healthy=""
for _ in $(seq 1 30); do
  healthy=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$PREFIX-a")
  [ "$healthy" = healthy ] && break
  sleep 1
done
check "docker reports healthy" test "$healthy" = healthy
check "healthcheck --couchdb exits 0" docker exec "$PREFIX-a" /usr/local/bin/healthcheck --couchdb
check "healthcheck without arguments exits 1" bash -c "! docker exec '$PREFIX-a' /usr/local/bin/healthcheck"
check "du works" docker exec "$PREFIX-a" du -s /opt/couchdb/data
check "docker exec ls fails (no coreutils)" bash -c "! docker exec '$PREFIX-a' ls /"

PROC=$(inside "$PREFIX-a" 'cat /proc/1/comm /proc/1/status; tr "\0" "\n" < /proc/1/cmdline')
check "pid 1 is beam.smp" has_line "$PROC" '^beam\.smp$'
check "VM runs as uid 5984" has_line "$PROC" '^Uid:\s+5984\s+5984\s+5984\s+5984$'
check "VM runs as gid 5984" has_line "$PROC" '^Gid:\s+5984\s+5984\s+5984\s+5984$'
check "VM has no supplementary groups" has_line "$PROC" '^Groups:\s*$'
check "VM uses ERLANG_COOKIE" has_arg "$PROC" -setcookie imagetest
LOGS_A=$(docker logs "$PREFIX-a" 2>&1)
check "no cookie warning when ERLANG_COOKIE is set" lacks_line "$LOGS_A" 'ERLANG_COOKIE is not set'

OWNERS=$(inside "$PREFIX-a" 'cd /proc/1/root/opt/couchdb && stat -c "%u:%g %n" . erts-*/bin/beam.smp lib releases etc data etc/default.d/99-creds.ini etc/vm.runtime.args')
for path in . lib releases 'erts-.*/bin/beam\.smp'; do
  check "$path belongs to root" has_line "$OWNERS" "^0:0 $path\$"
done
for path in data etc etc/default.d/99-creds.ini etc/vm.runtime.args; do
  check "$path belongs to couchdb" has_line "$OWNERS" "^5984:5984 $path\$"
done
check "couchdb cannot write to the release" bash -c "! docker run --rm --pid 'container:$PREFIX-a' --user 5984:5984 '$TOOLS_IMAGE' touch /proc/1/root/opt/couchdb/lib/x"
MODES=$(inside "$PREFIX-a" 'stat -c %a /proc/1/root/opt/couchdb/etc/default.d/99-creds.ini /proc/1/root/opt/couchdb/etc/vm.runtime.args | sort -u')
check "credentials and runtime args are mode 600" test "$MODES" = 600

echo "JavaScript, collation, Mango"
couch PUT /imagetest >/dev/null
couch PUT /imagetest/_design/test '{
  "views": {"by_k": {"map": "function (doc) { if (doc.k) { emit(doc.k, null); } }"}},
  "validate_doc_update": "function (doc) { if (doc.forbidden) { throw({forbidden: \"not allowed\"}); } }"
}' >/dev/null
for k in b B a A ä; do couch POST /imagetest "{\"k\":\"$k\"}" >/dev/null; done
KEYS=$(couch GET /imagetest/_design/test/_view/by_k | jq -c '[.rows[].key]')
if [ "$KEYS" = '["a","A","ä","b","B"]' ]; then result ok "JS view with ICU collation"; else result fail "JS view with ICU collation" "$KEYS"; fi
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/imagetest" -H 'Content-Type: application/json' -d '{"forbidden":true}')
check "validate_doc_update rejects (403)" test "$STATUS" = 403
couch POST /imagetest/_index '{"index":{"fields":["k"]},"name":"k"}' >/dev/null
FOUND=$(couch POST /imagetest/_find '{"selector":{"k":"ä"}}' | jq '.docs | length')
check "Mango _find" test "$FOUND" = 1
DATA_OWNER=$(inside "$PREFIX-a" 'stat -c %u:%g /proc/1/root/opt/couchdb/data/_dbs.couch')
check "data files belong to couchdb" test "$DATA_OWNER" = 5984:5984

echo "Restart"
COUNT_BEFORE=$(couch GET /imagetest | jq .doc_count)
docker restart -t 30 "$PREFIX-a" >/dev/null
if wait_up "$URL"; then result ok "CouchDB comes up after restart"; else result fail "CouchDB comes up after restart"; fi
COUNT=$(couch GET /imagetest | jq .doc_count)
check "data kept after restart ($COUNT_BEFORE documents)" test "$COUNT" = "$COUNT_BEFORE"
RUNTIME_ARGS=$(inside "$PREFIX-a" 'cat /proc/1/root/opt/couchdb/etc/vm.runtime.args')
check "vm.runtime.args has one -name after restart" test "$(grep -c '^-name' <<< "$RUNTIME_ARGS")" = 1
START=$(date +%s)
docker stop -t 30 "$PREFIX-a" >/dev/null
STOP_SECONDS=$(($(date +%s) - START))
check "docker stop finishes before the kill timeout (${STOP_SECONDS}s)" test "$STOP_SECONDS" -lt 25
EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$PREFIX-a")
check "exit code after docker stop is 0 (got $EXIT_CODE)" test "$EXIT_CODE" = 0

echo "Cluster mode without ERLANG_COOKIE"
docker run -d --name "$PREFIX-b" -p "127.0.0.1:$PORT_B:5984" \
  -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=imagetest -e COUCHDB_SHARDS=2 \
  "$IMAGE" >/dev/null
if wait_up "http://admin:imagetest@127.0.0.1:$PORT_B"; then result ok "CouchDB comes up in cluster mode"; else result fail "CouchDB comes up in cluster mode"; fi
CLUSTER=$(inside "$PREFIX-b" 'cat /proc/1/root/opt/couchdb/etc/default.d/00-cluster.ini; ls /proc/1/root/opt/couchdb/etc/default.d; tr "\0" "\n" < /proc/1/cmdline')
check "00-cluster.ini with q = 2" has_line "$CLUSTER" '^q = 2$'
check "no 00-single.ini" lacks_line "$CLUSTER" '^00-single\.ini$'
check "default cookie when ERLANG_COOKIE is unset" has_arg "$CLUSTER" -setcookie erlang-magic-cookie
check "-name couchdb@localhost when NODENAME is unset" has_arg "$CLUSTER" -name couchdb@localhost
LOGS_B=$(docker logs "$PREFIX-b" 2>&1)
check "warning about the default cookie" has_line "$LOGS_B" 'ERLANG_COOKIE is not set'

echo "Invalid ERLANG_COOKIE"
docker run -d --name "$PREFIX-c" -e SINGLE_NODE=true -e "ERLANG_COOKIE=it's" "$IMAGE" >/dev/null
EXIT_C=$(docker wait "$PREFIX-c")
check "launcher refuses a cookie with a single quote (exit $EXIT_C)" test "$EXIT_C" = 1
LOGS_C=$(docker logs "$PREFIX-c" 2>&1)
check "error message names ERLANG_COOKIE" has_line "$LOGS_C" 'ERLANG_COOKIE must not contain'

if [ "$FAILED" -ne 0 ]; then
  echo "----- logs $PREFIX-a"
  docker logs "$PREFIX-a" 2>&1 | tail -n 50 || true
  exit 1
fi
echo "All image tests passed"
