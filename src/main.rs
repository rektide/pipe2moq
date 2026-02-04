use anyhow::Result;
use clap::{Parser, Subcommand, CommandFactory};
use clap_complete::{generate, Shell};
use figment2::{Figment, providers::{Env, Format, Toml}};
use pipe2moq::{Pipe2Moq, PipelineConfig, AudioConfig, MoqConfig};
use tracing_subscriber::{EnvFilter, fmt};
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(name = "pipe2moq")]
#[command(about = "Low-latency audio streaming from PipeWire to MoQ", long_about = None)]
struct Args {
    #[command(subcommand)]
    command: Option<Commands>,

    #[arg(short, long, default_value = "config.toml")]
    config: PathBuf,

    #[arg(short, long)]
    relay_url: Option<String>,

    #[arg(long)]
    broadcast_path: Option<String>,

    #[arg(long)]
    track_name: Option<String>,

    #[arg(long)]
    sink_name: Option<String>,

    #[arg(long)]
    bitrate: Option<u32>,

    #[arg(long)]
    sample_rate: Option<u32>,

    #[arg(long)]
    channels: Option<u32>,

    #[arg(long)]
    complexity: Option<u32>,

    #[arg(long)]
    frame_size: Option<u32>,

    #[arg(long, action)]
    verbose: bool,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Generate shell completions
    Completions {
        #[arg(short, long)]
        shell: Shell,
    },
}

#[derive(Debug, serde::Deserialize)]
struct ConfigFile {
    #[serde(default)]
    relay: RelayConfig,
    #[serde(default)]
    audio: AudioFileConfig,
    #[serde(default)]
    pipeline: PipelineFileConfig,
}

#[derive(Debug, serde::Deserialize, Default)]
struct RelayConfig {
    #[serde(default)]
    url: String,
    #[serde(default)]
    broadcast_path: String,
    #[serde(default)]
    track_name: String,
}

#[derive(Debug, serde::Deserialize, Default)]
struct AudioFileConfig {
    #[serde(default)]
    sample_rate: Option<u32>,
    #[serde(default)]
    channels: Option<u32>,
    #[serde(default)]
    bitrate: Option<u32>,
    #[serde(default)]
    application: Option<String>,
    #[serde(default)]
    complexity: Option<u32>,
    #[serde(default)]
    frame_size: Option<u32>,
}

#[derive(Debug, serde::Deserialize, Default)]
struct PipelineFileConfig {
    #[serde(default)]
    buffer_time: Option<u32>,
    #[serde(default)]
    latency_time: Option<u32>,
    #[serde(default)]
    sink_name: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    if let Some(Commands::Completions { shell }) = args.command {
        let mut cmd = Args::command();
        generate(shell, &mut cmd, "pipe2moq", &mut std::io::stdout());
        return Ok(());
    }

    let filter = if args.verbose {
        EnvFilter::new("debug")
    } else {
        EnvFilter::from_default_env()
            .add_directive("pipe2moq=info".parse()?)
            .add_directive("gstreamer=warn".parse()?)
    };

    fmt()
        .with_env_filter(filter)
        .init();

    let config: ConfigFile = Figment::new()
        .merge(Toml::file(args.config))
        .merge(Env::prefixed("PIPE2MOQ_"))
        .extract()?;

    let relay_url = args.relay_url
        .or_else(|| if config.relay.url.is_empty() { None } else { Some(config.relay.url) })
        .unwrap_or_else(|| "https://localhost:4443/anon".to_string());

    let broadcast_path = args.broadcast_path
        .or_else(|| if config.relay.broadcast_path.is_empty() { None } else { Some(config.relay.broadcast_path) })
        .unwrap_or_else(|| "/live/audio.hang".to_string());

    let track_name = args.track_name
        .or_else(|| if config.relay.track_name.is_empty() { None } else { Some(config.relay.track_name) })
        .unwrap_or_else(|| "audio".to_string());

    let audio = AudioConfig {
        sample_rate: args.sample_rate.or(config.audio.sample_rate).unwrap_or(48000),
        channels: args.channels.or(config.audio.channels).unwrap_or(2),
        bitrate: args.bitrate.or(config.audio.bitrate).unwrap_or(96000),
        application: config.audio.application.unwrap_or_else(|| "voip".to_string()),
        complexity: args.complexity.or(config.audio.complexity).unwrap_or(5),
        frame_size: config.audio.frame_size.unwrap_or(20),
    };

    let sink_name = args.sink_name.or(config.pipeline.sink_name);
    let buffer_time = config.pipeline.buffer_time.unwrap_or(20000);
    let latency_time = config.pipeline.latency_time.unwrap_or(10000);

    let pipeline_config = PipelineConfig {
        audio,
        buffer_time,
        latency_time,
        sink_name,
    };

    let moq_config = MoqConfig {
        relay_url,
        broadcast_path,
        track_name,
    };

    let app = Pipe2Moq::new(pipeline_config, moq_config);
    app.run().await
}
