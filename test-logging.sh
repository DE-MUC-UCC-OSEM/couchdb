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

# Print the -name and -setcookie arguments of the running CouchDB VM, one per
# line. Read from /proc so they match whatever the entrypoint put into
# vm.args. The image has no grep/pgrep, so this uses bash builtins only.
vm_identity() {
  docker exec "$NAME" bash -c '
    for f in /proc/[0-9]*/cmdline; do
      args=()
      while IFS= read -r -d "" a; do args+=("$a"); done < "$f" 2>/dev/null || continue
      [[ ${args[0]:-} == *beam* ]] || continue
      for ((i = 0; i < ${#args[@]}; i++)); do
        case ${args[i]} in
          -name) node=${args[i+1]} ;;
          -setcookie) cookie=${args[i+1]} ;;
        esac
      done
      [ -n "${node:-}" ] && [ -n "${cookie:-}" ] || continue
      printf "%s\n%s\n" "$node" "$cookie"
      exit 0
    done
    exit 1
  '
}

# Evaluate an Erlang expression in a hidden node inside the container. The
# CouchDB node name is available to the expression as LOGTEST_NODE.
erl_eval() {
  docker exec -e LOGTEST_NODE="$NODE" -e LOGTEST_COOKIE="$COOKIE" "$NAME" bash -c '
    ROOT=/opt/couchdb
    ERTS_VSN=$(cut -d" " -f1 "$ROOT/releases/start_erl.data")
    exec "$ROOT/erts-$ERTS_VSN/bin/erl" -boot "$ROOT/releases/start_clean" \
      -name "logtest$$@${LOGTEST_NODE#*@}" -hidden -setcookie "$LOGTEST_COOKIE" \
      -noshell -eval "$1"
  ' _ "$1"
}

CONNECT='
  Node = list_to_atom(os:getenv("LOGTEST_NODE")),
  [_, Host] = string:split(atom_to_list(Node), "@"),
  case net_adm:ping(Node) of
    pong ->
      halt(0);
    pang ->
      io:format(standard_error,
        "cannot connect to ~s~n  self: ~s~n  getaddr: ~p~n  epmd names: ~p~n",
        [Node, node(), inet:getaddr(Host, inet), net_adm:names(Host)]),
      halt(1)
  end.
'

LOG_SERVER_PID='
  Node = list_to_atom(os:getenv("LOGTEST_NODE")),
  case rpc:call(Node, erlang, whereis, [couch_log_server]) of
    Pid when is_pid(Pid) ->
      io:format("~s~n", [rpc:call(Node, erlang, pid_to_list, [Pid])]),
      halt(0);
    Other ->
      io:format(standard_error, "couch_log_server not found: ~p~n", [Other]),
      halt(1)
  end.
'

EMIT='
  Node = list_to_atom(os:getenv("LOGTEST_NODE")),
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

{ read -r NODE; read -r COOKIE; } < <(vm_identity) || true
if [ -z "${NODE:-}" ] || [ -z "${COOKIE:-}" ]; then
  echo "Could not read -name/-setcookie of the CouchDB VM"
  exit 1
fi
echo "Connecting to $NODE"
erl_eval "$CONNECT"

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
