use network_protocol::NETWORK_PROTOCOL_VERSION;
use zeroize::Zeroizing;

use super::path_handshake;
use super::{
    CryptoHandshakeError, APPLICATION_ROOT_DOMAIN, HANDSHAKE_CAPABILITY, IDENTITY_ONLY_ACCEPT,
    IDENTITY_ONLY_BINDING, IDENTITY_ONLY_CONFIRM, IDENTITY_PUBLIC_KEY_BYTES,
    MAX_HANDSHAKE_PAYLOAD_BYTES, MAX_SESSION_BINDING_BYTES, NOISE_PUBLIC_KEY_BYTES,
    ROOT_CONFIRM_BYTES, ROOT_CONFIRM_DOMAIN, ROOT_EXCHANGE_ACCEPT, ROOT_EXCHANGE_MAGIC,
    ROOT_EXCHANGE_ROOT_CONFIRM, ROOT_EXCHANGE_ROOT_SEED, ROOT_EXCHANGE_VERSION, ROOT_SEED_BYTES,
};
pub(super) fn derive_application_root(
    root_seed: &[u8; ROOT_SEED_BYTES],
    handshake_hash: &[u8],
    session_binding: &str,
) -> Result<[u8; 32], CryptoHandshakeError> {
    let hkdf = hkdf::Hkdf::<sha2::Sha256>::new(Some(handshake_hash), root_seed);
    let mut root = [0u8; 32];
    let mut info = Vec::with_capacity(APPLICATION_ROOT_DOMAIN.len() + session_binding.len());
    info.extend_from_slice(APPLICATION_ROOT_DOMAIN);
    info.extend_from_slice(session_binding.as_bytes());
    hkdf.expand(&info, &mut root)
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok(root)
}

pub(super) fn derive_root_confirm(
    root_key: &[u8; 32],
    handshake_hash: &[u8; 32],
    session_binding: &str,
) -> Result<[u8; ROOT_CONFIRM_BYTES], CryptoHandshakeError> {
    let hkdf = hkdf::Hkdf::<sha2::Sha256>::new(Some(handshake_hash), root_key);
    let mut info = Vec::with_capacity(ROOT_CONFIRM_DOMAIN.len() + session_binding.len());
    info.extend_from_slice(ROOT_CONFIRM_DOMAIN);
    info.extend_from_slice(session_binding.as_bytes());
    let mut confirm = [0u8; ROOT_CONFIRM_BYTES];
    hkdf.expand(&info, &mut confirm)
        .map_err(|_| CryptoHandshakeError::Failed)?;
    Ok(confirm)
}

pub(super) fn root_exchange_payload(
    message_type: u8,
    session_binding: &str,
    payload: &[u8],
) -> Result<Vec<u8>, CryptoHandshakeError> {
    if !matches!(
        message_type,
        ROOT_EXCHANGE_ROOT_SEED
            | ROOT_EXCHANGE_ROOT_CONFIRM
            | ROOT_EXCHANGE_ACCEPT
            | IDENTITY_ONLY_BINDING
            | IDENTITY_ONLY_CONFIRM
            | IDENTITY_ONLY_ACCEPT
    ) || payload.len() > MAX_HANDSHAKE_PAYLOAD_BYTES
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    validate_binding(session_binding)?;
    let mut output = Vec::with_capacity(12 + session_binding.len() + payload.len());
    output.extend_from_slice(ROOT_EXCHANGE_MAGIC);
    output.push(ROOT_EXCHANGE_VERSION);
    output.push(message_type);
    output.extend_from_slice(&NETWORK_PROTOCOL_VERSION.to_be_bytes());
    append_string(&mut output, session_binding)?;
    append_bytes(&mut output, payload)?;
    Ok(output)
}

pub(super) fn root_seed_payload(
    root_seed: &[u8; ROOT_SEED_BYTES],
    local_session_binding: &str,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(local_session_binding)?;
    let mut payload = Vec::with_capacity(ROOT_SEED_BYTES + 2 + local_session_binding.len());
    payload.extend_from_slice(root_seed);
    append_string(&mut payload, local_session_binding)?;
    Ok(payload)
}

pub(super) fn root_confirm_payload(
    confirm: &[u8; ROOT_CONFIRM_BYTES],
    local_session_binding: &str,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(local_session_binding)?;
    let mut payload = Vec::with_capacity(ROOT_CONFIRM_BYTES + 2 + local_session_binding.len());
    payload.extend_from_slice(confirm);
    append_string(&mut payload, local_session_binding)?;
    Ok(payload)
}

pub(super) fn identity_only_binding_payload(
    local_session_binding: &str,
) -> Result<Vec<u8>, CryptoHandshakeError> {
    validate_binding(local_session_binding)?;
    let mut payload = Vec::with_capacity(2 + local_session_binding.len());
    append_string(&mut payload, local_session_binding)?;
    Ok(payload)
}

pub(super) fn parse_identity_only_binding_payload(
    payload: &[u8],
) -> Result<String, CryptoHandshakeError> {
    let mut cursor = Cursor::new(payload);
    let binding = cursor.take_string(MAX_SESSION_BINDING_BYTES)?;
    if !cursor.done() {
        return Err(CryptoHandshakeError::Invalid);
    }
    validate_binding(&binding)?;
    Ok(binding)
}

