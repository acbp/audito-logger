#!/bin/bash
set -euo pipefail

# Script para dividir arquivos de transcrição em categorias mic e sys
# Este script processa arquivos de transcrição e cria versões ordenadas e filtradas

TRANSCRIPTS_DIR="/data/transcripts"

# Função para limpar arquivos .txt vazios no diretório TRANSCRIPTS_DIR
clean_empty_txt_files() {
    for txt_file in "$TRANSCRIPTS_DIR"/*.txt; do
        [ -f "$txt_file" ] || continue

        # Verificar se o arquivo .txt está vazio
        if [ ! -s "$txt_file" ]; then
            echo "🗑️ Removendo arquivo .txt vazio: $txt_file"
            rm -f "$txt_file"
        fi
    done
}

# Função para limpar arquivos de controle .processed que não têm mais arquivos correspondentes em TRANSCRIPTS_DIR
clean_processed_files() {
    for processed_file in "$TRANSCRIPTS_DIR"/.*_processed; do
        [ -f "$processed_file" ] || continue

        # Extrair o nome do arquivo original do nome do arquivo de controle
        # O formato é .{original_filename}_processed
        base_name=$(basename "$processed_file")
        if [[ "$base_name" == .*_processed ]]; then
            # Remover o prefixo "." e o sufixo "_processed"
            original_filename="${base_name#\.}"
            original_filename="${original_filename%_processed}"

            # Verificar se o arquivo original correspondente ainda existe em TRANSCRIPTS_DIR
            corresponding_file="$TRANSCRIPTS_DIR/$original_filename"
            if [ ! -f "$corresponding_file" ]; then
                echo "🗑️ Removendo arquivo de controle órfão: $processed_file"
                rm -f "$processed_file"
            fi
        fi
    done
}

# Loop para monitorar continuamente novos arquivos de transcrição
while true; do
    # Limpar arquivos .txt vazios periodicamente
    clean_empty_txt_files

    # Limpar arquivos de controle órfãos periodicamente
    clean_processed_files

    # Encontrar arquivos de transcrição que ainda não foram processados
    for transcript_file in "$TRANSCRIPTS_DIR"/*-transcription.txt; do
        # Verificar se o arquivo existe (evitar erro quando não há arquivos)
        [ -f "$transcript_file" ] || continue

        # Verificar se o arquivo foi modificado recentemente para evitar processamento durante escrita
        # Criar nome do arquivo de controle baseado no nome do arquivo original
        base_name=$(basename "$transcript_file" .txt)
        control_file="$TRANSCRIPTS_DIR/.${base_name}_processed"

        # Só processar se o arquivo for mais novo que o arquivo de controle
        if [ ! -f "$control_file" ] || [ "$transcript_file" -nt "$control_file" ]; then
            echo "🔄 Processando divisão de transcrição: $transcript_file"

            # Criar versão ordenada do arquivo de transcrição
            sorted_file="${transcript_file}.sort"
            sort -t"|" -k1 "$transcript_file" | sed -e "s/\[_EOT_\]//" > "$sorted_file"

            # Dividir em arquivos mic e sys
            mic_file="${sorted_file}.mic"
            sys_file="${sorted_file}.sys"

            grep -E '\[.*\|.*mic\]' "$sorted_file" > "$mic_file"
            grep -E '\[.*\|.*sys\]' "$sorted_file" > "$sys_file"

            echo "✅ Arquivo dividido em:"
            echo "   - Mic: $mic_file"
            echo "   - Sys: $sys_file"

            # Atualizar o arquivo de controle para indicar que este foi processado
            touch "$control_file"
        fi
    done

    # Aguardar antes de verificar novamente
    sleep 30
done