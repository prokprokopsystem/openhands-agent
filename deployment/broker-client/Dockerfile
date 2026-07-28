FROM ghcr.io/openhands/agent-canvas:1.6.1@sha256:fc24163754bee2ab0115b117d57512cc01b4d99770e7ac17c3607e76290deeb6

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*
USER openhands
