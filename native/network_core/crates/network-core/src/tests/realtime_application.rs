use super::application::MAX_REALTIME_APPLICATION_DATA_BYTES;
use super::*;
use crate::runtime::RuntimeState;
use network_protocol::{network_event, NetworkErrorCode, SendRealtimeApplicationDataCommand};
use network_webrtc::{
    DataChannelReliability, RealtimeIoDriver, RealtimeIoDriverHandle, WebRtcConfig, WebRtcPeer,
};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc::unbounded_channel;

fn application_session(peer_id: &str, driver: Option<RealtimeIoDriverHandle>) -> RealtimeSession {
    RealtimeSession {
        peer_id: peer_id.into(),
        shared_session_instance_id: "00112233445566778899aabbccddeeff".into(),
        connection_session_id: None,
        direct_signaling_path: None,
        peer: None,
        driver,
        revision: 1,
        remote_revision: 0,
        ice_revision: 1,
        seen_candidates: HashSet::new(),
    }
}

fn application_command(
    realtime_id: &str,
    generation: u64,
    payload: Vec<u8>,
) -> SendRealtimeApplicationDataCommand {
    SendRealtimeApplicationDataCommand {
        realtime_id: realtime_id.into(),
        generation,
        payload,
    }
}

#[tokio::test]
async fn application_data_rejects_bad_size_and_stale_generation() {
    let (event_tx, _event_rx) = unbounded_channel();
    let state = RuntimeState::new(event_tx, Arc::new(std::sync::atomic::AtomicU16::new(0)));
    let realtime_id = "00112233445566778899aabbccddeeff";
    let oversized = send_application_data(
        &state,
        application_command(
            realtime_id,
            1,
            vec![1; MAX_REALTIME_APPLICATION_DATA_BYTES + 1],
        ),
    )
    .await;
    assert!(matches!(
        oversized,
        Err(error) if error.code == NetworkErrorCode::InvalidArgument as i32
    ));
    let empty =
        send_application_data(&state, application_command(realtime_id, 1, Vec::new())).await;
    assert!(matches!(
        empty,
        Err(error) if error.code == NetworkErrorCode::InvalidArgument as i32
    ));

    state
        .realtime
        .lock()
        .await
        .insert_new_session(realtime_id.into(), application_session("peer-a", None));
    let generation = state
        .realtime
        .lock()
        .await
        .session_generation(realtime_id)
        .expect("generation");
    let stale = send_application_data(
        &state,
        application_command(realtime_id, generation + 1, b"mark".to_vec()),
    )
    .await;
    assert!(matches!(
        stale,
        Err(error) if error.code == NetworkErrorCode::InvalidArgument as i32
            && error.message.contains("generation")
    ));
    let closed = send_application_data(
        &state,
        application_command(realtime_id, generation, b"mark".to_vec()),
    )
    .await;
    assert!(matches!(
        closed,
        Err(error) if error.message.contains("data channel")
    ));
}

#[tokio::test]
async fn application_data_round_trip_keeps_generation() {
    let caller_driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("caller peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("caller driver")
    .into_handle();
    let responder_driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver")
    .into_handle();
    caller_driver
        .lock()
        .unwrap()
        .peer_mut()
        .create_data_channel("ssh-mobile-realtime", DataChannelReliability::default())
        .expect("data channel");
    let offer = caller_driver
        .lock()
        .unwrap()
        .peer_mut()
        .create_offer()
        .unwrap();
    let answer = {
        let mut responder = responder_driver.lock().unwrap();
        responder.peer_mut().accept_remote_offer(offer).unwrap();
        responder.peer_mut().create_answer().unwrap()
    };
    caller_driver
        .lock()
        .unwrap()
        .peer_mut()
        .accept_remote_answer(answer)
        .unwrap();

    let (caller_tx, mut caller_rx) = unbounded_channel();
    let (responder_tx, mut responder_rx) = unbounded_channel();
    let caller = Arc::new(RuntimeState::new(
        caller_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let responder = Arc::new(RuntimeState::new(
        responder_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let caller_id = "00112233445566778899aabbccddeeff";
    let responder_id = "ffeeddccbbaa99887766554433221100";
    caller.realtime.lock().await.insert_new_session(
        caller_id.into(),
        application_session("peer-b", Some(Arc::clone(&caller_driver))),
    );
    responder.realtime.lock().await.insert_new_session(
        responder_id.into(),
        application_session("peer-a", Some(Arc::clone(&responder_driver))),
    );
    let caller_generation = caller
        .realtime
        .lock()
        .await
        .session_generation(caller_id)
        .expect("caller generation");
    let responder_generation = responder
        .realtime
        .lock()
        .await
        .session_generation(responder_id)
        .expect("responder generation");

    let caller_io = tokio::spawn(run_realtime_session_io(
        Arc::clone(&caller),
        caller_id.into(),
        "peer-b".into(),
        caller_driver.clone(),
    ));
    let responder_io = tokio::spawn(run_realtime_session_io(
        Arc::clone(&responder),
        responder_id.into(),
        "peer-a".into(),
        responder_driver.clone(),
    ));

    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let mut caller_open = false;
    let mut responder_open = false;
    while !(caller_open && responder_open) {
        tokio::select! {
            event = caller_rx.recv() => {
                caller_open |= matches!(
                    event.and_then(|event| event.payload),
                    Some(network_event::Payload::RealtimeApplicationChannel(channel))
                        if channel.open && channel.generation == caller_generation
                );
            }
            event = responder_rx.recv() => {
                responder_open |= matches!(
                    event.and_then(|event| event.payload),
                    Some(network_event::Payload::RealtimeApplicationChannel(channel))
                        if channel.open && channel.generation == responder_generation
                );
            }
            _ = tokio::time::sleep_until(deadline) => panic!("application channel did not open"),
        }
    }

    send_application_data(
        &caller,
        application_command(caller_id, caller_generation, b"mark".to_vec()),
    )
    .await
    .expect("send mark");

    let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let payload = loop {
        tokio::select! {
            Some(event) = responder_rx.recv() => {
                if let Some(network_event::Payload::RealtimeApplicationData(data)) = event.payload {
                    assert_eq!(data.generation, responder_generation);
                    assert_eq!(data.realtime_id, responder_id);
                    break data.payload;
                }
            }
            Some(_) = caller_rx.recv() => {}
            _ = tokio::time::sleep_until(payload_deadline) => {
                panic!("application payload was not delivered")
            }
        }
    };
    assert_eq!(payload, b"mark");
    caller_io.abort();
    responder_io.abort();
}
