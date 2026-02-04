use anyhow::Result;
use bytes::Bytes;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app::{AppSink, AppSinkCallbacks};

use std::process::Command;
use tokio::sync::mpsc;
use tracing::{error, info, debug, warn};
use url::Url;

#[derive(Clone)]
pub struct AudioConfig {
    pub sample_rate: u32,
    pub channels: u32,
    pub bitrate: u32,
    pub application: String,
    pub complexity: u32,
    pub frame_size: u32,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            sample_rate: 48000,
            channels: 2,
            bitrate: 96000,
            application: "generic".to_string(),
            complexity: 5,
            frame_size: 20,
        }
    }
}

#[derive(Clone)]
pub struct PipelineConfig {
    pub audio: AudioConfig,
    pub buffer_time: u32,
    pub latency_time: u32,
    pub sink_name: Option<String>,
}

impl Default for PipelineConfig {
    fn default() -> Self {
        Self {
            audio: AudioConfig::default(),
            buffer_time: 20000,
            latency_time: 10000,
            sink_name: None,
        }
    }
}

#[derive(Clone)]
pub struct MoqConfig {
    pub relay_url: String,
    pub broadcast_path: String,
    pub track_name: String,
}

impl Default for MoqConfig {
    fn default() -> Self {
        Self {
            relay_url: "https://localhost:4443/anon".to_string(),
            broadcast_path: "/live/audio".to_string(),
            track_name: "audio".to_string(),
        }
    }
}

pub struct Pipe2Moq {
    pipeline_config: PipelineConfig,
    moq_config: MoqConfig,
}

impl Pipe2Moq {
    pub fn new(pipeline_config: PipelineConfig, moq_config: MoqConfig) -> Self {
        Self {
            pipeline_config,
            moq_config,
        }
    }

    pub async fn run(&self) -> Result<()> {
        info!("Starting Pipe2Moq");
        info!("Relay URL: {}", self.moq_config.relay_url);
        info!("Broadcast path: {}", self.moq_config.broadcast_path);
        info!("Audio config: {}Hz, {} channels, {} kbps",
              self.pipeline_config.audio.sample_rate,
              self.pipeline_config.audio.channels,
              self.pipeline_config.audio.bitrate / 1000);

        let (frame_sender, mut frame_receiver) = mpsc::channel::<(Bytes, u64)>(100);

        let pipeline_handle = tokio::task::spawn_blocking({
            let pipeline_config = self.pipeline_config.clone();
            move || Self::run_gstreamer_pipeline(pipeline_config, frame_sender)
        });

        let moq_handle = tokio::task::spawn({
            let moq_config = self.moq_config.clone();
            async move { Self::run_moq_publisher(moq_config, &mut frame_receiver).await }
        });

        tokio::select! {
            result = pipeline_handle => {
                if let Err(e) = result {
                    error!("GStreamer pipeline error: {e}");
                    return Err(e.into());
                }
            }
            result = moq_handle => {
                if let Err(e) = result {
                    error!("MoQ publisher error: {e}");
                    return Err(e.into());
                }
            }
        }

        Ok(())
    }

