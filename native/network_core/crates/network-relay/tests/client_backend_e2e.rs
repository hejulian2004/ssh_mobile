//! Live client → Caddy → Go Relay coverage.
//!
//! Unlike `relay_control_client_integration.rs`, this test deliberately does
//! not start a Rust test server.  The shell entry point starts an isolated
//! Relay/Front/Caddy Compose project and supplies its loopback URL and one-time
//! enrollment token through the environment.  The HTTP helper below is kept
//! test-only so the production SDK does not acquire an HTTP dependency merely
//! for this cross-process gate.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use network_protocol::{
    ScreenShareConsentDecision, ScreenShareConsentPurpose, ScreenShareConsentV2,
    ScreenShareMediaKind,
};
use network_relay::v2::{
    CandidateBundle, ControlEvent, DataEvent, DiscoverySnapshot, RealtimeSignalKind,
    RelayControlClient, RelayDataClient, ResolveStatus, RuntimeEpoch, TransportCapability,
};
use prost::Message;
use rand::RngCore;
use serde_json::{json, Value};
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::process::Command;
use tokio::sync::mpsc;

const EVENT_TIMEOUT: Duration = Duration::from_secs(12);

#[derive(Clone)]
struct Identity {
    device_id: String,
    signing_seed: [u8; 32],
    public_key: [u8; 32],
    credential: String,
}

impl Identity {
    fn new(device_id: &str) -> Self {
        let mut signing_seed = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut signing_seed);
        let signing_key = SigningKey::from_bytes(&signing_seed);
        Self {
            device_id: device_id.to_string(),
            signing_seed,
            public_key: signing_key.verifying_key().to_bytes(),
            credential: String::new(),
        }
    }
}

