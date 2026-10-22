use super::*;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::{accept_async, tungstenite::Message, WebSocketStream};

#[tokio::test]
async fn tcp_transport_round_trips_bounded_frames() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut transport = TcpTransport::from_stream(stream);
        let frame = transport.recv_frame().await.unwrap();
        transport.send_frame(&frame).await.unwrap();
    });

    let mut transport = TcpTransport::connect("0.0.0.0:0".parse().unwrap(), peer)
        .await
        .unwrap();
    assert_eq!(transport.peer_addr().unwrap(), peer);
    assert_eq!(transport.send_frame(b"tcp-frame").await.unwrap(), 9);
    assert_eq!(transport.recv_frame().await.unwrap(), b"tcp-frame");
    transport.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn udp_transport_round_trips_datagrams_without_stream_framing() {
    // A connected UDP socket needs a known peer. Build the pair from two
    // sockets so the test also exercises source filtering.
    let left_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let right_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let left_addr = left_socket.local_addr().unwrap();
    let right_addr = right_socket.local_addr().unwrap();
    left_socket.connect(right_addr).await.unwrap();
    right_socket.connect(left_addr).await.unwrap();
    let mut left = UdpTransport::from_socket(left_socket, right_addr);
    let mut right = UdpTransport::from_socket(right_socket, left_addr);

    assert_eq!(left.send_datagram(b"udp-datagram").await.unwrap(), 12);
    assert_eq!(right.recv_datagram().await.unwrap(), b"udp-datagram");
    assert_eq!(right.send_datagram(b"reply").await.unwrap(), 5);
    assert_eq!(left.recv_datagram().await.unwrap(), b"reply");
    left.close().await.unwrap();
    right.close().await.unwrap();
}

#[tokio::test]
async fn websocket_transport_round_trips_binary_messages() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        if let Some(Ok(Message::Binary(payload))) = futures_util::StreamExt::next(&mut socket).await
        {
            futures_util::SinkExt::send(&mut socket, Message::Binary(payload))
                .await
                .unwrap();
        }
    });

    let mut transport = Transport::connect_websocket(&format!("ws://{peer}/v1/transport"))
        .await
        .unwrap();
    assert_eq!(transport.kind(), TransportKind::WebSocket);
    assert_eq!(transport.send(b"websocket-message").await.unwrap(), 17);
    assert_eq!(transport.recv().await.unwrap(), b"websocket-message");
    transport.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn common_transport_reports_its_kind() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut transport = TcpTransport::from_stream(stream);
        assert_eq!(transport.recv_frame().await.unwrap(), b"common-tcp");
        transport.send_frame(b"common-ack").await.unwrap();
    });
    let mut transport = Transport::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
        .await
        .unwrap();
    assert_eq!(transport.kind(), TransportKind::Tcp);
    assert_eq!(transport.send(b"common-tcp").await.unwrap(), 10);
    assert_eq!(transport.recv().await.unwrap(), b"common-ack");
    transport.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn tcp_transport_supports_an_explicit_local_bind_and_split_surface() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut transport = TcpTransport::from_stream(stream);
        let frame = transport.recv_frame().await.unwrap();
        transport.send_frame(&frame).await.unwrap();
    });

    let transport = Transport::connect_tcp("127.0.0.1:0".parse().unwrap(), peer)
        .await
        .unwrap();
    assert_eq!(transport.kind(), TransportKind::Tcp);
    let (mut reader, mut writer) = transport.into_split();
    assert_eq!(writer.send(b"explicit-bind").await.unwrap(), 13);
    assert_eq!(reader.recv().await.unwrap(), b"explicit-bind");
    writer.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn common_udp_surface_binds_routes_and_closes_both_halves() {
    let peer_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer = peer_socket.local_addr().unwrap();
    let mut transport = Transport::bind_udp("127.0.0.1:0".parse().unwrap(), peer)
        .await
        .unwrap();
    assert_eq!(transport.kind(), TransportKind::Udp);
    assert_eq!(transport.send(b"enum-udp").await.unwrap(), 8);
    let mut received = [0_u8; 32];
    let (length, source) = peer_socket.recv_from(&mut received).await.unwrap();
    assert_eq!(&received[..length], b"enum-udp");

    peer_socket.send_to(b"udp-reply", source).await.unwrap();
    assert_eq!(transport.recv().await.unwrap(), b"udp-reply");
    transport.close().await.unwrap();
    assert!(matches!(
        transport.send(b"closed").await,
        Err(TransportError::Closed)
    ));
}

