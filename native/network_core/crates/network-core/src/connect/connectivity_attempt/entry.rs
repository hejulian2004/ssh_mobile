use super::*;

impl ConnectivityAttemptCoordinator {
    /// 建连唯一入口（§37），默认 CommunicationClass=ReliableMessage（§17）。
    /// 成功后返回 `()`；失败返回类型化错误（§33）。
    ///
    /// 这是 FFI 默认路径的便捷入口（命令面经 `connect_with_class` 到达）；
    /// 保留它以让默认调用保持工作。
    #[allow(dead_code)]
    pub(crate) async fn connect(&self, peer_id: &str) -> Result<(), ProtocolError> {
        self.connect_with_class(peer_id, CommunicationClass::ReliableMessage)
            .await
    }

    /// Run only the bounded Direct stage for a recovery probe.  A healthy
    /// Relay path remains available while this operation runs; this method
    /// never enters Resolve or Relay fallback.
    pub(crate) async fn probe_direct(
        &self,
        peer_id: &str,
        class: CommunicationClass,
    ) -> Result<(), ProtocolError> {
        let endpoint = self
            .state
            .lifecycle
            .endpoint
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::InvalidArgument,
                    "runtime is not configured",
                    "direct_probe",
                    peer_id,
                )
            })?;
        let identity = self
            .state
            .lifecycle
            .identity
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::InvalidArgument,
                    "runtime is not configured",
                    "direct_probe",
                    peer_id,
                )
            })?;
        let peer = self
            .state
            .peers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    "peer has no configured route",
                    "direct_probe",
                    peer_id,
                )
            })?;
        if !self
            .state
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "direct route is not authorized",
                "direct_probe",
                peer_id,
            ));
        }
        let capability = communication_class_capability(default_communication_class(class));
        if self
            .try_stage_a_direct(peer_id, &peer, endpoint, identity, capability)
            .await?
        {
            Ok(())
        } else {
            Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "direct recovery probe did not produce a path",
                "direct_probe",
                peer_id,
            ))
        }
    }

    /// 带 CommunicationClass 的建连入口（§17/§37）。这是 FFI 面向的连接表面：
    /// 调用方指定本次业务所需能力，连接层只用它查询/选择实际 ConnectionProfile；
    /// ConnectionSession 不保存最近一次业务类别。
    pub(crate) async fn connect_with_class(
        &self,
        peer_id: &str,
        class: CommunicationClass,
    ) -> Result<(), ProtocolError> {
        let class = default_communication_class(class);
        self.connect_with_capabilities(peer_id, communication_class_capability(class))
            .await
    }

    /// Internal connectivity entry point used by the peer supervisor when
    /// concurrent business requests have been merged into one capability mask.
    pub(crate) async fn connect_with_capabilities(
        &self,
        peer_id: &str,
        capability: u8,
    ) -> Result<(), ProtocolError> {
        match tokio::time::timeout(
            crate::connect::OVERALL_CONNECT_BUDGET,
            self.connect_with_capabilities_bounded(peer_id, capability, None),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "overall connectivity budget elapsed",
                "connect",
                peer_id,
            )),
        }
    }

    /// Command-owned connectivity entry point. The command id is carried on
    /// causal route-attempt events so Dart can resolve an exact operation
    /// context even when another operation targets the same peer.
    pub(crate) async fn connect_with_capabilities_for_command(
        &self,
        peer_id: &str,
        capability: u8,
        command_id: &str,
    ) -> Result<(), ProtocolError> {
        match tokio::time::timeout(
            crate::connect::OVERALL_CONNECT_BUDGET,
            self.connect_with_capabilities_bounded(peer_id, capability, Some(command_id)),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                "overall connectivity budget elapsed",
                "connect",
                peer_id,
            )),
        }
    }

    async fn connect_with_capabilities_bounded(
        &self,
        peer_id: &str,
        capability: u8,
        command_id: Option<&str>,
    ) -> Result<(), ProtocolError> {
        let connect_deadline = Instant::now() + crate::connect::OVERALL_CONNECT_BUDGET;
        let state = Arc::clone(&self.state);
        // 配置/身份/对端校验。
        let endpoint = state
            .lifecycle
            .endpoint
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::InvalidArgument,
                    "runtime is not configured",
                    "connect",
                    peer_id,
                )
            })?;
        let identity = state
            .lifecycle
            .identity
            .read()
            .await
            .clone()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::InvalidArgument,
                    "runtime is not configured",
                    "connect",
                    peer_id,
                )
            })?;
        let peer = state
            .peers
            .read()
            .await
            .get(peer_id)
            .cloned()
            .ok_or_else(|| {
                protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    "peer has no configured route",
                    "connect",
                    peer_id,
                )
            })?;
        // UpsertPeerV2 writes the route policy with the peer. A missing record
        // is not authorization.
        let authorization = state
            .peer_route_authorizations
            .read()
            .await
            .get(peer_id)
            .copied();
        if !authorization.is_some_and(|authorization| authorization.direct) {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::NoRoute,
                "direct route is not authorized",
                "connect",
                peer_id,
            ));
        }

        // Stage A is deliberately independent of the Relay control plane.  A
        // fresh monotonic remote cache/configured endpoint is enough to start
        // the bounded direct race; an already healthy path is handled by the
        // pre-control reuse fast path below. Resolve/Offer are only entered after this
        // pre-control reuse fast path and after the uncoordinated attempt fails.
        if self
            .try_stage_a_direct(
                peer_id,
                &peer,
                endpoint.clone(),
                identity.clone(),
                capability,
            )
            .await?
        {
            return Ok(());
        }

        // Any healthy path is also a reuse fast path.  It must be
        // decided before Stage B opens the one-shot Resolve → Offer ticket:
        // the frozen ConnectivityOffer has no target field, so emitting an
        // Offer and then returning from reuse would leave an unsolicited
        // server-side coordination ticket (and possibly a leaked waiter).
        if let Some(reused) = self.try_reuse_before_control(peer_id, capability).await? {
            self.finish_reuse(peer_id, reused).await;
            return Ok(());
        }

        // -----------------------------------------------------------------
        // 1. RESOLVING（§10）：Stage B owns one atomic Resolve → Offer
        // coordination transaction. The control client holds its narrow gate
        // through the authoritative Resolve and Offer enqueue, then returns
        // the Resolve snapshot plus an answer waiter. This keeps the target
        // binding coherent on the target-less ConnectivityOffer wire frame.
        // -----------------------------------------------------------------
        let (control, ready_presence_ttl) = {
            let control = self
                .state
                .relay
                .control
                .read()
                .await
                .clone()
                .ok_or_else(|| {
                    protocol_error_with_peer(
                        NetworkErrorCode::RelayError,
                        "authoritative Resolve is unavailable",
                        "connect",
                        peer_id,
                    )
                })?;
            if !control.is_usable().await {
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::RelayError,
                    "authoritative Resolve control plane is unavailable",
                    "connect",
                    peer_id,
                ));
            }
            let ready_presence_ttl = control.ready_presence_ttl();
            (control, ready_presence_ttl)
        };
        let (local_epoch, local_revision, local_snapshot) = {
            let manager = self.state.local_discovery.read().await;
            manager
                .as_ref()
                .map(|manager| {
                    (
                        manager.runtime_epoch(),
                        manager.revision(),
                        Some(manager.snapshot()),
                    )
                })
                .unwrap_or((RuntimeEpoch { high: 0, low: 0 }, 1, None))
        };
        self.connect_after_preflight(CoordinatedConnectContext {
            peer_id,
            capability,
            command_id,
            connect_deadline,
            state,
            endpoint,
            identity,
            peer,
            authorization,
            control,
            ready_presence_ttl,
            local_epoch,
            local_revision,
            local_snapshot,
        })
        .await
    }
}
