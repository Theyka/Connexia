//! Legacy Standard RDP Security (RC4) for the RDP backend.
//!
//! IronRDP deliberately does not implement the deprecated RC4-based
//! `PROTOCOL_RDP` security layer. Some servers, however, only offer it, so this
//! module implements the cryptographic core required to interoperate:
//!
//! * RC4 with the RDP key-update scheme (every 4096 packets),
//! * the RDP "salted" MACs (SHA1 + MD5),
//! * key establishment from the client/server randoms,
//! * RSA encryption of the client random using the server's proprietary
//!   certificate, and
//! * the Security Exchange PDU plus slow- and fast-path framing.
//!
//! The algorithms mirror FreeRDP's `libfreerdp/core/security.c`,
//! `libfreerdp/core/rdp.c` and `libfreerdp/core/connection.c`.

use std::borrow::Cow;

use anyhow::{anyhow, bail, Context as _};
use md5::Md5;
use num_bigint::BigUint;
use rand::RngCore;
use sha1::{Digest, Sha1};

use ironrdp::core::{decode, encode_buf, WriteBuf};
use ironrdp::pdu::gcc::EncryptionMethod;
use ironrdp::pdu::mcs::{decode_send_data_indication, McsMessage, SendDataIndication, SendDataRequest};
use ironrdp::pdu::x224::X224;

const PAD1: [u8; 40] = [0x36; 40];
const PAD2: [u8; 48] = [0x5C; 48];
const SALT: [u8; 3] = [0xD1, 0x26, 0x9E];

const SEC_ENCRYPT: u16 = 0x0008;
const SEC_SECURE_CHECKSUM: u16 = 0x0800;

/// Number of packets after which the RC4 keys are updated, as mandated by the
/// RDP protocol.
const KEY_UPDATE_INTERVAL: u32 = 4096;

const CLIENT_RANDOM_LEN: usize = 32;

/// RC4 stream cipher.
struct Rc4 {
    state: [u8; 256],
    i: u8,
    j: u8,
}

impl Rc4 {
    fn new(key: &[u8]) -> Self {
        assert!(!key.is_empty(), "RC4 key must not be empty");

        let mut state = [0u8; 256];
        for (i, item) in state.iter_mut().enumerate() {
            *item = i as u8;
        }

        let mut j: u8 = 0;
        for i in 0..256usize {
            j = j.wrapping_add(state[i]).wrapping_add(key[i % key.len()]);
            state.swap(i, usize::from(j));
        }

        Self { state, i: 0, j: 0 }
    }

    fn apply(&mut self, data: &mut [u8]) {
        for byte in data.iter_mut() {
            self.i = self.i.wrapping_add(1);
            self.j = self.j.wrapping_add(self.state[usize::from(self.i)]);
            self.state.swap(usize::from(self.i), usize::from(self.j));
            let idx = self.state[usize::from(self.i)].wrapping_add(self.state[usize::from(self.j)]);
            let k = self.state[usize::from(idx)];
            *byte ^= k;
        }
    }
}

/// `SaltedHash(Salt, Input, Salt1, Salt2) = MD5(Salt + SHA1(Input + Salt + Salt1 + Salt2))`
fn salted_hash(salt: &[u8], salt1: &[u8], salt2: &[u8], input: &[u8]) -> [u8; 16] {
    let mut hasher = Sha1::new();
    hasher.update(input);
    hasher.update(salt);
    hasher.update(salt1);
    hasher.update(salt2);
    let sha = hasher.finalize();

    let mut hasher = Md5::new();
    hasher.update(salt);
    hasher.update(sha);
    hasher.finalize().into()
}

fn md5_16_32_32(in0: &[u8], in1: &[u8], in2: &[u8]) -> [u8; 16] {
    let mut hasher = Md5::new();
    hasher.update(in0);
    hasher.update(in1);
    hasher.update(in2);
    hasher.finalize().into()
}

