# syntax=docker/dockerfile:1

# Global build argument (must be declared before the first FROM to be usable in FROM lines)
# Ubuntu 24.04 is used for both building and running the daemon: it is the platform the daemon's own CI
# builds on, and the runtime package names below are for this release.
ARG distro=24.04

# --- Stage 1: build the web UI with the multi-select patch applied ---
# The patch (webui-multiselect.patch) was made against this exact upstream commit.
FROM node:22-bookworm-slim AS webui-build
ARG webui_repo="https://github.com/airdcpp-web/airdcpp-webui.git"
ARG webui_ref="eeeea5025a5e720f38dac53ced8e002940f00a74"

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /webui
RUN git init -q . \
    && git remote add origin ${webui_repo} \
    && git fetch -q --depth 1 origin ${webui_ref} \
    && git checkout -q FETCH_HEAD

# Which patch to apply (all of them are made against the commit above):
#   webui-multiselect.patch                      full (default)
#   webui-stage-b-filelist-queue-search.patch    without the final filelist Actions menu commit
#   webui-stage-a-filelist.patch                 only the first filelist checkbox commits
#   none                                         unmodified web UI
ARG patch_file=webui-multiselect.patch
COPY webui-*.patch /tmp/patches/
RUN if [ "$patch_file" = "none" ]; then echo "No patch applied"; \
    else git apply --check /tmp/patches/$patch_file && git apply /tmp/patches/$patch_file; fi

RUN npm ci --no-audit --no-fund \
    && npm run build-webpack

# --- Stage 2: build the daemon from source with the hub user commands patch applied ---
# The patch (daemon-hubcommands.patch) was made against this exact upstream commit (2.14.1b-91).
FROM ubuntu:${distro} AS daemon-build
ARG daemon_repo="https://github.com/airdcpp-web/airdcpp-webclient.git"
ARG daemon_ref="e330cf88efaeea67768630b5c888dfd989563cdc"

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential cmake git python3 pkg-config ca-certificates \
        libbz2-dev zlib1g-dev libssl-dev libminiupnpc-dev libnatpmp-dev libtbb-dev \
        libmaxminddb-dev libleveldb-dev nlohmann-json3-dev \
        libboost1.83-dev libboost-regex1.83-dev libboost-thread1.83-dev libboost-system1.83-dev \
    && rm -rf /var/lib/apt/lists/*

# A full clone is needed: the version string is generated with "git describe --tags"
WORKDIR /daemon
RUN git clone ${daemon_repo} . \
    && git checkout -q ${daemon_ref}

COPY daemon-hubcommands.patch /tmp/daemon-hubcommands.patch
RUN git apply --check /tmp/daemon-hubcommands.patch && git apply /tmp/daemon-hubcommands.patch

# The web UI is built separately (stage 1), so skip the npm download
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DINSTALL_WEB_UI=OFF -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build build -j"$(nproc)" \
    && DESTDIR=/daemon-install cmake --install build --strip

# --- Stage 3: the regular image ---
FROM ubuntu:${distro}

# Changes on every build (see build.sh); makes sure that the package/Node.js installation layer is never reused from cache
ARG CACHEBUST=0

RUN installDeps=' \
        curl \
        gnupg \
    ' \
    && runtimeDeps=' \
        ca-certificates \
        locales \
        openssl \
        libboost-thread1.83.0 \
        libbz2-1.0 \
        libleveldb1d \
        libmaxminddb0 \
        libminiupnpc17 \
        libnatpmp1t64 \
        libssl3t64 \
        libtbb12 \
    ' \
# Install dependencies
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends ${installDeps} ${runtimeDeps} \
# Install node.js to enable airdcpp extension support.
# Pinned to the 18.x line before, which reached end-of-life in April 2025 —
# no more security backports land on it at all, which is why it was sitting
# on an old, unpatched build (including a 9.8-severity CVE). 24.x is a
# currently-maintained line, and its newer bundled npm also carries patched
# versions of tar/minimatch/http-cache-semantics.
    && curl -sL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && echo "Package install (build ${CACHEBUST})" \
# Cleanup
    && apt-get purge --autoremove -y ${installDeps} \
    && rm -rf /var/lib/apt/lists/*

# Some Ubuntu base images ship a default "ubuntu" user/group with ID 1000. entrypoint.sh creates the
# airdcpp user from PUID/PGID, which would fail for 1000 if that ID was already taken.
RUN if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi \
    && if getent group ubuntu >/dev/null 2>&1; then groupdel ubuntu; fi

# Configure locale
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
RUN sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen && dpkg-reconfigure -f noninteractive locales

# The daemon built in stage 2, laid out like the official portable package:
#   /airdcpp-webclient/airdcppd, dcppboot.xml (portable mode, config in ./config) and web-resources/
# The shared libraries (airdcpp, airdcpp-webapi) are in /usr/local/lib, which the binary has as its runpath.
COPY --from=daemon-build /daemon-install/usr/local/lib/ /usr/local/lib/
COPY --from=daemon-build /daemon-install/usr/local/bin/airdcppd /airdcpp-webclient/airdcppd
COPY --from=daemon-build /daemon/buildroot/resources/dcppboot.xml /airdcpp-webclient/dcppboot.xml
RUN ldconfig

# The patched web UI build (multi-select in filelists, queue and search)
COPY --from=webui-build /webui/dist/ /airdcpp-webclient/web-resources/

# Create default directories
RUN mkdir -p /.airdcpp /Downloads /Share \
    # Set permission on default directories
    && chmod a+rwX /.airdcpp /Downloads /Share \
    # Create symlink to configuration directory
    && ln -sf /.airdcpp /airdcpp-webclient/config \
    # Fix /favicon.ico 404 request
    && cd /airdcpp-webclient/web-resources \
    && ln -sf images/favicon.*.ico favicon.ico

# Copy dark mode CSS and the injector script, then run it
COPY dark.css /tmp/dark.css
COPY inject-css.js /tmp/inject-css.js
RUN node /tmp/inject-css.js \
    && rm /tmp/dark.css /tmp/inject-css.js

COPY .airdcpp/ /.default-config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 5600 5601 21248 21249
ENTRYPOINT ["/entrypoint.sh"]
