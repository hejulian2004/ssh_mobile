//! QUIC 单向应用通道帧。
//!
//! 文件传输继续使用独立的双向 stream；Delivery 消息使用单向 stream，
//! 这样文件协议和应用信封不会因为各自演进而互相误解析。每次重连只
//! 重新建立 stream，真正的 MessageId、Sequence 和 RecoveryEpoch 由上层
//! DataMessage 持有。

use network_protocol::NETWORK_PROTOCOL_VERSION;
use quinn::{Connection, RecvStream, SendStream};
use std::io::{Error, ErrorKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const CHANNEL_MAGIC: &[u8; 4] = b"SMCH";
pub const MAX_CHANNEL_FRAME_BYTES: usize = 48 * 1024;

/// 应用通道内的两类非业务 transport frame。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ChannelFrameKind {
    DataMessage = 1,
    DeliveryAck = 2,
    RealtimeSignal = 6,
}

impl TryFrom<u8> for ChannelFrameKind {
    type Error = Error;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::DataMessage),
            2 => Ok(Self::DeliveryAck),
            6 => Ok(Self::RealtimeSignal),
            _ => Err(Error::new(
                ErrorKind::InvalidData,
                "unsupported channel frame kind",
            )),
        }
    }
}

/// 在新建的 QUIC 单向 stream 上发送一个已编码的应用信封。
pub async fn send_channel_frame(
    connection: &Connection,
    kind: ChannelFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut send = connection.open_uni().await?;
    write_channel_frame(&mut send, kind, payload).await?;
    send.finish()?;
    Ok(())
}

/// 写入带长度边界的应用通道帧。
pub async fn write_channel_frame(
    send: &mut SendStream,
    kind: ChannelFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if payload.is_empty() || payload.len() > MAX_CHANNEL_FRAME_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "channel payload is outside protocol bounds",
        )
        .into());
    }
    send.write_all(CHANNEL_MAGIC).await?;
    send.write_u32(NETWORK_PROTOCOL_VERSION).await?;
    send.write_u8(kind as u8).await?;
    send.write_u32(payload.len() as u32).await?;
    send.write_all(payload).await?;
    send.flush().await?;
    Ok(())
}

/// 读取一个完整应用通道帧；长度先于分配校验，避免远端控制内存。
pub async fn read_channel_frame(
    recv: &mut RecvStream,
) -> Result<(ChannelFrameKind, Vec<u8>), Box<dyn std::error::Error + Send + Sync>> {
    let mut magic = [0u8; 4];
    recv.read_exact(&mut magic).await?;
    if &magic != CHANNEL_MAGIC {
        return Err(Error::new(ErrorKind::InvalidData, "invalid channel frame magic").into());
    }
    if recv.read_u32().await? != NETWORK_PROTOCOL_VERSION {
        return Err(Error::new(ErrorKind::InvalidData, "unsupported channel frame version").into());
    }
    let kind = ChannelFrameKind::try_from(recv.read_u8().await?)?;
    let payload_len = recv.read_u32().await? as usize;
    if payload_len == 0 || payload_len > MAX_CHANNEL_FRAME_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidData,
            "channel payload is outside protocol bounds",
        )
        .into());
    }
    let mut payload = vec![0u8; payload_len];
    recv.read_exact(&mut payload).await?;
    Ok((kind, payload))
}

#[cfg(test)]
#[path = "tests/channel.rs"]
mod tests;