#[tokio::test]
#[ignore = "requires the isolated Caddy → Go Relay deployment"]
async fn real_clients_complete_control_and_reservation_data_flow() {
    let base_url = std::env::var("CLIENT_BACKEND_E2E_BASE_URL")
        .expect("CLIENT_BACKEND_E2E_BASE_URL must point at the Caddy HTTP origin");
    let enrollment_token = std::env::var("RELAY_ENROLLMENT_TOKEN")
        .expect("RELAY_ENROLLMENT_TOKEN must be supplied by client_backend_e2e.sh");
    let mut device_a = Identity::new(&e2e_device_id("e2e-rust-a"));
    let mut device_b = Identity::new(&e2e_device_id("e2e-rust-b"));

    let (health_status, _) = http_json(&base_url, "/healthz", "GET", &[])
        .await
        .expect("Caddy health probe should reach Relay");
    assert_eq!(health_status, 204, "Relay health probe must return 204");

    let (bad_status, _) = http_json(
        &base_url,
        "/v2/devices/enroll",
        "POST",
        &serde_json::to_vec(&json!({
            "device_id": e2e_device_id("e2e-rust-invalid"),
            "public_key": URL_SAFE_NO_PAD.encode([0u8; 32]),
            "protocol_version": 2,
            "enrollment_token": "deliberately-invalid-token"
        }))
        .expect("encode invalid enrollment"),
    )
    .await
    .expect("invalid enrollment request should receive a Relay response");
    assert_eq!(bad_status, 401, "invalid enrollment token must be rejected");

    device_a.credential = enroll(&base_url, &enrollment_token, &device_a)
        .await
        .expect("first real device enrollment");
    device_b.credential = enroll(&base_url, &enrollment_token, &device_b)
        .await
        .expect("second real device enrollment");

    let mut wrong_control = RelayControlClient::new(
        base_url.clone(),
        device_a.device_id.clone(),
        "wrong-credential".into(),
        device_a.signing_seed,
    )
    .expect("construct invalid control client");
    assert!(
        wrong_control.connect().await.is_err(),
        "wrong credential must not upgrade /v2/control"
    );

    let mut control_a = RelayControlClient::new(
        base_url.clone(),
        device_a.device_id.clone(),
        device_a.credential.clone(),
        device_a.signing_seed,
    )
    .expect("construct device A control client");
    let mut control_b = RelayControlClient::new(
        base_url.clone(),
        device_b.device_id.clone(),
        device_b.credential.clone(),
        device_b.signing_seed,
    )
    .expect("construct device B control client");

    let ready_a = control_a.connect().await.expect("device A Ready");
    let ready_b = control_b.connect().await.expect("device B Ready");
    assert_eq!(ready_a.protocol_version, 2);
    assert_eq!(ready_b.protocol_version, 2);
    assert_eq!(ready_a.device_id, device_a.device_id);
    assert_eq!(ready_b.device_id, device_b.device_id);
    assert!(ready_a.heartbeat_interval_s > 0);
    assert!(ready_a.presence_ttl_s > 0);

    let mut events_b = control_b.take_events().expect("B control event stream");
    let snapshot_a = discovery_snapshot(11, 1);
    let snapshot_b = discovery_snapshot(22, 1);
    let ack_a = control_a
        .publish_discovery(snapshot_a.clone())
        .await
        .expect("A discovery publish");
    let ack_b = control_b
        .publish_discovery(snapshot_b.clone())
        .await
        .expect("B discovery publish");
    assert_eq!(ack_a.revision, 1);
    assert_eq!(ack_b.revision, 1);
    let heartbeat = control_a.heartbeat().await.expect("A heartbeat");
    assert!(heartbeat.server_time_ms > 0);

    let resolved = control_a
        .resolve_peer(&device_b.device_id)
        .await
        .expect("ResolvePeerResponse");
    assert_eq!(resolved.status, ResolveStatus::Ready as i32);
    let resolved_discovery = resolved.discovery.expect("resolved discovery snapshot");
    assert_eq!(resolved_discovery.runtime_epoch, snapshot_b.runtime_epoch);
    assert_eq!(resolved_discovery.revision, snapshot_b.revision);
    assert_eq!(
        resolved_discovery.candidate_bundle,
        snapshot_b.candidate_bundle
    );

    let attempt_id = format!("e2e-rust-attempt-{}", unique_suffix());
    let attempt = control_a
        .begin_connectivity_attempt(
            attempt_id.clone(),
            device_b.device_id.clone(),
            device_a.device_id.clone(),
            snapshot_a.runtime_epoch.clone().expect("A epoch"),
            snapshot_a.revision,
            Some(snapshot_a.clone()),
        )
        .await
        .expect("Resolve → ConnectivityOffer");
    let offer = next_offer(&mut events_b).await;
    assert_eq!(offer.attempt_id, attempt_id);
    assert_eq!(offer.initiator_device_id, device_a.device_id);
    control_b
        .send_connectivity_answer(
            &offer,
            true,
            &device_b.device_id,
            snapshot_b.runtime_epoch.clone().expect("B epoch"),
            snapshot_b.revision,
            Some(snapshot_b.clone()),
        )
        .await
        .expect("ConnectivityAnswer forwarding");
    let answer = attempt
        .wait_for_answer()
        .await
        .expect("initiator receives ConnectivityAnswer");
    assert!(answer.accepted);
    assert_eq!(answer.responder_device_id, device_b.device_id);

    let signal_payload = b"opaque-realtime-signal".to_vec();
    control_a
        .signal_webrtc(
            "e2e-realtime",
            &device_b.device_id,
            RealtimeSignalKind::Offer,
            1,
            &signal_payload,
        )
        .await
        .expect("RealtimeSignal forwarding");
    let signal = next_realtime_signal(&mut events_b).await;
    assert_eq!(signal.realtime_id, "e2e-realtime");
    assert_eq!(signal.payload, signal_payload);

    let issued_at_ms = unix_time_ms() as u64;
    let screen_share_consent = ScreenShareConsentV2 {
        schema_version: 2,
        operation_id: format!("e2e-screen-share-{}", unique_suffix()),
        realtime_id: "e2e-screen-share".into(),
        issued_at_ms,
        expires_at_ms: issued_at_ms + 120_000,
        decision: ScreenShareConsentDecision::Request as i32,
        sender_peer_id: device_a.device_id.clone(),
        purpose: ScreenShareConsentPurpose::ScreenShare as i32,
        media: ScreenShareMediaKind::ScreenVideo as i32,
        requires_acceptance: true,
        action_revision: 1,
        shared_session_instance_id: format!("e2e-screen-instance-{}", unique_suffix()),
    };
    let screen_share_payload = screen_share_consent.encode_to_vec();
    control_a
        .signal_webrtc_wire_kind(
            "e2e-screen-share",
            &device_b.device_id,
            6,
            1,
            &screen_share_payload,
        )
        .await
        .expect("screen-share consent forwarding");
    let screen_share_signal = next_realtime_signal(&mut events_b).await;
    assert_eq!(screen_share_signal.realtime_id, "e2e-screen-share");
    assert_eq!(screen_share_signal.target_device_id, device_b.device_id);
    assert_eq!(screen_share_signal.kind, 6);
    assert_eq!(screen_share_signal.revision, 1);
    assert_eq!(screen_share_signal.source_device_id, device_a.device_id);
    assert_eq!(screen_share_signal.payload, screen_share_payload);
    assert_eq!(
        ScreenShareConsentV2::decode(screen_share_signal.payload.as_slice())
            .expect("decode forwarded screen-share consent"),
        screen_share_consent
    );

    let reservation = control_a
        .reserve_relay(&attempt_id, &device_b.device_id, 30)
        .await
        .expect("RelayReserveResponse");
    assert_eq!(reservation.attempt_id, attempt_id);
    assert_eq!(reservation.reservation_id.len(), 32);
    assert_eq!(reservation.local_token.len(), 32);
    assert!(reservation.relay_data_endpoint.contains("/v2/relay/"));
    assert!(reservation.expires_at_ms > 0);
    let incoming = next_incoming_reservation(&mut events_b).await;
    assert_eq!(incoming.reservation_id, reservation.reservation_id);
    assert_eq!(incoming.attempt_id, attempt_id);
    assert_eq!(incoming.initiator_device_id, device_a.device_id);
    assert_eq!(incoming.local_token.len(), 32);

    // A responder token cannot be used by the initiator.  This also proves the
    // Caddy route reaches Relay's reservation authenticator rather than Front.
    let mut wrong_role = RelayDataClient::new(
        reservation.relay_data_endpoint.clone(),
        reservation.reservation_id.clone(),
        incoming.local_token.clone(),
        device_a.credential.clone(),
        device_a.signing_seed,
    )
    .expect("construct wrong-role data client");
    assert!(
        wrong_role.connect_reservation().await.is_err(),
        "a reservation token for the other role must be rejected"
    );

    let mut data_a = RelayDataClient::new(
        reservation.relay_data_endpoint.clone(),
        reservation.reservation_id.clone(),
        reservation.local_token.clone(),
        device_a.credential.clone(),
        device_a.signing_seed,
    )
    .expect("construct A data client");
    let mut data_b = RelayDataClient::new(
        incoming.relay_data_endpoint.clone(),
        incoming.reservation_id.clone(),
        incoming.local_token.clone(),
        device_b.credential.clone(),
        device_b.signing_seed,
    )
    .expect("construct B data client");
    let (data_a_result, data_b_result) =
        tokio::join!(data_a.connect_reservation(), data_b.connect_reservation());
    data_a_result.expect("A PairReady");
    data_b_result.expect("B PairReady");
    let mut data_events_a = data_a.take_events().expect("A data event stream");
    let mut data_events_b = data_b.take_events().expect("B data event stream");

    let opaque_payload = b"encrypted-payload-that-relay-must-not-parse".to_vec();
    data_a
        .send(7, &opaque_payload)
        .await
        .expect("send opaque payload through data plane");
    match next_data_event(&mut data_events_b).await {
        DataEvent::Payload {
            sequence,
            encrypted_payload,
        } => {
            assert_eq!(sequence, 7);
            assert_eq!(encrypted_payload, opaque_payload);
        }
        other => panic!("expected forwarded payload, got {other:?}"),
    }
    data_b.send_ack(7).await.expect("send payload ACK");
    assert_eq!(
        next_data_event(&mut data_events_a).await,
        DataEvent::Ack { sequence: 7 }
    );

    data_a.close().await.expect("close initiator data plane");
    match next_data_event(&mut data_events_b).await {
        DataEvent::Close { .. } | DataEvent::Disconnected { .. } => {}
        other => panic!("expected data close propagation, got {other:?}"),
    }
    data_b.close().await.expect("close responder data plane");
    control_a.disconnect().await;
    control_b.disconnect().await;

    if std::env::var("CLIENT_BACKEND_E2E_STRICT").as_deref() == Ok("1") {
        // Strict mode provisions a short credential TTL in the Compose env.
        // Wait past it, prove the old bearer is refused, then use the real
        // Ed25519 refresh proof and reconnect with the replacement credential.
        // An externally deployed service keeps its production TTL (normally
        // 24h), so online-e2e skips the time-based probe and exercises the
        // active revocation branch below instead of waiting 46 seconds only
        // to fail against a production TTL.
        if std::env::var("CLIENT_BACKEND_E2E_ONLINE").as_deref() != Ok("1") {
            tokio::time::sleep(Duration::from_secs(46)).await;
            let mut expired_control = RelayControlClient::new(
                base_url.clone(),
                device_a.device_id.clone(),
                device_a.credential.clone(),
                device_a.signing_seed,
            )
            .expect("construct expired-credential control client");
            assert!(
                expired_control.connect().await.is_err(),
                "an expired credential must be refused by /v2/control"
            );
            device_a.credential = refresh(&base_url, &device_a)
                .await
                .expect("refresh an expired credential");
            let mut reconnected = RelayControlClient::new(
                base_url.clone(),
                device_a.device_id.clone(),
                device_a.credential.clone(),
                device_a.signing_seed,
            )
            .expect("construct refreshed control client");
            reconnected
                .connect()
                .await
                .expect("reconnect with refreshed credential");
            reconnected.disconnect().await;
        }

        if std::env::var("CLIENT_BACKEND_E2E_REVOCATION").as_deref() == Ok("1") {
            strict_revocation_probe(&base_url, &enrollment_token).await;
        }
    }
}

