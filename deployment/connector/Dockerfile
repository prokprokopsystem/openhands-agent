FROM ghcr.io/openhands/agent-canvas:1.6.1@sha256:fc24163754bee2ab0115b117d57512cc01b4d99770e7ac17c3607e76290deeb6

ARG SOURCE_COMMIT
USER root

RUN test -n "${SOURCE_COMMIT}" \
    && rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources \
    && printf '%s\n' \
       'Types: deb' \
       'URIs: https://snapshot.debian.org/archive/debian/20260601T030000Z' \
       'Suites: trixie' \
       'Components: main' \
       'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
       'Check-Valid-Until: no' \
       > /etc/apt/sources.list.d/openhands-snapshot.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends openssh-client=1:10.0p1-7+deb13u4 \
    && test "$(dpkg-query -W -f='${Version}' openssh-client)" = '1:10.0p1-7+deb13u4' \
    && rm -rf /var/lib/apt/lists/*

COPY broker-client.py /usr/local/bin/openhands-broker-client
RUN chown root:root /usr/local/bin/openhands-broker-client \
    && chmod 0755 /usr/local/bin/openhands-broker-client \
    && install -d -o root -g 10001 -m 0750 /run/openhands-broker/client

LABEL org.openhands.connector.stage="4D.4" \
      org.openhands.connector.source="${SOURCE_COMMIT}" \
      org.openhands.connector.openssh-client="1:10.0p1-7+deb13u4"

USER openhands
