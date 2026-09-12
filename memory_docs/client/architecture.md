> Last updated: 2026-09-12

# Client Architecture

`apps/ssh_mobile_full/lib/app/` is the composition root. `AppRuntimeFactory`
creates App-scoped resources, `AppRuntime` owns lifecycle, and Feature Route
Scopes create/dispose route ViewModels.

Network V2 setup loads the App-owned Ed25519/X25519 identity bundle, configures
one `NetworkRuntime` once per App process, and creates one shared
`NetworkFacade`. LAN, SSH, SFTP, Realtime, and Relay borrow it; Features may
release subscriptions and HTTP/Discovery/Transfer resources but never stop,
destroy, or reconfigure the runtime/facade.

Stable boundaries:

- Core owns cross-Feature contracts and shared UI/data foundations; Features own
  presentation, application logic, repositories, and Feature databases.
- App Shell adapters inject Ports and join Features to App resources. Features
  never import another Feature implementation or another package's `/src/`.
- Shared SSH is lease-based: Features release leases, not the App-owned manager.
- Structured data stays in the owning Feature/Core database; App logs are the
  only App-owned diagnostics store. Secrets remain in secure storage.
- LAN Control V2 models Trust, Discovery, Reachability, Route, and Relay
  Enrollment/Authorization separately. The durable Trust Record is not the
  dynamic Discovery model; `removePeer` means explicit trust revoke/unpair.

Full designs: [modular refactor](../../docs/architecture/MODULAR_REFACTOR_PLAN.md),
[module dependency](../../docs/architecture/MODULE_DEPENDENCY.md),
[resource ownership](../../docs/architecture/RESOURCE_OWNERSHIP.md), and
[compatibility inventory](../../docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md).

## PR74 ownership map

`AppScreenSharePeerArbitrationRegistry` stores only one pending/active intent
per remote peer and uses the public Feature comparator; it owns no resource.
`AppScreenShareSessionLease` owns only one SDK Realtime session's stop,
terminal wait, and exact release. `AppScreenShareMediaCoordinator` owns the
route-scoped endpoint, capture/encoder, decoder, and opaque surface/Texture
lease. Navigator success transfers the session lease to the route; route
teardown stops media before session cleanup for senders, and stops receive
ingress/session before releasing receiver presentation. The global incoming
host uses LAN's receive trust capability, never the TrustStore directly.
