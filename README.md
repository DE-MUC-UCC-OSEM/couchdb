[![Build Docker Image](https://github.com/DE-MUC-UCC-OSEM/couchdb/actions/workflows/build-docker-image.yml/badge.svg)](https://github.com/DE-MUC-UCC-OSEM/couchdb/actions/workflows/build-docker-image.yml)

## Information
CouchDB running in a minimal OpenSUSE Docker Image

Building CouchDB from scratch using Erlang OTP and Fauxton sources. Everything put into a minimal Container image built from an OpenSUSE tumbleweed image

## Run the image

You can run the image via Docker
```
docker run -dit ghcr.io/de-muc-ucc-osem/couchdb:3.5.0-r1-tumbleweed
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
* 

Any additional configuration can be applied by mounting an ini file into the container.
```
-v /path/to/local.ini:/opt/couchdb/etc/local.d/local.ini
```
