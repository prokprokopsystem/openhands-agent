# FFmpeg + ffprobe, статическая сборка BtbN (GPL), закреплённая версия и сумма.
# Образ намеренно минимальный: нет Chromium, Node, HyperFrames и других приложений.
# База Debian нужна, потому что бинарники BtbN собраны под glibc, а не под musl.
# Корневая ФС в рантайме монтируется read-only.

FROM debian:bookworm-slim@sha256:c67e92c8099ba22853ab4cfda7cfb494d253d6012ca82dee98ba8976772af018 AS fetch

ARG FFMPEG_URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-02-28-12-59/ffmpeg-n8.0.1-66-g27b8d1a017-linux64-gpl-8.0.tar.xz
ARG FFMPEG_SHA256=26d2ecd0cefba99f9d1ea92252a3a4f743a58df4c1c3cf9f8bbaaa40b1fca5b0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL --retry 3 -o /tmp/ffmpeg.tar.xz "$FFMPEG_URL" \
 && echo "$FFMPEG_SHA256  /tmp/ffmpeg.tar.xz" | sha256sum -c - \
 && mkdir -p /ffmpeg-bin \
 && tar -xJf /tmp/ffmpeg.tar.xz -C /ffmpeg-bin \
      --strip-components=2 --wildcards '*/bin/ffmpeg' '*/bin/ffprobe' \
 && chmod 0755 /ffmpeg-bin/ffmpeg /ffmpeg-bin/ffprobe \
 && rm -f /tmp/ffmpeg.tar.xz

FROM debian:bookworm-slim@sha256:c67e92c8099ba22853ab4cfda7cfb494d253d6012ca82dee98ba8976772af018

LABEL org.opencontainers.image.title="video-studio/ffmpeg" \
      org.opencontainers.image.description="FFmpeg 8.0.1 + ffprobe, BtbN GPL build" \
      org.opencontainers.image.version="8.0.1" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

RUN groupadd -g 10001 studio \
 && useradd -u 10001 -g 10001 -M -d /home/studio -s /usr/sbin/nologin studio

COPY --from=fetch /ffmpeg-bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=fetch /ffmpeg-bin/ffprobe /usr/local/bin/ffprobe

USER 10001:10001
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/ffmpeg"]