#[tokio::test]
async fn transport_rejects_oversized_frames_and_closed_udp_writes() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        stream
            .write_u32((MAX_STREAM_FRAME_BYTES as u32).saturating_add(1))
            .await
            .unwrap();
    });
    let mut tcp = TcpTransport::connect("0.0.0.0:0".parse().unwrap(), peer)
        .await
        .unwrap();
    assert!(matches!(
        tcp.send_frame(&vec![0; MAX_STREAM_FRAME_BYTES + 1]).await,
        Err(TransportError::FrameTooLarge)
    ));
    assert!(matches!(
        tcp.recv_frame().await,
        Err(TransportError::FrameTooLarge)
    ));
    server.await.unwrap();

    let left_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let right_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let right_addr = right_socket.local_addr().unwrap();
    left_socket.connect(right_addr).await.unwrap();
    let mut udp = UdpTransport::from_socket(left_socket, right_addr);
    assert!(matches!(
        udp.send_datagram(&[]).await,
        Err(TransportError::FrameTooLarge)
    ));
    assert!(matches!(
        udp.send_datagram(&vec![0; MAX_DATAGRAM_BYTES + 1]).await,
        Err(TransportError::FrameTooLarge)
    ));
    udp.close().await.unwrap();
    assert!(matches!(
        udp.send_datagram(b"closed").await,
        Err(TransportError::Closed)
    ));
    assert!(matches!(
        udp.recv_datagram().await,
        Err(TransportError::Closed)
    ));
}

#[tokio::test]
async fn websocket_rejects_invalid_urls_and_binary_boundaries() {
    assert!(matches!(
        WebSocketTransport::connect("http://127.0.0.1:1").await,
        Err(TransportError::InvalidUrl)
    ));
    assert!(matches!(
        WebSocketTransport::connect("ws://[invalid").await,
        Err(TransportError::InvalidUrl)
    ));

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        let _ = futures_util::StreamExt::next(&mut socket).await;
    });
    let mut websocket = WebSocketTransport::connect(&format!("ws://{peer}/transport"))
        .await
        .unwrap();
    assert!(matches!(
        websocket.send_binary(&[]).await,
        Err(TransportError::FrameTooLarge)
    ));
    assert!(matches!(
        websocket
            .send_binary(&vec![0; MAX_WEBSOCKET_MESSAGE_BYTES + 1])
            .await,
        Err(TransportError::FrameTooLarge)
    ));
    websocket.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn websocket_split_halves_deliver_duplex_binary_frames() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        futures_util::SinkExt::send(&mut socket, Message::Ping(Vec::new().into()))
            .await
            .unwrap();
        futures_util::SinkExt::send(&mut socket, Message::Pong(Vec::new().into()))
            .await
            .unwrap();
        // The client automatically answers the server Ping. Keep reading
        // control frames until the actual binary payload arrives; otherwise
        // a scheduler can make the automatic Pong look like the first frame
        // and the test server would drop the socket before echoing anything.
        loop {
            let message = match futures_util::StreamExt::next(&mut socket).await {
                Some(Ok(message)) => message,
                Some(Err(error)) => panic!("server WebSocket read failed: {error}"),
                None => return,
            };
            match message {
                Message::Binary(payload) => {
                    futures_util::SinkExt::send(&mut socket, Message::Binary(payload))
                        .await
                        .unwrap();
                    break;
                }
                Message::Ping(payload) => {
                    futures_util::SinkExt::send(&mut socket, Message::Pong(payload))
                        .await
                        .unwrap();
                }
                Message::Pong(_) => {}
                Message::Close(_) => {
                    futures_util::SinkExt::close(&mut socket).await.unwrap();
                    return;
                }
                _ => {}
            }
        }

        // Keep the accepted socket alive until the client acknowledges the
        // echo and sends its close frame. Dropping it immediately can reset
        // the split reader before it consumes the binary payload.
        while let Some(message) = futures_util::StreamExt::next(&mut socket).await {
            match message.unwrap() {
                Message::Close(_) => {
                    futures_util::SinkExt::close(&mut socket).await.unwrap();
                    break;
                }
                Message::Ping(payload) => {
                    futures_util::SinkExt::send(&mut socket, Message::Pong(payload))
                        .await
                        .unwrap();
                }
                _ => {}
            }
        }
    });

    let transport = Transport::connect_websocket(&format!("ws://{peer}/v1/transport"))
        .await
        .unwrap();
    let (mut reader, mut writer) = transport.into_split();
    assert!(matches!(
        writer.send(&[]).await,
        Err(TransportError::FrameTooLarge)
    ));
    assert!(matches!(
        writer.send(&vec![0; MAX_WEBSOCKET_MESSAGE_BYTES + 1]).await,
        Err(TransportError::FrameTooLarge)
    ));
    // The halves are independent: send and receive concurrently (duplex).
    let (echo_received, wait_for_echo) = oneshot::channel();
    let write = tokio::spawn(async move {
        let sent = writer.send(b"websocket-split").await?;
        wait_for_echo.await.map_err(|_| TransportError::Closed)?;
        writer.close().await?;
        Ok::<_, TransportError>(sent)
    });
    let received = tokio::time::timeout(Duration::from_secs(2), reader.recv())
        .await
        .expect("split reader did not receive the echo")
        .unwrap();
    assert_eq!(received, b"websocket-split");
    echo_received
        .send(())
        .expect("split writer task exited before receiving the echo");
    assert_eq!(
        write.await.expect("split writer task panicked").unwrap(),
        b"websocket-split".len()
    );
    server.await.unwrap();
}

