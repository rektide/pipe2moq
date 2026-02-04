# Pipe2MoQ

Low-latency audio streaming from PipeWire to MoQ (Media over QUIC).

## Overview

Pipe2MoQ captures audio from the default PipeWire sink, encodes it using Opus, and publishes it to a MoQ relay. It's designed for minimal latency by tightly coupling the GStreamer pipeline with the MoQ publisher in a single process.

## Features

- 🚀 Ultra-low latency (< 50ms end-to-end with proper tuning)
- 📦 Single unified process (no hang-gst intermediate)
- 🔧 Configurable via TOML config file or command line
- 🎛️ Tunable Opus encoder settings (bitrate, complexity, frame size)
- 📊 Real-time pipeline monitoring

## Architecture

```
┌──────────────┐
│  PipeWire    │  Default audio sink
│   (Linux)    │
└──────┬───────┘
        │
        ▼
┌─────────────────────────────────┐
│   GStreamer Pipeline (Rust)     │
│  pulsesrc → audioconvert →        │
│  audioresample → opusenc →       │
│  appsink (Opus frames)           │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│   MoQ Publisher (Rust)          │
│   + hang (catalog, container)   │
│   + moq-lite (transport)        │
└──────┬──────────────────────────┘
       │
       ▼
┌──────────────┐
│ moq-relay    │  Fan-out to subscribers
│   server      │
└──────┬───────┘
       │
       └───▶ [Subscribers via WebTransport]
```

## Installation

### Prerequisites

- Rust (1.70+)
- GStreamer (1.20+)
- GStreamer plugins:
  - `gst-plugins-base` (audioconvert, audioresample)
  - `gst-plugins-good` (pulsesrc, opusenc)
- PipeWire/PulseAudio (for audio capture)

### Build

```bash
cargo build --release
```

## Configuration

Create a `config.toml` file:

```toml
[relay]
url = "https://localhost:4443/anon"
broadcast_path = "/live/audio.hang"
track_name = "audio"

[audio]
sample_rate = 48000
channels = 2
bitrate = 96000
application = "voip"
complexity = 5
frame_size = 20
max_ptime = 20

[pipeline]
buffer_time = 20000
latency_time = 10000
sink_name = null  # Optional: use specific sink
```

### Command Line Options

```bash
pipe2moq [OPTIONS]

Options:
  -c, --config <CONFIG>              Config file [default: config.toml]
      --relay-url <URL>               MoQ relay URL
      --broadcast-path <PATH>         Broadcast path
      --track-name <NAME>             Track name
      --sink-name <NAME>              PipeWire sink name
      --bitrate <KBPS>                Opus bitrate (kbps)
      --sample-rate <HZ>              Sample rate (Hz)
      --channels <N>                  Audio channels
      --complexity <0-10>            Opus complexity
  -v, --verbose                       Enable debug logging
  -h, --help                          Print help
```

### Environment Variables

Prefix with `PIPE2MOQ_`:

```bash
export PIPE2MOQ_RELAY_URL=https://relay.example.com/anon
export PIPE2MOQ_AUDIO_BITRATE=128000
pipe2moq
```

## Usage

### Basic Usage

```bash
# Use default configuration
pipe2moq

# With custom config file
pipe2moq -c /path/to/config.toml

# Override relay URL
pipe2moq --relay-url https://relay.example.com/anon
```

### Low Latency Voice

```bash
pipe2moq \
  --bitrate 64000 \
  --complexity 2 \
  --sample-rate 48000 \
  --channels 1
```

### High Quality Music

```bash
pipe2moq \
  --bitrate 256000 \
  --complexity 8 \
  --application audio
```

## Audio Tuning

### Opus Parameters

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| `bitrate` | 6000-510000 | 96000 | Bitrate in bps |
| `complexity` | 0-10 | 5 | CPU usage vs quality |
| `frame_size` | 2.5-60 | 20 | Frame size in ms |
| `max_ptime` | 3-120 | 20 | Max packet time in ms |

### Pipeline Buffering

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| `buffer_time` | 1000-500000 | 20000 | Max buffer size (μs) |
| `latency_time` | 5000-200000 | 10000 | Target latency (μs) |

### Latency Budget

For optimal settings (bitrate=96000, complexity=5):

| Stage | Latency |
|-------|---------|
| PipeWire capture | 5-10ms |
| Buffering | 10ms |
| Opus encoding | 5-7ms |
| Network | 10-25ms |
| MoQ processing | 5-10ms |
| WebCodecs decoding | 2-5ms |
| **Total** | **37-57ms** |

## Monitoring

### Logs

Enable verbose logging for diagnostics:

```bash
pipe2moq --verbose
```

Logs include:
- Audio source discovery
- Frame publishing rate
- GStreamer warnings/errors
- MoQ connection status

### Finding Your Audio Sink

```bash
# List all sinks
pactl list short sinks

# Get default sink
pactl get-default-sink
```

## Development

### Running Tests

```bash
cargo test
```

### Checking Audio Capture

Before running pipe2moq, verify audio capture works:

```bash
SINK=$(pactl get-default-sink)
gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=96000 \
  ! fakesink
```

## Troubleshooting

### No Audio Published

1. Check PipeWire is running: `pactl info`
2. Verify default sink: `pactl get-default-sink`
3. Test audio capture manually (see above)
4. Enable verbose logging: `--verbose`

### High Latency

1. Reduce `buffer_time` and `latency_time`
2. Lower Opus `complexity`
3. Reduce `frame_size` to 10ms
4. Check network RTT with relay

### CPU Usage Too High

1. Increase Opus `complexity` (paradoxically uses less CPU)
2. Reduce `sample_rate` to 24000 for voice
3. Reduce `channels` to 1 (mono)

### Connection Errors

1. Verify relay URL is correct
2. Check relay is running: `moq-relay`
3. Test TLS certificate (use `anon` path for development)

## License

MIT or Apache-2.0

## See Also

- [MoQ Specification](https://moq.dev)
- [GStreamer](https://gstreamer.freedesktop.org/)
- [PipeWire](https://pipewire.org/)
- [Opus Codec](https://opus-codec.org/)