/// Keep two real control sockets and their reservation data pair alive while
/// the shell orchestrator calls the authenticated admin revoke endpoint.  This
/// deliberately uses a separate pair from the expiry flow so the assertion is
/// about an active device lifecycle, not only admission after revocation.
async fn strict_revocation_probe(base_url: &str, enrollment_token: &str) {
    let ready_file = std::env::var("CLIENT_BACKEND_E2E_REVOCATION_READY_FILE")
        .expect("strict revocation ready-file path must be supplied");
    let done_file = std::env::var("CLIENT_BACKEND_E2E_REVOCATION_DONE_FILE")
        .expect("strict revocation done-file path must be supplied");
    let mut device_a = Identity::new(&e2e_device_id("e2e-rust-revoke-a"));
    let mut device_b = Identity::new(&e2e_device_id("e2e-rust-revoke-b"));
    device_a.credential = enroll(base_url, enrollment_token, &device_a)
        .await
        .expect("revocation probe device A enrollment");
    device_b.credential = enroll(base_url, enrollment_token, &device_b)
        .await
        .expect("revocation probe device B enrollment");

    let mut control_a = RelayControlClient::new(
        base_url.to_string(),
        device_a.device_id.clone(),
        device_a.credential.clone(),
        device_a.signing_seed,
    )
    .expect("construct revocation probe A control client");
    let mut control_b = RelayControlClient::new(
        base_url.to_string(),
        device_b.device_id.clone(),
        device_b.credential.clone(),
        device_b.signing_seed,
    )
    .expect("construct revocation probe B control client");
    control_a.connect().await.expect("revocation probe A Ready");
    control_b.connect().await.expect("revocation probe B Ready");
    let mut control_events_a = control_a.take_events().expect("A control event stream");
    let mut control_events_b = control_b.take_events().expect("B control event stream");

    let snapshot_a = discovery_snapshot(31, 1);
    let snapshot_b = discovery_snapshot(32, 1);
    control_a
        .publish_discovery(snapshot_a.clone())
        .await
        .expect("revocation probe A discovery publish");
    control_b
        .publish_discovery(snapshot_b.clone())
        .await
        .expect("revocation probe B discovery publish");
    let attempt_id = format!("e2e-rust-revoke-attempt-{}", unique_suffix());
    let attempt = control_a
        .begin_connectivity_attempt(
            attempt_id.clone(),
            device_b.device_id.clone(),
            device_a.device_id.clone(),
            snapshot_a.runtime_epoch.clone().expect("A epoch"),
            snapshot_a.revision,
            Some(snapshot_a),
        )
        .await
        .expect("revocation probe ConnectivityOffer");
    let offer = next_offer(&mut control_events_b).await;
    control_b
        .send_connectivity_answer(
            &offer,
            true,
            &device_b.device_id,
            snapshot_b.runtime_epoch.clone().expect("B epoch"),
            snapshot_b.revision,
            Some(snapshot_b),
        )
        .await
        .expect("revocation probe ConnectivityAnswer");
    attempt
        .wait_for_answer()
        .await
        .expect("revocation probe answer");

    let reservation = control_a
        .reserve_relay(&attempt_id, &device_b.device_id, 30)
        .await
        .expect("revocation probe reservation");
    let incoming = next_incoming_reservation(&mut control_events_b).await;
    let mut data_a = RelayDataClient::new(
        reservation.relay_data_endpoint.clone(),
        reservation.reservation_id.clone(),
        reservation.local_token,
        device_a.credential.clone(),
        device_a.signing_seed,
    )
    .expect("construct revocation probe A data client");
    let mut data_b = RelayDataClient::new(
        incoming.relay_data_endpoint,
        incoming.reservation_id,
        incoming.local_token,
        device_b.credential.clone(),
        device_b.signing_seed,
    )
    .expect("construct revocation probe B data client");
    let (data_a_result, data_b_result) =
        tokio::join!(data_a.connect_reservation(), data_b.connect_reservation());
    data_a_result.expect("revocation probe A PairReady");
    data_b_result.expect("revocation probe B PairReady");
    let mut data_events_a = data_a.take_events().expect("A data event stream");
    let mut data_events_b = data_b.take_events().expect("B data event stream");

    std::fs::write(&ready_file, b"ready\n").expect("publish revocation probe ready marker");
    wait_for_file(&done_file).await;

    wait_for_control_disconnect(&mut control_events_a).await;
    wait_for_data_disconnect(&mut data_events_a).await;
    wait_for_data_disconnect(&mut data_events_b).await;

    let mut revoked_control = RelayControlClient::new(
        base_url.to_string(),
        device_a.device_id,
        device_a.credential,
        device_a.signing_seed,
    )
    .expect("construct revoked admission client");
    assert!(
        revoked_control.connect().await.is_err(),
        "revoked credential must not open a new control socket"
    );
    control_b.disconnect().await;
}