/// `MACSignature = First64Bits(MD5(MACKey + pad2 + SHA1(MACKey + pad1 + length + data)))`
fn mac_signature(sign_key: &[u8], data: &[u8]) -> [u8; 8] {
    let length_le = (data.len() as u32).to_le_bytes();

    let mut hasher = Sha1::new();
    hasher.update(sign_key);
    hasher.update(PAD1);
    hasher.update(length_le);
    hasher.update(data);
    let sha = hasher.finalize();

    let mut hasher = Md5::new();
    hasher.update(sign_key);
    hasher.update(PAD2);
    hasher.update(sha);
    let digest: [u8; 16] = hasher.finalize().into();

    let mut out = [0u8; 8];
    out.copy_from_slice(&digest[..8]);
    out
}

/// Salted variant of [`mac_signature`], also covering the encryption counter.
fn salted_mac_signature(sign_key: &[u8], data: &[u8], use_count: u32) -> [u8; 8] {
    let length_le = (data.len() as u32).to_le_bytes();
    let use_count_le = use_count.to_le_bytes();

    let mut hasher = Sha1::new();
    hasher.update(sign_key);
    hasher.update(PAD1);
    hasher.update(length_le);
    hasher.update(data);
    hasher.update(use_count_le);
    let sha = hasher.finalize();

    let mut hasher = Md5::new();
    hasher.update(sign_key);
    hasher.update(PAD2);
    hasher.update(sha);
    let digest: [u8; 16] = hasher.finalize().into();

    let mut out = [0u8; 8];
    out.copy_from_slice(&digest[..8]);
    out
}

fn key_update(key: &mut [u8; 16], update_key: &[u8; 16], key_len: usize, method: EncryptionMethod) {
    let mut hasher = Sha1::new();
    hasher.update(&update_key[..key_len]);
    hasher.update(PAD1);
    hasher.update(&key[..key_len]);
    let sha = hasher.finalize();

    let mut hasher = Md5::new();
    hasher.update(&update_key[..key_len]);
    hasher.update(PAD2);
    hasher.update(sha);
    let digest: [u8; 16] = hasher.finalize().into();
    *key = digest;

    let mut rc4 = Rc4::new(&key[..key_len]);
    rc4.apply(&mut key[..key_len]);

    if method.contains(EncryptionMethod::BIT_40) {
        key[..3].copy_from_slice(&SALT[..3]);
    } else if method.contains(EncryptionMethod::BIT_56) {
        key[..1].copy_from_slice(&SALT[..1]);
    }
}

/// Reads a PER length (as used by the Fast-Path header), returning the value and
/// the number of bytes it occupied.
fn per_read_length(buf: &[u8]) -> anyhow::Result<(usize, usize)> {
    let a = *buf.first().ok_or_else(|| anyhow!("truncated PER length"))?;
    if a & 0x80 != 0 {
        let b = *buf.get(1).ok_or_else(|| anyhow!("truncated PER length"))?;
        Ok((((usize::from(a) & 0x7f) << 8) | usize::from(b), 2))
    } else {
        Ok((usize::from(a), 1))
    }
}

/// Writes a PER length, always using the two-byte form (like FreeRDP).
fn per_write_length(out: &mut Vec<u8>, len: usize) {
    out.push(0x80 | ((len >> 8) as u8 & 0x7f));
    out.push((len & 0xff) as u8);
}

/// The server's RSA public key, as carried by the proprietary (non-X.509)
/// certificate used for Standard RDP Security.
struct ServerPublicKey {
    modulus: BigUint,
    exponent: BigUint,
    modulus_len: usize,
}

