FROM opensuse/tumbleweed:latest AS app

RUN zypper update --no-confirm && \
    zypper install --no-confirm wget make autoconf gcc-c++ awk openssl-devel libicu-devel nodejs26 npm26 && \
    node --version && \
    npm --version

WORKDIR /usr/src

ARG ERLANG_OTP_VERSION
RUN wget https://github.com/erlang/otp/releases/download/OTP-$ERLANG_OTP_VERSION/otp_src_$ERLANG_OTP_VERSION.tar.gz && \
    tar -xvf otp_src_$ERLANG_OTP_VERSION.tar.gz && \
    cd otp_src_$ERLANG_OTP_VERSION && \
    ./configure --without-termcap --without-wx --without-javac --without-odbc && \
    make && \
    make install

ARG COUCHDB_VERSION
ARG FAUXTON_VERSION
COPY couch_log_writer_stdout.erl /usr/src/couch_log_writer_stdout.erl
COPY fauxton-shipped-deps.js /usr/src/fauxton-shipped-deps.js
# The finished release ends up in /usr/src/couchdb-release, the rootfs stage
# takes it from there.
RUN wget https://dlcdn.apache.org/couchdb/source/$COUCHDB_VERSION/apache-couchdb-$COUCHDB_VERSION.tar.gz && \
    tar -xvf apache-couchdb-$COUCHDB_VERSION.tar.gz && \
    cd apache-couchdb-$COUCHDB_VERSION && \
    ./configure --js-engine=quickjs --disable-spidermonkey && \
    cp /usr/src/couch_log_writer_stdout.erl src/couch_log/src/ && \
    rm -Rf src/fauxton/* && \
    rm -Rf src/fauxton/.* && \
    curl -L https://github.com/apache/couchdb-fauxton/archive/refs/tags/v$FAUXTON_VERSION.tar.gz | tar --directory src/fauxton --strip-components 1 -zxvf - && \
    rm -Rf share/www && \
    cd src/fauxton && \
    npm ci --ignore-scripts --no-audit --no-fund && \
    ./node_modules/grunt-cli/bin/grunt couchdb && \
    FAUXTON_VERSION=$FAUXTON_VERSION node /usr/src/fauxton-shipped-deps.js /usr/src/mend-scan/fauxton && \
    cd ../.. && \
    make && \
    make install && \
    mv /usr/src/apache-couchdb-$COUCHDB_VERSION/rel/couchdb /usr/src/couchdb-release

ARG COUCHDB_VERSION
ARG RELEASE_VERSION
ARG MEND_EMAIL
ARG MEND_ORGANIZATION
ARG MEND_URL
ARG MEND_USER_KEY
RUN curl -L https://downloads.mend.io/cli/linux_amd64/mend -o /tmp/mend && chmod +x /tmp/mend && \
    /tmp/mend update && \
    /tmp/mend dep -d "/usr/src/mend-scan" -e -s "OpenScape UC Portfolio//OSEM third party applications//couchdb-osem-sourcecode - $COUCHDB_VERSION-r$RELEASE_VERSION" -u --non-interactive

# Static launcher and healthcheck binaries (launcher/). They replace
# docker-entrypoint.sh, chroot and the CMD-SHELL healthchecks, because the
# final image has no bash and no coreutils. Built on the build platform and
# cross-compiled for the target.
FROM --platform=$BUILDPLATFORM opensuse/tumbleweed:latest AS launcher

RUN zypper install --no-confirm --no-recommends go && \
    zypper clean --all

ENV GOTOOLCHAIN=local
ENV CGO_ENABLED=0
WORKDIR /src
COPY launcher/ /src/
ARG TARGETOS
ARG TARGETARCH
RUN go version && \
    go vet ./... && \
    go test ./... && \
    export GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} && \
    go build -trimpath -ldflags "-s -w" -o /out/couchdb-launcher ./cmd/couchdb-launcher && \
    go build -trimpath -ldflags "-s -w" -o /out/healthcheck ./cmd/healthcheck

# Assemble the complete file system of the final image in /rootfs. Everything
# that is not copied here (bash, coreutils, rpm, zypper, the Erlang tools, ...)
# does not exist in the final image.
FROM app AS rootfs

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN zypper install --no-confirm --no-recommends dash coreutils findutils awk binutils ca-certificates timezone libicu && \
    zypper clean --all

RUN mkdir -p /rootfs/opt \
             /rootfs/usr/bin \
             /rootfs/usr/lib64 \
             /rootfs/usr/local/bin \
             /rootfs/usr/share \
             /rootfs/etc/ssl \
             /rootfs/etc/crypto-policies/back-ends \
             /rootfs/var/lib/ca-certificates \
             /rootfs/root \
             /rootfs/tmp && \
    chmod 700 /rootfs/root && \
    chmod 1777 /rootfs/tmp && \
    ln -s usr/bin /rootfs/bin && \
    ln -s usr/lib64 /rootfs/lib64

# CouchDB release without the Erlang development tools, the sources, the NIF
# build files (.c/.o/.d in couch/priv, SpiderMonkey couch_js sources) and the
# start scripts. The scripts need coreutils, couchdb-launcher replaces
# bin/couchdb. couchjs_coffee stays: couch_quickjs checks for it at startup.
RUN R=/rootfs/opt/couchdb && \
    cp -a /usr/src/couchdb-release $R && \
    test -f $R/lib/couch_log-*/ebin/couch_log_writer_stdout.beam && \
    rm -f $R/erts-*/bin/{ct_run,dialyzer,erl,erl_call,erlc,escript,heart,run_erl,start,to_erl,typer,yielding_c_fun} && \
    rm -Rf $R/erts-*/{doc,include,lib,man,src} && \
    rm -Rf $R/lib/*/{c_src,doc,examples,include,src} && \
    rm -Rf $R/lib/couch-*/priv/{couch_cfile,couch_ejson_compare,couch_js} && \
    rm -f $R/lib/crypto-*/priv/lib/otp_test_engine.so && \
    rm -f $R/lib/inets-*/priv/bin/runcgi.sh && \
    rm -f $R/bin/{couchdb,couchdb.cmd,remsh,weatherreport} && \
    mkdir -p $R/data $R/var

