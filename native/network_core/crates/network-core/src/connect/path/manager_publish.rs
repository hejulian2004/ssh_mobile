use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::connection::ConnectionProfile;
use crate::errors::CoreNetworkError;

use super::super::super::peer_supervisor::PeerId;
use super::super::active_route::PathCarrier;
use super::super::physical::{PathLease, PathProjection};
use super::super::{ActiveRoute, ActiveRouteCarrier, NoopPathCarrier, PathHandle, PathRegistry};
use super::{
    DirectPathState, DirectProbe, PathCloseReason, PathKind, PathSelection, PeerPathManager,
    RelayPathState,
};

impl PeerPathManager {
    pub(crate) fn new(peer_id: PeerId, registry: Arc<PathRegistry>) -> Self {
        Self {
            peer_id,
            registry,
            direct_path: None,
            direct_ready: None,
            relay_path: None,
            relay_ready: None,
            draining_paths: Vec::new(),
            direct_probe: None,
            draining: false,
            hard_closed: false,
        }
    }

    pub(crate) fn peer_id(&self) -> &PeerId {
        &self.peer_id
    }

    pub(crate) fn direct_ready(&self) -> Option<&PathHandle> {
        self.direct_ready.as_ref()
    }

    pub(crate) fn relay_ready(&self) -> Option<&PathHandle> {
        self.relay_ready.as_ref()
    }

    /// Return a weak projection tied to this manager's path identity. This is
    /// the integration seam for RuntimeState: it can index a PathHandle or
    /// PathProjection without retaining a second carrier lifetime owner.
    pub(crate) fn projection(&self, handle: &PathHandle) -> Option<PathProjection> {
        self.path_for_handle(handle).map(|path| PathProjection {
            handle: path.handle().clone(),
            path: Arc::downgrade(path),
        })
    }

    /// Transfer an authenticated route into the peer path owner. The route's
    /// carrier is moved into `PhysicalPath`; callers retain only the returned
    /// non-owning handle/projection and later acquire a `PathLease`.
    pub(crate) fn publish_ready_with_route(
        &mut self,
        route: ActiveRoute,
    ) -> Result<PathHandle, CoreNetworkError> {
        let profile = route.profile();
        self.publish_ready_with_carrier(
            profile,
            Box::new(ActiveRouteCarrier { route: Some(route) }),
        )
    }

    pub(crate) fn direct_state(&self) -> DirectPathState {
        if self
            .direct_path
            .as_ref()
            .is_some_and(|path| path.is_ready())
        {
            DirectPathState::Ready
        } else if self.direct_probe.is_some() {
            DirectPathState::Probe
        } else {
            DirectPathState::None
        }
    }

    pub(crate) fn relay_state(&self) -> RelayPathState {
        if self.relay_path.as_ref().is_some_and(|path| path.is_ready()) {
            RelayPathState::Ready
        } else {
            RelayPathState::None
        }
    }

    pub(crate) fn direct_probe(&self) -> Option<&DirectProbe> {
        self.direct_probe.as_ref()
    }

    pub(crate) fn publish_ready(
        &mut self,
        profile: ConnectionProfile,
    ) -> Result<PathHandle, CoreNetworkError> {
        self.publish_ready_with_carrier_at(profile, Box::new(NoopPathCarrier), Instant::now())
    }

    pub(crate) fn publish_ready_with_carrier(
        &mut self,
        profile: ConnectionProfile,
        carrier: Box<dyn PathCarrier>,
    ) -> Result<PathHandle, CoreNetworkError> {
        self.publish_ready_with_carrier_at(profile, carrier, Instant::now())
    }

    pub(in crate::connect::path) fn publish_ready_with_carrier_at(
        &mut self,
        profile: ConnectionProfile,
        carrier: Box<dyn PathCarrier>,
        created_at: Instant,
    ) -> Result<PathHandle, CoreNetworkError> {
        if self.draining || self.hard_closed {
            return Err(CoreNetworkError::Cancelled);
        }

        let kind = PathKind::from_profile(profile);
        let new_capability_mask = super::super::super::profile_capability_mask(profile);
        if new_capability_mask == 0 {
            carrier.close(PathCloseReason::HardClose);
            return Err(CoreNetworkError::CapabilityUnavailable);
        }

        // A path can be closed externally through the weak registry during
        // peer teardown. Do not let that dead slot block the next
        // authenticated publication.
        match kind {
            PathKind::Direct
                if self
                    .direct_path
                    .as_ref()
                    .is_some_and(|path| !path.is_ready()) =>
            {
                self.take_direct();
            }
            PathKind::Relay
                if self
                    .relay_path
                    .as_ref()
                    .is_some_and(|path| !path.is_ready()) =>
            {
                self.take_relay();
            }
            _ => {}
        }

        let old_path = match kind {
            PathKind::Direct => self.direct_path.as_ref(),
            PathKind::Relay => self.relay_path.as_ref(),
        };

        if let Some(old_path) = old_path {
            let old_capability_mask = old_path.handle().capability_mask();
            let needed_capabilities = match kind {
                PathKind::Direct => self
                    .direct_probe
                    .as_ref()
                    .map(|probe| probe.required_capabilities),
                PathKind::Relay => None,
            };
            let strict_needed_superset = new_capability_mask != old_capability_mask
                && new_capability_mask & old_capability_mask == old_capability_mask
                && needed_capabilities.is_some_and(|needed| new_capability_mask & needed == needed);

            // Once a compatible Ready path exists, it is the winner. An
            // equivalent or weaker late path is a failed attempt, not a
            // replacement. Only a capability superset needed by an active
            // Direct demand may promote and normal-retire the old path.
            if !strict_needed_superset {
                carrier.close(PathCloseReason::HardClose);
                return Err(CoreNetworkError::StaleAttempt);
            }
        } else if kind == PathKind::Direct
            && self.direct_probe.as_ref().is_some_and(|probe| {
                new_capability_mask & probe.required_capabilities != probe.required_capabilities
            })
        {
            // With no Ready path, the first authenticated path still has to
            // satisfy the capability that caused the Direct probe.
            carrier.close(PathCloseReason::HardClose);
            return Err(CoreNetworkError::CapabilityUnavailable);
        }

        let path = self
            .registry
            .create_path(&self.peer_id, profile, carrier, created_at)?;
        let handle = path.handle().clone();
        let old_path = match kind {
            PathKind::Direct => self.take_direct(),
            PathKind::Relay => self.take_relay(),
        };
        if let Some(old_path) = old_path {
            self.retire_path(old_path, PathCloseReason::NormalRetire);
        }
        match kind {
            PathKind::Direct => {
                self.direct_ready = Some(handle.clone());
                self.direct_path = Some(path);
                self.direct_probe = None;
            }
            PathKind::Relay => {
                self.relay_ready = Some(handle.clone());
                self.relay_path = Some(path);
            }
        }
        Ok(handle)
    }

