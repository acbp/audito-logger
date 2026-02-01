FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pulseaudio-utils \
        bash \
        python3-yaml \
        coreutils \
        sox \
        bc && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY run.sh ./
COPY config.yaml ./
RUN chmod +x run.sh

CMD ["./run.sh"]