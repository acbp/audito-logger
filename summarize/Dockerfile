FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        python3 \
        python3-pip \
        zstd \
        python3-requests \
        python3-watchdog && \
    rm -rf /var/lib/apt/lists/*

# Instalar Ollama
RUN curl -fsSL https://ollama.com/install.sh | sh

WORKDIR /app
COPY summarize.py prompt.txt ./

CMD ["python3", "summarize.py"]