#[tokio::test]
async fn websocket_receives_ping_pong_and_rejects_text_or_oversized_frames() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        futures_util::SinkExt::send(&mut socket, Message::Ping(Vec::new().into()))
            .await
            .unwrap();
        futures_util::SinkExt::send(&mut socket, Message::Pong(Vec::new().into()))
            .await
            .unwrap();
        futures_util::SinkExt::send(
            &mut socket,
            Message::Binary(b"after-control".to_vec().into()),
        )
        .await
        .unwrap();
    });
    let mut transport = WebSocketTransport::connect(&format!("ws://{peer}/control"))
        .await
        .unwrap();
    assert_eq!(transport.recv_binary().await.unwrap(), b"after-control");
    server.await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        futures_util::SinkExt::send(&mut socket, Message::Text("not-binary".into()))
            .await
            .unwrap();
    });
    let mut transport = WebSocketTransport::connect(&format!("ws://{peer}/text"))
        .await
        .unwrap();
    assert!(matches!(
        transport.recv_binary().await,
        Err(TransportError::InvalidFrame)
    ));
    server.await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        futures_util::SinkExt::send(
            &mut socket,
            Message::Binary(vec![0; MAX_WEBSOCKET_MESSAGE_BYTES + 1].into()),
        )
        .await
        .unwrap();
    });
    let mut transport = WebSocketTransport::connect(&format!("ws://{peer}/large"))
        .await
        .unwrap();
    assert!(matches!(
        transport.recv_binary().await,
        Err(TransportError::FrameTooLarge)
    ));
    server.await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        futures_util::SinkExt::send(&mut socket, Message::Close(None))
            .await
            .unwrap();
    });
    let mut transport = WebSocketTransport::connect(&format!("ws://{peer}/close"))
        .await
        .unwrap();
    assert!(matches!(
        transport.recv_binary().await,
        Err(TransportError::Closed)
    ));
    server.await.unwrap();
}