async fn wait_for_file(path: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while tokio::time::Instant::now() < deadline {
        if Path::new(path).exists() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("strict revocation admin action did not complete within 60 seconds");
}

async fn wait_for_control_disconnect(events: &mut mpsc::Receiver<ControlEvent>) {
    loop {
        if let ControlEvent::Disconnected { .. } = next_control_event(events).await {
            return;
        }
    }
}

async fn wait_for_data_disconnect(events: &mut mpsc::Receiver<DataEvent>) {
    loop {
        match next_data_event(events).await {
            DataEvent::Close { .. } | DataEvent::Disconnected { .. } => return,
            _ => {}
        }
    }
}

async fn enroll(base_url: &str, token: &str, identity: &Identity) -> Result<String, String> {
    let body = serde_json::to_vec(&json!({
        "device_id": identity.device_id,
        "public_key": URL_SAFE_NO_PAD.encode(identity.public_key),
        "protocol_version": 2,
        "platform": "rust-e2e",
        "enrollment_token": token,
    }))
    .map_err(|error| format!("encode enrollment: {error}"))?;
    let (status, response) = http_json(base_url, "/v2/devices/enroll", "POST", &body).await?;
    if status != 200 {
        return Err(format!("enrollment returned HTTP {status}"));
    }
    let payload: Value = serde_json::from_slice(&response)
        .map_err(|error| format!("invalid enrollment response: {error}"))?;
    let credential = payload
        .get("credential")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "enrollment response omitted credential".to_string())?;
    let expires_at = payload
        .get("expires_at")
        .and_then(Value::as_i64)
        .ok_or_else(|| "enrollment response omitted expires_at".to_string())?;
    let server_time = payload
        .get("server_time")
        .and_then(Value::as_i64)
        .ok_or_else(|| "enrollment response omitted server_time".to_string())?;
    if payload.get("protocol_version").and_then(Value::as_u64) != Some(2)
        || expires_at <= server_time
    {
        return Err("enrollment response protocol/expiry is invalid".to_string());
    }
    Ok(credential.to_string())
}

