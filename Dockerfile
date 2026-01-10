# Converge Ledger Dockerfile
# Multi-stage build for minimal production image
#
# Copyright (c) 2025 Aprio One AB
# Author: Kenneth Pernyer

# =============================================================================
# Stage 1: Build
# =============================================================================
FROM elixir:1.17-otp-27-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    npm

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
# Stage 2: Runtime
# =============================================================================
FROM alpine:3.22 AS runtime

# Install runtime dependencies (must match OpenSSL version from build stage)
RUN apk add --no-cache \
    libstdc++ \
    ncurses-libs \
    openssl \
    libgcc

# Create non-root user
RUN addgroup -g 1000 converge && \
    adduser -u 1000 -G converge -s /bin/sh -D converge

WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=converge:converge /app/_build/prod/rel/converge_ledger ./

# Set runtime environment
ENV HOME=/app
ENV MIX_ENV=prod
ENV RELEASE_NODE=converge_ledger
ENV GRPC_PORT=50051

# Mnesia data directory
RUN mkdir -p /app/data/mnesia && chown -R converge:converge /app/data
ENV MNESIA_DIR=/app/data/mnesia

# Switch to non-root user
USER converge

# Expose gRPC port
EXPOSE 50051

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD nc -z localhost ${GRPC_PORT} || exit 1

# Start the application
CMD ["bin/converge_ledger", "start"]
