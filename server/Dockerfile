FROM rust:1-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY migrations ./migrations
RUN cargo build --release -p uniconsole-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/uniconsole-server /usr/local/bin/
EXPOSE 8080
CMD ["uniconsole-server"]
