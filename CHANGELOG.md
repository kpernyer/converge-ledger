# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-01-10

### Added

- Initial release of Converge Ledger
- **Append-only storage** with Mnesia backend
  - Sequential, immutable entries per context
  - Monotonic sequence numbers
  - Nanosecond timestamps
- **gRPC API** (Protobuf-based)
  - `Append` - Add entries to a context
  - `Get` - Retrieve entries with filters (key, after_sequence, limit)
  - `Snapshot` - Serialize entire context to binary
  - `Load` - Restore context from snapshot
  - `Watch` - Real-time streaming of new entries
- **WatchRegistry** for subscription management
  - Per-context subscriptions
  - Optional key filtering
  - Automatic cleanup on process exit
- **OTP Application** with supervision tree
- **Clustering support** via libcluster
- Documentation
  - README with architecture overview
  - ARCHITECTURE.md with design decisions
  - CONTRIBUTING.md with development guidelines

### Design Principles

- Derivative, not authoritative (Rust engine holds truth)
- Append-only (no updates, deletes, or rewrites)
- Eventually consistent (CRDT-style without conflicts)
- Fail-safe (data loss doesn't break correctness)

[Unreleased]: https://github.com/kpernyer/converge-ledger/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kpernyer/converge-ledger/releases/tag/v0.1.0
