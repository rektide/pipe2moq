#!/usr/bin/env bash
# Monitor PipeWire sink and display audio statistics

echo "PipeWire Audio Monitor"
echo "====================="
echo ""

# Get default sink
SINK=$(pactl get-default-sink 2>/dev/null)
if [ -z "$SINK" ]; then
    echo "Error: Could not determine default sink"
    exit 1
fi

echo "Default sink: $SINK"
echo ""

# Check if monitor source exists
MONITOR="${SINK}.monitor"
SOURCES=$(pactl list short sources 2>/dev/null)

if ! echo "$SOURCES" | grep -q "$MONITOR"; then
    echo "Warning: Monitor source '$MONITOR' not found"
    echo "Available sources:"
    echo "$SOURCES" | grep -i "monitor"
    echo ""
    echo "Monitor devices may need to be created with:"
    echo "  pactl load-module module-null-sink sink_name=$MONITOR"
    exit 1
fi

# Display sink info
echo "Sink details:"
pactl list sinks 2>/dev/null | grep "$SINK"

echo ""
echo "Monitor source:"
pactl list sources 2>/dev/null | grep "$MONITOR"

echo ""
echo "Audio server info:"
pactl info 2>/dev/null

echo ""
echo "Use 'pactl subscribe' to monitor live audio levels"
echo "Press Ctrl+C to stop monitoring..."

# Monitor with timeout
timeout 0 pactl subscribe || true
