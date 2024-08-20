FROM opensuse/tumbleweed:latest AS app

RUN zypper update --no-confirm && \
    zypper install --no-confirm wget make autoconf gcc-c++ awk openssl-devel libicu-devel mozjs78 mozjs78-devel libmozjs-78-0

WORKDIR /usr/src

ARG ERLANG_OTP_VERSION
RUN wget https://github.com/erlang/otp/releases/download/OTP-$ERLANG_OTP_VERSION/otp_src_$ERLANG_OTP_VERSION.tar.gz && \
    tar -xvf otp_src_$ERLANG_OTP_VERSION.tar.gz && \
    cd otp_src_$ERLANG_OTP_VERSION && \
    ./configure --without-termcap --without-wx --without-javac --without-odbc && \
    make && \
    make install

ARG COUCHDB_VERSION
RUN wget https://dlcdn.apache.org/couchdb/source/$COUCHDB_VERSION/apache-couchdb-$COUCHDB_VERSION.tar.gz && \
    tar -xvf apache-couchdb-$COUCHDB_VERSION.tar.gz && \
    cd apache-couchdb-$COUCHDB_VERSION && \
    ./configure --spidermonkey-version 78 && \
    make && \
    make install && \
    tar --create --file=/tmp/couchdb.tar.xz --directory=/usr/src/apache-couchdb-$COUCHDB_VERSION/rel/couchdb --xz --verbose --utc .

FROM opensuse/tumbleweed:latest AS base

COPY --from=app /tmp/couchdb.tar.xz /tmp/couchdb.tar.xz

RUN mkdir -p /opt/couchdb && \
    groupadd -g 5984 -r couchdb && useradd -u 5984 -d /opt/couchdb -g couchdb couchdb && \
    tar --directory /opt/couchdb -xvf /tmp/couchdb.tar.xz && \
    chown -R couchdb:couchdb /opt/couchdb && \
    zypper update --no-confirm && \
    zypper install --no-confirm libmozjs-78-0 && \
    rpm -e --allmatches $(rpm -qa --qf "%{NAME}\n" | grep -v -E "bash|coreutils|filesystem|glibc$|libacl1|libattr1|libcap2|libgcc_s1|libgmp|libncurses|libpcre1|libreadline|libselinux|libstdc\+\+|openSUSE-release|system-user-root|terminfo-base|libpcre2|sed|libz1|libjitterentropy3|libopenssl3|crypto-policies|libmozjs-78-0|libicu75|timezone") && \
    rm -Rf /etc/zypp && \
    rm -Rf /usr/lib/zypp* && \
    rm -Rf /var/{cache,log,run}/* && \
    rm -Rf /var/lib/zypp && \
    rm -Rf /usr/lib/rpm && \
    rm -Rf /usr/lib/sysimage/rpm && \
    rm -Rf /usr/share/man && \
    rm -Rf /usr/local && \
    rm -Rf /srv/www && \
    rm -Rf /tmp/*

COPY --chown=couchdb:couchdb --chmod=740 vm.args /opt/couchdb/etc/vm.args
COPY --chown=couchdb:couchdb --chmod=740 docker-entrypoint.sh /opt/couchdb
RUN chown -R couchdb:couchdb /opt/couchdb

FROM scratch

COPY --from=base / /

ENTRYPOINT ["/opt/couchdb/docker-entrypoint.sh"]

ENV COUCHDB_ARGS_FILE="/opt/couchdb/etc/vm.args"

EXPOSE 5984 4369 9100

VOLUME /opt/couchdb/data

USER 5984:5984

CMD ["/opt/couchdb/bin/couchdb"]