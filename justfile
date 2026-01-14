# ConvergeContext - Append-only shared context store
#
# This service is derivative, not authoritative.
# The Rust engine remains the single semantic authority.

default: fmt lint test

# Format code
fmt:
    mix format

# Check formatting (CI)
fmt-check:
    mix format --check-formatted

# Run linter
lint:
    mix credo --strict

# Run tests
test:
    mix test

# Run tests with coverage
test-cover:
    mix test --cover

# Start interactive shell
run:
    iex -S mix

# Start in production mode
run-prod:
    MIX_ENV=prod iex -S mix

# Get dependencies
deps:
    mix deps.get

# Compile
compile:
    mix compile

# Build release
build:
    MIX_ENV=prod mix release

# Clean build artifacts
clean:
    mix clean
    rm -rf _build deps

# Setup project (first time)
setup: deps compile

# Full CI check
ci: fmt-check lint test

# Generate documentation
docs:
    mix docs

# Dialyzer type checking
dialyzer:
    mix dialyzer

# Docker release
IMAGE_NAME := "kpernyer/converge-ledger"
VERSION := "0.1.1"

docker-build:
    docker build . -t {{IMAGE_NAME}}:{{VERSION}} -t {{IMAGE_NAME}}:latest

docker-push:
    docker push {{IMAGE_NAME}}:{{VERSION}}
    docker push {{IMAGE_NAME}}:latest

# Hex release
publish:
    mix hex.publish
