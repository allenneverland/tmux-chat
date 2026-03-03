# syntax=docker/dockerfile:1

FROM rust:1-bookworm AS dev
RUN rustup component add rustfmt
WORKDIR /workspace

FROM dev AS builder
COPY . /workspace
RUN cargo build --release -p push-server

FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /workspace/target/release/push-server /usr/local/bin/push-server
EXPOSE 8790
ENTRYPOINT ["push-server"]