# Remove the debug_info and documentation chunks of all .beam files. The
# module attributes (Attr) stay, couch_epi reads the vsn attribute; CInf keeps
# module_info(compile). Runs the erl of the unchanged release, the copy in
# /rootfs has no erl any more.
RUN ERL=$(echo /usr/src/couchdb-release/erts-*/bin/erl) && \
    $ERL -noshell -boot /usr/src/couchdb-release/releases/start_clean -eval ' \
      case beam_lib:strip_release("/rootfs/opt/couchdb", ["Attr", "CInf"]) of \
        {ok, _} -> halt(0); \
        Error -> io:format(standard_error, "~p~n", [Error]), halt(1) \
      end.'

# /bin/sh is required at runtime: Erlang starts ports ({spawn, Cmd}: the
# QuickJS query servers, os_mon), epmd and "kill" through /bin/sh, os_mon's
# disksup needs "sh -s" and df. dash is the smallest POSIX shell available.
# du is not needed by CouchDB; it is kept for checking the disk usage of the
# data directory (docker exec <container> du -sh /opt/couchdb/data).
RUN cp /usr/bin/dash /rootfs/usr/bin/dash && \
    ln -s dash /rootfs/usr/bin/sh && \
    cp /usr/bin/df /rootfs/usr/bin/df && \
    cp /usr/bin/du /rootfs/usr/bin/du