impl ServerPublicKey {
    /// Parses the proprietary certificate blob (`CERT_CHAIN_VERSION_1`).
    fn parse(cert: &[u8]) -> anyhow::Result<Self> {
        if cert.len() < 36 {
            bail!("server certificate is too short ({})", cert.len());
        }

        let version = u32::from_le_bytes([cert[0], cert[1], cert[2], cert[3]]);
        if version != 1 {
            bail!("unsupported server certificate version {version} (expected 1)");
        }

        let sig_alg = u32::from_le_bytes([cert[4], cert[5], cert[6], cert[7]]);
        let key_alg = u32::from_le_bytes([cert[8], cert[9], cert[10], cert[11]]);
        // Both `SIGNATURE_ALG_RSA` and `KEY_EXCHANGE_ALG_RSA` are 1 in MS-RDPBCGR.
        if sig_alg != 1 || key_alg != 1 {
            bail!("unsupported server certificate algorithms (sig={sig_alg}, key={key_alg})");
        }

        let blob_type = u16::from_le_bytes([cert[12], cert[13]]);
        if blob_type != 0x0006 {
            bail!("unsupported public key blob type 0x{blob_type:04X}");
        }

        if &cert[16..20] != b"RSA1" {
            bail!("invalid RSA1 magic in server public key");
        }

        let key_len = u32::from_le_bytes([cert[20], cert[21], cert[22], cert[23]]) as usize;
        let bit_len = u32::from_le_bytes([cert[24], cert[25], cert[26], cert[27]]);
        let data_len = u32::from_le_bytes([cert[28], cert[29], cert[30], cert[31]]);

        if key_len <= 8 || key_len != (bit_len as usize / 8) + 8 {
            bail!("invalid RSA key length {key_len} (bit length {bit_len})");
        }
        if data_len != (bit_len / 8).saturating_sub(1) {
            bail!("invalid RSA data length {data_len} (bit length {bit_len})");
        }

        let modulus_len = key_len - 8;
        let modulus_end = 36 + modulus_len;
        if cert.len() < modulus_end + 8 {
            bail!("server certificate is truncated");
        }

        // Both the exponent and the modulus are stored little-endian.
        let exponent_bytes = &cert[32..36];
        let modulus_bytes = &cert[36..modulus_end];

        Ok(Self {
            modulus: BigUint::from_bytes_le(modulus_bytes),
            exponent: BigUint::from_bytes_le(exponent_bytes),
            modulus_len,
        })
    }

    /// Raw RSA public-key operation (no padding), as used by RDP. The message
    /// is interpreted little-endian and the result is returned little-endian,
    /// zero-padded to the modulus length.
    fn encrypt(&self, message: &[u8]) -> Vec<u8> {
        let m = BigUint::from_bytes_le(message);
        let c = m.modpow(&self.exponent, &self.modulus);

        let mut out = c.to_bytes_le();
        out.resize(self.modulus_len, 0);
        out
    }
}

/// Derives the client's RC4 key material and encrypts the client random.
///
/// Both steps are needed to build the Security Exchange PDU; the same derived
/// state is then used to construct the [`RdpSecurity`] wrapper.
pub fn establish(
    client_random: &[u8; CLIENT_RANDOM_LEN],
    server_random: &[u8; CLIENT_RANDOM_LEN],
    method: EncryptionMethod,
) -> RdpSecurity {
    let mut pre_master_secret = [0u8; 48];
    pre_master_secret[..24].copy_from_slice(&client_random[..24]);
    pre_master_secret[24..].copy_from_slice(&server_random[..24]);

    let master_secret = [
        salted_hash(&pre_master_secret, client_random, server_random, b"A"),
        salted_hash(&pre_master_secret, client_random, server_random, b"BB"),
        salted_hash(&pre_master_secret, client_random, server_random, b"CCC"),
    ]
    .concat();

    let session_key_blob = [
        salted_hash(&master_secret, client_random, server_random, b"X"),
        salted_hash(&master_secret, client_random, server_random, b"YY"),
        salted_hash(&master_secret, client_random, server_random, b"ZZZ"),
    ]
    .concat();

    let mut sign_key = [0u8; 16];
    sign_key.copy_from_slice(&session_key_blob[..16]);

    let mut decrypt_key = md5_16_32_32(&session_key_blob[16..32], client_random, server_random);
    let mut encrypt_key = md5_16_32_32(&session_key_blob[32..48], client_random, server_random);

    let key_len = if method.contains(EncryptionMethod::BIT_128) {
        16
    } else if method.contains(EncryptionMethod::BIT_56) {
        sign_key[..1].copy_from_slice(&SALT[..1]);
        decrypt_key[..1].copy_from_slice(&SALT[..1]);
        encrypt_key[..1].copy_from_slice(&SALT[..1]);
        8
    } else {
        sign_key[..3].copy_from_slice(&SALT[..3]);
        decrypt_key[..3].copy_from_slice(&SALT[..3]);
        encrypt_key[..3].copy_from_slice(&SALT[..3]);
        8
    };

    let rc4_encrypt = Rc4::new(&encrypt_key[..key_len]);
    let rc4_decrypt = Rc4::new(&decrypt_key[..key_len]);

    RdpSecurity {
        method,
        key_len,
        sign_key,
        encrypt_key,
        decrypt_key,
        encrypt_update_key: encrypt_key,
        decrypt_update_key: decrypt_key,
        rc4_encrypt,
        rc4_decrypt,
        encrypt_use_count: 0,
        decrypt_use_count: 0,
        encrypt_checksum_use_count: 0,
        decrypt_checksum_use_count: 0,
    }
}

