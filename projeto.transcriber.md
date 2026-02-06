# Especificação Técnica: Sistema de Transcrição e Sumarização de Áudio Local

## Objetivo
Capturar continuamente áudio do microfone e canais selecionáveis do sistema em chunks de 5 minutos, transcrever localmente com `whisper.cpp`, e gerar resumos diários com pontos principais usando **Ollama + `gemma3:1b`** (modelo de 1B com janela de contexto de 32k tokens). Sistema modular, offline, idempotente, rodando via Docker no Ubuntu.

---

## Estrutura de Diretórios

```
audio-logger/
├── capture/
│   ├── run.sh
│   └── config.yaml
├── transcribe/
│   ├── process.sh
│   └── whisper.cpp/
│       └── models/
│           └── ggml-base.bin
├── summarize/
│   ├── summarize.py
│   └── prompt.txt
├── data/
│   ├── raw/                 # chunks de áudio brutos (.wav)
│   ├── done/                # controle de processamento (transcribe)
│   ├── transcripts/         # transcrições diárias: YYYY-MM-DD-transcription.txt
│   └── summaries/           # resumos: YYYY-MM-DD-summary.md + done/
└── docker-compose.yml
```

---

## Requisitos do Host (Ubuntu)

- Ubuntu 20.04, 22.04 ou 24.04
- PulseAudio ativo
- Docker e Docker Compose instalados
- UID do usuário: 1000 (ajustar se diferente)

Verifique:
```bash
id -u
pactl list short sources
```

---

## Módulo de Captura (`capture/run.sh`)

Grava chunks de 5 minutos por canal usando `parecord`.

### Configuração (`capture/config.yaml`)
```yaml
channels:
  - source: alsa_input.pci-0000_00_1f.3.analog-stereo
    label: mic
  - source: alsa_output.pci-0000_00_1f.3.analog-stereo.monitor
    label: sys
chunk_duration_sec: 300
sample_rate: 48000
bit_depth: 16
format: wav
output_dir: /data/raw
```

> **Nota**: Substitua os valores de `source` pelos obtidos com `pactl list short sources`.

### Código (`capture/run.sh`)
```bash
#!/bin/bash
set -euo pipefail

CONFIG="config.yaml"
OUTPUT_DIR="/data/raw"

DURATION=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG'))['chunk_duration_sec'])")
RATE=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG'))['sample_rate'])")
CHANNELS_RAW=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('$CONFIG'))
for ch in cfg['channels']:
    print(f\"{ch['source']} {ch['label']}\")
")

mkdir -p "$OUTPUT_DIR"

while true; do
  NOW=$(date -u +"%Y%m%d-%H%M")
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    SOURCE=$(echo "$line" | cut -d' ' -f1)
    LABEL=$(echo "$line" | cut -d' ' -f2)
    FILE="$OUTPUT_DIR/${NOW}-${LABEL}.wav"

    echo "▶️ Gravando $FILE (fonte: $SOURCE)"
    timeout "$DURATION" parecord \
      --rate="$RATE" \
      --channels=1 \
      --format=s16le \
      --file-format=wav \
      --device="$SOURCE" \
      "$FILE" &
  done <<< "$CHANNELS_RAW"

  wait
  sleep 1
done
```

Permissões:
```bash
chmod +x capture/run.sh
```

---

## Módulo de Transcrição (`transcribe/process.sh`)

Processa `.wav` com `whisper.cpp`, evita reprocessamento.

### Pré-requisito
```bash
cd transcribe
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
make
./models/download-ggml-model.sh base
```

