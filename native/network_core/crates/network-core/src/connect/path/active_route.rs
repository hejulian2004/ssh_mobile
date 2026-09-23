use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use network_protocol::RouteType;
use network_quic::{send_channel_frame, ChannelFrameKind};
use network_relay::RelayDataClient;
use quinn::{Connection, VarInt};

use crate::connection::{
    ConnectionProfile, GenericFrameKind, GenericRouteHandle, Route, RouteTransport,
};

use super::generic_route::GenericRouteOwner;
use super::manager::PathCloseReason;
use super::{ActiveRouteCarrier, NoopPathCarrier, RouteView, RouteViewCarrier};

type PathIoResult = Result<(), Box<dyn std::error::Error + Send + Sync>>;
type PathIoFuture = Pin<Box<dyn Future<Output = PathIoResult> + Send>>;

/// A route carrier owned by the peer path layer. It is intentionally kept
/// separate from ConnectionSessionStore: the store records admission facts,
/// while this value owns the authenticated transport and its I/O handles.
pub(crate) struct ActiveRoute {
    profile: ConnectionProfile,
    carrier: ActiveConnection,
}

enum ActiveConnection {
    Quic(Connection),
    Generic(GenericRouteOwner),
    #[cfg(test)]
    GenericTest(GenericRouteHandle),
    Relay(Option<Arc<RelayDataClient>>),
}

/// Cloneable, non-owning I/O projection used by a leased business operation.
#[derive(Clone)]
pub(crate) enum StreamCarrier {
    Quic(Connection),
    Generic(GenericRouteHandle),
    #[cfg(test)]
    GenericTest(GenericRouteHandle),
    Relay(Option<Arc<RelayDataClient>>),
}

impl ActiveRoute {
    pub(crate) fn quic(connection: Connection, route: RouteType) -> Self {
        Self {
            profile: ConnectionProfile::for_route(route)
                .expect("QUIC and Relay route types have a composed profile"),
            carrier: ActiveConnection::Quic(connection),
        }
    }

    pub(crate) fn generic(owner: GenericRouteOwner) -> Self {
        Self {
            profile: owner.handle().profile(),
            carrier: ActiveConnection::Generic(owner),
        }
    }

    #[cfg(test)]
    pub(crate) fn generic_test(handle: GenericRouteHandle) -> Self {
        Self {
            profile: handle.profile(),
            carrier: ActiveConnection::GenericTest(handle),
        }
    }

    pub(crate) fn relay(client: Option<Arc<RelayDataClient>>) -> Self {
        Self {
            profile: ConnectionProfile::new(Route::relay(RouteTransport::WebSocket)),
            carrier: ActiveConnection::Relay(client),
        }
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    fn connection(&self) -> Option<Connection> {
        match self.view().carrier {
            RouteViewCarrier::Quic(connection) => Some(connection),
            _ => None,
        }
    }

    fn stream_carrier(&self) -> Option<StreamCarrier> {
        Some(match self.view().carrier {
            RouteViewCarrier::Quic(connection) => StreamCarrier::Quic(connection),
            RouteViewCarrier::Generic(handle) => StreamCarrier::Generic(handle),
            #[cfg(test)]
            RouteViewCarrier::GenericTest(handle) => StreamCarrier::GenericTest(handle),
            RouteViewCarrier::Relay(client) => StreamCarrier::Relay(client),
        })
    }

    fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        match self.view().carrier {
            RouteViewCarrier::Relay(client) => client,
            _ => None,
        }
    }

    fn view(&self) -> RouteView {
        let carrier = match &self.carrier {
            ActiveConnection::Quic(connection) => RouteViewCarrier::Quic(connection.clone()),
            ActiveConnection::Generic(owner) => RouteViewCarrier::Generic(owner.handle().clone()),
            #[cfg(test)]
            ActiveConnection::GenericTest(handle) => RouteViewCarrier::GenericTest(handle.clone()),
            ActiveConnection::Relay(client) => RouteViewCarrier::Relay(client.clone()),
        };
        RouteView {
            profile: self.profile,
            carrier,
        }
    }

    pub(crate) async fn close(self) {
        match self.carrier {
            ActiveConnection::Quic(connection) => {
                connection.close(VarInt::from_u32(0), b"physical path closed");
            }
            ActiveConnection::Generic(owner) => owner.close().await,
            #[cfg(test)]
            ActiveConnection::GenericTest(handle) => {
                let _ = handle.close().await;
            }
            ActiveConnection::Relay(Some(client)) => client.request_disconnect().await,
            ActiveConnection::Relay(None) => {}
        }
    }
}

