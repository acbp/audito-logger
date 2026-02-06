#!/usr/bin/env python3
import os
import json
import sys
import time
from pathlib import Path

# Check if running in Docker container (mount point exists) or locally
if os.path.exists("./data"):
    TRANSCRIPTS_DIR = "./data/transcripts"
    SUMMARIES_DIR = "./data/summaries"
    DONE_DIR = "./data/summaries/done"
else:
    TRANSCRIPTS_DIR = "/data/transcripts"
    SUMMARIES_DIR = "/data/summaries"
    DONE_DIR = "/data/summaries/done"

os.makedirs(SUMMARIES_DIR, exist_ok=True)
os.makedirs(DONE_DIR, exist_ok=True)

# Check if running in Docker container or locally
if os.path.exists("./summarize/prompt.txt"):
    prompt_path = "./summarize/prompt.txt"
else:
    prompt_path = "/app/prompt.txt"

with open(prompt_path, "r") as f:
    BASE_PROMPT = f.read().strip()

def extract_timestamps_from_transcript(transcript: str) -> list:
    """Extract timestamps from transcript and return time ranges"""
    import re
    # Find all timestamps in the format [YYYY-MM-DDTHH:MM:SSZ | label] content
    timestamp_pattern = r'\[(\d{4}-\d{2}-\d{2}T(\d{2}):(\d{2}):(\d{2})Z)'
    matches = re.findall(timestamp_pattern, transcript)

    if not matches:
        return []

    # Extract just the HH:MM parts
    times = [f"{match[1]}:{match[2]}" for match in matches]
    return sorted(list(set(times)))  # Remove duplicates and sort

def assign_times_to_keypoints(key_points: list, timestamps: list) -> list:
    """Assign time ranges to key points based on available timestamps"""
    if not timestamps:
        # If no timestamps available, return keypoints as-is
        return key_points

    # If we have more key points than timestamps, we need to create ranges or group them
    enhanced_key_points = []

    if len(key_points) <= len(timestamps):
        # We have enough timestamps for each key point
        for i, point in enumerate(key_points):
            if i < len(timestamps):
                time_str = timestamps[i]
                # Calculate next time for range, or use same time if it's the last one
                if i + 1 < len(timestamps):
                    end_time = timestamps[i + 1]
                    time_range = f"{time_str}-{end_time}"
                else:
                    # If it's the last timestamp, estimate end time by adding 15 minutes
                    hour, minute = time_str.split(':')
                    minute = str(int(minute) + 15).zfill(2)
                    if int(minute) >= 60:
                        minute = str(int(minute) - 60).zfill(2)
                        hour = str(int(hour) + 1).zfill(2)
                    end_time = f"{hour}:{minute}"
                    time_range = f"{time_str}-{end_time}"

                enhanced_point = f"[{time_range}] {point}"
                enhanced_key_points.append(enhanced_point)
    else:
        # More key points than timestamps, need to distribute timestamps among key points
        # For simplicity, we'll assign timestamps cyclically and create ranges
        for i, point in enumerate(key_points):
            # Map key point index to timestamp index
            timestamp_idx = i % len(timestamps)
            time_str = timestamps[timestamp_idx]

            # Calculate end time based on position
            if timestamp_idx + 1 < len(timestamps):
                end_time = timestamps[timestamp_idx + 1]
                time_range = f"{time_str}-{end_time}"
            else:
                # If it's the last timestamp, estimate end time by adding 15 minutes
                hour, minute = time_str.split(':')
                minute = str(int(minute) + 15).zfill(2)
                if int(minute) >= 60:
                    minute = str(int(minute) - 60).zfill(2)
                    hour = str(int(hour) + 1).zfill(2)
                end_time = f"{hour}:{minute}"
                time_range = f"{time_str}-{end_time}"

            enhanced_point = f"[{time_range}] {point}"
            enhanced_key_points.append(enhanced_point)

    return enhanced_key_points

