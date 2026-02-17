# TARGET_PLAYTIME Extension Header Specification

A MoQ Transport extension header for synchronized multi-consumer playback.

---

## Abstract

This document specifies the `TARGET_PLAYTIME` extension header for Media over QUIC Transport (MOQT). The extension provides wall-clock timing information for media objects, enabling synchronized playback across multiple consumers with different network latencies and output hardware.

---

# Journal - Specification Development

## Design Goals

1. **Synchronized playback**: Multiple consumers play at the same wall-clock time
2. **Fixed global delay**: All consumers use a common delay buffer
3. **Per-consumer calibration**: Each consumer accounts for its own output latency
4. **Relay visibility**: Relays see (but don't modify) timing information
5. **Backward compatibility**: Unknown extensions are forwarded unchanged

---

# Specification

## TARGET_PLAYTIME Extension Header

**Extension Header Type:** `0xE2` (226)  
**Scope:** Object  
**Value Format:** Length-prefixed bytes (Type is odd)  
**Value Size:** 8 bytes (signed 64-bit integer)

### Value Semantics

TARGET_PLAYTIME contains a 64-bit signed integer representing the Unix epoch timestamp in **nanoseconds** when the media object should be played (presented to the output device).

```
TARGET_PLAYTIME {
  Type (0xE2),
  Length (0x08),
  Timestamp (i64)  // signed 64-bit, nanoseconds since Unix epoch
}
```

The timestamp value:
- **Positive values**: Nanoseconds since 1970-01-01 00:00:00 UTC
- **Negative values**: Nanoseconds before 1970-01-01 00:00:00 UTC (unlikely in practice)
- **Zero**: Unix epoch (1970-01-01 00:00:00 UTC)

### Wire Format

Since Type `0xE2` is odd, the Key-Value-Pair encoding includes a Length field:

```
Key-Value-Pair {
  Delta Type (i),     // Encoded as varint, delta from previous type
  Length (i),         // Always 0x08 (8 bytes) for TARGET_PLAYTIME
  Value (8 bytes)     // Signed 64-bit integer, big-endian
}
```

### Semantics

The TARGET_PLAYTIME indicates the **absolute wall-clock time** when this object's payload should be presented to the output device (e.g., speakers for audio, display for video).

**Consumers** use TARGET_PLAYTIME to:
1. Determine when to play each frame
2. Calculate clock offset from the publisher
3. Measure end-to-end latency
4. Implement jitter buffers with precise timing

**Publishers** set TARGET_PLAYTIME to:
1. The capture time plus a fixed global delay
2. Account for encoding latency in the timestamp

**Relays** MUST:
1. Preserve TARGET_PLAYTIME unchanged
2. Cache it with the object
3. Forward it to subscribers

### Processing Rules

| Entity | Can Add | Can Modify | Can Remove | Notes |
|--------|---------|------------|------------|-------|
| Original Publisher | YES | YES (before publish) | YES (before publish) | Owns the timestamp |
| Relay | NO | NO | NO | Must preserve unchanged |
| Subscriber | N/A | N/A | N/A | Reads only |

### Malformed Conditions

A Track is considered malformed (see [Section 2.4.2 of draft-ietf-moq-transport](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/)) if any of the following conditions are detected:

1. An Object contains more than one instance of TARGET_PLAYTIME.
2. TARGET_PLAYTIME Length field is not exactly 8 bytes.
3. TARGET_PLAYTIME timestamp is not monotonically increasing within a Group (for real-time streams).
4. TARGET_PLAYTIME timestamp is unreasonably far in the past or future (implementation-defined threshold).

### Caching and Forwarding

Relays MUST cache TARGET_PLAYTIME as part of the Object metadata. If the Object is cached, TARGET_PLAYTIME MUST be preserved and included when the Object is forwarded.

Relays MUST NOT attempt to modify TARGET_PLAYTIME based on their local clock or any other criteria.

---

# Journal - Encoding Details

## Why 64-bit Signed?

| Format | Range | Precision | Notes |
|--------|-------|-----------|-------|
| Unsigned 62-bit varint | 0 to ~4.6×10^18 | - | MoQ native format, but no negatives |
| Unsigned 64-bit | 0 to ~1.8×10^19 | - | Can't represent pre-1970 |
| **Signed 64-bit** | ±9.2×10^18 | - | Full Unix timestamp range |

**Nanosecond precision** is required for:
- Audio synchronization (samples at 48kHz = ~20μs per sample)
- Video frame timing (at 60fps = ~16.7ms per frame)
- Multi-track alignment (audio/video sync)

**Range with nanoseconds**:
- 64-bit signed nanoseconds covers ±292 years from Unix epoch
- Years 1677 to 2262 are representable

## Wire Encoding

Since `0xE2` is odd, we use length-prefixed encoding:

```
Example: TARGET_PLAYTIME = 1708234567890123456 ns
         (2024-02-18 02:36:07.890123456 UTC)

Hex bytes (assuming this is the first extension, delta from 0):
  E2          // Type 0xE2 (delta from 0)
  08          // Length: 8 bytes
  17 AC 3F 2D // Timestamp bytes (big-endian)...
  D5 04 12 30 // ...continued
```

---

# Journal - Usage Examples

## Publisher Implementation

```rust
use std::time::{SystemTime, UNIX_EPOCH};

const TARGET_PLAYTIME_TYPE: u64 = 0xE2;
const GLOBAL_DELAY_NS: i64 = 200_000_000; // 200ms

fn publish_frame(payload: Vec<u8>, capture_time: SystemTime) {
    let capture_ns = capture_time
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i64;
    
    // Target playtime = capture time + global delay
    let target_playtime = capture_ns + GLOBAL_DELAY_NS;
    
    let mut ext_headers = ExtensionHeaders::new();
    ext_headers.set_bytesvalue(
        TARGET_PLAYTIME_TYPE,
        target_playtime.to_be_bytes().to_vec()
    );
    
    // Create object with extension headers
    let object = SubgroupObjectExt {
        object_id_delta: 0,
        extension_headers: ext_headers,
        payload_length: payload.len(),
        status: None,
    };
    // ... encode and send
}
```

## Subscriber Implementation

```rust
use std::time::{SystemTime, UNIX_EPOCH};

const TARGET_PLAYTIME_TYPE: u64 = 0xE2;
const MY_OUTPUT_LATENCY_NS: i64 = 10_000_000; // 10ms speaker latency

fn receive_frame(object: SubgroupObjectExt) {
    // Extract TARGET_PLAYTIME
    let target_playtime = object.extension_headers
        .get(TARGET_PLAYTIME_TYPE)
        .and_then(|kvp| kvp.bytes_value())
        .map(|bytes| {
            let arr: [u8; 8] = bytes.try_into().unwrap();
            i64::from_be_bytes(arr)
        });
    
    if let Some(target_ns) = target_playtime {
        // Adjust for my output latency
        let my_playtime = target_ns - MY_OUTPUT_LATENCY_NS;
        
        // Calculate when to play
        let now_ns = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos() as i64;
        
        let wait_ns = my_playtime - now_ns;
        
        if wait_ns > 0 {
            // Schedule playback
            schedule_playback(wait_ns, object.payload);
        } else {
            // Late! Play immediately or drop
            play_immediately(object.payload);
        }
    }
}
```

---

# Journal - Comparison with Alternatives

## Option 1: TARGET_PLAYTIME (This Specification)

| Aspect | Evaluation |
|--------|------------|
| Precision | Nanosecond - excellent |
| Complexity | Medium - requires clock sync |
| Relay impact | Minimal - pass-through |
| Standardization | Application-defined initially |

## Option 2: Track-Relative Timestamps (hang)

Using existing hang container timestamps (relative microseconds):

```
play_time = first_frame_time + frame_offset + global_delay
```

| Aspect | Evaluation |
|--------|------------|
| Precision | Microsecond - good |
| Complexity | Low - no clock sync needed |
| Relay impact | None - in payload |
| Standardization | Already in hang spec |

**Limitation**: Requires correlating track time to wall-clock time at session start.

## Option 3: NTP/PTP External Sync

Rely on external clock synchronization:

| Aspect | Evaluation |
|--------|------------|
| Precision | Depends on NTP/PTP quality |
| Complexity | High - infrastructure |
| Relay impact | None |
| Standardization | N/A - out of band |

## Option 4: Hybrid Approach

Combine TARGET_PLAYTIME with hang timestamps:
- TARGET_PLAYTIME in first object of each group
- hang timestamps for intra-group timing

| Aspect | Evaluation |
|--------|------------|
| Precision | Best of both |
| Complexity | Higher |
| Bandwidth | Lower (one extension per group) |

---

# Journal - Decision Points

## For pipe2moq Implementation

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Type code | `0xE2` | In "standards, space less critical" range (64-16383) |
| Time unit | Nanoseconds | Matches gstreamer/pipe2moq precision |
| Encoding | Signed 64-bit BE | Full Unix timestamp range |
| Scope | Object only | Per-frame precision needed |
| Immutable | Yes | Via IMMUTABLE_EXTENSIONS if desired |

## Open Questions

1. **Should TARGET_PLAYTIME be wrapped in IMMUTABLE_EXTENSIONS?**
   - Pro: Guarantees no modification
   - Con: Adds nesting complexity
   - Recommendation: Yes, for critical synchronization use cases

2. **How to handle clock drift?**
   - Consumer should track drift over time
   - Could add DRIFT_CORRECTION extension for publisher updates
   - Recommendation: Start with consumer-side drift tracking

3. **What global delay value?**
   - Audio conferencing: 100-300ms
   - Live music: <50ms
   - Recommendation: Configurable per-session

---

# IANA Considerations

This document requests registration of the following extension header in the "MOQ Extension Headers" registry:

| Field | Value |
|-------|-------|
| Type | `0xE2` (226) |
| Name | TARGET_PLAYTIME |
| Scope | Object |
| Specification | This document |
| Repeatable | No |

---

# Security Considerations

1. **Clock manipulation**: Malicious publishers could set unreasonable timestamps
   - Mitigation: Consumers should validate timestamps are within acceptable range

2. **Replay attacks**: Old objects with past timestamps could be re-injected
   - Mitigation: Consumers should reject timestamps too far in the past

3. **Timing attacks**: Precise timestamps could reveal information about publisher
   - Mitigation: Add small random jitter if privacy is critical

---

# References

## Normative References

- [draft-ietf-moq-transport-16](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/) - MoQ Transport
- [draft-lcurley-moq-hang-01](https://www.ietf.org/archive/id/draft-lcurley-moq-hang-01.html) - Hang container format

## Informative References

- [RFC 9580](https://www.rfc-editor.org/rfc/rfc9580) - NTPv4
- [IEEE 1588](https://standards.ieee.org/ieee/1588/6825/) - PTP
- [WebCodecs](https://www.w3.org/TR/webcodecs/) - Browser codec API

---

# Appendix A: Type Code Selection

The type code `0xE2` (226) was selected because:

1. Falls in range 64-16383 (0x40-0x3FFF) for standards utilization
2. Not allocated in current IANA registry
3. Odd number → Length-prefixed encoding (required for 8-byte value)
4. Memorable hex value

Alternative codes in same range: `0xC8`, `0xDC`, `0xF0`, etc.

---

# Appendix B: Related Work

## WebRTC

WebRTC uses RTP with RTCP Sender Reports for clock synchronization:
- NTP timestamp + RTP timestamp mapping
- Requires RTCP traffic
- Not applicable to MoQ architecture

## HLS/DASH

HTTP-based streaming uses:
- Segment timing in manifests (PTS)
- Wall-clock not embedded in segments
- Assumes client clock sync via HTTP

## NTP/PTP

Network Time Protocol and Precision Time Protocol:
- Separate infrastructure
- Microsecond (NTP) to nanosecond (PTP) precision
- TARGET_PLAYTIME assumes loosely synchronized clocks (~10ms)
