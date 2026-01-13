# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1.0 | :x:                |

## Trust Model

**Converge Ledger is designed to run in a trusted, private network.**

It is **NOT** intended to be exposed directly to the public internet. It assumes:

1.  **Network Isolation:** Access to the gRPC port and Erlang distribution ports is restricted to trusted services (Converge Core) via firewalls, VPCs, or service meshes.
2.  **Trusted Peers:** All nodes in the cluster share a secret Erlang Cookie and are trusted.
3.  **Single Writer:** While not enforced by cryptography, the system assumes a single authoritative writer (Converge Core) for any given context.

## Authentication & Authorization

The Ledger currently **does not implement** application-level authentication (e.g., API keys, JWTs).

*   **gRPC:** We recommend running behind a sidecar (like Envoy) or using a Service Mesh (like Linkerd/Istio) to handle mTLS and identity if strict access control is required.
*   **Erlang Distribution:** Nodes authenticate using a shared secret "cookie". **You must set a strong, random cookie** in production.

## Known Risks & Mitigations

| Risk | Context | Mitigation |
| :--- | :--- | :--- |
| **Unauthenticated Access** | gRPC port is open to anyone on the network. | Restrict network access to the Converge Core IPs/Subnet. |
| **Cluster Injection** | Attackers on the same subnet can join the cluster via Gossip. | Use strong Erlang Cookies. Isolate the VLAN. |
| **Denial of Service** | Large payloads can consume memory (Mnesia is RAM-heavy). | Implement gRPC message size limits (default is often 4MB). Monitor memory usage. |
| **Code Injection** | Erlang distribution allows remote code execution. | **CRITICAL:** Never expose distribution ports (4369, 9000+) to the internet. |

## Reporting a Vulnerability

If you discover a security vulnerability, please do **NOT** open a public issue.

*   Email: security@converge.zone
*   We will acknowledge your report within 48 hours.
*   We will provide a fix or workaround within 30 days.