def call_ollama(prompt: str) -> dict:
    import subprocess
    import socket
    
    # Tenta primeiro usando o ollama diretamente no host
    try:
        result = subprocess.run(
            ["ollama", "run", "gemma3:1b"],
            input=prompt,
            text=True,
            capture_output=True,
            timeout=300
        )
        if result.returncode != 0:
            print(f"⚠️ Ollama local falhou, tentando via API: {result.stderr}", file=sys.stderr)
            raise RuntimeError(f"Ollama error: {result.stderr}")
        output = result.stdout.strip()
        if output.startswith("```json"):
            output = output.split("```json", 1)[1].split("```")[0]
        return json.loads(output)
    except Exception as e:
        print(f"❌ Falha ao processar com Ollama local: {e}", file=sys.stderr)
        
        # Tenta via API se o método direto falhar
        try:
            import requests
            response = requests.post(
                "http://host.docker.internal:11434/api/generate",
                json={
                    "model": "gemma3:1b",
                    "prompt": prompt,
                    "stream": False
                },
                timeout=300
            )
            
            if response.status_code == 200:
                result_text = response.json()["response"]
                
                # Extrai o JSON da resposta
                import re
                json_match = re.search(r'\{.*\}', result_text, re.DOTALL)
                if json_match:
                    json_str = json_match.group()
                    return json.loads(json_str)
                else:
                    print("⚠️ Não foi possível extrair JSON da resposta da API", file=sys.stderr)
                    return {"summary": "[SUMÁRIO VIA API]", "key_points": ["[PROCESSADO COM ERROS]"]}
            else:
                print(f"⚠️ API retornou código {response.status_code}: {response.text}", file=sys.stderr)
        except Exception as api_error:
            print(f"❌ Falha ao processar com API Ollama: {api_error}", file=sys.stderr)
        
        # Retorna fallback em caso de falha total
        return {"summary": "[ERRO NA SUMARIZAÇÃO]", "key_points": []}


def json_to_markdown(result: dict, date_str: str, transcript: str = "") -> str:
    """Convert JSON result to markdown format with time information"""
    markdown_content = f"# Resumo Diário - {date_str}\n\n"
    markdown_content += f"## Resumo Conciso\n{result['summary']}\n\n"
    markdown_content += f"## Pontos Principais\n"

    # Extract timestamps from the transcript
    timestamps = extract_timestamps_from_transcript(transcript)

    # Enhance key points with time information
    enhanced_key_points = assign_times_to_keypoints(result['key_points'], timestamps)

    for point in enhanced_key_points:
        markdown_content += f"- {point}\n"

    return markdown_content

def main():
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
    
    class TranscriptHandler(FileSystemEventHandler):
        def on_created(self, event):
            if event.is_directory:
                return
            
            if event.src_path.endswith('.txt'):
                self.process_transcript(event.src_path)
        
        def on_modified(self, event):
            # Processa arquivos modificados também, caso sejam atualizados
            if event.is_directory:
                return
                
            if event.src_path.endswith('.txt'):
                # Adiciona um pequeno delay para garantir que a escrita foi concluída
                time.sleep(2)
                self.process_transcript(event.src_path)
        
        def process_transcript(self, file_path):
            transcript_path = Path(file_path)
            date_str = transcript_path.stem.replace("-transcription", "")
            summary_path = Path(SUMMARIES_DIR) / f"{date_str}-summary.md"
            done_marker = Path(DONE_DIR) / f"{date_str}.done"

            if done_marker.exists():
                return

            print(f"🧠 Sumarizando: {transcript_path.name}")

            with open(transcript_path, "r", encoding="utf-8") as f:
                transcript = f.read().strip()

            if not transcript:
                print(f"⚠️  Transcrição vazia: {transcript_path.name}")
                done_marker.touch()
                return

            prompt = BASE_PROMPT.replace("{{transcript}}", transcript)
            result = call_ollama(prompt)

            # Convert JSON result to markdown
            markdown_content = json_to_markdown(result, date_str, transcript)

            with open(summary_path, "w", encoding="utf-8") as f:
                f.write(markdown_content)

            done_marker.touch()
            print(f"✅ Salvo: {summary_path.name}")
    
    # Configura o observador de arquivos
    event_handler = TranscriptHandler()
    observer = Observer()
    observer.schedule(event_handler, TRANSCRIPTS_DIR, recursive=False)
    
    print(f"🔍 Monitorando mudanças em {TRANSCRIPTS_DIR}")
    observer.start()
    
    try:
        # Mantém o programa rodando
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
        print("\n🛑 Parando o monitoramento...")
    
    observer.join()

if __name__ == "__main__":
    main()