    fn run_gstreamer_pipeline(
        config: PipelineConfig,
        frame_sender: mpsc::Sender<(Bytes, u64)>,
    ) -> Result<()> {
        gst::init()?;

        let pipeline = gst::Pipeline::default();

        let source_device = if let Some(ref sink) = config.sink_name {
            format!("{}.monitor", sink)
        } else {
            let output = Command::new("pactl")
                .args(&["get-default-sink"])
                .output()?;
            let sink_name = String::from_utf8_lossy(&output.stdout).trim().to_string();
            format!("{}.monitor", sink_name)
        };

        info!("Audio source: {}", source_device);

        let pulsesrc = gst::ElementFactory::make("pulsesrc")
            .property("device", &source_device)
            .property("buffer-time", config.buffer_time as i64)
            .property("latency-time", config.latency_time as i64)
            .build()?;

        let capsfilter = gst::ElementFactory::make("capsfilter")
            .property("caps", &gst::Caps::builder("audio/x-raw")
                .field("rate", config.audio.sample_rate as i32)
                .field("channels", config.audio.channels as i32)
                .build())
            .build()?;

        let audioconvert = gst::ElementFactory::make("audioconvert").build()?;
        let audioresample = gst::ElementFactory::make("audioresample").build()?;

        let opusenc = gst::ElementFactory::make("opusenc")
            .property("bitrate", config.audio.bitrate as i32)
            .property_from_str("audio-type", if config.audio.application == "voice" { "voice" } else { "generic" })
            .property("complexity", config.audio.complexity as i32)
            .property_from_str("frame-size", &config.audio.frame_size.to_string())
            .build()?;

        let appsink = AppSink::builder()
            .sync(false)
            .build();

        pipeline.add_many([
            &pulsesrc, &capsfilter, &audioconvert,
            &audioresample, &opusenc, appsink.upcast_ref(),
        ])?;

        gst::Element::link_many([
            &pulsesrc, &capsfilter, &audioconvert,
            &audioresample, &opusenc, appsink.upcast_ref(),
        ])?;

        let sender = frame_sender;

        appsink.set_callbacks(
            AppSinkCallbacks::builder()
                .new_sample(move |appsink| {
                    let sample = appsink.pull_sample()
                        .map_err(|_| gst::FlowError::Eos)?;

                    let buffer = sample.buffer().ok_or_else(|| {
                        error!("Failed to get buffer from sample");
                        gst::FlowError::Error
                    })?;

                    let pts = buffer.pts().unwrap_or(gst::ClockTime::ZERO);
                    let timestamp_us = pts.nseconds() / 1000;

                    let size = buffer.size();
                    let mut data = Vec::with_capacity(size);
                    {
                        let map = buffer.map_readable().map_err(|_| {
                            error!("Failed to map buffer readable");
                            gst::FlowError::Error
                        })?;
                        data.extend_from_slice(map.as_slice());
                    }

                    let bytes = Bytes::from(data);
                    debug!("Sending Opus frame: {} bytes, timestamp {} μs", size, timestamp_us);

                    if sender.blocking_send((bytes, timestamp_us)).is_err() {
                        error!("Failed to send frame to MoQ publisher");
                        return Err(gst::FlowError::Error);
                    }

                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );

        pipeline.set_state(gst::State::Playing)?;

        let bus = pipeline.bus().expect("Pipeline without bus");
        for msg in bus.iter_timed(gst::ClockTime::NONE) {
            use gst::MessageView;
            match msg.view() {
                MessageView::Eos(..) => {
                    info!("GStreamer pipeline EOS");
                    break;
                }
                MessageView::Error(err) => {
                    pipeline.set_state(gst::State::Null)?;
                    error!("GStreamer error: {} ({:?})", err.error(), err.debug());
                    return Err(anyhow::anyhow!("GStreamer pipeline error: {}", err.error()));
                }
                MessageView::Warning(warn_msg) => {
                    warn!("GStreamer warning: {:?}", warn_msg.message());
                }
                _ => (),
            }
        }

        pipeline.set_state(gst::State::Null)?;
        Ok(())
    }

    async fn run_moq_publisher(
        config: MoqConfig,
        frame_receiver: &mut mpsc::Receiver<(Bytes, u64)>,
    ) -> Result<()> {
        info!("Creating MoQ origin for relay at {}", config.relay_url);

        let origin = moq_native::moq_lite::Origin::produce();
        let client = moq_native::Client::new(moq_native::ClientConfig::default())?
            .with_publish(origin.consumer);
        let url = Url::parse(&config.relay_url)?;
        let _session = client.connect(url).await?;
        info!("Connected to MoQ relay");

        let mut broadcast = origin.producer.create_broadcast(&config.broadcast_path)
            .expect("Failed to create broadcast");

        let audio_track = moq_native::moq_lite::Track {
            name: config.track_name.clone(),
            priority: 1,
        };

        let mut track_producer = broadcast.create_track(audio_track);

        info!("Publishing broadcast {} with track {}",
              config.broadcast_path, config.track_name);

        let mut frame_count = 0u64;
        while let Some((data, _timestamp_us)) = frame_receiver.recv().await {
            frame_count += 1;
            if frame_count % 100 == 0 {
                info!("Published {} frames", frame_count);
            }

            let mut group = track_producer.append_group();
            group.write_frame(data);
            group.close();
        }

        info!("MoQ publisher finished");
        Ok(())
    }
}