#[cfg(feature = "testkit")]
#[tokio::test]
async fn gated_writers_release_tcp_and_udp_payloads_without_blocking_reads() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut transport = TcpTransport::from_stream(stream);
        assert_eq!(transport.recv_frame().await.unwrap(), b"gated-tcp");
        transport.send_frame(b"tcp-ack").await.unwrap();
        transport.recv_frame().await.unwrap()
    });
    let transport = Transport::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
        .await
        .unwrap();
    let gate = crate::testkit::WriterGate::new();
    let mut gated = transport.with_gated_writer(gate.clone());
    assert_eq!(gated.kind(), TransportKind::Tcp);
    let task = tokio::spawn(async move {
        let first = gated.send(b"gated-tcp").await?;
        let received = gated.recv().await?;
        let second = gated.send(b"second-tcp").await?;
        gated.close().await?;
        Ok::<_, TransportError>((first, received, second))
    });
    gate.entered().await;
    assert!(!task.is_finished());
    gate.release();
    assert_eq!(task.await.unwrap().unwrap(), (9, b"tcp-ack".to_vec(), 10));
    server.await.unwrap();

    let peer_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer = peer_socket.local_addr().unwrap();
    let transport = Transport::bind_udp("127.0.0.1:0".parse().unwrap(), peer)
        .await
        .unwrap();
    let gate = crate::testkit::WriterGate::new();
    let mut gated = transport.with_gated_writer(gate.clone());
    assert_eq!(gated.kind(), TransportKind::Udp);
    let task = tokio::spawn(async move {
        let first = gated.send(b"gated-udp").await?;
        let received = gated.recv().await?;
        let second = gated.send(b"second-udp").await?;
        gated.close().await?;
        Ok::<_, TransportError>((first, received, second))
    });
    gate.entered().await;
    gate.release();
    let mut bytes = [0_u8; 32];
    let (length, source) = peer_socket.recv_from(&mut bytes).await.unwrap();
    assert_eq!(&bytes[..length], b"gated-udp");
    peer_socket.send_to(b"udp-ack", source).await.unwrap();
    let (length, _) = peer_socket.recv_from(&mut bytes).await.unwrap();
    assert_eq!(&bytes[..length], b"second-udp");
    assert_eq!(task.await.unwrap().unwrap(), (9, b"udp-ack".to_vec(), 10));
}

/// A gated WebSocket write parks inside `send` without blocking the read
/// half, and cancelling the in-flight write (dropping the send future)
/// does not disturb the reader's independent delivery.
#[cfg(feature = "testkit")]
#[tokio::test]
async fn websocket_cancelled_write_keeps_the_reader_half_live() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        // Push an independent frame, then hold the socket open until the
        // test ends so the reader has a deterministic delivery target.
        futures_util::SinkExt::send(&mut socket, Message::Binary(b"server-push".to_vec().into()))
            .await
            .unwrap();
        let _ = futures_util::StreamExt::next(&mut socket).await;
    });

    let gate = crate::testkit::WriterGate::new();
    let transport = Transport::connect_websocket(&format!("ws://{peer}/v1/transport"))
        .await
        .unwrap();
    let (mut reader, mut writer) = transport.with_gated_writer(gate.clone()).into_split();

    // Provably park a write inside TransportWriter::send.
    let write_task = tokio::spawn(async move { writer.send(b"parked").await });
    gate.entered().await;
    assert!(
        !write_task.is_finished(),
        "gated WebSocket write is not blocked in-flight"
    );

    // Cancelling the in-flight write does not disturb the read half.
    write_task.abort();
    let pushed = tokio::time::timeout(Duration::from_secs(2), reader.recv())
        .await
        .expect("reader was blocked after the write was cancelled")
        .unwrap();
    assert_eq!(pushed, b"server-push");

    // Releasing the reader half drops the last shared stream reference, so
    // the socket closes and the server task can observe the connection end.
    drop(reader);
    tokio::time::timeout(Duration::from_secs(2), server)
        .await
        .expect("server did not observe the client release")
        .expect("server task panicked");
}

