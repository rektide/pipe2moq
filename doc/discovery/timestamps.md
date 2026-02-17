# Timestamps in Media over QUIC (MoQ)

Research into timestamp handling and synchronization mechanisms for multi-consumer synchronized playback.

## Overview

For pipe2moq, we want many consumers to play in sync with each other at a fixed global delay, where each output can track and calibrate its own latency. This document explores what MoQ provides for timestamping and synchronization.

---

# Journal - Tech Stack Review

## Core Technologies

| Technology | Purpose | Notes |
|------------|---------|-------|
| **MoQ Transport** | IETF standard for media over QUIC | draft-ietf-moq-transport-16 (Jan 2026) |
| **moq-lite** | Simplified subset of MoQ Transport | Forward-compatible, practical implementation |
| **hang** | Media container format on top of moq-lite | WebCodecs-based, includes timestamps |
| **QUIC** | Transport protocol | Provides streams and datagrams |
| **WebTransport** | QUIC in browsers | Uses HTTP/3 |

## Reference Implementations

- [`moq-dev/moq`](https://github.com/moq-dev/moq) - Rust/TypeScript implementation (moq-lite + hang)
- [`cloudflare/moq-rs`](https://github.com/cloudflare/moq-rs) - Rust implementation (IETF moq-transport)

---

# Journal - Core Finding: Where Timestamps Live

## Key Insight

**MoQ Transport does NOT provide built-in timestamp metadata for media objects.** 

Timestamps are handled at the **container layer** (hang), not the transport layer. This is a deliberate design choice - MoQ is a generic transport that's agnostic to media format.

### MoQ Transport Layer (No Timestamps)

The IETF MoQ Transport specification provides:

- **Objects** (called "Frames" in moq-lite): addressable byte sequences
- **Groups**: collections of objects, join points
- **Tracks**: sequences of groups
- **Extension Headers**: optional metadata visible to relays

Object properties include:
- Group ID, Object ID
- Track alias
- Publisher priority
- Object status
- Extension headers

**There is no timestamp field in the transport protocol itself.**

### Hang Container Layer (Has Timestamps)

The [`draft-lcurley-moq-hang`](https://www.ietf.org/archive/id/draft-lcurley-moq-hang-01.html) specification defines:

> **Each frame starts with a timestamp, a QUIC variable-length integer (62-bit max) encoded in microseconds.**

This timestamp is part of the **payload**, not metadata:
```
Frame = [timestamp: varint (μs)] + [codec payload: bytes]
```

The timestamp is a **presentation timestamp** relative to the start of the track, NOT a wall-clock time.

---

# Journal - Extension Headers in MoQ Transport

## Available Extension Headers (IANA Registry)

| Type | Name | Scope | Description |
|------|------|-------|-------------|
| `0x02` | DELIVERY_TIMEOUT | Track | Duration (ms) to attempt forwarding |
| `0x04` | MAX_CACHE_DURATION | Track | Duration (ms) object can be cached |
| `0x0B` | IMMUTABLE_EXTENSIONS | Track, Object | Marks extensions as immutable |
| `0x0E` | DEFAULT_PUBLISHER_PRIORITY | Track | Default priority |
| `0x22` | DEFAULT_PUBLISHER_GROUP_ORDER | Track | Group ordering |
| `0x30` | DYNAMIC_GROUPS | Track | Dynamic group support |
| `0x3C` | PRIOR_GROUP_ID_GAP | Object | Groups that don't exist |
| `0x3E` | PRIOR_OBJECT_ID_GAP | Object | Objects that don't exist |

**All time-related extensions are DURATIONS, not timestamps.**

## IMMUTABLE_EXTENSIONS (Type 0x0B)

This extension allows applications to attach custom metadata that:
- Relays MUST preserve but cannot modify
- Is cached with the object
- Is forwarded to subscribers

**Potential use for custom timestamps**: You could define a custom extension type carrying wall-clock timestamps. However, this is application-specific and not standardized.

---

# Journal - Timestamp Implementation in moq-dev/moq

## Location in Codebase

The timestamp handling is in the `hang` crate:
- [`rs/hang/src/container/frame.rs`](https://github.com/moq-dev/moq/blob/main/rs/hang/src/container/frame.rs) - Frame with timestamp
- [`rs/moq-lite/src/model/time.rs`](https://github.com/moq-dev/moq/blob/main/rs/moq-lite/src/model/time.rs) - Timescale type

## Timescale Type

```rust
pub type Timestamp = moq_lite::Timescale<1_000_000>;  // microseconds

pub struct Frame {
    pub timestamp: Timestamp,    // Presentation timestamp
    pub keyframe: bool,          // Independent decode point
    pub payload: BufList,        // Codec data
}
```

Key points:
- Timestamps are **relative** to track start, not wall-clock
- Each track has its own timebase (zero for one track ≠ zero for another)
- The implementation deliberately obscures wall-clock time to catch bad assumptions

## Frame Encoding

```rust
// From hang/src/container/frame.rs
pub fn encode(&self, group: &mut moq_lite::GroupProducer) -> Result<(), Error> {
    let mut header = BytesMut::new();
    self.timestamp.encode(&mut header);  // Timestamp first
    // Then codec payload
    let size = header.len() + self.payload.remaining();
    let mut chunked = group.create_frame(size.into());
    chunked.write_chunk(header.freeze());
    // ... write payload chunks
}
```

---

# Journal - Synchronization Approaches

## Option 1: Use Hang Container (Recommended)

Use the existing hang container format:
- **Pros**: Standardized, WebCodecs-compatible, already implemented
- **Cons**: Relative timestamps only; need coordination for wall-clock sync

**Implementation**:
1. Publisher encodes each frame with presentation timestamp
2. All subscribers decode timestamps from frames
3. Each subscriber plays at `now + fixed_delay` where `now` is relative to track start
4. Latency calibration happens at application level

## Option 2: Custom Extension Headers

Define application-specific extension headers:
- **Pros**: Visible to relays, can carry wall-clock time
- **Cons**: Non-standard, requires custom implementation on all endpoints

**Example**:
```rust
// Custom extension type for wall-clock timestamp (hypothetical)
const WALL_CLOCK_TIMESTAMP: u64 = 0x100; // Application-defined

extension_headers.set_intvalue(WALL_CLOCK_TIMESTAMP, unix_micros);
```

## Option 3: Wall-Clock in Payload

Include wall-clock reference in first frame of each group:
- **Pros**: Simple, no protocol changes
- **Cons**: Correlating clocks requires NTP/PTP-like mechanisms

## Option 4: External Clock Synchronization

Use NTP or PTP to synchronize system clocks:
- **Pros**: Independent of MoQ, works with any approach
- **Cons**: Requires infrastructure, network-dependent accuracy

---

# Journal - Multi-Consumer Sync Strategy

## Recommended Approach for pipe2moq

Given the constraints, here's a practical synchronization strategy:

### 1. Track-Relative Timestamps (Hang Style)

Each audio frame carries a presentation timestamp relative to track start:
```
frame_0: timestamp=0μs, audio_data
frame_1: timestamp=20000μs, audio_data  // 20ms frame duration
frame_2: timestamp=40000μs, audio_data
...
```

### 2. Fixed Global Delay

All consumers play with a fixed delay D from "now":
```
play_time = first_frame_timestamp + current_timestamp_offset + D
```

Where:
- `first_frame_timestamp`: when the first frame was captured
- `current_timestamp_offset`: time elapsed since capture
- `D`: global delay buffer (e.g., 200ms)

### 3. Per-Consumer Latency Calibration

Each consumer:
1. Measures its own output latency (pipewire → speaker)
2. Subtracts its measured latency from D
3. Adjusts playback timing accordingly

```
effective_delay = global_delay - my_output_latency
```

### 4. NTP for Wall-Clock Correlation (Optional)

For better synchronization across devices:
1. All participants sync to NTP/PTP
2. Publisher includes wall-clock reference in first group
3. Consumers correlate track time to wall-clock time

---

# Discussion Questions

1. **What global delay value?** 
   - Trade-off: higher = more buffer for latency variation, lower = better interactivity
   - For audio conferencing: 100-300ms typical
   - For live music: <50ms needed

2. **How to handle clock drift?**
   - Consumer clocks may drift relative to publisher
   - Need periodic resynchronization or drift compensation

3. **How to communicate global delay?**
   - Could be in catalog.json (hang style)
   - Could be application-level configuration
   - Could be negotiated per-session

4. **What about network jitter?**
   - QUIC handles retransmissions
   - Application-level jitter buffer needed
   - Size of jitter buffer affects effective delay

---

# Decision Points

## For pipe2moq Implementation

| Decision | Recommendation | Rationale |
|----------|---------------|-----------|
| Container format | Use hang-style timestamps | Already works, WebCodecs compatible |
| Timestamp type | Track-relative μs | Standard, sufficient for sync |
| Global delay config | Config parameter | Start simple, can extend later |
| Latency calibration | Consumer-side measurement | Each output knows its hardware |
| Wall-clock sync | Future enhancement | Optional for initial implementation |

## Code References

### moq-dev/moq
- Frame with timestamp: `rs/hang/src/container/frame.rs`
- Timescale type: `rs/moq-lite/src/model/time.rs`
- Frame consumer (timestamp decoding): `rs/hang/src/container/consumer.rs`

### cloudflare/moq-rs
- Extension headers: `moq-transport/src/data/extension_headers.rs`
- Subgroup handling: `moq-transport/src/serve/subgroup.rs`

---

# References

## Specifications
- [draft-ietf-moq-transport-16](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/) - MoQ Transport
- [draft-lcurley-moq-hang-01](https://www.ietf.org/archive/id/draft-lcurley-moq-hang-01.html) - Hang container format
- [draft-lcurley-moq-lite-02](https://www.ietf.org/archive/id/draft-lcurley-moq-lite-02.html) - moq-lite subset

## Implementations
- [moq-dev/moq](https://github.com/moq-dev/moq) - Reference moq-lite + hang
- [cloudflare/moq-rs](https://github.com/cloudflare/moq-rs) - IETF moq-transport
- [moq-wg/moq-transport](https://github.com/moq-wg/moq-transport) - Spec repository

## Related
- [WebCodecs](https://www.w3.org/TR/webcodecs/) - Browser codec API
- [WebTransport](https://www.w3.org/TR/webtransport/) - Browser QUIC API
