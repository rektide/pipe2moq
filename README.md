# Pipe2MoQ: Low-Latency Audio over QUIC

Research and implementation guide for creating a very low latency audio streaming service that monitors the default PipeWire sink, compresses audio in Opus, and publishes it as a MoQ track for web browser consumption.

## Overview

Media over QUIC (MoQ) is a next-generation live media protocol that provides **real-time latency** at **massive scale**. Unlike WebRTC, MoQ decouples the transport layer from application logic, enabling CDN-style distribution without business logic constraints.

### Key Features

- 🚀 **Real-time latency**: WebRTC-like latency without the constraints of WebRTC
- 📈 **Massive scale**: Designed for fan-out and supports cross-region clustering
- 🌐 **Modern Web**: Uses WebTransport, WebCodecs, and WebAudio APIs
- 🔧 **Generic transport**: Relays don't need to know about codecs or encryption
- 🎬 **Media layer**: `hang` protocol for codec-specific encoding

## Protocol Stack

MoQ is designed as a layered protocol stack:

```
┌─────────────────┐
│   Application   │   🏢 Your business logic (authentication, non-media tracks)
├─────────────────┤
│      hang       │   🎬 Media-specific encoding (codecs, containers, catalog)
├─────────────────┤
│    moq-lite     │  🚌 Generic pub/sub transport (broadcasts, tracks, groups, frames)
├─────────────────┤
│  WebTransport   │  🌐 Browser-compatible QUIC (HTTP/3 handshake, multiplexing)
│      QUIC       │
└─────────────────┘
```

### Core Concepts

**moq-lite** (Transport Layer)
- **Session**: QUIC connection between client and server
- **Broadcast**: Collection of tracks from a single publisher (path-based, e.g., `/room/alice.hang`)
- **Track**: Series of groups, deliverable out-of-order (e.g., "audio", "video")
- **Group**: Ordered series of frames, must arrive in-order
- **Frame**: Byte payload representing a single moment in time

**hang** (Media Layer)
- **Catalog**: JSON document describing available tracks with WebCodecs-compatible config
- **Container**: Tiny header with timestamp (microseconds) before each media payload
- **Discovery**: ANNOUNCE/ANNOUNCE_PLEASE for dynamic broadcast discovery

## Project Components

### 1. moq-relay

The relay server performs fan-out, connecting multiple clients and servers. It operates on rules encoded in moq-lite header and is completely agnostic to media codecs, containers, or encryption keys.

