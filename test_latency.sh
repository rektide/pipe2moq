#!/usr/bin/env bash
# GStreamer Latency Testing Script for Opus Encoding
# This script measures actual pipeline latency with different configurations

set -e

# Get default sink
SINK=$(pactl get-default-sink 2>/dev/null)
if [ -z "$SINK" ]; then
    echo "Error: Could not determine default sink"
    echo "Please ensure PipeWire/PulseAudio is running"
    exit 1
fi

echo "GStreamer Pipeline Latency Testing"
echo "=================================="
echo ""
echo "Using sink: $SINK"
echo ""

# Test 1: Default configuration (measure actual latency)
echo "Test 1: Default configuration - Measure reported latency"
echo "--------------------------------------------"
timeout 15 gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=96000 application=voip complexity=5 \
      frame-size=20 max-ptime=20 \
  ! identity silent=false name=identity \
  ! fakesink sync=true 2>&1 | \
  sed -n -e 's/.*latency=\([0-9]*\)s*\).*/Latency: \1 ms/p' || echo "No latency reported"
echo ""

# Test 2: With timestamp tracking (compare capture vs output time)
echo "Test 2: Timestamp tracking - Compare capture vs output time"
echo "---------------------------------------------------------"
timeout 15 gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" do-timestamp=true \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=96000 application=voip complexity=5 \
      frame-size=20 max-ptime=20 \
  ! identity silent=false name=identity \
  ! fakesink sync=false 2>&1 | grep -E "(PTS|DTS|latency)" || echo "No timestamp info"
echo ""

# Test 3: Minimal buffer configuration
echo "Test 3: Minimal buffer configuration - buffer-time=5ms, latency-time=2ms"
echo "------------------------------------------------------------------------"
timeout 15 gst-launch-1.0 \
  pulsesrc device="${SINK}.monitor" buffer-time=5000 latency-time=2000 \
  ! audio/x-raw,rate=48000,channels=2 \
  ! audioconvert \
  ! audioresample \
  ! opusenc bitrate=96000 application=voip complexity=2 \
      frame-size=20 max-ptime=20 \
  ! identity silent=false name=identity \
  ! fakesink sync=false 2>&1 | grep -c buffer || echo "No buffer info"
echo ""

# Test 4: Compare complexity levels
echo "Test 4: Complexity comparison - Low (2) vs Medium (5) vs High (8)"
echo "-------------------------------------------------------------------"
for complexity in 2 5 8; do
    echo "Testing complexity=$complexity"
    timeout 10 gst-launch-1.0 \
      pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
      ! audio/x-raw,rate=48000,channels=2 \
      ! audioconvert \
      ! audioresample \
      ! opusenc bitrate=96000 application=voip complexity=$complexity \
            frame-size=20 max-ptime=20 \
      ! identity silent=false \
      ! fakesink sync=false 2>&1 || true
    echo ""
done
echo ""

# Test 5: Compare frame sizes
echo "Test 5: Frame size comparison - 10ms vs 20ms vs 40ms"
echo "-----------------------------------------------------------"
for framesize in 10 20 40; do
    echo "Testing frame-size=${framesize}ms"
    timeout 10 gst-launch-1.0 \
      pulsesrc device="${SINK}.monitor" buffer-time=20000 latency-time=10000 \
      ! audio/x-raw,rate=48000,channels=2 \
      ! audioconvert \
      ! audioresample \
      ! opusenc bitrate=96000 application=voip complexity=5 \
            frame-size=$framesize max-ptime=$framesize \
      ! identity silent=false \
      ! fakesink sync=false 2>&1 || true
    echo ""
done
echo ""

echo "Testing complete!"
echo "Key findings to look for:"
echo "1. Reported latency from pulsesrc (actual-latency-time)"
echo "2. Buffer underruns in logs"
echo "3. Real-time performance at different complexity levels"
echo "4. Audio quality vs latency trade-off"
