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

fn hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

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
        crate::rdp_trace::hex("Security Exchange PDU", &buf[..written]);
        Ok(buf[..written].to_vec())
    }

    /// Dumps the derived key material to the opt-in trace log.
    pub fn trace_keys(&self, context: &str) {
        if std::env::var_os("CONNEXIA_RDP_TRACE").is_none() {
            return;
        }

        crate::rdp_trace::line(&format!(
            "{context}: method={:?} key_len={} \
             sign={} decrypt={} encrypt={}",
            self.method,
            self.key_len,
            hex_string(&self.sign_key),
            hex_string(&self.decrypt_key),
            hex_string(&self.encrypt_key),
        ));
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
        // A single buffer may contain several concatenated TPKT PDUs: for
        // example the CLIPRDR initialization batch is Capabilities + Temporary
        // Directory + Format List, and `ironrdp_svc::encode_svc_messages`
        // produces one MCS SendDataRequest per PDU. Each PDU carries its own
        // security header and MAC, so they must be encrypted individually.
        let mut out = Vec::with_capacity(frame.len() + 16);
        let mut offset = 0;

        while offset < frame.len() {
            let Some(pdu_len) = tpkt_length(&frame[offset..]) else {
                // Not a TPKT-framed PDU (or truncated); keep the remainder.
                out.extend_from_slice(&frame[offset..]);
                break;
            };

            out.extend_from_slice(&self.encrypt_one_slow_path(
                &frame[offset..offset + pdu_len],
                strip_security_header,
            )?);
            offset += pdu_len;
        }

        Ok(out)
    }

    /// Encrypts a single slow-path PDU (one TPKT-framed `SendDataRequest`).
    fn encrypt_one_slow_path(&mut self, frame: &[u8], strip_security_header: bool) -> anyhow::Result<Vec<u8>> {
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

        let use_count = self.encrypt_checksum_use_count;
        let mac = salted_mac_signature(&self.sign_key[..self.key_len], body, use_count);

        let mut cipher = body.to_vec();
        self.encrypt_rc4(&mut cipher);

        // NOTE: never log `body`, it is the Client Info plaintext (credentials).
        crate::rdp_trace::line(&format!(
            "encrypt_slow_path: flags={flags:#06x} use_count={use_count} \
             body_len={} mac={}",
            body.len(),
            hex_string(&mac),
        ));
        crate::rdp_trace::hex("  ciphertext", &cipher);

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
        crate::rdp_trace::hex("  frame", &buf[..written]);
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
        crate::rdp_trace::line(&format!(
            "decrypt_slow_path: flags={flags:#06x} encrypted={} user_data_len={}",
            flags & SEC_ENCRYPT != 0,
            user_data.len(),
        ));
        if flags & SEC_ENCRYPT == 0 {
            return Ok(frame.to_vec());
        }

        let security_header = &user_data[..4];
        let mac = &user_data[4..12];

        let use_count = self.decrypt_checksum_use_count;
        let mut plain = user_data[12..].to_vec();
        self.decrypt_rc4(&mut plain);

        crate::rdp_trace::line(&format!(
            "decrypt_slow_path: flags={flags:#06x} use_count={use_count} \
             body_len={} prepend={prepend_security_header}",
            plain.len(),
        ));
        crate::rdp_trace::hex("  ciphertext", &user_data[12..]);
        crate::rdp_trace::hex("  plaintext", &plain);

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
        crate::rdp_trace::line(&format!(
            "decrypt_fast_path: header={header:#04x} encrypted={} len={}",
            flags & 0x02 != 0,
            frame.len(),
        ));
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

    /// Encrypts an outgoing Fast-Path input PDU (client → server).
    ///
    /// The wire layout is
    /// `[header:1][length:2][MAC:8][encrypted(numEvents? + events)]`.
    /// When the header's number-of-events field is zero a dedicated `numEvents`
    /// byte follows the length, but it belongs to the encrypted region: the
    /// server skips the 8-byte MAC first and only then reads `numEvents`
    /// uncrypted (see xrdp's `xrdp_sec_recv_fastpath`). Both the MAC and the
    /// cipher therefore cover that byte plus the events.
    fn encrypt_fast_path(&mut self, frame: &[u8]) -> anyhow::Result<Vec<u8>> {
        let header = *frame.first().ok_or_else(|| anyhow!("empty Fast-Path PDU"))?;
        let (_, length_size) = per_read_length(&frame[1..])?;
        // When the number-of-events field is zero, a dedicated byte follows the
        // length (used for batches of more than 15 events).
        let has_num_events_byte = (header >> 2) & 0x1f == 0;
        let payload_start = 1 + length_size + usize::from(has_num_events_byte);
        if frame.len() < payload_start {
            bail!("truncated Fast-Path PDU");
        }

        let mut plain = Vec::with_capacity(frame.len() - payload_start + 1);
        if has_num_events_byte {
            plain.push(frame[1 + length_size]);
        }
        plain.extend_from_slice(&frame[payload_start..]);

        crate::rdp_trace::line(&format!(
            "encrypt_fast_path: header={header:#04x} length_size={length_size} \
             num_events_byte={has_num_events_byte} plain_len={} use_count={} events={}",
            plain.len(),
            self.encrypt_use_count,
            hex_string(&plain),
        ));
        let mac = salted_mac_signature(&self.sign_key[..self.key_len], &plain, self.encrypt_checksum_use_count);

        let mut cipher = plain;
        self.encrypt_rc4(&mut cipher);

        // MAC comes immediately after the header/length; the (optional)
        // number-of-events byte is part of the encrypted region that follows.
        let mut out = Vec::with_capacity(1 + 2 + 8 + cipher.len());
        // Keep the action/number-of-events bits, set ENCRYPTED and SECURE_CHECKSUM.
        out.push((header & 0x3f) | (0x03 << 6));
        per_write_length(&mut out, 1 + 2 + 8 + cipher.len());
        out.extend_from_slice(&mac);
        out.extend_from_slice(&cipher);
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

/// Total length of the TPKT PDU at the start of `buf`, or `None` when the
/// buffer does not begin with a complete TPKT PDU.
fn tpkt_length(buf: &[u8]) -> Option<usize> {
    if buf.len() < 4 || buf[0] != 0x03 {
        return None;
    }

    let length = u16::from_be_bytes([buf[2], buf[3]]) as usize;
    if length < 4 || length > buf.len() {
        return None;
    }

    Some(length)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Reference values produced by a verbatim port of FreeRDP's
    /// `security_establish_keys` / xrdp's `xrdp_sec_establish_keys` for these
    /// fixed randoms (128-bit method).
    #[test]
    fn establish_matches_reference_keys() {
        let client_random: [u8; 32] = core::array::from_fn(|i| (i as u8) + 1);
        let server_random: [u8; 32] = core::array::from_fn(|i| (i as u8) + 0x80);

        let security = establish(&client_random, &server_random, EncryptionMethod::BIT_128);

        assert_eq!(security.key_len, 16);
        assert_eq!(hex(&security.sign_key), "7d018c30a4cdc5006b0d99de35df5e61");
        assert_eq!(hex(&security.decrypt_key), "f3a12eb7b25c6c0f319eedac244318e1");
        assert_eq!(hex(&security.encrypt_key), "fa5de76f517167cd9d480126ca603818");
    }

    fn unhex(text: &str) -> Vec<u8> {
        (0..text.len() / 2)
            .map(|i| u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).unwrap())
            .collect()
    }

    /// Fast-Path input must be framed exactly like FreeRDP's
    /// `fastpath_send_multiple_input_pdu`: `[header|0xC0][len:2 BE = total][MAC:8][cipher]`,
    /// with the MAC computed over the plaintext event bytes.
    #[test]
    fn fast_path_input_matches_freerdp_layout() {
        let client_random: [u8; 32] = core::array::from_fn(|i| (i as u8) + 1);
        let server_random: [u8; 32] = core::array::from_fn(|i| (i as u8) + 0x80);
        let mut security = establish(&client_random, &server_random, EncryptionMethod::BIT_128);

        // A single Synchronize event, as IronRDP's `FastPathInput` encodes it:
        // header (1 event, action 0) = 0x04, PER length = 3, event = 0x60.
        let frame = [0x04u8, 0x03, 0x60];

        let expected_mac = salted_mac_signature(&security.sign_key[..security.key_len], &[0x60], 0);
        let out = security.encrypt_fast_path(&frame).expect("encrypt fast-path input");

        assert_eq!(out.len(), 12, "1 header + 2 length + 8 MAC + 1 cipher");
        assert_eq!(out[0], 0xC4, "action/number-of-events kept, ENCRYPTED|SECURE_CHECKSUM set");
        assert_eq!(
            [out[1], out[2]],
            [0x80, 0x0C],
            "2-byte PER length equal to the whole PDU size (12)"
        );
        assert_eq!(&out[3..11], &expected_mac, "MAC over the plaintext event bytes");
    }

    /// With more than 15 events the header's count field is zero and IronRDP
    /// emits a dedicated `numEvents` byte after the length. That byte must be
    /// encrypted together with the events (right after the MAC); the server
    /// skips the MAC first and reads `numEvents` from the decrypted stream.
    #[test]
    fn fast_path_input_encrypts_num_events_byte() {
        let client_random: [u8; 32] = core::array::from_fn(|i| (i as u8) + 1);
        let server_random: [u8; 32] = core::array::from_fn(|i| (i as u8) + 0x80);
        let mut security = establish(&client_random, &server_random, EncryptionMethod::BIT_128);

        // 16 Synchronize events: header = 0x00 (count spills into a byte),
        // PER length = 19 (1 header + 1 length + 1 count + 16 events),
        // count byte = 0x10, then 16 event bytes 0x60.
        let mut frame = vec![0x00, 0x13, 0x10];
        frame.extend_from_slice(&[0x60; 16]);
        assert_eq!(frame.len(), 19);

        let mut plain = vec![0x10];
        plain.extend_from_slice(&[0x60; 16]);
        let expected_mac = salted_mac_signature(&security.sign_key[..security.key_len], &plain, 0);

        let out = security.encrypt_fast_path(&frame).expect("encrypt fast-path input");

        assert_eq!(out.len(), 28, "1 header + 2 length + 8 MAC + 1 count + 16 events");
        assert_eq!(out[0], 0xC0);
        assert_eq!([out[1], out[2]], [0x80, 0x1C], "2-byte PER length = 28");
        assert_eq!(
            &out[3..11],
            &expected_mac,
            "MAC covers the numEvents byte and the events"
        );
    }

    /// A synthetic proprietary certificate (512-bit modulus) and the raw
    /// little-endian RSA result, both produced by an independent Python
    /// reference implementing the FreeRDP layout.
    #[test]
    fn rsa_encrypt_matches_reference() {
        let cert = unhex(concat!(
            "01000000010000000100000006005c0052534131",
            "48000000000200003f00000001000100030a11181f262d343b424950575e656c",
            "737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c",
            "535a61686f767d848b9299a0a7aeb5bc0000000000000000",
        ));
        let client_random: [u8; 32] = core::array::from_fn(|i| (i as u8) + 1);
        let expected = "af6d22694bbf950def3435cabafa4221261cb0c0f721fa8f72c08f2cb469f5b5bd48254f803f3f44372d328a4e59ce1a4415000d7a46a180cadbef87f2aebd71";

        let key = ServerPublicKey::parse(&cert).expect("parse cert");
        assert_eq!(key.modulus_len, 64);
        assert_eq!(hex(&key.encrypt(&client_random)), expected);
    }
}
