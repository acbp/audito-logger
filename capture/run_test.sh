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

while true; do
  NOW=$(date -u +"%Y%m%d-%H%M")
  
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    SOURCE=$(echo "$line" | cut -d' ' -f1)
    LABEL=$(echo "$line" | cut -d' ' -f2)
    TEMP_FILE="/tmp/${NOW}-${LABEL}.wav"
    FINAL_FILE="$OUTPUT_DIR/${NOW}-${LABEL}.wav"

    echo "▶️ Verificando atividade de áudio em $SOURCE"
    
    # Gravar com detecção de atividade de voz (VAD) usando sox
    timeout "$DURATION" parecord \
      --rate="$RATE" \
      --channels=1 \
      --format=s16le \
      --file-format=wav \
      --device="$SOURCE" \
      "$TEMP_FILE" 2>/dev/null || true

    # Verificar se o arquivo tem conteúdo significativo
    if [ -f "$TEMP_FILE" ] && [ -s "$TEMP_FILE" ]; then
      # Calcular o nível médio de amplitude (RMS) - threshold reduzido para testes
      RMS_LEVEL=$(sox "$TEMP_FILE" -n stat 2>&1 | grep "RMS amplitude" | awk '{print $3}' | sed 's/[()]//g')
      
      # Threshold reduzido para testes (0.001 em vez de 0.01)
      THRESHOLD=0.001
      
      # Comparar o nível RMS com o threshold
      if [ ! -z "$RMS_LEVEL" ] && [ $(echo "$RMS_LEVEL > $THRESHOLD" | bc -l) -eq 1 ]; then
        mv "$TEMP_FILE" "$FINAL_FILE"
        echo "🔊 Conteúdo detectado: $FINAL_FILE (RMS: $RMS_LEVEL)"
      else
        echo "🔇 Silêncio detectado, ignorando: $TEMP_FILE (RMS: $RMS_LEVEL)"
        rm -f "$TEMP_FILE"
      fi
    else
      echo "🔇 Arquivo vazio ou não gravado para: $SOURCE"
    fi
  done <<< "$CHANNELS_RAW"

  sleep 1
done