pub struct RdpSecurity {
    method: EncryptionMethod,
    key_len: usize,
    sign_key: [u8; 16],
    encrypt_key: [u8; 16],
    decrypt_key: [u8; 16],
    encrypt_update_key: [u8; 16],
    decrypt_update_key: [u8; 16],
    rc4_encrypt: Rc4,
    rc4_decrypt: Rc4,
    encrypt_use_count: u32,
    decrypt_use_count: u32,
    encrypt_checksum_use_count: u32,
    decrypt_checksum_use_count: u32,
}

impl RdpSecurity {
    /// Picks the strongest encryption method both sides support.
    pub fn select_method(server: EncryptionMethod) -> anyhow::Result<EncryptionMethod> {
        for method in [
            EncryptionMethod::BIT_128,
            EncryptionMethod::BIT_56,
            EncryptionMethod::BIT_40,
        ] {
            if server.contains(method) {
                return Ok(method);
            }
        }

        bail!(
            "server requires an unsupported RDP encryption method ({server:?}); only RC4 40/56/128-bit is implemented"
        )
    }

    /// Builds the Security Exchange PDU carrying the RSA-encrypted client
    /// random. `initiator_id`/`channel_id` route it like a Client Info PDU.
    pub fn security_exchange_pdu(
        initiator_id: u16,
        channel_id: u16,
        client_random: &[u8; CLIENT_RANDOM_LEN],
        server_cert: &[u8],
    ) -> anyhow::Result<Vec<u8>> {
        let public_key = ServerPublicKey::parse(server_cert)
            .context("parse server public key for Security Exchange")?;
        let encrypted = public_key.encrypt(client_random);

        let mut user_data = Vec::with_capacity(4 + 4 + encrypted.len() + 8);
        user_data.extend_from_slice(&(0x0001u16 | 0x0200u16).to_le_bytes());
        user_data.extend_from_slice(&0u16.to_le_bytes());
        user_data.extend_from_slice(&((encrypted.len() + 8) as u32).to_le_bytes());
        user_data.extend_from_slice(&encrypted);
        user_data.extend_from_slice(&[0u8; 8]);

        let pdu = SendDataRequest {
            initiator_id,
            channel_id,
            user_data: Cow::Owned(user_data),
        };

        let mut buf = WriteBuf::new();
        let written = encode_buf(&X224(pdu), &mut buf).context("encode Security Exchange PDU")?;
        Ok(buf[..written].to_vec())
    }

    pub fn generate_client_random() -> [u8; CLIENT_RANDOM_LEN] {
        let mut random = [0u8; CLIENT_RANDOM_LEN];
        rand::rng().fill_bytes(&mut random);
        random
    }

    fn encrypt_rc4(&mut self, data: &mut [u8]) {
        if self.encrypt_use_count >= KEY_UPDATE_INTERVAL {
            key_update(
                &mut self.encrypt_key,
                &self.encrypt_update_key,
                self.key_len,
                self.method,
            );
            self.rc4_encrypt = Rc4::new(&self.encrypt_key[..self.key_len]);
            self.encrypt_use_count = 0;
        }

        self.rc4_encrypt.apply(data);
        self.encrypt_use_count += 1;
        self.encrypt_checksum_use_count += 1;
    }

    fn decrypt_rc4(&mut self, data: &mut [u8]) {
        if self.decrypt_use_count >= KEY_UPDATE_INTERVAL {
            key_update(
                &mut self.decrypt_key,
                &self.decrypt_update_key,
                self.key_len,
                self.method,
            );
            self.rc4_decrypt = Rc4::new(&self.decrypt_key[..self.key_len]);
            self.decrypt_use_count = 0;
        }

        self.rc4_decrypt.apply(data);
        self.decrypt_use_count += 1;
        self.decrypt_checksum_use_count += 1;
    }