### Código (`transcribe/process.sh`)
```bash
#!/bin/bash
set -euo pipefail

INPUT_DIR="/data/raw"
DONE_DIR="/data/done"
OUT_DIR="/data/transcripts"

mkdir -p "$DONE_DIR" "$OUT_DIR"

find "$INPUT_DIR" -name "*.wav" | sort | while read -r file; do
  basename=$(basename "$file")
  done_file="$DONE_DIR/$basename"

  if [ -f "$done_file" ]; then
    continue
  fi

  echo "🧠 Transcrevendo: $file"

  date_str=$(echo "$basename" | cut -d'-' -f1)
  year=${date_str:0:4}
  month=${date_str:4:2}
  day=${date_str:6:2}
  out_txt="$OUT_DIR/${year}-${month}-${day}-transcription.txt"

  ./whisper.cpp/main \
    -m ./whisper.cpp/models/ggml-base.bin \
    -f "$file" \
    -l pt \
    -otxt \
    --print-special \
    --no-timestamps

  txt_sidecar="$file.txt"
  if [ -f "$txt_sidecar" ]; then
    timestamp=$(stat -c %Y "$file" | xargs -I{} date -d @{} -u +"%Y-%m-%dT%H:%M:%SZ")
    label=$(echo "$basename" | cut -d'-' -f3 | cut -d'.' -f1)

    mkdir -p "$(dirname "$out_txt")"
    echo "[$timestamp | $label] $(cat "$txt_sidecar")" >> "$out_txt"
    rm "$txt_sidecar"
  fi

  touch "$done_file"
done
```

Permissões:
```bash
chmod +x transcribe/process.sh
```

---

## Módulo de Sumarização (`summarize/summarize.py`)

Gera resumo e pontos principais a partir das transcrições diárias usando **`gemma3:1b`**. O resumo final é armazenado em formato markdown.

### Prompt (`summarize/prompt.txt`)
```text
Você é um assistente especializado em resumir registros de áudio.
Analise o seguinte bloco de transcrição e gere:

1. Um **resumo conciso** (máximo 150 palavras), incluindo referências temporais quando possível.
2. Uma lista de **pontos principais** (3 a 7 itens), cada um com até 20 palavras, incluindo intervalos de tempo aproximados (ex: "14h30–14h45").

Responda **exclusivamente em JSON válido**, sem markdown, no formato:

{
  "summary": "resumo aqui",
  "key_points": ["[HH:MM-HH:MM] ponto 1", "HH:MM-HH:MM] ponto 2", ...]
}

Transcrição:
{{transcript}}
```

### Código (`summarize/summarize.py`)
```python
#!/usr/bin/env python3
import os
import json
import sys
import time
from pathlib import Path

TRANSCRIPTS_DIR = "/data/transcripts"
SUMMARIES_DIR = "/data/summaries"
DONE_DIR = "/data/summaries/done"

os.makedirs(SUMMARIES_DIR, exist_ok=True)
os.makedirs(DONE_DIR, exist_ok=True)

with open("/app/prompt.txt", "r") as f:
    BASE_PROMPT = f.read().strip()

def call_ollama(prompt: str) -> dict:
    import subprocess
    try:
        result = subprocess.run(
            ["ollama", "run", "gemma3:1b"],
            input=prompt,
            text=True,
            capture_output=True,
            timeout=300
        )
        if result.returncode != 0:
            raise RuntimeError(f"Ollama error: {result.stderr}")
        output = result.stdout.strip()
        if output.startswith("```json"):
            output = output.split("```json", 1)[1].split("```")[0]
        return json.loads(output)
    except Exception as e:
        print(f"❌ Falha ao processar com Ollama: {e}", file=sys.stderr)
        return {"summary": "[ERRO NA SUMARIZAÇÃO]", "key_points": []}

def main():
    transcript_files = sorted(Path(TRANSCRIPTS_DIR).glob("*.txt"))
    for transcript_path in transcript_files:
        date_str = transcript_path.stem.replace("-transcription", "")
        summary_path = Path(SUMMARIES_DIR) / f"{date_str}-summary.json"
        done_marker = Path(DONE_DIR) / f"{date_str}.done"

        if done_marker.exists():
            continue

        print(f"🧠 Sumarizando: {transcript_path.name}")

        with open(transcript_path, "r", encoding="utf-8") as f:
            transcript = f.read().strip()

        if not transcript:
            print(f"⚠️  Transcrição vazia: {transcript_path.name}")
            done_marker.touch()
            continue

        prompt = BASE_PROMPT.replace("{{transcript}}", transcript)
        result = call_ollama(prompt)

        with open(summary_path, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)

        done_marker.touch()
        print(f"✅ Salvo: {summary_path.name}")
        time.sleep(2)

