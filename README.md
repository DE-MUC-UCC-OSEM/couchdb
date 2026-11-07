[![Build Docker Image](https://github.com/DE-MUC-UCC-OSEM/couchdb/actions/workflows/build-docker-image.yml/badge.svg)](https://github.com/DE-MUC-UCC-OSEM/couchdb/actions/workflows/build-docker-image.yml)

## Information
CouchDB running in a minimal OpenSUSE Docker Image

Building CouchDB from scratch using Erlang OTP and Fauxton sources. Everything put into a minimal Container image built from an OpenSUSE tumbleweed image

Fauxton is built from source at the requested version and replaces the Fauxton bundled with the CouchDB release. The Mend source scan only covers the npm packages that end up in the Fauxton bundle (see `fauxton-shipped-deps.js`), not Fauxton's build and test tooling.

## Image content

The final image is assembled file by file (`rootfs` stage in the `Dockerfile`) and contains only what CouchDB needs at runtime:

* the CouchDB release without the Erlang development tools (`erl`, `erlc`, `escript`, ...), sources, headers and start scripts; binaries and `.beam` files are stripped
* the shared libraries the binaries are linked against (glibc, OpenSSL, ICU, libstdc++, ...), ICU collation data, time zones, CA certificates
* `/bin/sh` (dash) and `df`: the Erlang VM starts ports, `epmd` and the JavaScript query servers through `/bin/sh`, and `os_mon`'s disk monitor needs `sh` and `df`
* `du`: not needed by CouchDB, kept for checking the disk usage of the data directory (`docker exec <container> du -sh /opt/couchdb/data`)
* `/usr/local/bin/couchdb-launcher`: the entrypoint (see below)
* `/usr/local/bin/healthcheck`: the container healthcheck

| | file system | gzip |
| --- | --- | --- |
| 3.5.3-r1 (tumbleweed with `rpm -e` allowlist) | 206 MB | 93 MB |
| minimal image (same CouchDB 3.5.3 release) | 107 MB | 46 MB |

The largest remaining parts are the ICU collation data (32 MB), Fauxton (24 MB) and the shared libraries (20 MB).

There is no bash, no coreutils apart from `df` and `du` (no `ls`, `cat`, `chroot`, ...), no `rpm` and no `zypper`. The release in `/opt/couchdb` belongs to root; only `data`, `etc` and `var` belong to the `couchdb` user (5984).

`couchdb-launcher` (source in `launcher/`) writes the configuration from the environment variables to `/opt/couchdb/etc/default.d`, writes `-name` and `-setcookie` to `/opt/couchdb/etc/vm.runtime.args`, gives `data`, `etc` and `var` to the `couchdb` user (also for mounted volumes, read-only mounts are skipped), drops to that user and starts the Erlang VM. Arguments of `docker run` are passed on to the VM.

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

Always set `ERLANG_COOKIE` to a random value, the same on all nodes of a cluster. Without it the well-known default cookie `erlang-magic-cookie` is used (with a warning in the log), and everyone who can reach the ports 4369 and 9100 can run code in CouchDB. The cookie is not stored in the database, so it can be set or changed on any restart (on all nodes of a cluster at the same time).

Any additional configuration can be applied by mounting an ini file into the container.
```
-v /path/to/local.ini:/opt/couchdb/etc/local.d/local.ini
```

## Healthcheck

The image declares a Docker healthcheck. It starts `/usr/local/bin/healthcheck --couchdb`, which connects to port 5984 (exit code 0 = healthy, 1 = unhealthy). The image has no shell, so healthchecks of compose files or orchestrators must use the exec form:
```
healthcheck:
  test: ["CMD", "/usr/local/bin/healthcheck", "--couchdb"]
```
`CMD-SHELL` checks with `bash`, `curl` or `timeout` do not work.

## Debugging

`docker exec` works only for the binaries in the image. For a shell with tools, start a container of another image (e.g. the `app` stage: `docker build --target app -t couchdb:tools .`) in the namespaces of the CouchDB container. As uid 5984, `/proc/1/root` is the file system of the CouchDB container:
```
docker run --rm -it --network container:couchdb --pid container:couchdb --user 5984:5984 couchdb:tools bash
```
An Erlang remote shell (needs the node name and the cookie):
```
docker run --rm -it --network container:couchdb couchdb:tools erl -name debug@127.0.0.1 -setcookie "$ERLANG_COOKIE" -remsh couchdb@127.0.0.1 -hidden
```

## Tests

```
docker build --target app -t couchdb:ci-tools .   # tools for the sidecar containers
./test-image.sh couchdb:ci-test couchdb:ci-tools
./test-logging.sh couchdb:ci-test couchdb:ci-tools
(cd launcher && go test ./...)
```

## Logging

Errors are written to stderr, everything else is written to stdout:

* stderr: `error`, `critical`, `alert`, `emergency`
* stdout: `debug`, `info`, `notice`, `warning` and `report` entries (e.g. Mango `mango-stats`)

Which entries are logged at all is still controlled by `[log] level` and `[log] report_level`.

When the container is started with a TTY (`-t`), Docker merges stdout and stderr into a single stream, so the split is only visible without `-t` (e.g. `docker run -d` or Kubernetes).

To restore the default CouchDB behaviour (everything to stderr), set `[log] writer = stderr` in a mounted ini file.
