#!/bin/bash
set -euo pipefail

# Definir variáveis importantes
export LD_LIBRARY_PATH="./whisper.cpp/build/src:${LD_LIBRARY_PATH:-}"

INPUT_DIR="/data/raw"
DONE_DIR="/data/done"
OUT_DIR="/data/transcripts"

mkdir -p "$DONE_DIR" "$OUT_DIR"

# Função para limpar arquivos .txt vazios no diretório INPUT_DIR
clean_empty_txt_files() {
    for txt_file in "$INPUT_DIR"/*.txt; do
        [ -f "$txt_file" ] || continue

        # Verificar se o arquivo .txt está vazio
        if [ ! -s "$txt_file" ]; then
            echo "🗑️ Removendo arquivo .txt vazio: $txt_file"
            rm -f "$txt_file"
        fi
    done
}

# Função para limpar arquivos .done que não têm mais arquivos correspondentes em INPUT_DIR
clean_done_files() {
    for done_file in "$DONE_DIR"/*; do
        [ -f "$done_file" ] || continue

        # Obter o nome do arquivo base (sem o caminho)
        basename=$(basename "$done_file")

        # Verificar se o arquivo correspondente ainda existe em INPUT_DIR
        corresponding_file="$INPUT_DIR/$basename"
        if [ ! -f "$corresponding_file" ]; then
            echo "🗑️ Removendo arquivo .done órfão: $done_file"
            rm -f "$done_file"
        fi
    done
}

# Loop infinito para monitorar continuamente o diretório de entrada
while true; do
    # Limpar arquivos .txt vazios periodicamente
    clean_empty_txt_files

    # Limpar arquivos .done órfãos periodicamente
    clean_done_files

    # Encontrar arquivos WAV que ainda não foram processados
    for file in "$INPUT_DIR"/*.wav; do
        # Verificar se o arquivo existe (evitar erro quando não há arquivos)
        [ -f "$file" ] || continue

        basename=$(basename "$file")
        done_file="$DONE_DIR/$basename"

        # Pular se o arquivo já foi processado
        if [ -f "$done_file" ]; then
            continue
        fi

        # Verificar se o arquivo está sendo escrito por outro processo
        # Usando flock para verificar se o arquivo está bloqueado
        if (set -o noclobber; 2>/dev/null >"$file.lock";) && rm -f "$file.lock"; then
            # Verificar se o arquivo tem conteúdo significativo (> 1KB por exemplo)
            if [ -s "$file" ] && [ $(stat -c%s "$file") -gt 1024 ]; then
                # Arquivo tem conteúdo, podemos processar
                echo "🧠 Transcrevendo: $file"

                date_str=$(echo "$basename" | cut -d'-' -f1)
                year=${date_str:0:4}
                month=${date_str:4:2}
                day=${date_str:6:2}
                out_txt="$OUT_DIR/${year}-${month}-${day}-transcription.txt"

                # Tentar transcrição até 5 vezes antes de remover o arquivo
                success=false
                attempt=1
                max_attempts=5

                while [ $attempt -le $max_attempts ]; do
                    echo "🧠 Tentativa $attempt de $max_attempts para transcrever: $file"

                    if LD_LIBRARY_PATH="./whisper.cpp/build/src:./whisper.cpp/build/ggml/src:${LD_LIBRARY_PATH:-}" ./whisper.cpp/build/bin/whisper-cli \
                        -f "$file" \
                        -m ./whisper.cpp/models/ggml-base-q8_0.bin \
                        -np -nf \
                        -vt 0.65 \
                        --vad \
                        --vad-model ./whisper.cpp/models/ggml-silero-v6.2.0.bin \
                        -l pt \
                        --output-txt \
                        --print-special \
                        --no-timestamps; then

                        # Verificar se o arquivo sidecar foi criado e tem conteúdo
                        txt_sidecar="$file.txt"
                        if [ -f "$txt_sidecar" ] && [ -s "$txt_sidecar" ]; then
                            timestamp=$(stat -c %Y "$file" | xargs -I{} date -d @{} -u +"%Y-%m-%dT%H:%M:%SZ")
                            label=$(echo "$basename" | cut -d'-' -f3 | cut -d'.' -f1)

                            mkdir -p "$(dirname "$out_txt")"
                            echo "[$timestamp | $label] $(cat "$txt_sidecar")" >> "$out_txt"
                            rm "$txt_sidecar"

                            # Somente marcar como processado se houve transcrição bem sucedida
                            touch "$done_file"

                            # Remover o arquivo original após transcrição bem sucedida
                            rm -f "$file"
                            echo "✅ Processamento concluído e arquivo removido: $file"
                            success=true
                            break
                        else
                            echo "⚠️ Arquivo sidecar vazio ou não encontrado, nova tentativa ($attempt/$max_attempts)..."
                        fi
                    else
                        echo "❌ Falha na tentativa $attempt/$max_attempts para $file"
                    fi

                    attempt=$((attempt + 1))
                    sleep 2  # Esperar 2 segundos entre tentativas
                done

                if [ "$success" = false ]; then
                    # Após 5 tentativas malsucedidas, remover o arquivo para evitar loop infinito
                    echo "💥 Após $max_attempts tentativas, removendo $file para evitar loop infinito"
                    rm -f "$file"
                    # Também marcar como processado para não tentar novamente
                    touch "$done_file"
                fi
            else
                # Arquivo está vazio ou muito pequeno, provavelmente ainda sendo gravado
                echo "⏳ Arquivo muito pequeno ou vazio, pulando: $file"
            fi
        else
            # Arquivo está sendo escrito, vamos pular por enquanto
            echo "⏳ Arquivo em escrita, pulando: $file"
        fi
    done

    # Aguardar antes de verificar novamente
    sleep 10
done
