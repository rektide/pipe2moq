# initial "all in one" prompt

build a rust package that uses gstreamer rust, hang, and moq-relay rust to create a tightly coupled gstreamer pipeline pursuant to the `system design` in the readme.

- our goal is to try to decrease latency by having one unified process that combines the gstreamer pipeline with the moq-relay serving
- if we can find a way to skip `hang-gst` and more directly wire the gstreamer pipeline to the moq-relay that would be great!
- use figment2 to make aspects of the pipeline configurable
