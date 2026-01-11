# Converge Ledger Dockerfile
# Multi-stage build with Debian slim runtime
#
# Copyright (c) 2025 Aprio One AB
# Author: Kenneth Pernyer

# =============================================================================
# Stage 1: Build (Debian-based for glibc compatibility with Chainguard)
# =============================================================================
FROM elixir:1.17-otp-27-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set build environment
ENV MIX_ENV=prod

WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files first (for caching)
COPY mix.exs mix.lock ./
COPY config config

# Fetch and compile dependencies
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy application code
COPY lib lib
COPY priv priv

# Compile application
RUN mix compile

# Build release
RUN mix release converge_ledger

# =============================================================================
# Stage 2: Runtime (Debian slim - matching build OpenSSL version)
# =============================================================================
# Using Debian slim for:
# - OpenSSL version compatibility with build stage
# - Minimal attack surface (slim variant)
# - glibc compatibility (required by BEAM)
FROM debian:bookworm-slim AS runtime

# Install only required runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    libncurses6 \
    libssl3 \
    locales \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

# Create non-root user
RUN groupadd -g 1000 converge && \
    useradd -u 1000 -g converge -m converge

WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=converge:converge /app/_build/prod/rel/converge_ledger ./

# Set runtime environment
ENV HOME=/app
ENV MIX_ENV=prod
ENV RELEASE_NODE=converge_ledger
ENV GRPC_PORT=50051
# UTF-8 locale for Elixir
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Mnesia data directory
RUN mkdir -p /app/data/mnesia && chown -R converge:converge /app/data
ENV MNESIA_DIR=/app/data/mnesia

# Switch to non-root user
USER converge

# Expose gRPC port
EXPOSE 50051

# Health check using Erlang release command
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/app/bin/converge_ledger", "pid"]

# Start the application
ENTRYPOINT ["/app/bin/converge_ledger"]
CMD ["start"]
