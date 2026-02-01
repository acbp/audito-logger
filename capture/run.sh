#!/bin/bash
set -euo pipefail

CONFIG="/app/config.yaml"
OUTPUT_DIR="/data/raw"

DURATION=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG'))['chunk_duration_sec'])")
RATE=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG'))['sample_rate'])")
CHANNELS_RAW=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('$CONFIG'))
for ch in cfg['channels']:
    print(f\"{ch['source']} {ch['label']}\")
")

# Tenta criar os diretórios necessários
mkdir -p /data/raw /data/done /data/transcripts 2>/dev/null || true

# Calcular o intervalo entre chunks considerando sobreposição
# Usar um intervalo ligeiramente menor que a duração para garantir continuidade
OVERLAP_SECONDS=10
INTERVAL=$((DURATION - OVERLAP_SECONDS))

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

  # Aguardar menos que a duração total para garantir continuidade entre chunks
  sleep $INTERVAL
done