if __name__ == "__main__":
    main()
```

Permissões:
```bash
chmod +x summarize/summarize.py
```

---

## Dockerfiles

### `capture/Dockerfile`
```dockerfile
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pulseaudio-utils \
        bash \
        python3-yaml \
        coreutils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY run.sh config.yaml ./
RUN chmod +x run.sh

CMD ["./run.sh"]
```

### `transcribe/Dockerfile`
```dockerfile
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        wget && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

RUN cd whisper.cpp && make -j$(nproc)

CMD ["./process.sh"]
```

### `summarize/Dockerfile`
```dockerfile
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        python3 \
        python3-pip && \
    rm -rf /var/lib/apt/lists/*

# Instalar Ollama
RUN curl -fsSL https://ollama.com/install.sh | sh

WORKDIR /app
COPY summarize.py prompt.txt ./

CMD ["python3", "summarize.py"]
```

---

## Docker Compose (`docker-compose.yml`)

```yaml
version: '3.8'
services:
  capture:
    build: ./capture
    volumes:
      - .//data
      - /run/user/1000/pulse:/run/user/1000/pulse
    environment:
      - PULSE_SERVER=unix:/run/user/1000/pulse/native
      - HOME=/tmp
    devices:
      - /dev/snd
    restart: unless-stopped
    user: "1000:1000"

  transcribe:
    build: ./transcribe
    volumes:
      - .//data
    restart: on-failure
    user: "1000:1000"

  summarize:
    build: ./summarize
    volumes:
      - .//data
    restart: on-failure
    user: "1000:1000"
```

> Substitua `1000` pelo seu UID real se diferente.

---

## Fluxo de Execução

1. **Configure manualmente `capture/config.yaml`** com suas fontes de áudio:
   ```bash
   pactl list short sources
   ```

2. **Baixar modelo de transcrição**:
   ```bash
   cd transcribe
   git clone https://github.com/ggerganov/whisper.cpp
   cd whisper.cpp
   make
   ./models/download-ggml-model.sh base
   ```

3. **Iniciar captura contínua**:
   ```bash
   docker compose up -d capture
   ```

4. **Transcrever periodicamente**:
   ```bash
   docker compose run --rm transcribe
   ```

5. **Gerar resumos com `gemma3:1b`**:
   ```bash
   docker compose run --rm summarize
   ```

---

## Reprocessamento

- **Transcrição**: apague arquivos em `data/done/`.
- **Sumarização**: apague arquivos em `data/summaries/done/`.
- Todos os módulos processam em ordem cronológica e evitam duplicação.

---

## Requisitos de Hardware

- **Captura/Transcrição**: 2 GB RAM
- **Sumarização**: **2 GB RAM livres** (suficiente para `gemma3:1b` em CPU)
- **Disco**: ~2 GB livres (modelos + áudio)

> O modelo `gemma3:1b` é leve, rápido e ideal para resumos curtos com contexto longo (até 32k tokens).

---

## Saída Exemplo

### Transcrição (`data/transcripts/2026-02-01-transcription.txt`)
```
[2026-02-01T14:30:00Z | mic] Boa tarde, vamos iniciar a reunião.
[2026-02-01T14:32:15Z | sys] Notificação recebida.
```

### Resumo (`data/summaries/2026-02-01-summary.md`)
```markdown
# Resumo Diário - 2026-02-01

## Resumo Conciso
A reunião foi iniciada com uma saudação. Uma notificação foi recebida durante a sessão.

## Pontos Principais
- [14:30-14:45] Início da reunião com saudação
- [14:45-15:00] Notificação recebida durante a gravação
```