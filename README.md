[![Build Docker Image](https://github.com/DE-MUC-UCC-OSEM/couchdb/actions/workflows/build-docker-image.yml/badge.svg)](https://github.com/DE-MUC-UCC-OSEM/couchdb/actions/workflows/build-docker-image.yml)

## Information
CouchDB running in a minimal OpenSUSE Docker Image

Building CouchDB from scratch using Erlang OTP and Fauxton sources. Everything put into a minimal Container image built from an OpenSUSE tumbleweed image

## Run the image

You can run the image via Docker
```
docker run -dit \
  -e SINGLE_NODE=true \
  -e COUCHDB_USER=admin \
  -e COUCHDB_PASSWORD=admin \
  -e COUCHDB_SECRET=s0m3rand0mstr1ng \
  ghcr.io/de-muc-ucc-osem/couchdb:3.5.2-r1-tumbleweed
```

To persist the data, mount a local folder or volume
```
-v /path/to/local/folder:/opt/couchdb/data
```
## Configuration

The following can be configured via environment variables

* COUCHDB_USER (https://docs.couchdb.org/en/stable/config/auth.html#admins)
* COUCHDB_PASSWORD (https://docs.couchdb.org/en/stable/config/auth.html#admins)
* COUCHDB_SECRET (https://docs.couchdb.org/en/stable/config/auth.html#chttpd_auth/secret)
* COUCHDB_SHARDS (https://docs.couchdb.org/en/stable/cluster/sharding.html#shards-and-replicas)
* NODENAME (https://www.erlang.org/doc/system/distributed.html#distribution-command-line-flags)
* ERLANG_COOKIE (https://www.erlang.org/doc/system/distributed.html#distribution-command-line-flags)
* COUCHDB_LOG_STDERR_LEVEL (see [Logging](#logging), default `error`)

Any additional configuration can be applied by mounting an ini file into the container.
```
-v /path/to/local.ini:/opt/couchdb/etc/local.d/local.ini
```

## Logging

Log entries at or above `COUCHDB_LOG_STDERR_LEVEL` (`[log] stderr_level`, default `error`) are written to stderr, all other entries are written to stdout.
Valid levels are `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert` and `emergency`.

When the container is started with a TTY (`-t`), Docker merges stdout and stderr into a single stream, so the split is only visible without `-t` (e.g. `docker run -d` or Kubernetes).

To restore the default CouchDB behaviour (everything to stderr), set `[log] writer = stderr` in a mounted ini file.
