#!/bin/bash

# Smoke test for couch_log_writer_stdout: starts the image, emits one log
# entry per level (plus a structured report and a Mango _find), and checks
# that errors land on stderr, everything else on stdout, and that
# couch_log_server never restarts.
#
# Usage: test-logging.sh <image>

set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
NAME="couchdb-logtest-$$"
PORT="${LOGTEST_PORT:-15984}"
URL="http://admin:logtest@127.0.0.1:$PORT"
TMP=$(mktemp -d)

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ ! -s "$TMP/stdout" ]; then
    echo "----- container logs"
    docker logs "$NAME" 2>&1 | tail -n 100 || true
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Evaluate an Erlang expression in a hidden node inside the container,
# connected to the CouchDB node (default name and cookie from the entrypoint).
erl_eval() {
  docker exec "$NAME" bash -c '
    ROOT=/opt/couchdb
    ERTS_VSN=$(cut -d" " -f1 "$ROOT/releases/start_erl.data")
    exec "$ROOT/erts-$ERTS_VSN/bin/erl" -boot "$ROOT/releases/start_clean" \
      -name "logtest$$@localhost" -hidden -setcookie erlang-magic-cookie \
      -noshell -eval "$1"
  ' _ "$1"
}

LOG_SERVER_PID='
  case rpc:call(couchdb@localhost, erlang, whereis, [couch_log_server]) of
    Pid when is_pid(Pid) ->
      io:format("~s~n", [rpc:call(couchdb@localhost, erlang, pid_to_list, [Pid])]),
      halt(0);
    Other ->
      io:format(standard_error, "couch_log_server not found: ~p~n", [Other]),
      halt(1)
  end.
'

EMIT='
  Node = couchdb@localhost,
  Check = fun(Expected, Res) when Res =:= Expected -> ok;
             (_, Res) -> io:format(standard_error, "rpc failed: ~p~n", [Res]), halt(1)
          end,
  [Check(ok, rpc:call(Node, couch_log, L, ["logtest-~s", [L]]))
   || L <- [info, notice, warning, error, critical, alert, emergency]],
  Check(true, rpc:call(Node, couch_log, report, ["logtest-report", #{k => 1}])),
  Check(ok, rpc:call(Node, couch_log, info,
    ["~ts", [<<"logtest-unicode \x{e4}\x{f6}\x{fc} ~s \x{65e5}\x{672c}"/utf8>>]])),
  halt(0).
'

echo "Starting $IMAGE"
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:5984" \
  -e SINGLE_NODE=true -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=logtest \
  "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  curl -sf "$URL/_up" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "$URL/_up" >/dev/null || { echo "CouchDB did not come up"; exit 1; }

echo "Reading couch_log_server pid via rpc"
PID_BEFORE=$(erl_eval "$LOG_SERVER_PID")
echo "Emitting test log entries"

erl_eval "$EMIT"
curl -sf -X PUT "$URL/logtest" >/dev/null
curl -sf -X PUT "$URL/logtest/doc1" -H 'Content-Type: application/json' -d '{"a":1}' >/dev/null
curl -sf -X POST "$URL/logtest/_find" -H 'Content-Type: application/json' \
  -d '{"selector":{"a":1}}' >/dev/null

# couch_log_server:log/1 is a cast; give it time to drain.
sleep 3
PID_AFTER=$(erl_eval "$LOG_SERVER_PID")
docker logs "$NAME" >"$TMP/stdout" 2>"$TMP/stderr"

FAILED=0
result() {
  if [ "$1" = ok ]; then
    printf "  PASS  %s\n" "$2"
  else
    printf "  FAIL  %s\n" "$2"
    FAILED=1
  fi
}

expect_on() {
  local stream=$1 other=$2 marker=$3
  if grep -qF -- "$marker" "$TMP/$stream" && ! grep -qF -- "$marker" "$TMP/$other"; then
    result ok "$marker -> $stream"
  else
    result fail "$marker -> $stream"
  fi
}

echo "Results:"
for marker in logtest-info logtest-notice logtest-warning logtest-report logtest-unicode mango-stats; do
  expect_on stdout stderr "$marker"
done
for marker in logtest-error logtest-critical logtest-alert logtest-emergency; do
  expect_on stderr stdout "$marker"
done

# Only couch_log_server crashes count; CouchDB logs unrelated errors on a
# fresh node (e.g. chttpd_auth_cache before _users exists).
if grep -qF couch_log_server "$TMP/stdout" "$TMP/stderr"; then
  result fail "no logger crashes"
else
  result ok "no logger crashes"
fi

if [ "$PID_BEFORE" = "$PID_AFTER" ]; then
  result ok "couch_log_server not restarted ($PID_BEFORE)"
else
  result fail "couch_log_server not restarted ($PID_BEFORE -> $PID_AFTER)"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "----- stdout"
  cat "$TMP/stdout"
  echo "----- stderr"
  cat "$TMP/stderr"
  exit 1
fi
