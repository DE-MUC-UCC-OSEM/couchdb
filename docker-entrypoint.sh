#!/bin/bash

set -e

if [ "$COUCHDB_USER" ] && [ "$COUCHDB_PASSWORD" ]; then
  printf "[admins]\n%s = %s\n" "$COUCHDB_USER" "$COUCHDB_PASSWORD" > /opt/couchdb/etc/local.d/99-creds.ini
fi

if [ "$COUCHDB_SECRET" ]; then
  printf "\n[chttpd_auth]\nsecret = %s\n" "$COUCHDB_SECRET" > /opt/couchdb/etc/local.d/99-secret.ini
fi

if [ "$NODENAME" ]; then
  printf "\n-name couchdb@%s\n" "$NODENAME" >> /opt/couchdb/etc/vm.args
else
  printf "\n-name couchdb@localhost\n" >> /opt/couchdb/etc/vm.args
fi

printf "[chttpd]\nbind_address = 0.0.0.0\nport = 5984\n" > /opt/couchdb/etc/local.d/10-binding.ini
printf "[couchdb]\njs_engine = quickjs\n" > /opt/couchdb/etc/local.d/10-quickjs.ini

chown -R 5984:5984 /opt/couchdb

exec "$@"
