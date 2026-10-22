> Last updated: 2026-10-22

# PR49 Dependency Architecture Graph

Status: **PASS**

The dependency direction is layered and ownership-safe. The SDK exposes
contracts; it does not create HTTP clients, sockets, FFI handles, databases,
or native runtime resources.

## Dart package graph

```text
Feature packages ───────────────┐
                                ├──> network_sdk (public contracts/facades)
App Shell ──────────────────────┘              │
     │                                         │ injected ports/adapters
     ├──> ssh_mobile_network_native ──────────┘
     └──> network_transport ───> ssh_mobile_network_native

network_sdk
  ├──> dart:async / dart:convert / dart:typed_data
  └──> no production dependency on Feature, App, FFI, Socket, HTTP, or
      secure-storage implementations
```

The graph is intentionally App-mediated at the native boundary: the current
workspace has no direct `network_sdk -> ssh_mobile_network_native` dependency.
This keeps the SDK portable and lets the App Shell own the native runtime.

Within `network_sdk`, the public barrel exports the stable contracts. The V2
library parts group command ownership into Connection, Identity, Transfer,
Realtime, and Relay lifecycle domains; none imports another Feature or a
transport implementation.

## Rust cargo graph

```text
network-ffi ───────────────> network-core
     │                           ├──> network-protocol
     │                           ├──> network-identity
     │                           ├──> network-nat
     │                           ├──> network-quic
     │                           ├──> network-transfer
     │                           ├──> network-relay ───> network-protocol
     │                           ├──> network-transport
     │                           └──> network-webrtc
     └──────────────────────> network-protocol

network-relay-proto ───────> prost (standalone relay codec package)

network-core internal domain ports
RuntimeState ──> RelayDomainState + TransferDomainState
RuntimeState ──> RelayTransferPort ──> Relay transfer adapter
RuntimeState ──> TransferRelayPort ──> Transfer recovery adapter

Relay production ownership
  relay.rs ──> relay_control/
            ├──> relay_data/
            └──> relay_transfer/
  transfer.rs ──> transfer_operations/

The two internal ports are the only Relay↔Transfer command/recovery bridge;
`relay.rs` and `transfer.rs` no longer call each other's module-private entry
points directly. RuntimeState remains the lifecycle root, while lifecycle
resources are grouped in `RuntimeLifecycleState` and Relay/Transfer business
state is grouped in their domain aggregates. Relay control/data/transfer and
Transfer operation functions are physically separated behind the root
re-exports without changing the public crate surface.
```

The permitted product direction is:

```text
App / Feature
      ↓
SDK contract
      ↓
App-owned native adapter / FFI
      ↓
Rust Core
```

## Forbidden edges checked

- No Core crate depends on the Dart SDK.
- No SDK library imports a Feature or App `/src/` implementation.
- No Feature imports another Feature implementation through `/src/`.
- No `network_sdk` production code imports `dart:io`, creates an `HttpClient`,
  or owns a native runtime.
- No new Core → SDK or Feature → Feature implementation edge was introduced.

The current state, lifecycle, and cross-domain ownership boundaries are typed
and tested. No dependency-cycle-producing split is authorized.
