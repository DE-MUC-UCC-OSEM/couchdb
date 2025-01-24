#!/bin/bash

set -e

if [ "$SINGLE_NODE" ]; then
  printf "[couchdb]\nsingle_node = true\n\n[cluster]\nn = 1\n" > /opt/couchdb/etc/default.d/00-single.ini
else
  printf "[cluster]\nn = 3\n" > /opt/couchdb/etc/default.d/00-cluster.ini
  printf "reconnect_interval_sec = 10\n" >> /opt/couchdb/etc/default.d/00-cluster.ini
  if [ "$COUCHDB_SHARDS" ]; then
    printf "q = %s\n" "$COUCHDB_SHARDS" >> /opt/couchdb/etc/default.d/00-cluster.ini
  else
    printf "q = 4\n" >> /opt/couchdb/etc/default.d/00-cluster.ini
  fi
fi

if [ "$COUCHDB_USER" ] && [ "$COUCHDB_PASSWORD" ]; then
  printf "[admins]\n%s = %s\n" "$COUCHDB_USER" "$COUCHDB_PASSWORD" > /opt/couchdb/etc/default.d/99-creds.ini
fi

if [ "$COUCHDB_SECRET" ]; then
  printf "[chttpd_auth]\nsecret = %s\n" "$COUCHDB_SECRET" > /opt/couchdb/etc/default.d/99-secret.ini
fi

if [ "$NODENAME" ]; then
  printf "\n-name couchdb@%s" "$NODENAME" >> /opt/couchdb/etc/vm.args
else
  printf "\n-name couchdb@localhost" >> /opt/couchdb/etc/vm.args
fi

if [ "$ERLANG_COOKIE" ]; then
  printf "\n-setcookie '%s'" "$ERLANG_COOKIE" >> /opt/couchdb/etc/vm.args
else
  printf "\n-setcookie 'erlang-magic-cookie'" >> /opt/couchdb/etc/vm.args
fi

printf "[chttpd]\nbind_address = 0.0.0.0\nport = 5984\n" > /opt/couchdb/etc/default.d/10-binding.ini
printf "[couchdb]\njs_engine = quickjs\n" > /opt/couchdb/etc/default.d/10-quickjs.ini
printf "[couchdb]\nmax_document_size = 10000000\n" > /opt/couchdb/etc/default.d/10-size.ini

chown -R couchdb:couchdb /opt/couchdb

exec "$@"
