//! Registry of opaque native media endpoint leases.

use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex, Weak,
};

#[cfg(test)]
use network_webrtc::{H264AdaptationTarget, MediaDirection};
use network_webrtc::{RealtimeIoDriver, RealtimeIoDriverHandle, WebRtcError};

use super::*;

static NEXT_RUNTIME_GENERATION: AtomicU64 = AtomicU64::new(1);
static NEXT_ENDPOINT_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone)]
struct SessionBinding {
    peer_id: String,
    generation: u64,
    driver: Weak<Mutex<RealtimeIoDriver>>,
}

#[derive(Clone)]
pub(crate) struct EndpointLease {
    pub(crate) realtime_id: String,
    pub(crate) peer_id: String,
    pub(crate) runtime_generation: u64,
    pub(crate) session_generation: u64,
    pub(crate) direction: RealtimeMediaDirection,
    pub(crate) driver: Weak<Mutex<RealtimeIoDriver>>,
}

/// Runtime-owned registry for native media endpoint leases.
pub(crate) struct RealtimeMediaRegistry {
    runtime_generation: u64,
    session_bindings: HashMap<String, SessionBinding>,
    pub(crate) endpoints: HashMap<RealtimeMediaEndpointId, EndpointLease>,
}

impl RealtimeMediaRegistry {
    pub(crate) fn new() -> Self {
        Self {
            runtime_generation: NEXT_RUNTIME_GENERATION.fetch_add(1, Ordering::Relaxed),
            session_bindings: HashMap::new(),
            endpoints: HashMap::new(),
        }
    }

    pub(crate) fn create(
        &mut self,
        realtime_id: &str,
        peer_id: &str,
        direction: RealtimeMediaDirection,
        expected_generation: u64,
        session_generation: u64,
        driver: &RealtimeIoDriverHandle,
    ) -> Result<RealtimeMediaEndpointId, RealtimeMediaError> {
        if expected_generation != session_generation {
            return Err(RealtimeMediaError::StaleGeneration);
        }
        let driver_weak = Arc::downgrade(driver);
        let session_generation = match self.session_bindings.get(realtime_id) {
            Some(existing)
                if existing.peer_id == peer_id
                    && existing.generation == session_generation
                    && Weak::ptr_eq(&existing.driver, &driver_weak) =>
            {
                existing.generation
            }
            Some(_) => {
                self.invalidate_realtime(realtime_id);
                self.insert_session_binding(
                    realtime_id,
                    peer_id,
                    session_generation,
                    driver_weak.clone(),
                )
            }
            None => self.insert_session_binding(
                realtime_id,
                peer_id,
                session_generation,
                driver_weak.clone(),
            ),
        };

        if self.endpoints.values().any(|endpoint| {
            endpoint.realtime_id == realtime_id
                && endpoint.peer_id == peer_id
                && endpoint.runtime_generation == self.runtime_generation
                && endpoint.session_generation == session_generation
                && endpoint.direction == direction
        }) {
            return Err(RealtimeMediaError::DuplicateEndpoint);
        }

        let endpoint_id = RealtimeMediaEndpointId(NEXT_ENDPOINT_ID.fetch_add(1, Ordering::Relaxed));
        self.endpoints.insert(
            endpoint_id,
            EndpointLease {
                realtime_id: realtime_id.to_owned(),
                peer_id: peer_id.to_owned(),
                runtime_generation: self.runtime_generation,
                session_generation,
                direction,
                driver: driver_weak,
            },
        );
        Ok(endpoint_id)
    }

    fn insert_session_binding(
        &mut self,
        realtime_id: &str,
        peer_id: &str,
        generation: u64,
        driver: Weak<Mutex<RealtimeIoDriver>>,
    ) -> u64 {
        self.session_bindings.insert(
            realtime_id.to_owned(),
            SessionBinding {
                peer_id: peer_id.to_owned(),
                generation,
                driver,
            },
        );
        generation
    }

    pub(crate) fn invalidate_realtime(&mut self, realtime_id: &str) {
        self.session_bindings.remove(realtime_id);
        self.endpoints
            .retain(|_, endpoint| endpoint.realtime_id != realtime_id);
    }

    pub(crate) fn invalidate_all(&mut self) {
        self.session_bindings.clear();
        self.endpoints.clear();
    }

    pub(crate) fn snapshot_endpoint(
        &self,
        endpoint_id: RealtimeMediaEndpointId,
        direction: RealtimeMediaDirection,
    ) -> Result<EndpointLease, RealtimeMediaError> {
        let endpoint = self.endpoint_lease(endpoint_id)?;
        if endpoint.direction != direction {
            return Err(RealtimeMediaError::DirectionMismatch);
        }
        Ok(endpoint)
    }

    pub(crate) fn endpoint_lease(
        &self,
        endpoint_id: RealtimeMediaEndpointId,
    ) -> Result<EndpointLease, RealtimeMediaError> {
        let endpoint = self
            .endpoints
            .get(&endpoint_id)
            .ok_or(RealtimeMediaError::StaleEndpoint)?;
        if endpoint.runtime_generation != self.runtime_generation {
            return Err(RealtimeMediaError::StaleEndpoint);
        }
        Ok(endpoint.clone())
    }

