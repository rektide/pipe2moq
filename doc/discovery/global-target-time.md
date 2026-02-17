# TARGET_PLAYTIME Extension Header for Media over QUIC

## Abstract

This document specifies the TARGET_PLAYTIME extension header for Media over QUIC Transport (MOQT). The extension provides absolute wall-clock timing information for media objects, enabling synchronized playback across multiple consumers with different network latencies and output hardware.

## Status of This Memo

This is an application-defined extension header specification. It is not part of the IETF MoQ Transport standard but follows the extension header conventions defined in [I-D.ietf-moq-transport].

---

## 1. Introduction

Media over QUIC Transport (MOQT) is a publish/subscribe protocol for media distribution. The base protocol uses relative timestamps embedded in media containers (e.g., the hang container format) for presentation timing. However, relative timestamps require correlation between track time and wall-clock time, which complicates synchronized multi-consumer scenarios.

This document defines the TARGET_PLAYTIME extension header, which carries an absolute Unix epoch timestamp indicating when a media object should be presented. This enables:

- **Synchronized playback**: Multiple consumers play at the same wall-clock time
- **Fixed global delay**: Publishers set a common delay buffer
- **Per-consumer calibration**: Each consumer accounts for its own output latency

---

## 2. Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals, as shown here.

This document uses terminology from [I-D.ietf-moq-transport], including:
- **Object**: An addressable unit whose payload is a sequence of bytes
- **Original Publisher**: The initial publisher of a given track
- **Relay**: An entity that is both a Publisher and a Subscriber

Additional terms defined by this document:
- **Target Playtime**: The absolute wall-clock time when an object's payload should be presented to the output device

---

## 3. TARGET_PLAYTIME Extension Header

The TARGET_PLAYTIME extension (Extension Header Type 0xE3) is an Object Extension. It expresses the absolute wall-clock time in nanoseconds since the Unix epoch when the media object should be presented to the output device.

TARGET_PLAYTIME only applies to Objects, not Tracks.

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

The TARGET_PLAYTIME indicates the absolute wall-clock time when this object's payload should be presented to the output device (e.g., speakers for audio, display for video).

**Publishers** set TARGET_PLAYTIME to the capture time plus a fixed global delay:

```
target_playtime = capture_time + global_delay
```

Where:
- `capture_time`: Wall-clock time when media was captured
- `global_delay`: Application-defined buffer (e.g., 200ms)

**Consumers** use TARGET_PLAYTIME to determine playback timing:

```
wait_duration = target_playtime - output_latency - current_time
```

Where:
- `output_latency`: Consumer's hardware output latency (e.g., 10ms speaker latency)
- `current_time`: Consumer's current wall-clock time

Consumers SHOULD implement jitter buffering based on TARGET_PLAYTIME values to handle network latency variations.

### 3.3. Validity Constraints

TARGET_PLAYTIME, if present, MUST contain exactly 8 bytes. If an endpoint receives a TARGET_PLAYTIME with a Length field other than 8, it MUST close the session with PROTOCOL_VIOLATION.

A Track is considered malformed (see Section 2.4.2 of [I-D.ietf-moq-transport]) if any of the following conditions are detected:

* An Object contains more than one instance of TARGET_PLAYTIME.
* TARGET_PLAYTIME Length field is not exactly 8 bytes.
* The Timestamp bytes cannot be decoded as a valid signed 64-bit integer.

This extension is optional. Publishers that do not support TARGET_PLAYTIME will not include it. Consumers that do not support TARGET_PLAYTIME MUST ignore it and rely on container-level timestamps if available.

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

### A.1. Publisher Implementation (Rust)

```rust
use std::time::{SystemTime, UNIX_EPOCH};

const TARGET_PLAYTIME_TYPE: u64 = 0xE3;
const GLOBAL_DELAY_NS: i64 = 200_000_000; // 200ms

fn create_frame_with_target_playtime(payload: Vec<u8>) -> SubgroupObjectExt {
    let capture_ns = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i64;
    
    let target_playtime = capture_ns + GLOBAL_DELAY_NS;
    
    let mut ext_headers = ExtensionHeaders::new();
    ext_headers.set_bytesvalue(
        TARGET_PLAYTIME_TYPE,
        target_playtime.to_be_bytes().to_vec()
    );
    
    SubgroupObjectExt {
        object_id_delta: 0,
        extension_headers: ext_headers,
        payload_length: payload.len(),
        status: None,
    }
}
```

### A.2. Consumer Implementation (Rust)

```rust
use std::time::{SystemTime, UNIX_EPOCH};

const TARGET_PLAYTIME_TYPE: u64 = 0xE3;
const OUTPUT_LATENCY_NS: i64 = 10_000_000; // 10ms speaker latency

fn process_frame(object: SubgroupObjectExt) -> Duration {
    let target_ns = object.extension_headers
        .get(TARGET_PLAYTIME_TYPE)
        .and_then(|kvp| kvp.bytes_value())
        .map(|bytes| {
            let arr: [u8; 8] = bytes.as_slice().try_into().unwrap();
            i64::from_be_bytes(arr)
        })
        .unwrap_or(0);
    
    let adjusted_target = target_ns - OUTPUT_LATENCY_NS;
    
    let now_ns = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i64;
    
    let wait_ns = adjusted_target - now_ns;
    
    if wait_ns > 0 {
        Duration::from_nanos(wait_ns as u64)
    } else {
        Duration::ZERO // Late frame, play immediately
    }
}
```

### A.3. Wire Encoding Example

For TARGET_PLAYTIME = 1708234567890123456 ns (2024-02-18 02:36:07.890123456 UTC):

```
E3                // Type: 0xE3 (delta from 0)
08                // Length: 8 bytes
17 AC 3F 2D       // Timestamp (big-endian)...
D5 04 12 30       // ...continued

Total: 10 bytes on wire
```
