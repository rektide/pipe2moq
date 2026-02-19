# TARGET_PLAYTIME Extension Header for Media over QUIC

## Abstract

This document specifies the TARGET_PLAYTIME extension header for Media over QUIC Transport (MOQT). The extension provides absolute wall-clock timing information for media objects, enabling synchronized playback across multiple consumers with different network latencies and output hardware.

## Status of This Memo

This is an application-defined extension header specification. It is not part of the IETF MoQ Transport standard but follows the extension header conventions defined in [I-D.ietf-moq-transport].

---

## 1. Introduction

Media over QUIC Transport (MOQT) is a publish/subscribe protocol for media distribution. The base protocol uses relative timestamps embedded in media containers (e.g., the hang container format) for presentation timing. However, relative timestamps require correlation between track time and wall-clock time, which complicates synchronized multi-consumer scenarios.

This document defines the TARGET_PLAYTIME extension header, which carries an absolute Unix epoch timestamp indicating when a Group of media objects should begin playback. This enables:

- **Synchronized playback**: Multiple consumers play at the same wall-clock time
- **Fixed global delay**: Publishers set a common delay buffer  
- **Per-consumer calibration**: Each consumer accounts for its own output latency
- **Efficient signaling**: One timestamp per Group rather than per Object

---

## 2. Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals, as shown here.

This document uses terminology from [I-D.ietf-moq-transport], including:
- **Object**: An addressable unit whose payload is a sequence of bytes
- **Group**: A series of Objects delivered in order until closed or cancelled
- **Original Publisher**: The initial publisher of a given track
- **Relay**: An entity that is both a Publisher and a Subscriber

Additional terms defined by this document:
- **Target Playtime**: The absolute wall-clock time when a Group's playback should begin

---

## 3. TARGET_PLAYTIME Extension Header

The TARGET_PLAYTIME extension (Extension Header Type 0xE3) is an Object Extension. It expresses the absolute wall-clock time in nanoseconds since the Unix epoch when the Group should begin playback.

TARGET_PLAYTIME only applies to Objects, not Tracks.

TARGET_PLAYTIME is OPTIONAL. When present, it SHOULD appear only on the first Object of a Group, establishing the wall-clock anchor time for that Group. Subsequent Objects within the same Group use relative timing based on their sequence within the Group or container-level timestamps.

### 3.1. Wire Format

```
TARGET_PLAYTIME {
  Type (0xE3),
  Length (i),
  Timestamp (..)
}
```

**Type**: The extension header type 0xE3. Since 0xE3 is odd, the Key-Value-Pair encoding includes a Length field.

**Length**: A variable-length integer specifying the length of the Timestamp field in bytes. MUST be 8.

**Timestamp**: An 8-byte signed 64-bit integer in big-endian byte order, representing nanoseconds since the Unix epoch (1970-01-01 00:00:00 UTC). Positive values represent times after the epoch; negative values represent times before the epoch.

### 3.2. Semantics

The TARGET_PLAYTIME indicates the absolute wall-clock time when playback of this Group should begin.

#### 3.2.1. Group-Level Timing

TARGET_PLAYTIME establishes a wall-clock anchor for an entire Group:

- **First Object**: If TARGET_PLAYTIME is present on the first Object of a Group, it specifies when that Group's playback begins.
- **Subsequent Objects**: Objects within the same Group that follow the first Object SHOULD NOT include TARGET_PLAYTIME. They play in sequence using their natural frame duration or container-level timestamps relative to the Group's anchor.

This design minimizes overhead (one timestamp per Group rather than per Object) while maintaining precise synchronization.

**Publishers** set TARGET_PLAYTIME on the first Object of each Group:

```
target_playtime = capture_time + global_delay
```

Where:
- `capture_time`: Wall-clock time when the Group's first frame was captured
- `global_delay`: Application-defined buffer (e.g., 160ms)

**Consumers** use TARGET_PLAYTIME to determine Group playback timing:

```
group_start_time = target_playtime - output_latency
```

Objects within the Group play at:
```
object_play_time = group_start_time + object_relative_offset
```

Where `object_relative_offset` is derived from:
- Container-level timestamps (e.g., hang microseconds header)
- Natural frame duration × object index within Group
- Application-specific timing metadata

Consumers SHOULD implement jitter buffering based on TARGET_PLAYTIME values to handle network latency variations.

### 3.3. Validity Constraints

TARGET_PLAYTIME, if present, MUST contain exactly 8 bytes. If an endpoint receives a TARGET_PLAYTIME with a Length field other than 8, it MUST close the session with PROTOCOL_VIOLATION.

A Track is considered malformed (see Section 2.4.2 of [I-D.ietf-moq-transport]) if any of the following conditions are detected:

* An Object contains more than one instance of TARGET_PLAYTIME.
* TARGET_PLAYTIME Length field is not exactly 8 bytes.
* The Timestamp bytes cannot be decoded as a valid signed 64-bit integer.

This extension is OPTIONAL. Publishers that do not support TARGET_PLAYTIME will not include it. Consumers that do not support TARGET_PLAYTIME MUST ignore it and rely on container-level timestamps if available.

When TARGET_PLAYTIME is used, it SHOULD appear only on the first Object of a Group. Consumers that receive TARGET_PLAYTIME on non-first Objects within a Group MAY:
- Use the timestamp as a new anchor for subsequent Objects
- Ignore it and continue using the Group's initial anchor
- Treat it as an error condition

### 3.4. Processing Rules

```
+===================+==========+==========+==========+
| Entity            | Can Add  | Can Mod  | Can Rem  |
+===================+==========+==========+==========+
| Original Publisher| YES      | YES      | YES      |
+-------------------+----------+----------+----------+
| Relay             | NO       | NO       | NO       |
+-------------------+----------+----------+----------+
```