    #[cfg(test)]
    pub(crate) fn session_generation(&self, endpoint_id: RealtimeMediaEndpointId) -> Option<u64> {
        self.endpoints
            .get(&endpoint_id)
            .map(|endpoint| endpoint.session_generation)
    }

    pub(crate) fn validate_endpoint(
        &self,
        endpoint_id: RealtimeMediaEndpointId,
        realtime_id: &str,
        peer_id: &str,
        generation: u64,
        direction: RealtimeMediaDirection,
    ) -> Result<(), RealtimeMediaError> {
        let endpoint = self
            .endpoints
            .get(&endpoint_id)
            .ok_or(RealtimeMediaError::StaleEndpoint)?;
        if endpoint.realtime_id != realtime_id || endpoint.peer_id != peer_id {
            return Err(RealtimeMediaError::PeerMismatch);
        }
        if endpoint.session_generation != generation {
            return Err(RealtimeMediaError::StaleGeneration);
        }
        if endpoint.direction != direction {
            return Err(RealtimeMediaError::DirectionMismatch);
        }
        if endpoint.runtime_generation != self.runtime_generation {
            return Err(RealtimeMediaError::StaleEndpoint);
        }
        Ok(())
    }

    // These registry-only helpers keep the deterministic unit tests focused
    // on lease semantics without reintroducing a registry lock around the
    // production hot path. Runtime callers use the free functions below,
    // which snapshot the lease and acquire only the driver's owner lock.
    #[cfg(test)]
    pub(crate) fn with_endpoint<T>(
        &self,
        endpoint_id: RealtimeMediaEndpointId,
        direction: RealtimeMediaDirection,
        operation: impl FnOnce(&mut RealtimeIoDriver) -> Result<T, WebRtcError>,
    ) -> Result<T, RealtimeMediaError> {
        let endpoint = self.snapshot_endpoint(endpoint_id, direction)?;
        with_endpoint_lease(endpoint, operation)
    }

    #[cfg(test)]
    pub(crate) fn release(
        &mut self,
        endpoint_id: RealtimeMediaEndpointId,
    ) -> Result<(), RealtimeMediaError> {
        let Some(endpoint) = self.endpoints.get(&endpoint_id).cloned() else {
            return Ok(());
        };
        let driver = endpoint
            .driver
            .upgrade()
            .ok_or(RealtimeMediaError::StaleEndpoint)?;
        let direction = match endpoint.direction {
            RealtimeMediaDirection::Send => MediaDirection::Sendonly,
            RealtimeMediaDirection::Receive => MediaDirection::Recvonly,
        };
        let mut driver = driver
            .lock()
            .map_err(|_| RealtimeMediaError::DriverUnavailable)?;
        driver
            .peer_mut()
            .clear_h264_screen_video(direction)
            .map_err(|_| RealtimeMediaError::DriverUnavailable)?;
        self.endpoints.remove(&endpoint_id);
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn request_keyframe(
        &self,
        endpoint_id: RealtimeMediaEndpointId,
    ) -> Result<(), RealtimeMediaError> {
        let endpoint = self.endpoint_lease(endpoint_id)?;
        let direction = match endpoint.direction {
            RealtimeMediaDirection::Send => MediaDirection::Sendonly,
            RealtimeMediaDirection::Receive => MediaDirection::Recvonly,
        };
        with_endpoint_lease(endpoint, |driver| {
            driver
                .peer_mut()
                .request_h264_screen_video_keyframe(direction)
        })
    }

    #[cfg(test)]
    pub(crate) fn reset_decoder(
        &self,
        endpoint_id: RealtimeMediaEndpointId,
    ) -> Result<(), RealtimeMediaError> {
        let endpoint = self.snapshot_endpoint(endpoint_id, RealtimeMediaDirection::Receive)?;
        with_endpoint_lease(endpoint, |driver| {
            driver.peer_mut().reset_h264_screen_video_decoder()
        })
    }

    #[cfg(test)]
    pub(crate) fn apply_adaptation(
        &self,
        endpoint_id: RealtimeMediaEndpointId,
        target: H264AdaptationTarget,
    ) -> Result<(), RealtimeMediaError> {
        let endpoint = self.snapshot_endpoint(endpoint_id, RealtimeMediaDirection::Send)?;
        with_endpoint_lease(endpoint, |driver| {
            driver.peer_mut().apply_h264_screen_video_adaptation(target)
        })
    }
}

pub(crate) fn with_endpoint_lease<T>(
    endpoint: EndpointLease,
    operation: impl FnOnce(&mut RealtimeIoDriver) -> Result<T, WebRtcError>,
) -> Result<T, RealtimeMediaError> {
    let driver = endpoint
        .driver
        .upgrade()
        .ok_or(RealtimeMediaError::StaleEndpoint)?;
    let mut driver = driver
        .lock()
        .map_err(|_| RealtimeMediaError::DriverUnavailable)?;
    operation(&mut driver).map_err(|_| RealtimeMediaError::FrameRejected)
}
