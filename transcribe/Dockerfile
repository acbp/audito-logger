FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        wget \
        cmake \
        libasound2-dev \
        portaudio19-dev \
        libsndfile1-dev \
        lsof \
        python3 \
        bash \
        ca-certificates \
        curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copiar os scripts necessários
COPY process.sh ./
COPY split_transcripts.sh ./

# Clonar o whisper.cpp e baixar os modelos (essa camada pode ser cacheada)
RUN git clone https://github.com/ggerganov/whisper.cpp

# Baixar modelo base
RUN cd whisper.cpp && \
    cd models && \
    wget -O ggml-base-q8_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q8_0.bin

# Compilar o whisper.cpp (esta etapa é mais demorada e deve ser cacheada)
RUN cd whisper.cpp && \
    make -j$(nproc)

RUN chmod +x process.sh split_transcripts.sh

# Definir o caminho das bibliotecas compartilhadas
ENV LD_LIBRARY_PATH=/app/whisper.cpp/build/src:/app/whisper.cpp/build/ggml/src:${LD_LIBRARY_PATH}

CMD ["./process.sh"]