The TARGET_PLAYTIME extension can be added by the Original Publisher but MUST NOT be added by Relays. This extension MUST NOT be modified or removed by Relays.

### 3.5. Caching and Forwarding

Relays MUST preserve TARGET_PLAYTIME unchanged. Relays MUST cache TARGET_PLAYTIME as part of the Object metadata and MUST forward it to subscribers.

Relays MUST NOT attempt to modify TARGET_PLAYTIME based on their local clock or any other criteria.

---

## 4. Security Considerations

**Clock Manipulation**: Malicious publishers could set unreasonable timestamps (e.g., far future or past). Consumers SHOULD validate that received timestamps are within an acceptable range and reject objects with timestamps too far from the current time.

**Replay Attacks**: Objects with timestamps in the past could be replayed by attackers. Consumers SHOULD reject objects with TARGET_PLAYTIME values significantly in the past (e.g., more than the global delay threshold).

**Timing Attacks**: Precise timestamps could reveal information about the publisher's clock synchronization or location. Applications with privacy requirements SHOULD consider adding small random jitter to timestamps.

---

## 5. IANA Considerations

This document requests registration of the following extension header in the "MOQ Extension Headers" registry:

```
+========+================+========+===============+
| Type   | Name           | Scope  | Specification |
+========+================+========+===============+
| 0xE3   | TARGET_PLAYTIME| Object | Section 3     |
+--------+----------------+--------+---------------+
```

---

## 6. References

### 6.1. Normative References

[I-D.ietf-moq-transport]
:    Nandakumar, S., Vasiliev, V., Swett, I., and A. Frindell, "Media over QUIC Transport", Work in Progress, Internet-Draft, draft-ietf-moq-transport-16, January 2026.

[RFC2119]
:    Bradner, S., "Key words for use in RFCs to Indicate Requirement Levels", BCP 14, RFC 2119, DOI 10.17487/RFC2119, March 1997.

[RFC8174]
:    Leiba, B., "Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words", BCP 14, RFC 8174, DOI 10.17487/RFC8174, May 2017.

### 6.2. Informative References

[draft-lcurley-moq-hang]
:    Curley, L., "Media over QUIC - Hang", Work in Progress, Internet-Draft, draft-lcurley-moq-hang-01, November 2025.

---

## Appendix A. Example Usage

### A.1. Publisher Implementation (Rust) - Group Level

```rust
use std::time::{SystemTime, UNIX_EPOCH};

const TARGET_PLAYTIME_TYPE: u64 = 0xE3;
const GLOBAL_DELAY_NS: i64 = 160_000_000; // 160ms

// Called once per Group, on the first Object only
fn create_group_with_target_playtime(first_frame: Vec<u8>) -> Vec<u8> {
    let capture_ns = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i64;
    
    let target_playtime = capture_ns + GLOBAL_DELAY_NS;
    
    // Prepend TARGET_PLAYTIME to first frame of group
    let mut payload = Vec::with_capacity(8 + first_frame.len());
    payload.extend_from_slice(&target_playtime.to_be_bytes());
    payload.extend_from_slice(&first_frame);
    payload
}

// Subsequent frames in the group are sent without TARGET_PLAYTIME
fn create_continuation_frame(frame: Vec<u8>) -> Vec<u8> {
    frame // Just the Opus payload, no TARGET_PLAYTIME
}
```

### A.2. Consumer Implementation (Rust)

```rust
use std::time::{SystemTime, UNIX_EPOCH};
use std::collections::HashMap;

const TARGET_PLAYTIME_TYPE: u64 = 0xE3;
const OUTPUT_LATENCY_NS: i64 = 10_000_000; // 10ms speaker latency
const FRAME_DURATION_NS: i64 = 20_000_000; // 20ms for Opus at 48kHz

struct GroupPlayback {
    anchor_time: i64,  // TARGET_PLAYTIME from first object
    object_index: i64,
}

fn process_group_first_object(payload: &[u8]) -> (GroupPlayback, &[u8]) {
    // First 8 bytes are TARGET_PLAYTIME
    let anchor_ns = i64::from_be_bytes(payload[..8].try_into().unwrap());
    let audio_data = &payload[8..];
    
    let group = GroupPlayback {
        anchor_time: anchor_ns - OUTPUT_LATENCY_NS,
        object_index: 0,
    };
    
    (group, audio_data)
}

fn schedule_playback(group: &GroupPlayback, audio_data: &[u8]) -> std::time::Duration {
    let play_time = group.anchor_time + (group.object_index * FRAME_DURATION_NS);
    
    let now_ns = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i64;
    
    let wait_ns = play_time - now_ns;
    
    if wait_ns > 0 {
        std::time::Duration::from_nanos(wait_ns as u64)
    } else {
        std::time::Duration::ZERO // Late frame, play immediately
    }
}
```

### A.3. Wire Encoding Example

For a Group starting at TARGET_PLAYTIME = 1708234567890123456 ns (2024-02-18 02:36:07.890123456 UTC):

**First Object of Group (with TARGET_PLAYTIME):**
```
E3                // Type: 0xE3 (delta from 0)
08                // Length: 8 bytes
17 AC 3F 2D       // Timestamp (big-endian)...
D5 04 12 30       // ...continued
[Opus frame 0]    // Audio payload

Total: 10 + payload bytes
```

**Subsequent Objects in Group (no TARGET_PLAYTIME):**
```
[Opus frame 1]    // Audio payload only
[Opus frame 2]    // Audio payload only
...
```

The consumer plays frame 0 at TARGET_PLAYTIME, frame 1 at TARGET_PLAYTIME + 20ms, frame 2 at TARGET_PLAYTIME + 40ms, etc.
