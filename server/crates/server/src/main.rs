use tracing_subscriber::EnvFilter;
use uniconsole_server::{app, config::Config};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "uniconsole_server=info,tower_http=info".into()),
        )
        .init();

    app::run(Config::from_env()?).await
}