#[tokio::test]
async fn udp_split_halves_share_the_connected_datagram_socket() {
    let left_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let right_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let left_addr = left_socket.local_addr().unwrap();
    let right_addr = right_socket.local_addr().unwrap();
    left_socket.connect(right_addr).await.unwrap();
    right_socket.connect(left_addr).await.unwrap();
    let left = Transport::Udp(UdpTransport::from_socket(left_socket, right_addr));
    let right = Transport::Udp(UdpTransport::from_socket(right_socket, left_addr));

    let (mut left_reader, mut left_writer) = left.into_split();
    let (mut right_reader, mut right_writer) = right.into_split();

    // Split halves preserve datagram boundaries and full-duplex flow.
    assert_eq!(
        left_writer.send(b"split-datagram").await.unwrap(),
        b"split-datagram".len()
    );
    assert_eq!(right_reader.recv().await.unwrap(), b"split-datagram");
    assert_eq!(right_writer.send(b"reply").await.unwrap(), b"reply".len());
    assert_eq!(left_reader.recv().await.unwrap(), b"reply");

    // Closing the writer half releases only that half's Arc reference; the
    // reader half keeps delivering until it is also dropped.
    left_writer.close().await.unwrap();
    assert!(matches!(
        left_writer.send(b"after-close").await,
        Err(TransportError::Closed)
    ));
    assert_eq!(
        right_writer.send(b"still-live").await.unwrap(),
        b"still-live".len()
    );
    assert_eq!(left_reader.recv().await.unwrap(), b"still-live");
    right_writer.close().await.unwrap();
}

#[tokio::test]
async fn websocket_accept_and_connection_failures_are_typed() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut transport = WebSocketTransport::accept(stream).await.unwrap();
        assert_eq!(transport.recv_binary().await.unwrap(), b"accepted");
        transport.send_binary(b"accepted-reply").await.unwrap();
        transport.close().await.unwrap();
    });
    let mut client = Transport::connect_websocket(&format!("ws://{peer}/accepted"))
        .await
        .unwrap();
    assert_eq!(client.send(b"accepted").await.unwrap(), 8);
    assert_eq!(client.recv().await.unwrap(), b"accepted-reply");
    client.close().await.unwrap();
    server.await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        stream
            .write_all(b"not a websocket handshake")
            .await
            .unwrap();
    });
    let raw = tokio::net::TcpStream::connect(peer).await.unwrap();
    assert!(matches!(
        WebSocketTransport::accept(raw).await,
        Err(TransportError::WebSocket(_))
    ));
    server.await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let closed_peer = listener.local_addr().unwrap();
    drop(listener);
    assert!(matches!(
        Transport::connect_tcp("0.0.0.0:0".parse().unwrap(), closed_peer).await,
        Err(TransportError::Io(_))
    ));
    assert!(matches!(
        WebSocketTransport::connect(&format!("ws://{closed_peer}/missing")).await,
        Err(TransportError::WebSocket(_))
    ));
}

#[tokio::test]
async fn split_websocket_reader_maps_binary_text_and_close_boundaries() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        futures_util::SinkExt::send(
            &mut socket,
            Message::Binary(vec![0; MAX_WEBSOCKET_MESSAGE_BYTES + 1].into()),
        )
        .await
        .unwrap();
    });
    let transport = Transport::connect_websocket(&format!("ws://{peer}/oversized"))
        .await
        .unwrap();
    let (mut reader, _writer) = transport.into_split();
    assert!(matches!(
        reader.recv().await,
        Err(TransportError::FrameTooLarge)
    ));
    server.await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        futures_util::SinkExt::send(&mut socket, Message::Text("text".into()))
            .await
            .unwrap();
    });
    let transport = Transport::connect_websocket(&format!("ws://{peer}/text"))
        .await
        .unwrap();
    let (mut reader, _writer) = transport.into_split();
    assert!(matches!(
        reader.recv().await,
        Err(TransportError::InvalidFrame)
    ));
    server.await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket: WebSocketStream<_> = accept_async(stream).await.unwrap();
        futures_util::SinkExt::send(&mut socket, Message::Close(None))
            .await
            .unwrap();
    });
    let transport = Transport::connect_websocket(&format!("ws://{peer}/close"))
        .await
        .unwrap();
    let (mut reader, _writer) = transport.into_split();
    assert!(matches!(reader.recv().await, Err(TransportError::Closed)));
    server.await.unwrap();
}
