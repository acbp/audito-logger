# Audio Logger

A comprehensive audio processing pipeline that captures, transcribes, and summarizes audio content using Docker containers.

## Overview

This project implements an audio processing pipeline with three main components:
- **Capture**: Records audio from various sources
- **Transcribe**: Converts audio to text using speech recognition
- **Summarize**: Generates summaries of the transcribed content

## Architecture

The system is built using Docker containers for each component:

### Capture Module (`capture/`)
- Records audio from specified sources
- Configurable via `config.yaml`
- Outputs audio files to shared storage

### Transcribe Module (`transcribe/`)
- Converts audio files to text transcripts
- Uses speech-to-text technology
- Processes files in batches

### Summarize Module (`summarize/`)
- Creates concise summaries of transcribed content
- Uses AI-powered text summarization
- Stores results in organized format

## Prerequisites

- Docker
- Docker Compose
- Audio recording capabilities (for capture module)

## Setup

1. Clone the repository:
```bash
git clone <repository-url>
cd audio-logger
```

2. Build and start the services:
```bash
docker-compose up --build
```

## Configuration

Each module has its own configuration:
- `capture/config.yaml`: Audio capture settings
- `summarize/prompt.txt`: Summarization prompt template

## Data Flow

1. Audio is captured by the capture module
2. Audio files are processed by the transcribe module
3. Transcripts are summarized by the summarize module
4. Results are stored in the `data/` directory

## Directory Structure

```
audio-logger/
├── capture/              # Audio capture module
│   ├── config.yaml       # Capture configuration
│   ├── Dockerfile        # Capture container definition
│   ├── run.sh            # Capture startup script
│   └── run_test.sh       # Test script for capture
├── transcribe/           # Audio transcription module
│   ├── Dockerfile        # Transcription container definition
│   ├── process.sh        # Processing script
│   └── split_transcripts.sh # Transcript splitting utility
├── summarize/            # Content summarization module
│   ├── Dockerfile        # Summarization container definition
│   ├── prompt.txt        # Summarization prompt
│   └── summarize.py      # Summarization script
├── data/                 # Storage for audio, transcripts, and summaries
├── docker-compose.yml    # Docker Compose orchestration
└── README.md             # Project documentation
```

## Usage

The system can be orchestrated using Docker Compose:

```bash
# Build and start all services
docker-compose up --build

# Start services in detached mode
docker-compose up -d

# View logs
docker-compose logs -f

# Stop services
docker-compose down
```

## Customization

- Modify `capture/config.yaml` to adjust audio capture settings
- Update `summarize/prompt.txt` to customize summarization behavior
- Adjust Docker resources in `docker-compose.yml` as needed

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## License

[Specify your license here]