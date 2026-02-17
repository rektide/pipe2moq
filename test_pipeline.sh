#!/usr/bin/env bash
# Quick test script for Pipe2MoQ pipeline
# Tests audio capture, Opus encoding, and MoQ publishing

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "===================================="
echo "  Pipe2MoQ Test Script"
echo "===================================="
echo ""

# Check dependencies
echo -n "${YELLOW}Checking dependencies...${NC}"

if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
    echo -e " ${RED}✗${NC} gst-launch-1.0 not found"
    echo "  Install: sudo apt install gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good"
    exit 1
else
    echo -e " ${GREEN}✓${NC} gst-launch-1.0"
fi

if ! command -v pulsesrc >/dev/null 2>&1; then
    echo -e " ${RED}✗${NC} pulsesrc not found"
    exit 1
else
    echo -e " ${GREEN}✓${NC} pulsesrc"
fi

if ! command -v opusenc >/dev/null 2>&1; then
    echo -e " ${RED}✗${NC} opusenc not found"
    exit 1
else
    echo -e " ${GREEN}✓${NC} opusenc"
fi

if ! command -v moqpublish >/dev/null 2>&1; then
    echo -e " ${YELLOW}⚠${NC} moqpublish not found (GStreamer plugin may not be installed)"
    echo "  Build and install from: https://github.com/moq-dev/gstreamer"
    echo "  Or run: cargo install --path . moq-relay"
fi

echo ""

# Get default sink
SINK=$(pactl get-default-sink 2>/dev/null)
if [ -z "$SINK" ]; then
    echo -e " ${RED}Error: Could not determine default sink${NC}"
    exit 1
fi

echo -e "${GREEN}Default sink: $SINK${NC}"
echo ""

# Configuration
RELAY_URL="${RELAY_URL:-http://localhost:4443/anon}"
BROADCAST_PATH="${BROADCAST_PATH:-/test/audio}"
TRACK_NAME="${TRACK_NAME:-audio}"

echo "Configuration:"
echo "  Relay URL:      $RELAY_URL"
echo "  Broadcast path:   $BROADCAST_PATH"
echo "  Track name:      $TRACK_NAME"
echo ""

# Select test mode
case "${1:-help}" in
    capture)
        echo "=== Test 1: Audio Capture Only ==="
        echo "Testing audio capture from sink monitor..."
        timeout 5 gst-launch-1.0 \
            pulsesrc device="${SINK}.monitor" \
            ! audio/x-raw,rate=48000,channels=2 \
            ! audioconvert \
            ! audioresample \
            ! fakesink sync=true 2>&1 | grep -E "(latency|buffer)" || true
        echo "✓ Capture test complete"
        ;;

    encode)
        echo "=== Test 2: Opus Encoding ==="
        echo "Testing Opus encoder with complexity=5..."
        timeout 10 gst-launch-1.0 \
            pulsesrc device="${SINK}.monitor" \
            ! audio/x-raw,rate=48000,channels=2 \
            ! audioconvert \
            ! audioresample \
            ! opusenc bitrate=96000 application=voip complexity=5 \
                frame-size=20 max-ptime=20 \
            ! identity silent=false \
            ! filesink location=/tmp/test_opus.opus 2>&1 || true
        if [ -f /tmp/test_opus.opus ]; then
            SIZE=$(ls -lh /tmp/test_opus.opus | awk '{print $5}')
            DURATION=$(ffprobe -v error -hide_banner /tmp/test_opus.opus 2>&1 | grep Duration | sed 's/.*Duration: \([0-9:]*\),.*/\1/')
            echo "✓ Encoded: $SIZE, $DURATION"
        else
            echo "✗ Encoding failed"
        fi
        ;;

    latency)
        echo "=== Test 3: Latency Measurement ==="
        echo "Measuring reported latency from pipeline..."
        timeout 10 gst-launch-1.0 \
            pulsesrc device="${SINK}.monitor" \
            ! audio/x-raw,rate=48000,channels=2 \
            ! audioconvert \
            ! audioresample \
            ! opusenc bitrate=96000 application=voip complexity=5 \
                frame-size=20 max-ptime=20 \
            ! identity silent=false name=identity \
            ! fakesink sync=true 2>&1 | \
            sed -n -e 's/.*latency=\([0-9]*\)s*\).*/Latency: \1 ms/p' || echo "No latency data"
        echo "✓ Latency test complete"
        ;;

    publish)
        if ! command -v moqpublish >/dev/null 2>&1; then
            echo -e "${RED}Error: moqpublish not installed${NC}"
            echo "Please install GStreamer MoQ plugin first"
            exit 1
        fi

        echo "=== Test 4: MoQ Publishing ==="
        echo "Publishing audio stream to MoQ relay..."
        echo "Press Ctrl+C to stop"
        echo ""

        # Run the pipeline
        gst-launch-1.0 \
            pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
            ! audio/x-raw,rate=48000,channels=2 \
            ! audioconvert \
            ! audioresample \
            ! opusenc bitrate=96000 application=voip complexity=5 \
                frame-size=20 max-ptime=20 \
            ! moqpublish name=publish \
                relay-url="$RELAY_URL" \
                broadcast-path="$BROADCAST_PATH" \
                track-name="$TRACK_NAME"
        ;;

    full)
        echo "=== Running Full Pipeline Test ==="
        echo "This tests the complete end-to-end pipeline"
        echo ""
        echo "Prerequisites:"
        echo "  1. moq-relay server running on $RELAY_URL"
        echo "  2. moqpublish GStreamer plugin installed"
        echo ""
        read -p "Press Enter when ready to start publishing..." -r

        gst-launch-1.0 \
            pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
            ! audio/x-raw,rate=48000,channels=2 \
            ! audioconvert \
            ! audioresample \
            ! opusenc bitrate=96000 application=voip complexity=5 \
                frame-size=20 max-ptime=20 \
            ! moqpublish name=publish \
                relay-url="$RELAY_URL" \
                broadcast-path="$BROADCAST_PATH" \
                track-name="$TRACK_NAME"
        ;;

    *)
        echo "Usage: $0 [mode]"
        echo ""
        echo "Modes:"
        echo "  capture    - Test audio capture from PipeWire sink"
        echo "  encode     - Test Opus encoding (creates test file)"
        echo "  latency    - Measure and display pipeline latency"
        echo "  publish    - Publish to MoQ relay (requires moqpublish plugin)"
        echo "  full       - Run complete end-to-end pipeline test"
        echo ""
        echo "Environment variables:"
        echo "  RELAY_URL      - MoQ relay URL (default: http://localhost:4443/anon)"
        echo "  BROADCAST_PATH  - Broadcast namespace (default: /test/audio)"
        echo "  TRACK_NAME      - Track name (default: audio)"
        echo ""
        echo "Examples:"
        echo "  $0 full RELAY_URL=https://your-relay.example.com"
        echo "  $0 publish RELAY_URL=http://localhost:4443/anon TRACK_NAME=voice"
        ;;
esac