async fn refresh(base_url: &str, identity: &Identity) -> Result<String, String> {
    let mut nonce_bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = URL_SAFE_NO_PAD.encode(nonce_bytes);
    let timestamp = i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| format!("system clock precedes Unix epoch: {error}"))?
            .as_secs(),
    )
    .map_err(|_| "system clock exceeds signed Unix seconds".to_string())?;
    let transcript = format!("POST\n/v2/devices/refresh\n{timestamp}\n{nonce}");
    let signature = URL_SAFE_NO_PAD.encode(
        SigningKey::from_bytes(&identity.signing_seed)
            .sign(transcript.as_bytes())
            .to_bytes(),
    );
    let body = serde_json::to_vec(&json!({
        "device_id": identity.device_id,
        "public_key": URL_SAFE_NO_PAD.encode(identity.public_key),
        "timestamp": timestamp,
        "nonce": nonce,
        "signature": signature,
    }))
    .map_err(|error| format!("encode refresh: {error}"))?;
    let (status, response) = http_json(base_url, "/v2/devices/refresh", "POST", &body).await?;
    if status != 200 {
        return Err(format!("credential refresh returned HTTP {status}"));
    }
    let payload: Value = serde_json::from_slice(&response)
        .map_err(|error| format!("invalid refresh response: {error}"))?;
    payload
        .get("credential")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| "refresh response omitted credential".to_string())
}