# Strip all ELF files and keep the list for the library lookup below
RUN find /rootfs -type f -print0 | \
    while IFS= read -r -d '' f; do \
      if [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then echo "$f"; fi; \
    done > /tmp/elf-files && \
    xargs -a /tmp/elf-files -d '\n' strip --strip-unneeded && \
    wc -l < /tmp/elf-files

# Shared libraries required by the ELF files. Fails on unresolved libraries.
COPY copy-libs.sh /usr/src/copy-libs.sh
RUN bash /usr/src/copy-libs.sh /rootfs /tmp/elf-files

# Data files: ICU collation data, time zones, CA certificates, the OpenSSL
# configuration (openssl.cnf includes the crypto policy, config_diagnostics
# makes a missing include fatal), the OpenSSL legacy provider (loaded by the
# Erlang crypto application; the FIPS provider was not part of the image
# before either) and the name service switch configuration.
RUN cp -a /usr/share/icu /usr/share/zoneinfo /rootfs/usr/share/ && \
    cp -a /etc/localtime /rootfs/etc/localtime && \
    cp -a /var/lib/ca-certificates/ca-bundle.pem /var/lib/ca-certificates/pem /rootfs/var/lib/ca-certificates/ && \
    cp -a /etc/ssl/ca-bundle.pem /etc/ssl/certs /etc/ssl/openssl.cnf /rootfs/etc/ssl/ && \
    cp -L /etc/crypto-policies/back-ends/opensslcnf.config /rootfs/etc/crypto-policies/back-ends/opensslcnf.config && \
    mkdir -p /rootfs/usr/lib64/ossl-modules && cp /usr/lib64/ossl-modules/legacy.so /rootfs/usr/lib64/ossl-modules/ && \
    if [ -f /etc/nsswitch.conf ]; then cp /etc/nsswitch.conf /rootfs/etc/; else cp /usr/etc/nsswitch.conf /rootfs/etc/; fi && \
    printf 'root:x:0:0:root:/root:/sbin/nologin\ncouchdb:x:5984:5984:CouchDB:/opt/couchdb:/sbin/nologin\n' > /rootfs/etc/passwd && \
    printf 'root:x:0:\ncouchdb:x:5984:\n' > /rootfs/etc/group

COPY --chmod=644 vm.args /rootfs/opt/couchdb/etc/vm.args
COPY --from=launcher --chmod=755 /out/couchdb-launcher /out/healthcheck /rootfs/usr/local/bin/

# The release belongs to root. couchdb-launcher gives data, etc and var to
# couchdb on every start (also for mounted volumes).
RUN chown -R root:root /rootfs/opt/couchdb && \
    chown -R 5984:5984 /rootfs/opt/couchdb/{data,etc,var}

# Smoke test: fails the build on missing libraries. The chroot has no /dev
# and no /proc, the container runtime provides them.
RUN chroot /rootfs /bin/sh -c 'df --version && du --version' > /dev/null && echo "sh, df and du ok" && \
    QJS=$(cd /rootfs && echo opt/couchdb/lib/couch_quickjs-*/priv/couchjs_mainjs) && \
    printf '["reset"]\n' | chroot /rootfs /$QJS | grep true > /dev/null && echo "couchjs ok" && \
    { chroot /rootfs /usr/local/bin/healthcheck || true; } | grep usage > /dev/null && echo "healthcheck ok"

# Runtime image: CouchDB, dash, df, du and the launcher. No bash, no coreutils,
# no package manager. Do not use RUN in this stage.
FROM scratch

COPY --from=rootfs /rootfs/ /

ENV PATH="/usr/local/bin:/usr/bin"
ENV HOME="/opt/couchdb"
ENV COUCHDB_ARGS_FILE="/opt/couchdb/etc/vm.args"

EXPOSE 5984 4369 9100

LABEL org.opencontainers.image.vendor="Apache Software Foundation"
LABEL org.opencontainers.image.title="Apache CouchDB"
LABEL org.opencontainers.image.version="__COUCHDB_VERSION__-r__RELEASE_VERSION__-tumbleweed"
LABEL org.opencontainers.image.licenses="Apache License 2.0"
LABEL org.opencontainers.image.url="https://github.com/DE-MUC-UCC-OSEM/couchdb"
LABEL org.opencontainers.image.source="https://github.com/DE-MUC-UCC-OSEM/couchdb"
LABEL org.opencontainers.image.description="Apache CouchDB __COUCHDB_VERSION__-r__RELEASE_VERSION__-tumbleweed with ErlangOTP __ERLANG_OTP_VERSION__ and Fauxton __FAUXTON_VERSION__"
LABEL org.opencontainers.image.created="__CURRENT_TIME__"

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5 \
    CMD ["/usr/local/bin/healthcheck", "--couchdb"]

# couchdb-launcher writes the configuration, drops to the couchdb user and
# execs the Erlang VM, which then receives SIGTERM directly.
ENTRYPOINT ["/usr/local/bin/couchdb-launcher"]