    /// Encrypts an outgoing slow-path PDU (an X.224/MCS `SendDataRequest`).
    ///
    /// When `strip_security_header` is set, the first four bytes (a
    /// `BasicSecurityHeader` that IronRDP embeds for Client Info and licensing
    /// PDUs) are moved out of the encrypted region and become the outer
    /// security header, matching the wire format.
    pub fn encrypt_slow_path(&mut self, frame: &[u8], strip_security_header: bool) -> anyhow::Result<Vec<u8>> {
        let msg: X224<McsMessage<'_>> =
            decode(frame).context("decode outgoing slow-path PDU")?;
        let McsMessage::SendDataRequest(request) = msg.0 else {
            // Not a SendDataRequest: leave untouched (e.g. Security Exchange).
            return Ok(frame.to_vec());
        };

        let payload = request.user_data.as_ref();
        let (flags, body) = if strip_security_header && payload.len() >= 4 {
            (
                u16::from_le_bytes([payload[0], payload[1]]) | SEC_ENCRYPT | SEC_SECURE_CHECKSUM,
                &payload[4..],
            )
        } else {
            (SEC_ENCRYPT | SEC_SECURE_CHECKSUM, payload)
        };

        let mac = salted_mac_signature(&self.sign_key[..self.key_len], body, self.encrypt_checksum_use_count);

        let mut cipher = body.to_vec();
        self.encrypt_rc4(&mut cipher);

        let mut user_data = Vec::with_capacity(4 + 8 + cipher.len());
        user_data.extend_from_slice(&flags.to_le_bytes());
        user_data.extend_from_slice(&0u16.to_le_bytes());
        user_data.extend_from_slice(&mac);
        user_data.extend_from_slice(&cipher);

        let pdu = SendDataRequest {
            initiator_id: request.initiator_id,
            channel_id: request.channel_id,
            user_data: Cow::Owned(user_data),
        };

        let mut buf = WriteBuf::new();
        let written = encode_buf(&X224(pdu), &mut buf).context("encode encrypted slow-path PDU")?;
        Ok(buf[..written].to_vec())
    }

    /// Decrypts an incoming slow-path PDU.
    ///
    /// `prepend_security_header` controls whether the security header is
    /// re-attached to the decrypted body (required for licensing and
    /// auto-detect PDUs, which IronRDP models with an embedded
    /// `BasicSecurityHeader`).
    pub fn decrypt_slow_path(&mut self, frame: &[u8], prepend_security_header: bool) -> anyhow::Result<Vec<u8>> {
        let ctx = decode_send_data_indication(frame).context("decode incoming slow-path PDU")?;
        let user_data = ctx.user_data;

        if user_data.len() < 12 {
            return Ok(frame.to_vec());
        }

        let flags = u16::from_le_bytes([user_data[0], user_data[1]]);
        if flags & SEC_ENCRYPT == 0 {
            return Ok(frame.to_vec());
        }

        let security_header = &user_data[..4];
        let mac = &user_data[4..12];

        let mut plain = user_data[12..].to_vec();
        self.decrypt_rc4(&mut plain);

        let salted = flags & SEC_SECURE_CHECKSUM != 0;
        let expected = if salted {
            salted_mac_signature(
                &self.sign_key[..self.key_len],
                &plain,
                self.decrypt_checksum_use_count.wrapping_sub(1),
            )
        } else {
            mac_signature(&self.sign_key[..self.key_len], &plain)
        };

        if expected != mac {
            // Standard RDP Security cannot protect against MITM anyway;
            // FreeRDP deliberately treats signature mismatches as non-fatal.
            tracing::warn!("incoming RDP packet signature mismatch");
        }

        let mut rebuilt = Vec::with_capacity(user_data.len());
        if prepend_security_header {
            // Clear SEC_ENCRYPT: the payload is now plaintext.
            let plain_flags = flags & !SEC_ENCRYPT;
            rebuilt.extend_from_slice(&plain_flags.to_le_bytes());
            rebuilt.extend_from_slice(&security_header[2..4]);
        }
        rebuilt.extend_from_slice(&plain);

        let pdu = SendDataIndication {
            initiator_id: ctx.initiator_id,
            channel_id: ctx.channel_id,
            user_data: Cow::Owned(rebuilt),
        };

        let mut buf = WriteBuf::new();
        let written = encode_buf(&X224(pdu), &mut buf).context("encode decrypted slow-path PDU")?;
        Ok(buf[..written].to_vec())
    }