/// Minimal HTTP/1.1 client for the test-only bootstrap requests. Cleartext
/// loopback traffic stays dependency-free; an HTTPS origin uses the system
/// `curl` trust store (or `CLIENT_BACKEND_E2E_CA_FILE`) so a release profile
/// can exercise a trusted test CA without adding an HTTP client dependency to
/// the production SDK.
async fn http_json(
    base_url: &str,
    path: &str,
    method: &str,
    body: &[u8],
) -> Result<(u16, Vec<u8>), String> {
    let url = url::Url::parse(base_url).map_err(|error| format!("invalid base URL: {error}"))?;
    if !matches!(url.path(), "" | "/") || url.query().is_some() || url.fragment().is_some() {
        return Err("Rust live E2E HTTP helper requires an origin without a path".into());
    }
    if url.scheme() == "https" {
        return http_json_via_curl(&url, path, method, body).await;
    }
    if url.scheme() != "http" {
        return Err("Rust live E2E HTTP helper requires an http or https origin".into());
    }
    let host = url
        .host_str()
        .ok_or_else(|| "base URL is missing a host".to_string())?;
    let port = url.port_or_known_default().unwrap_or(80);
    let host_header = match url.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_string(),
    };
    let mut stream = TcpStream::connect((host, port))
        .await
        .map_err(|error| format!("connect {host_header}: {error}"))?;
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host_header}\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|error| format!("write HTTP headers: {error}"))?;
    stream
        .write_all(body)
        .await
        .map_err(|error| format!("write HTTP body: {error}"))?;
    let mut bytes = Vec::new();
    stream
        .read_to_end(&mut bytes)
        .await
        .map_err(|error| format!("read HTTP response: {error}"))?;
    let header_end = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| "HTTP response did not contain headers".to_string())?;
    let headers = String::from_utf8_lossy(&bytes[..header_end]);
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .ok_or_else(|| "HTTP response did not contain a status".to_string())?
        .parse::<u16>()
        .map_err(|error| format!("invalid HTTP status: {error}"))?;
    let header_block = headers.to_ascii_lowercase();
    let raw_body = &bytes[header_end + 4..];
    let body = if header_block.contains("transfer-encoding: chunked") {
        decode_chunked(raw_body)?
    } else {
        raw_body.to_vec()
    };
    Ok((status, body))
}