    /// Start or extend one Direct probe. A stronger request extends the
    /// current demand rather than creating another physical establishment.
    pub(crate) fn ensure_direct_probe(
        &mut self,
        generation: u64,
        required_capabilities: u8,
        budget: Duration,
    ) -> Result<&DirectProbe, CoreNetworkError> {
        if self.draining || self.hard_closed {
            return Err(CoreNetworkError::Cancelled);
        }
        let deadline = Instant::now() + budget;
        match self.direct_probe.as_mut() {
            Some(probe) => {
                if probe.generation != generation {
                    return Err(CoreNetworkError::StaleAttempt);
                }
                probe.extend(required_capabilities, deadline);
            }
            None => {
                self.direct_probe = Some(DirectProbe {
                    generation,
                    required_capabilities,
                    deadline,
                });
            }
        }
        Ok(self.direct_probe.as_ref().expect("probe just installed"))
    }

    pub(crate) fn finish_direct_probe(&mut self, generation: u64) -> bool {
        if self
            .direct_probe
            .as_ref()
            .is_some_and(|probe| probe.generation == generation)
        {
            self.direct_probe = None;
            true
        } else {
            false
        }
    }

    /// Select Direct immediately when compatible. If it is unavailable, an
    /// already Ready Relay is usable while Direct probing continues.
    pub(crate) fn select(&self, required_capabilities: u8) -> Option<PathSelection> {
        self.select_with_authorization(required_capabilities, true, true)
    }

    /// Select a ready path after applying the peer's explicit route
    /// authorization.  The unrestricted [select] form is retained for the
    /// native path-manager unit seams; RuntimeState uses this policy-aware
    /// form for all production business selection.
    pub(crate) fn select_with_authorization(
        &self,
        required_capabilities: u8,
        allow_direct: bool,
        allow_relay: bool,
    ) -> Option<PathSelection> {
        if allow_direct
            && self
                .direct_path
                .as_ref()
                .is_some_and(|path| path.is_acquirable(required_capabilities))
        {
            return Some(PathSelection::Direct);
        }
        if allow_relay
            && self
                .relay_path
                .as_ref()
                .is_some_and(|path| path.is_acquirable(required_capabilities))
        {
            return Some(PathSelection::Relay);
        }
        None
    }

    pub(crate) fn acquire(
        &self,
        required_capabilities: u8,
    ) -> Result<(PathSelection, PathLease), CoreNetworkError> {
        self.acquire_with_authorization(required_capabilities, true, true)
    }

    /// Acquire a path only from the route topologies authorized for this
    /// peer.  Filtering is performed while the path owner is locked, before a
    /// borrower lease can be created, so an unauthorized route is never
    /// exposed to business code as a selectable candidate.
    pub(crate) fn acquire_with_authorization(
        &self,
        required_capabilities: u8,
        allow_direct: bool,
        allow_relay: bool,
    ) -> Result<(PathSelection, PathLease), CoreNetworkError> {
        if allow_direct {
            if let Some(path) = self.direct_path.as_ref() {
                if path.is_acquirable(required_capabilities) {
                    match path.try_acquire() {
                        Ok(lease) => return Ok((PathSelection::Direct, lease)),
                        Err(CoreNetworkError::StaleAttempt) => {}
                        Err(error) => return Err(error),
                    }
                }
            }
        }
        if allow_relay {
            if let Some(path) = self.relay_path.as_ref() {
                if path.is_acquirable(required_capabilities) {
                    match path.try_acquire() {
                        Ok(lease) => return Ok((PathSelection::Relay, lease)),
                        Err(CoreNetworkError::StaleAttempt) => {}
                        Err(error) => return Err(error),
                    }
                }
            }
        }
        Err(CoreNetworkError::NoRoute)
    }

    pub(crate) fn acquire_relay(
        &self,
        required_capabilities: u8,
    ) -> Result<PathLease, CoreNetworkError> {
        let path = self
            .relay_path
            .as_ref()
            .filter(|path| path.is_acquirable(required_capabilities))
            .ok_or(CoreNetworkError::NoRoute)?;
        path.try_acquire()
    }
}