pub(super) async fn send_route_view(
    view: RouteView,
    relay_token: &str,
    kind: GenericFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let is_stream = matches!(
        kind,
        GenericFrameKind::StreamBytes
            | GenericFrameKind::StreamOpen
            | GenericFrameKind::StreamClose
    );
    if is_stream
        && !view
            .profile
            .supports(crate::connection::ConnectionCapability::ReliableStream)
        || !is_stream
            && !view
                .profile
                .supports(crate::connection::ConnectionCapability::ReliableMessage)
    {
        return Err(std::io::Error::other("physical path lacks requested capability").into());
    }
    match view.carrier {
        RouteViewCarrier::Quic(connection) => {
            let kind = match kind {
                GenericFrameKind::DataMessage => ChannelFrameKind::DataMessage,
                GenericFrameKind::DeliveryAck => ChannelFrameKind::DeliveryAck,
                _ => {
                    return Err(
                        std::io::Error::other("stream frames require QUIC bi-stream").into(),
                    )
                }
            };
            send_channel_frame(&connection, kind, payload).await
        }
        RouteViewCarrier::Generic(handle) => handle
            .send(kind, payload)
            .await
            .map_err(|error| std::io::Error::other(error.to_string()).into()),
        #[cfg(test)]
        RouteViewCarrier::GenericTest(handle) => handle
            .send(kind, payload)
            .await
            .map_err(|error| std::io::Error::other(error.to_string()).into()),
        RouteViewCarrier::Relay(Some(relay)) => match kind {
            GenericFrameKind::DataMessage => {
                crate::relay::send_relay_channel_message(&relay, relay_token, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into())
            }
            GenericFrameKind::DeliveryAck => {
                crate::relay::send_relay_channel_ack(&relay, relay_token, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into())
            }
            GenericFrameKind::StreamBytes
            | GenericFrameKind::StreamOpen
            | GenericFrameKind::StreamClose => {
                crate::relay::send_relay_stream_frame(&relay, relay_token, payload)
                    .await
                    .map_err(|error| std::io::Error::other(error.to_string()).into())
            }
        },
        RouteViewCarrier::Relay(None) => Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "Relay path unavailable",
        )
        .into()),
    }
}

/// A physical carrier transferred into a
/// [`PhysicalPath`](super::physical::PhysicalPath).
///
/// The trait intentionally consumes the carrier on close. This makes the
/// ownership boundary explicit: a handle or lease can never close a carrier
/// without the physical-path owner first revoking or retiring it. Production
/// adapters can wrap a QUIC connection, generic route owner, or Relay data
/// client in this trait without changing the path state machine or wire
/// contract.
pub(crate) trait PathCarrier: Send + 'static {
    fn close(self: Box<Self>, reason: PathCloseReason);

    fn connection(&self) -> Option<Connection> {
        None
    }

    fn stream_carrier(&self) -> Option<StreamCarrier> {
        None
    }

    fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        None
    }

    fn send_channel_frame(
        &self,
        _relay_token: &str,
        _kind: GenericFrameKind,
        _payload: &[u8],
    ) -> PathIoFuture {
        Box::pin(async {
            Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "physical path I/O unavailable",
            )
            .into())
        })
    }
}

impl PathCarrier for NoopPathCarrier {
    fn close(self: Box<Self>, _reason: PathCloseReason) {}
}

impl PathCarrier for ActiveRouteCarrier {
    fn close(mut self: Box<Self>, _reason: PathCloseReason) {
        let Some(route) = self.route.take() else {
            return;
        };
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move { route.close().await });
        }
    }

    fn connection(&self) -> Option<Connection> {
        self.route.as_ref().and_then(ActiveRoute::connection)
    }

    fn stream_carrier(&self) -> Option<StreamCarrier> {
        self.route.as_ref().and_then(ActiveRoute::stream_carrier)
    }

    fn relay_data(&self) -> Option<Arc<RelayDataClient>> {
        self.route.as_ref().and_then(ActiveRoute::relay_data)
    }

    fn send_channel_frame(
        &self,
        relay_token: &str,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> PathIoFuture {
        let Some(view) = self.route.as_ref().map(ActiveRoute::view) else {
            return Box::pin(async {
                Err(std::io::Error::new(
                    std::io::ErrorKind::NotConnected,
                    "physical path unavailable",
                )
                .into())
            });
        };
        let relay_token = relay_token.to_owned();
        let payload = payload.to_owned();
        Box::pin(async move { send_route_view(view, &relay_token, kind, &payload).await })
    }
}

/// Convenient adapter for callers that already own a concrete carrier and
/// only need to supply its close operation to the path owner.
struct CallbackPathCarrier {
    close: Option<Box<dyn FnOnce(PathCloseReason) + Send>>,
}

impl PathCarrier for CallbackPathCarrier {
    fn close(mut self: Box<Self>, reason: PathCloseReason) {
        if let Some(close) = self.close.take() {
            close(reason);
        }
    }
}

pub(crate) fn callback_path_carrier<F>(close: F) -> Box<dyn PathCarrier>
where
    F: FnOnce(PathCloseReason) + Send + 'static,
{
    Box::new(CallbackPathCarrier {
        close: Some(Box::new(close)),
    })
}

pub(super) fn close_carrier(carrier: Option<Box<dyn PathCarrier>>, reason: PathCloseReason) {
    if let Some(carrier) = carrier {
        carrier.close(reason);
    }
}