    /// Fast-Path output PDUs (server → client) are laid out as
    /// `[header][length][MAC 8][ciphertext]`.
    fn decrypt_fast_path(&mut self, frame: &[u8]) -> anyhow::Result<Vec<u8>> {
        let header = *frame.first().ok_or_else(|| anyhow!("empty Fast-Path PDU"))?;
        let flags = (header >> 6) & 0x03;
        if flags & 0x02 == 0 {
            return Ok(frame.to_vec());
        }

        let (_, length_size) = per_read_length(&frame[1..])?;
        let header_len = 1 + length_size;
        if frame.len() < header_len + 8 {
            bail!("truncated encrypted Fast-Path PDU");
        }

        let mac = &frame[header_len..header_len + 8];
        let mut plain = frame[header_len + 8..].to_vec();
        self.decrypt_rc4(&mut plain);

        let salted = flags & 0x01 != 0;
        let expected = if salted {
            salted_mac_signature(
                &self.sign_key[..self.key_len],
                &plain,
                self.decrypt_checksum_use_count.wrapping_sub(1),
            )
        } else {
            mac_signature(&self.sign_key[..self.key_len], &plain)
        };

        if expected != mac {
            tracing::warn!("incoming Fast-Path RDP packet signature mismatch");
        }

        let mut out = Vec::with_capacity(1 + 2 + plain.len());
        out.push(header & 0x3f); // clear the encryption flags
        per_write_length(&mut out, 1 + 2 + plain.len());
        out.extend_from_slice(&plain);
        Ok(out)
    }

    /// Fast-Path input PDUs (client → server) are laid out the same way.
    fn encrypt_fast_path(&mut self, frame: &[u8]) -> anyhow::Result<Vec<u8>> {
        let header = *frame.first().ok_or_else(|| anyhow!("empty Fast-Path PDU"))?;
        let (_, length_size) = per_read_length(&frame[1..])?;
        // When the number-of-events field is zero, a dedicated byte follows the
        // length (used for batches of more than 15 events). It stays outside the
        // encrypted region.
        let has_num_events_byte = (header >> 2) & 0x0f == 0;
        let payload_start = 1 + length_size + usize::from(has_num_events_byte);
        if frame.len() < payload_start {
            bail!("truncated Fast-Path PDU");
        }

        let num_events_byte = has_num_events_byte.then(|| frame[1 + length_size]);
        let payload = &frame[payload_start..];
        let mac = salted_mac_signature(&self.sign_key[..self.key_len], payload, self.encrypt_checksum_use_count);

        let mut cipher = payload.to_vec();
        self.encrypt_rc4(&mut cipher);

        let mut body = Vec::with_capacity(usize::from(has_num_events_byte) + 8 + cipher.len());
        if let Some(byte) = num_events_byte {
            body.push(byte);
        }
        body.extend_from_slice(&mac);
        body.extend_from_slice(&cipher);

        let mut out = Vec::with_capacity(1 + 2 + body.len());
        // Keep the action/number-of-events bits, set ENCRYPTED and SECURE_CHECKSUM.
        out.push((header & 0x3f) | (0x03 << 6));
        per_write_length(&mut out, 1 + 2 + body.len());
        out.extend_from_slice(&body);
        Ok(out)
    }

    /// Encrypts a frame regardless of whether it is slow- or Fast-Path.
    pub fn encrypt_frame(&mut self, frame: &[u8]) -> anyhow::Result<Vec<u8>> {
        if frame.first() == Some(&0x03) {
            // Slow-path: never strip an embedded security header during the
            // session (share-control PDUs have none).
            self.encrypt_slow_path(frame, false)
        } else {
            self.encrypt_fast_path(frame)
        }
    }

    /// Decrypts a frame regardless of whether it is slow- or Fast-Path.
    pub fn decrypt_frame(&mut self, frame: &[u8]) -> anyhow::Result<Vec<u8>> {
        if frame.first() == Some(&0x03) {
            self.decrypt_slow_path(frame, false)
        } else {
            self.decrypt_fast_path(frame)
        }
    }
}