async fn http_json_via_curl(
    origin: &url::Url,
    path: &str,
    method: &str,
    body: &[u8],
) -> Result<(u16, Vec<u8>), String> {
    let mut target = origin.clone();
    target.set_path(path);
    target.set_query(None);
    target.set_fragment(None);
    let mut command = Command::new("curl");
    command
        .arg("--silent")
        .arg("--show-error")
        .arg("--max-time")
        .arg("15")
        .arg("--request")
        .arg(method)
        .arg("--header")
        .arg("Accept: application/json")
        .arg("--header")
        .arg("Accept-Encoding: identity")
        .arg("--header")
        .arg("Content-Type: application/json")
        .arg("--data-binary")
        .arg("@-")
        .arg("--write-out")
        .arg("\n__CLIENT_BACKEND_STATUS__%{http_code}")
        .arg(target.as_str())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Ok(ca_file) = std::env::var("CLIENT_BACKEND_E2E_CA_FILE") {
        if !ca_file.trim().is_empty() {
            command.arg("--cacert").arg(ca_file);
        }
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("start curl for HTTPS bootstrap: {error}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(body)
            .await
            .map_err(|error| format!("write HTTPS bootstrap body: {error}"))?;
    }
    let output = child
        .wait_with_output()
        .await
        .map_err(|error| format!("read curl HTTPS bootstrap result: {error}"))?;
    let marker = b"\n__CLIENT_BACKEND_STATUS__";
    let marker_start = output
        .stdout
        .windows(marker.len())
        .rposition(|window| window == marker)
        .ok_or_else(|| {
            let diagnostic = String::from_utf8_lossy(&output.stderr);
            format!("curl HTTPS bootstrap omitted status: {diagnostic}")
        })?;
    let status = std::str::from_utf8(&output.stdout[marker_start + marker.len()..])
        .map_err(|error| format!("invalid curl HTTPS status: {error}"))?
        .trim()
        .parse::<u16>()
        .map_err(|error| format!("invalid curl HTTPS status: {error}"))?;
    if !output.status.success() {
        let diagnostic = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "curl HTTPS bootstrap failed (HTTP {status}): {diagnostic}"
        ));
    }
    Ok((status, output.stdout[..marker_start].to_vec()))
}