pub(super) fn parse_root_exchange_payload<'a>(
    message: &'a [u8],
    expected_type: u8,
    session_binding: &str,
) -> Result<&'a [u8], CryptoHandshakeError> {
    let mut cursor = Cursor::new(message);
    if cursor.take(4)? != ROOT_EXCHANGE_MAGIC
        || cursor.take_byte()? != ROOT_EXCHANGE_VERSION
        || cursor.take_byte()? != expected_type
        || cursor.take_u32()? != NETWORK_PROTOCOL_VERSION
        || cursor.take_string(MAX_SESSION_BINDING_BYTES)? != session_binding
    {
        return Err(CryptoHandshakeError::Invalid);
    }
    let payload = cursor.take_bytes(MAX_HANDSHAKE_PAYLOAD_BYTES)?;
    if !cursor.done() {
        return Err(CryptoHandshakeError::Invalid);
    }
    Ok(payload)
}

pub(super) fn parse_fixed_root_exchange_payload<const N: usize>(
    message: &[u8],
    expected_type: u8,
    session_binding: &str,
) -> Result<Zeroizing<[u8; N]>, CryptoHandshakeError> {
    let payload = parse_root_exchange_payload(message, expected_type, session_binding)?;
    let value = payload
        .try_into()
        .map_err(|_| CryptoHandshakeError::Invalid)?;
    Ok(Zeroizing::new(value))
}

pub(super) fn validate_binding(binding: &str) -> Result<(), CryptoHandshakeError> {
    if binding.is_empty()
        || binding.len() > MAX_SESSION_BINDING_BYTES
        || !binding.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(CryptoHandshakeError::InvalidBinding);
    }
    Ok(())
}

pub(super) fn append_string(output: &mut Vec<u8>, value: &str) -> Result<(), CryptoHandshakeError> {
    if value.len() > u16::MAX as usize {
        return Err(CryptoHandshakeError::Invalid);
    }
    append_string_unchecked(output, value);
    Ok(())
}

pub(super) fn append_string_unchecked(output: &mut Vec<u8>, value: &str) {
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value.as_bytes());
}

pub(super) fn append_bytes(output: &mut Vec<u8>, value: &[u8]) -> Result<(), CryptoHandshakeError> {
    if value.len() > u16::MAX as usize {
        return Err(CryptoHandshakeError::Invalid);
    }
    append_bytes_unchecked(output, value);
    Ok(())
}

pub(super) fn append_bytes_unchecked(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value);
}

pub(super) fn proof_unsigned_length_with_path(
    peer_id: &str,
    session_binding: &str,
    local_session_binding: &str,
    metadata: &path_handshake::PathHandshakeMetadata,
) -> usize {
    4 + 1
        + 4
        + 2
        + peer_id.len()
        + IDENTITY_PUBLIC_KEY_BYTES
        + NOISE_PUBLIC_KEY_BYTES
        + 2
        + session_binding.len()
        + 2
        + local_session_binding.len()
        + 4
        + 4
        + 1
        + 1
        + 2
        + metadata.path_binding.len()
        + 2
        + metadata.connection_profile.len()
        + 2
        + HANDSHAKE_CAPABILITY.len()
}

pub(super) struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    pub(super) fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    pub(super) fn take(&mut self, length: usize) -> Result<&'a [u8], CryptoHandshakeError> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or(CryptoHandshakeError::Invalid)?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or(CryptoHandshakeError::Invalid)?;
        self.offset = end;
        Ok(value)
    }

    pub(super) fn take_byte(&mut self) -> Result<u8, CryptoHandshakeError> {
        Ok(self.take(1)?[0])
    }

    pub(super) fn take_u32(&mut self) -> Result<u32, CryptoHandshakeError> {
        Ok(u32::from_be_bytes(
            self.take(4)?
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        ))
    }

    pub(super) fn take_fixed(&mut self, length: usize) -> Result<&'a [u8], CryptoHandshakeError> {
        self.take(length)
    }

    pub(super) fn take_string(&mut self, max: usize) -> Result<String, CryptoHandshakeError> {
        let length = u16::from_be_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        ) as usize;
        if length == 0 || length > max {
            return Err(CryptoHandshakeError::Invalid);
        }
        String::from_utf8(self.take(length)?.to_vec()).map_err(|_| CryptoHandshakeError::Invalid)
    }

    pub(super) fn take_bytes(&mut self, max: usize) -> Result<&'a [u8], CryptoHandshakeError> {
        let length = u16::from_be_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| CryptoHandshakeError::Invalid)?,
        ) as usize;
        if length > max {
            return Err(CryptoHandshakeError::Invalid);
        }
        self.take(length)
    }

    pub(super) fn remaining(&self) -> usize {
        self.bytes.len().saturating_sub(self.offset)
    }

    pub(super) fn done(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

impl<'a> path_handshake::MetadataCursor for Cursor<'a> {
    fn take_byte(&mut self) -> Result<u8, path_handshake::PathHandshakeError> {
        self.take(1)
            .map(|bytes| bytes[0])
            .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)
    }

    fn take_u32(&mut self) -> Result<u32, path_handshake::PathHandshakeError> {
        let bytes = self
            .take(4)
            .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)?;
        Ok(u32::from_be_bytes(bytes.try_into().map_err(|_| {
            path_handshake::PathHandshakeError::InvalidFrame
        })?))
    }

    fn take_bytes(&mut self, max: usize) -> Result<&[u8], path_handshake::PathHandshakeError> {
        let bytes = self
            .take(2)
            .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)?;
        let length = u16::from_be_bytes(
            bytes
                .try_into()
                .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)?,
        ) as usize;
        if length == 0 || length > max {
            return Err(path_handshake::PathHandshakeError::InvalidFrame);
        }
        self.take(length)
            .map_err(|_| path_handshake::PathHandshakeError::InvalidFrame)
    }
}
