use clap::{Parser, Subcommand};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[derive(Parser, Debug)]
#[command(name = "host-agent")]
#[command(version)]
#[command(about = "Host relay agent for Reattach notifications")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Install service and hook integration
    Install,
    /// Pair host agent with push server
    Pair {
        /// Pairing token issued by push server
        #[arg(long)]
        token: String,
    },
    /// Run host agent daemon
    Run,
    /// Show host agent status
    Status,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "host_agent=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let cli = Cli::parse();

    match cli.command {
        Commands::Install => {
            println!("host-agent install is not implemented yet");
        }
        Commands::Pair { token } => {
            println!(
                "host-agent pair is not implemented yet (received token length: {})",
                token.len()
            );
        }
        Commands::Run => {
            println!("host-agent run is not implemented yet");
        }
        Commands::Status => {
            println!("host-agent status is not implemented yet");
        }
    }
}