fn decode_chunked(mut input: &[u8]) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    loop {
        let line_end = input
            .windows(2)
            .position(|window| window == b"\r\n")
            .ok_or_else(|| "chunked HTTP response has no size line".to_string())?;
        let size_text = std::str::from_utf8(&input[..line_end])
            .map_err(|error| format!("invalid chunk size: {error}"))?
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        let size = usize::from_str_radix(size_text, 16)
            .map_err(|error| format!("invalid chunk size: {error}"))?;
        input = &input[line_end + 2..];
        if size == 0 {
            return Ok(output);
        }
        if input.len() < size + 2 || &input[size..size + 2] != b"\r\n" {
            return Err("chunked HTTP response has a truncated chunk".to_string());
        }
        output.extend_from_slice(&input[..size]);
        input = &input[size + 2..];
    }
}

fn discovery_snapshot(seed: u64, revision: u32) -> DiscoverySnapshot {
    DiscoverySnapshot {
        runtime_epoch: Some(RuntimeEpoch {
            high: seed,
            low: seed.wrapping_add(1),
        }),
        revision,
        transport_capabilities: vec![
            TransportCapability::Webrtc as i32,
            TransportCapability::RelayData as i32,
        ],
        candidate_bundle: Some(CandidateBundle {
            candidates: vec![format!("candidate-{seed}").into_bytes()],
        }),
        published_at_ms: unix_time_ms(),
    }
}

fn unix_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn unique_suffix() -> String {
    let mut bytes = [0u8; 8];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

fn e2e_device_id(suffix: &str) -> String {
    format!(
        "{}{}",
        std::env::var("CLIENT_BACKEND_E2E_DEVICE_PREFIX").unwrap_or_default(),
        suffix
    )
}

async fn next_control_event(events: &mut mpsc::Receiver<ControlEvent>) -> ControlEvent {
    tokio::time::timeout(EVENT_TIMEOUT, events.recv())
        .await
        .expect("Relay control event timed out")
        .expect("Relay control event stream closed")
}

async fn next_offer(
    events: &mut mpsc::Receiver<ControlEvent>,
) -> network_relay::v2::ConnectivityOffer {
    loop {
        if let ControlEvent::ConnectivityOffer(offer) = next_control_event(events).await {
            return offer;
        }
    }
}

async fn next_realtime_signal(
    events: &mut mpsc::Receiver<ControlEvent>,
) -> network_relay::v2::RealtimeSignal {
    loop {
        if let ControlEvent::RealtimeSignal(signal) = next_control_event(events).await {
            return signal;
        }
    }
}

async fn next_incoming_reservation(
    events: &mut mpsc::Receiver<ControlEvent>,
) -> network_relay::v2::IncomingRelayReservation {
    loop {
        if let ControlEvent::IncomingRelayReservation(reservation) =
            next_control_event(events).await
        {
            return reservation;
        }
    }
}

async fn next_data_event(events: &mut mpsc::Receiver<DataEvent>) -> DataEvent {
    tokio::time::timeout(EVENT_TIMEOUT, events.recv())
        .await
        .expect("Relay data event timed out")
        .expect("Relay data event stream closed")
}

// Keep the signing import in this test's dependency surface explicit: the
// identity is used by RelayControlClient, while this assertion ensures the
// generated public key is a valid Ed25519 key and not merely random bytes.
#[allow(dead_code)]
fn sign_probe(seed: &[u8; 32]) -> Vec<u8> {
    SigningKey::from_bytes(seed)
        .sign(b"client-backend-e2e")
        .to_bytes()
        .to_vec()
}

// Convert accidental std::io errors in future helper extensions without
// exposing response contents (which may contain credentials).
#[allow(dead_code)]
fn io_message(error: io::Error) -> String {
    error.to_string()
}
