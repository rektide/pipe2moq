#!/usr/bin/env bash
# End-to-end latency measurement script
# Captures audio from sink, encodes via Opus, decodes, and measures delay

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "================================"
echo "  End-to-End Latency Measurement"
echo "================================"
echo ""

# Check dependencies
if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
    echo -e "${RED}✗ gst-launch-1.0 not found${NC}"
    echo "Install: sudo apt install gstreamer1.0-tools"
    exit 1
fi

if ! command -v aplay >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Warning: aplay not found${NC}"
    echo "Install: sudo apt install alsa-utils"
    echo "Latency measurement will skip playback test"
fi

# Get default sink
SINK=$(pactl get-default-sink 2>/dev/null)
if [ -z "$SINK" ]; then
    echo -e "${RED}Error: Could not determine default sink${NC}"
    exit 1
fi

echo -e "${GREEN}Using sink: $SINK${NC}"
echo ""

# Configuration
COMPLEXITY="${COMPLEXITY:-5}"
BITRATE="${BITRATE:-96000}"
FRAMESIZE="${FRAMSIZE:-20}"

echo "Configuration:"
echo "  Complexity:   $COMPLEXITY"
echo "  Bitrate:      $BITRATE bps"
echo "  Frame Size:   $FRAMESIZE ms"
echo ""

# Test 1: Measure capture latency (source only)
echo -e "${GREEN}=== Test 1: Capture Latency (Source Only) ===${NC}"
echo "Measuring time from pulsesrc to encoder..."
echo ""

# Save start time
START=$(date +%s%N)

# Run capture-only pipeline
timeout 10 gst-launch-1.0 \
    pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
    ! audio/x-raw,rate=48000,channels=2 \
    ! identity signal-handoff=false name=identity \
    ! fakesink sync=true 2>&1 || true

# Get timestamps from output
CAPTURE_TS=$(grep -o "^pipeline0:" /proc/$(pgrep -f 'gst-launch-1.0')/fd/1 2>/dev/null | \
    sed -n -e 's/.*running time=\([0-9]*\)s*\).*/\1/p') || echo "0")

if [ -n "$CAPTURE_TS" ]; then
    echo -e "${YELLOW}Could not capture start time${NC}"
else
    echo -e "${GREEN}Capture time: $CAPTURE_TS ms${NC}"
fi

echo ""

# Test 2: Measure encoding latency
echo -e "${GREEN}=== Test 2: Encoding Latency ===${NC}"
echo "Measuring time through encoder (pulsesrc → opusenc → identity)..."
echo ""

# Run encoding pipeline and capture timing
timeout 10 gst-launch-1.0 -v \
    pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
    ! audio/x-raw,rate=48000,channels=2 \
    ! identity signal-handoff=false name=pre-identity \
    ! opusenc bitrate=$BITRATE application=voip complexity=$COMPLEXITY \
        frame-size=$FRAMESIZE max-ptime=$FRAMESIZE \
    ! identity signal-handoff=false name=post-identity \
    ! fakesink sync=true 2>&1 | \
    tee /tmp/encoder_output.log \
    >(sed -n -e 's/.*running time=\([0-9]*\)s*\).*/Pre-encoder timestamp: \1 ms/p') \
    >(grep -E "(latency|running.*time)" | tail -1) || true

if [ -f /tmp/encoder_output.log ]; then
    PRE_ENC=$(grep "Pre-encoder timestamp:" /tmp/encoder_output.log | sed 's/Pre-encoder timestamp: \([0-9]*\) ms\)/\1/')
    POST_ENC=$(grep "Post-encoder timestamp:" /tmp/encoder_output.log | sed 's/Post-encoder timestamp: \([0-9]*\) ms\)/\1/')
else
    echo -e "${YELLOW}Could not capture encoder timestamps${NC}"
fi

if [ -n "$PRE_ENC" ] && [ -n "$POST_ENC" ]; then
    ENC_LATENCY=$(echo "$POST_ENC - $PRE_ENC" | bc)
    echo -e "${GREEN}Encoding latency: $ENC_LATENCY ms${NC}"
else
    echo -e "${YELLOW}Could not calculate encoding latency${NC}"
fi

echo ""

# Test 3: Measure end-to-end latency with decode
echo -e "${GREEN}=== Test 3: End-to-End Latency ===${NC}"
echo "Measuring: pulsesrc → opusenc → opusdec → fakesink"
echo ""

START_E2E=$(date +%s%N)

# Generate test audio using GStreamer
if [ ! -f /tmp/test_sine.wav ]; then
    echo "Generating test audio..."
    timeout 5 gst-launch-1.0 audiotestsrc wave=sine frequency=440 num-buffers=100 ! \
        audio/x-raw,rate=48000,channels=2 ! \
        filesink location=/tmp/test_sine.wav 2>&1 || true
fi

# Run end-to-end pipeline
if command -v aplay >/dev/null; then
    echo "Running end-to-end test with playback..."
    timeout 20 gst-launch-1.0 \
        pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
        ! audio/x-raw,rate=48000,channels=2 \
        ! audioconvert \
        ! audioresample \
        ! opusenc bitrate=$BITRATE application=voip complexity=$COMPLEXITY \
            frame-size=$FRAMESIZE max-ptime=$FRAMESIZE \
        ! opusdec \
        ! identity signal-handoff=false \
        ! autoaudiosink 2>&1 | \
        tee /tmp/e2e.log \
        >(sed -n -e 's/.*running time=\([0-9]*\)s*\).*/\1/p') \
        >(grep -E "(latency|running.*time)" | tail -3) || true
else
    echo -e "${YELLOW}Skipping playback test (aplay not available)${NC}"
    echo ""
    echo "Encoder-only latency measured: $ENC_LATENCY ms"
fi

# Calculate end-to-end latency
if [ -f /tmp/e2e.log ]; then
    END_TS=$(grep "^pipeline0:" /tmp/e2e.log | sed -n -e 's/.*running time=\([0-9]*\)s*\).*/\1/p' | tail -1)

    if [ -n "$END_TS" ]; then
        E2E_LATENCY=$(echo "$END_TS - $START_E2E" | bc)
        echo -e "${GREEN}End-to-end latency: $E2E_LATENCY ms${NC}"
    else
        echo -e "${YELLOW}Could not calculate end-to-end latency${NC}"
    fi
fi

echo ""

# Cleanup
rm -f /tmp/test_sine.wav /tmp/encoder_output.log /tmp/e2e.log

# Summary
echo -e "${GREEN}================================${NC}"
echo "  Test Summary"
echo "================================${NC}"
echo ""
echo "Results (if measured):"
if [ -n "$CAPTURE_TS" ]; then
    echo "  Capture latency:  ~${CAPTURE_TS} ms"
fi
if [ -n "$ENC_LATENCY" ]; then
    echo "  Encoding latency: ${ENC_LATENCY} ms"
fi
if [ -n "$E2E_LATENCY" ]; then
    echo "  End-to-end latency: ${E2E_LATENCY} ms"
fi

echo ""
echo "Target latencies for reference:"
echo "  Voice over IP:   < 150ms"
echo "  Interactive gaming:  < 100ms"
echo "  Live music:     < 50ms"
echo ""