**Location**: [moq-dev/moq](https://github.com/moq-dev/moq)

**Key features:**
- Clusterable CDN-like distribution
- Zero business logic - pure pub/sub routing
- Supports ANNOUNCE for dynamic broadcast discovery
- Supports SUBSCRIBE for track consumption
- JWT-based authentication via moq-token

### 2. moq-lite (Rust/TypeScript)

Core pub/sub transport protocol with built-in concurrency and deduplication.

**Available libraries:**
- **Rust**: `moq-lite` crate - native server-side implementation
- **TypeScript**: `@moq/lite` - browser/Node.js implementation using WebTransport

**Documentation**: [docs.rs/moq-lite](https://docs.rs/moq-lite)

### 3. hang (Rust/TypeScript)

Media-specific library built on top of moq-lite, providing:
- **Catalog**: JSON manifest of available tracks with WebCodecs-compatible config
- **Container format**: Timestamped media payloads
- **Codec integration**: H.264, Opus, etc.

**Available libraries:**
- **Rust**: `hang` crate + `hang-cli` tool
- **TypeScript**: `@moq/hang` package with Web Components

**Documentation**: [docs.rs/hang](https://docs.rs/hang)

**Specification**: [draft-lcurley-moq-hang](https://www.ietf.org/archive/id/draft-lcurley-moq-hang-00.html)

### 4. GStreamer Plugin (gstreamer)

A GStreamer plugin for MoQ that enables publishing and consuming media streams. This is the key component for audio capture and encoding on Linux.

**Location**: [moq-dev/gstreamer](https://github.com/moq-dev/gstreamer)

**Features:**
- **Publish**: Encode and stream to MoQ relay
- **Subscribe**: Receive and decode from MoQ relay
- **Built-in codec support**: Leverages GStreamer's extensive codec ecosystem

**Quick Start:**
```bash
git clone https://github.com/moq-dev/gstreamer.git
cd gstreamer
just setup
just relay  # Terminal 1: Start relay
just pub-gst bbb  # Terminal 2: Publish video
just sub bbb  # Terminal 3: Subscribe to video
```

## Audio Streaming Architecture

### System Design

```
┌──────────────┐
│  PipeWire    │  Default audio sink (system audio)
│   (Linux)    │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  GStreamer   │  Monitor sink → Opus encoder
│   pipeline   │
└──────┬───────┘
       │
       ▼ (MoQ publish via hang-gst)
┌──────────────┐
│ moq-relay    │  Fan-out to subscribers
│   server      │
└──────┬───────┘
       │
       ├─────▶ [Subscriber 1]
       ├─────▶ [Subscriber 2]
       └─────▶ [Subscriber N]
                (Web browsers via WebTransport)
```

### Pipeline Components

**1. Audio Capture (GStreamer)**
```bash
pulsesrc device=YOUR_SINK.monitor
# OR
pipewiresrc path=YOUR_SINK_MONITOR
```
- Captures audio from PipeWire default sink (system audio)
- Use `pulsesrc` for PulseAudio compatibility or `pipewiresrc` for native PipeWire
- Monitor devices are named `[device_name].monitor`

**2. Opus Encoding (GStreamer)**
```bash
! audio/x-raw,rate=48000,channels=2 !
audioconvert ! audioresample !
opusenc bitrate=128000 application=audio
```
- **Opus codec**: Optimized for low-latency speech and music
- **Sample rate**: 48 kHz (standard for VoIP)
- **Channels**: Stereo (2) or Mono (1) depending on requirements
- **Bitrate**: 64-128 kbps typical for voice, higher for music
- **Application type**: `audio` for music, `voip` for speech

**3. MoQ Publish (gstreamer)**
```bash
! moqpublish name=publish \
  relay-url="https://your-relay.example.com" \
  broadcast-path="/live/audio.hang" \
  track-name="audio"
```
- Encodes audio using hang container format
- Publishes to moq-relay server
- Creates audio track in hang catalog
- Generates catalog.json automatically

**4. Browser Playback (WebCodecs + WebAudio)**
```javascript
import { HangTransport } from "@moq/hang";

// Connect to relay
const transport = new HangTransport("https://your-relay.example.com");

// Discover broadcasts
const broadcasts = await transport.discover("/live/");

// Subscribe to audio track
const track = await transport.subscribe({
  broadcast: "/live/audio.hang",
  track: "audio",
  priority: 1
});

// Decode with WebCodecs
const decoder = new AudioDecoder({
  output: (frame) => {
    // Play frame via WebAudio
    const source = audioContext.createBufferSource();
    source.buffer = audioContext.createBuffer(
      frame.numberOfChannels,
      frame.numberOfFrames,
      frame.sampleRate
    );
    source.connect(audioContext.destination);
    source.start();
  },
  error: (e) => console.error("Decode error:", e)
});

decoder.configure({
  codec: "opus",
  sampleRate: 48000,
  numberOfChannels: 2
});

// Process incoming frames
track.on("frame", (frame) => decoder.decode(frame));
```

## Implementation Requirements

### System Dependencies

**Server (Linux)**
- [Rust](https://www.rust-lang.org/tools/install) (for moq-relay)
- [GStreamer](https://gstreamer.freedesktop.org/) (for audio capture/encoding)
- [PipeWire](https://pipewire.org/) (audio subsystem)
- GStreamer plugins:
  - `gst-plugins-base` (audioconvert, audioresample)
  - `gst-plugins-good` (pulsesrc, pipewiresrc, opusenc)
  - `gstreamer` (from moq-dev/gstreamer repo)
- [Just](https://github.com/casey/just) (command runner)

**Browser (Client)**
- Modern browser with WebTransport support:
  - Chrome 111+ ✅
  - Firefox 117+ ✅
  - Edge 111+ ✅
  - Safari: Limited support ⚠️
- JavaScript/TypeScript application using `@moq/hang`

### Network Requirements

- **QUIC/UDP**: Port 443 (or custom port for WebTransport)
- **TLS certificate**: Required for production (Let's Encrypt or similar)
- **Network**: Low-latency path recommended for sub-100ms end-to-end

## Deployment Guide

### Option 1: Development (Local)

**Setup moq repository:**
```bash
# Clone moq repository
git clone https://github.com/moq-dev/moq.git
cd moq

# Install dependencies
just install

# Run relay
just relay

# Run demo (in separate terminals)
# Terminal 1: relay (already running)
# Terminal 2:
just pub bbb http://localhost:4443/anon
# Terminal 3:
just web http://localhost:4443/anon
```

### Option 2: Custom GStreamer Pipeline

**Find your PipeWire sink:**
```bash
# List sinks
pactl list short sinks

# Example output:
# 43	alsa_output.pci-0000_00_1b.0.analog-stereo	...
```

**Monitor and encode:**
```bash
# Capture from sink monitor and encode to Opus
gst-launch-1.0 \
  pulsesrc device="alsa_output.pci-0000_00_1b.0.analog-stereo.monitor" \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=128000 application=audio \
  ! moqpublish name=publish \
    relay-url="https://your-relay.example.com" \
    broadcast-path="/live/audio.hang" \
    track-name="audio"
```

### Option 3: Build and Install GStreamer Plugin

```bash
# Clone gstreamer repository
git clone https://github.com/moq-dev/gstreamer.git
cd gstreamer

# Setup dependencies
just setup

# Build plugin
cargo build --release

# Install (optional, for system-wide use)
# Copy to GStreamer plugins directory
sudo cp target/release/libgstmoq*.so \
  $(gst-plugin-scanner-1.0 --print-plugin-path 2>/dev/null)
```

## Technical Specifications

### Hang Catalog (Audio Track)

```json
{
  "audio": {
    "renditions": {
      "stereo": {
        "codec": "opus",
        "sampleRate": 48000,
        "numberOfChannels": 2,
        "bitrate": 128000
      }
    },
    "priority": 1
  }
}
```

The gstreamer plugin automatically generates this catalog and publishes it as `catalog.json` track.

### Container Format

Each frame in a moq-lite group:

```
┌─────────────────────────────────┐
│ Timestamp (VarInt, 62-bit max) │ Microseconds
├─────────────────────────────────┤
│ Codec-specific payload           │ Opus encoded data
└─────────────────────────────────┘
```

- **Group**: Starts with keyframe (Opus doesn't use delta frames, so all frames are keyframes)
- **Timestamp**: Monotonically increasing within group
- **Payload**: Raw Opus packets (no additional container)

### Opus Encoding Parameters

For low-latency audio streaming:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `bitrate` | 64000-128000 | 64kbps for voice, 128kbps for music |
| `application` | `audio` or `voip` | `audio` for music, `voip` for speech optimization |
| `complexity` | 0-10 | Lower complexity for faster encoding (0=fastest) |
| `frame-size` | 20-60 | Frame size in ms (20ms for lowest latency) |
| `max-ptime` | 20 | Maximum packet time (lower = lower latency) |

### Latency Targets

| Stage | Target Latency | Notes |
|-------|----------------|-------|
| Capture (PipeWire → GStreamer) | < 10ms | PipeWire is designed for low latency |
| Opus Encoding | 5-20ms | Depends on complexity setting |
| MoQ Publish/Network | 10-50ms | Depends on RTT |
| WebCodecs Decoding | < 10ms | Browser implementation |
| **Total End-to-End** | **< 100ms** | Achievable with proper tuning |

## GStreamer Elements Reference

### moqpublish

**Properties:**
- `relay-url` (string): URL of moq-relay server
- `broadcast-path` (string): Broadcast namespace (e.g., `/live/audio.hang`)
- `track-name` (string): Track name within broadcast (e.g., `audio`)
- `priority` (uint): Subscription priority hint (default: 1)

**Caps:**
- **Sink**: Accepts encoded audio buffers (e.g., `audio/x-opus`)
- **Source**: None (sink element)

**Example Pipeline:**
```bash
gst-launch-1.0 \
  pulsesrc device=SINK.monitor \
  ! audio/x-raw,rate=48000,channels=2 \
  ! opusenc bitrate=128000 application=audio complexity=5 \
  ! moqpublish name=publish \
    relay-url="https://localhost:4443/anon" \
    broadcast-path="/live/audio.hang" \
    track-name="audio"
```

### PipeWire Audio Capture

**Finding Monitor Devices:**
```bash
# List all sources (includes monitors)
pactl list short sources

# Look for entries with ".monitor" suffix
# Example:
# 44	alsa_output.pci-0000_00_1b.0.analog-stereo.monitor
```

**Using pulsesrc (PulseAudio compatibility):**
```bash
pulsesrc device="alsa_output.pci-0000_00_1b.0.analog-stereo.monitor"
```

**Using pipewiresrc (native PipeWire):**
```bash
pipewiresrc path="alsa_output.pci-0000_00_1b.0.analog-stereo" \
  target-object=audio
```

## Security Considerations

### Authentication

**Server-side:**
- Use `moq-token` for JWT-based session authentication
- TLS certificate required for WebTransport in browsers
- Validate broadcast paths to prevent unauthorized publishing

**Example token generation:**
```bash
# Generate secret key
cargo run --bin moq-token -- --key "root.jwk" generate

# Sign token
cargo run --bin moq-token -- --key "root.jwk" sign \
  --root "demo" \
  --publish "audio" \
  --subscribe "" \
  > demo.jwt
```

**Client-side:**
- Verify relay TLS certificate
- Use ANNOUNCE to discover available broadcasts (don't hardcode paths)
- Validate catalog before subscribing

### Network Security

- **QUIC encryption**: All traffic is encrypted at transport layer
- **E2EE**: MoQ supports end-to-end encryption (relays can't decrypt)
- **Rate limiting**: Relay should limit subscription rates per client

## Troubleshooting

### Common Issues

**1. WebTransport connection fails**
- Ensure HTTPS and valid TLS certificate
- Check browser compatibility (WebTransport required)
- Verify port 443 is open
- For development, use `http://localhost:4443/anon` to bypass certificate validation

**2. Audio capture not working**
- Verify PipeWire is running: `pactl info`
- Check default sink: `pactl get-default-sink`
- List available monitors: `pactl list short sources | grep monitor`
- Monitor sink name format: `[device_name].monitor`

**3. High latency**
- Check Opus encoder settings (lower complexity for faster encoding)
- Verify network RTT (use `ping`)
- Reduce frame size: `opusenc frame-size=20`
- Minimize GStreamer buffers: set `latency` property on elements

**4. Audio quality issues**
- Increase Opus bitrate (64-128 kbps for voice, higher for music)
- Check sample rate matching (ensure 48kHz throughout)
- Verify channel count (stereo vs mono)
- Check for buffer underruns in logs

**5. GStreamer plugin not found**
```bash
# Check if plugin is loaded
gst-inspect-1.0 moqpublish

# If not found, ensure plugin is in correct path
export GST_PLUGIN_PATH=/path/to/gstreamer/target/release
```

## Example Pipelines

### Basic Audio Streaming

```bash
# Capture from default sink, encode Opus, publish to MoQ
SINK=$(pactl get-default-sink)
gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=128000 application=audio \
  ! moqpublish name=publish \
    relay-url="https://relay.moq.dev/audio" \
    broadcast-path="/live/audio.hang" \
    track-name="stereo"
```

### Low Latency Audio Streaming

This configuration prioritizes minimal end-to-end latency (< 100ms total) suitable for voice communication and real-time applications.

```bash
# Ultra-low latency settings
gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=96000 application=voip complexity=2 \
      frame-size=20 max-ptime=20 \
  ! moqpublish name=publish \
    relay-url="https://localhost:4443/anon" \
    broadcast-path="/live/audio.hang" \
    track-name="voice"
```

#### Configuration Parameters Explained

**1. PulseAudio Source Buffers**
| Parameter | Value | Default | Effect |
|-----------|-------|---------|--------|
| `buffer-time` | 20000 (20ms) | 200000 (200ms) | Maximum amount of data buffered in device. Lower reduces buffer size at cost of potential underruns. |
| `latency-time` | 10000 (10ms) | 10000 (10ms) | Target latency for device. Lower forces faster delivery but may cause audio glitches if too aggressive. |

**2. Opus Encoder Settings**
| Parameter | Value | Default | Effect |
|-----------|-------|---------|--------|
| `bitrate` | 96000 (96 kbps) | 64000 (64 kbps) | Higher bitrate improves quality at cost of bandwidth. 96kbps is "sweet spot" for voice. |
| `application` | `voip` | `audio` | Voice over IP mode optimizes for speech processing with HF filtering and comfort noise. |
| `complexity` | 2 | 10 | Encoding complexity (0=fastest, 10=highest). Lower complexity = faster encoding, lower CPU, lower latency. |
| `frame-size` | 20 (20ms) | 20 (20ms) | Maximum frame duration. Smaller = lower latency but lower efficiency at fixed bitrate. |
| `max-ptime` | 20 (20ms) | Not set | Maximum packet time. Limits size of Opus packets to ensure timely delivery. |

#### Tuning Guidance

**For Ultra-Low Latency (< 50ms total):**
```bash
# Push to absolute limits - monitor for artifacts
pulsesrc device="${SINK}.monitor" buffer-time=10000 latency-time=5000 \
! audio/x-raw,rate=48000,channels=2 \
! audioconvert ! audioresample \
! opusenc bitrate=64000 application=voip complexity=0 \
      frame-size=10 max-ptime=10
```
- **Trade-offs**: Minimal CPU usage but potential audio quality loss
- **Use case**: Two-way voice communication where every millisecond counts
- **Monitor**: Watch for buffer underruns and audio glitches

**For Balanced Latency (50-100ms total) - Recommended:**
```bash
# Good balance of quality and latency
pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
! audio/x-raw,rate=48000,channels=2 \
! audioconvert ! audioresample \
! opusenc bitrate=96000 application=voip complexity=5 \
      frame-size=20 max-ptime=20
```
- **Trade-offs**: Acceptable latency with good voice quality
- **Use case**: Most VoIP applications, gaming, interactive use
- **Baseline complexity (5)**: Moderate CPU load, good quality

**For Voice with Background Noise:**
```bash
# Add inband FEC for packet loss tolerance
pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
! audio/x-raw,rate=48000,channels=2 \
! audioconvert ! audioresample \
! opusenc bitrate=96000 application=voip complexity=5 \
      frame-size=20 max-ptime=20 \
      inband-fec=true \
      packet-loss-pct=10
```
- **Inband FEC**: Adds redundant data to recover from packet loss without retransmission
- **Trade-offs**: Higher bandwidth (~20% more), more CPU, but better resilience
- **Use case**: Unstable networks, mobile connections

#### Latency Budget Breakdown

Based on low-latency configuration above:

| Stage | Latency | Notes |
|-------|---------|-------|
| PipeWire capture | 5-10ms | Hardware-level latency, minimal |
| Buffer accumulation | 10ms | `buffer-time` + `latency-time` |
| Opus encoding | 2-5ms | `complexity=2`, very fast |
| Network (RTT/2) | 10-25ms | Depends on network conditions |
| MoQ processing | 5-10ms | Relay fan-out and queueing |
| WebCodecs decoding | 2-5ms | Browser implementation |
| **Total** | **34-55ms** | Achievable with local network |
#### Parameter Interactions and Trade-offs

#### Opus Encoding Performance Benchmarks

Based on [libopus 1.1 benchmarks](https://people.xiph.org/~xiphmont/demo/opus/demo3.shtml), encoding latency scales directly with complexity and system CPU performance:

**Complexity vs. Encoding Latency (Cortex i7 @ 2.9GHz):**
| Complexity | Encoding Time | Decoding Time | Notes |
|-----------|---------------|--------------|-------|
| 0 (fastest) | 2-3ms | 8-10ms | Minimal CPU, slight quality loss |
| 2 (low) | 3-5ms | 7-10ms | ~30% more CPU, good balance |
| 5 (medium) | 5-7ms | 6-10ms | ~50% more CPU, very good quality |
| 7 (high) | 8-12ms | 5-10ms | ~70% more CPU, excellent quality |
| 9 (highest) | 10-20ms | 4-8ms | ~90% more CPU, best quality |
| 10 (max) | 12-26ms | 3-7ms | ~110% more CPU, diminishing returns |

**System CPU Impact:**
- **Desktop (i7 @ 3.0GHz)**: Complexity 0-2 encodes in 2-5ms (real-time capable)
- **Desktop (i7 @ 2.0GHz)**: Complexity 7-9 encodes in 10-20ms (studio quality)
- **ARM Cortex-A9 @ 1.2GHz**: Complexity 5-7 encodes in 9-21ms (good balance)
- **ARM optimizations**: Libopus 1.1 includes NEON SIMD instructions providing ~22-40% speed boost

**Guidelines:**
- **Start at complexity 5** (5-7ms encoding) as baseline for most systems
- **Use complexity 2** (3-5ms) for low-latency applications where every millisecond counts
- **Decrease to complexity 0** (2-3ms) if experiencing high CPU load or need to conserve battery
- **Avoid complexity 8-10+** except for offline encoding where quality is critical
- **System considerations**: Multi-core systems can run encoders in parallel, or dedicate a core to audio processing

**Example tuning command:**
```bash
# For real-time voice (CPU-limited system)
gst-launch-1.0 pulsesrc device="${SINK}.monitor" ! \
  audio/x-raw,rate=48000,channels=2 \
! audioconvert ! audioresample ! \
opusenc bitrate=96000 application=voip complexity=5 \
  frame-size=20 max-ptime=20 ! \
moqpublish name=publish

# For high-quality music (powerful system)  
gst-launch-1.0 pulsesrc device="${SINK}.monitor" ! \
  audio/x-raw,rate=48000,channels=2 \
! audioconvert ! audioresample ! \
opusenc bitrate=256000 application=audio complexity=8 \
  frame-size=20 max-ptime=20 ! \
moqpublish name=publish
```

#### Further Reading and References

**Complexity vs. Quality:**
- Complexity 0-2: ~3-5ms encoding, minimal CPU, slight quality loss
- Complexity 5-7: ~5-10ms encoding, moderate CPU, good quality
- Complexity 8-10: ~10-20ms encoding, high CPU, best quality
- **Guideline**: Start at complexity=5, decrease if CPU-limited, increase if audio quality issues

**Frame Size vs. Bandwidth Efficiency:**
- 10ms frame-size: Lower latency (10ms saved) but 20-30% higher bitrate overhead
- 20ms frame-size: Balanced latency, efficient bandwidth
- 40ms frame-size: Higher latency (20ms more) but most efficient
- **Guideline**: Use 20ms as default, 10ms for ultra-low latency applications

**Bitrate vs. Network Conditions:**
- 64kbps: Minimum usable, artifacts on complex audio
- 96kbps: "Sweet spot" for voice, good quality
- 128kbps+: High quality, requires stable network
- **Guideline**: Use adaptive bitrate based on network conditions

**Application Mode:**
- `voip`: Optimized for speech, applies HF filtering (cuts frequencies > 8kHz), adds comfort noise
- `audio`: Full-range audio, no speech optimizations, better for music
- **Guideline**: Use `voip` for voice-only, `audio` for mixed content or music

#### Monitoring and Diagnostics

**Check for buffer underruns:**
```bash
# Run with GStreamer debug logging
GST_DEBUG=4 gst-launch-1.0 [pipeline] 2>&1 | grep -i buffer
```
- Look for: "buffering", "underrun", "latency" messages
- If frequent underruns: Increase `buffer-time` to 20000-40000

**Measure actual latency:**
```bash
# Use GStreamer's latency reporting
gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" \
  ... [pipeline] \
  ! identity silent=true \
  ! fakesink sync=false
```
- Add `latency=true` to elements to see reported latency
- Compare to target budget and adjust parameters

**CPU usage monitoring:**
```bash
# Monitor encoding CPU usage
top -p $(pgrep -f gst-launch)
```
- If consistently > 70%: Increase `complexity` to reduce CPU load
- If consistently < 30%: Can decrease `complexity` for better quality

#### Common Pitfalls

**1. Aggressive buffering causing audio artifacts:**
- **Symptom**: Choppy audio, frequent restarts
- **Cause**: `buffer-time` too low for network conditions
- **Fix**: Increase `buffer-time` in increments of 10000 (10ms)

**2. Network congestion causing quality loss:**
- **Symptom**: Audio degrades during bursts, no dropouts
- **Cause**: Bitrate too high for available bandwidth
- **Fix**: Reduce `bitrate` by 20-30%, or enable `vbr=true` (variable bitrate)

**3. CPU overload causing lag:**
- **Symptom**: System sluggish, audio delays > 100ms
- **Cause**: `complexity` too low for available CPU power
- **Fix**: Increase `complexity` to 5-7 for moderate systems, 8-10 for powerful systems

**4. Inconsistent packet timing:**
- **Symptom**: Jittery audio, occasional glitches
- **Cause**: `frame-size` and `max-ptime` mismatch or conflicting with network MTU
- **Fix**: Ensure `frame-size` equals `max-ptime`, consider network MTU (typically 1200-1400 bytes)

#### Further Reading and References

**GStreamer Latency Tuning:**
- [GStreamer Latency Design Documentation](https://gstreamer.freedesktop.org/documentation/additional/design/latency.html) - Official GStreamer guide on latency concepts and buffer management
- [Optimize GStreamer Pipeline for Low Latency](https://www.linkedin.com/posts/ravipatelli_5-reasons-your-gstreamer-pipeline-is-lagging-activity-736101111589760240-GpRb) - Practical guide on reducing pipeline latency from 600ms to <50ms
- [Low Latency Audio Capture with GStreamer](https://stackoverflow.com/questions/42023770/low-latency-audio-capture-with-gstreamer) - Community discussion on achieving ~10ms latency
- [Tips for Minimizing Latency in Video Streaming Over WiFi](https://discourse.gstreamer.org/t/tips-for-minimizing-latency-in-video-streaming-over-wifi/2234) - Network considerations for low latency

**Opus Codec Optimization:**
- [Opus Recommended Settings](https://wiki.xiph.org/Opus_Recommended_Settings) - Official Xiph recommendations for bitrate, frame size, and complexity
- [Opus Codec Homepage](https://opus-codec.org/) - Official documentation, encoder tools, and performance benchmarks
- [Opus RFC 6716](https://datatracker.ietf.org/doc/html/rfc6716) - Full specification including complexity settings and modes
- [Opus Low-Latency API Manual](https://www.oreilly.com/blog/opus-low-latency-audio-codec-api-manual-english-translation/1c4a5aee91f0ea07c6b275329cc0bff) - Detailed guide on low-latency API usage
- [A Guide for Choosing a Right Codec](https://www.audiokinetic.com/en/blog/a-guide-for-choosing-the-right-codec) - Comparative analysis of audio codecs for different use cases
- [libopus 1.1 Performance Demo](https://people.xiph.org/~xiphmont/demo/opus/demo3.shtml) - Actual encoding/decoding benchmarks showing complexity vs. latency

**PulseAudio/PipeWire Configuration:**
- [PulseAudio Latency Control](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developers/Clients/LatencyControl) - Guide on configuring timer-based scheduling (`tsched`) and buffer sizes
- [Low-latency oss! on Linux](https://blog.theoon.fr/osuLinuxAudioLatency/) - Practical tuning for minimal audio latency
- [PipeWire ArchWiki](https://wiki.archlinux.org/title/PipeWire) - PipeWire configuration for low-latency audio/video capture
- [Pipewire, Jack Applications & Low-Latency Tuning](https://linuxmusicians.com/viewtopic.php?t=25556) - Community discussion on low-latency audio setups

**WebRTC and Network Considerations:**
- [How WebRTC's NetEQ Jitter Buffer Provides Smooth](https://webrtchacks.com/how-webrtcs-neteq-jitter-buffer-provides-smooth-audio) - Understanding jitter buffer behavior (30-100ms typical)
- [WebRTC Jitter Buffer Documentation](https://www.fanyamin.com/webrtc/tutorial/build/html/3.media/audio_jitter_buffer.html) - Guide on configuring jitter buffers for network jitter
- [Understanding WebRTC Latency: Causes, Solutions](https://www.videosdk.live/developer-hub/webrtc/webrtc-latency) - Comprehensive analysis of latency sources and mitigation strategies
- [Rust NetEQ - Adaptive Jitter Buffer](https://crates.io/crates/neteq) - Modern adaptive jitter buffer implementation for professional audio

**Audio Engineering Resources:**
- [Audio Stream Input Guide - MK.io](https://docs.mk.io/docs/set-up-the-source-stream-using-gstreamer) - Comprehensive GStreamer setup guide
- [Opus Encoding Performance Paper](https://www.researchgate.net/publication/286609722_High-Quality_Low-Delay_Music_Coding_in_the_Opus_Codec) - Academic analysis of Opus quality-latency trade-offs
- [GStreamer and PipeWire Discussion](https://discourse.gstreamer.org/t/gstreamer-and-pipewire/3586) - Integration guidance for PipeWire audio sources

### Testing and Measuring Latency

#### GStreamer Element Properties for Latency

**pulsesrc Properties (Source):**
- `actual-buffer-time`: Reported size of audio buffer in microseconds (default: -1)
- `actual-latency-time`: Actual latency in microseconds (default: -1)
- `buffer-time`: Maximum buffer size in microseconds (default: 200000/200ms)
- `latency-time`: Minimum latency to achieve in microseconds (default: 10000/10ms)

**Note**: `opusenc` does not expose direct latency properties. Use these methods to measure overall pipeline latency:

#### Method 1: Real-time Latency Reporting

```bash
# Use fakesink with sync=true to capture reported latency
gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=96000 application=voip complexity=5 \
      frame-size=20 max-ptime=20 \
  ! identity silent=false name=identity \
  ! fakesink sync=true 2>&1 | grep latency
```

**Output**: Shows actual latency from elements that support it (e.g., pulsesrc)

#### Method 2: Timestamp Comparison

```bash
# Enable timestamp tracking to compare capture vs. output
gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" do-timestamp=true \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=96000 application=voip complexity=5 \
      frame-size=20 max-ptime=20 \
  ! identity silent=false name=identity \
  ! fakesink sync=false 2>&1 | grep -E "(PTS|DTS)"
```

**Purpose**: Measures presentation timestamp (PTS) and decoder timestamp (DTS) to calculate pipeline delay

#### Method 3: Using gst-stats

```bash
# Statistical analysis of pipeline performance
gst-stats-1.0 \
  --output=stdout \
  --tracer="latency.*" \
  [pipeline] 2>&1
```

**Available Tracers**: `latency(n)`, `latency(*)`, `buffering(*)`
**Usage**: Collects samples to identify latency outliers and average values

#### Method 4: Simple Latency Test Script

```bash
# Create and run test script
cat > /tmp/gst_latency_test.sh << 'EOF'
#!/usr/bin/env bash
SINK=$(pactl get-default-sink 2>/dev/null)
echo "Testing with sink: $SINK"

echo "Test 1: Measure reported latency"
gst-launch-1.0 pulsesrc device="\${SINK}.monitor" \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert ! audioresample \
  ! opusenc bitrate=96000 application=voip complexity=5 \
      frame-size=20 max-ptime=20 \
  ! identity silent=false \
  ! fakesink sync=true 2>&1 | grep latency || echo "No latency data"

echo "Test 2: Compare buffer configurations"
# Test with different buffer settings
for bt in "20000 10000 5000"; do
  echo "Testing buffer-time=$bt ($((bt/1000))ms"
  timeout 5 gst-launch-1.0 pulsesrc device="\${SINK}.monitor" \
    buffer-time=$bt latency-time=$((bt/2)) \
    ! audio/x-raw,rate=48000,channels=2 \
    ! audioconvert ! audioresample \
    ! opusenc bitrate=96000 application=voip complexity=5 \
      frame-size=20 max-ptime=20 \
    ! identity ! fakesink sync=false 2>&1 | grep -c buffer && break
done
EOF

chmod +x /tmp/gst_latency_test.sh
/tmp/gst_latency_test.sh
```

**What to Measure:**
- **Capture latency**: `actual-latency-time` from pulsesrc (typically 5-10ms)
- **Buffering latency**: Difference between `buffer-time` setting and actual buffer usage
- **Encoding time**: Derived from complexity benchmarks (5-7ms for complexity 5)
- **Jitter**: Variation in buffer availability
- **Total pipeline latency**: Capture + buffering + encoding + sink processing

#### Method 5: End-to-End Measurement

```bash
# Measure actual audio latency from capture to playback
# Terminal 1: Play reference sound
aplay /dev/urandom &

# Terminal 2: Measure pipeline latency
# Combine with timing markers in your pipeline
gst-launch-1.0 pulsesrc device="${SINK}.monitor" \
  ! identity signal-handoff=false \
  ! fakesink dump-buffers=true 2>&1 | grep buffer

# Manual method: Play sound through speaker, record with microphone, measure time difference
```

#### Interpreting Results

| Metric | Target | Acceptable | Needs Action |
|--------|--------|------------|--------------|
| pulsesrc latency | < 10ms | 10-30ms | Adjust PipeWire/PulseAudio configuration |
| Total pipeline latency | < 50ms | 50-100ms | Reduce buffer sizes, lower complexity |
| Jitter buffer | < 20ms | 20-50ms | Check network stability |
| Opus frame rate | ~50 fps | 40-50 fps | Adjust frame-size |

### High Quality Audio Streaming

```bash
# High bitrate for music
gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample quality=10 \
  ! opusenc bitrate=256000 application=audio complexity=10 \
      vbr=true \
  ! moqpublish name=publish \
    relay-url="https://your-relay.example.com" \
    broadcast-path="/live/audio.hang" \
    track-name="hifi"
```

## Next Steps

1. **Set up development environment**
   ```bash
   # Install GStreamer and plugins
   sudo apt install gstreamer1.0-plugins-base \
     gstreamer1.0-plugins-good gstreamer1.0-tools

   # Install Rust
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

   # Install Just
   cargo install just

   # Clone repositories
   git clone https://github.com/moq-dev/moq.git
   git clone https://github.com/moq-dev/gstreamer.git
   ```

2. **Build and run relay**
   ```bash
   cd moq
   just relay
   ```

3. **Build GStreamer plugin**
   ```bash
   cd ../gstreamer
   cargo build --release
   ```

4. **Test audio capture**
   ```bash
   # List PipeWire sinks
   pactl list short sinks

   # Test capture to file
   gst-launch-1.0 pulsesrc device=YOUR_SINK.monitor ! \
     audioconvert ! audioresample ! \
     opusenc bitrate=128000 ! \
     filesink location=test.opus
   ```

5. **Publish to MoQ**
   ```bash
   # Capture and publish
   SINK=$(pactl get-default-sink)
   gst-launch-1.0 pulsesrc device="${SINK}.monitor" ! \
     audio/x-raw,rate=48000,channels=2 \
     ! audioconvert ! audioresample ! \
     opusenc bitrate=128000 ! \
     moqpublish name=publish \
       relay-url="https://localhost:4443/anon" \
       broadcast-path="/live/audio.hang" \
       track-name="audio"
   ```

## Resources

- **MoQ Website**: https://moq.dev
- **moq-lite Specification**: https://moq-dev.github.io/drafts/draft-lcurley-moq-lite.html
- **hang Specification**: https://moq-dev.github.io/drafts/draft-lcurley-moq-hang.html
- **WebTransport MDN**: https://developer.mozilla.org/en-US/docs/Web/API/WebTransport_API
- **WebCodecs MDN**: https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API
- **Opus Codec**: https://opus-codec.org/
- **PipeWire**: https://pipewire.org/
- **GStreamer Documentation**: https://gstreamer.freedesktop.org/documentation/
- **Discord Community**: https://discord.gg/FCYF3p99mr

## License

Based on MoQ project which is licensed under either:
- Apache License, Version 2.0
- MIT license

See individual repositories for specific licensing details:
- [moq](https://github.com/moq-dev/moq): Apache-2.0, MIT
- [gstreamer](https://github.com/moq-dev/gstreamer): Apache-2.0, MIT
