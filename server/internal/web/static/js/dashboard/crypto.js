const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function b64ToBytes(b64) {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

export function bytesToB64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function b64urlToBytes(text) {
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/");
  return b64ToBytes(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
}

export function randomBytes(length) {
  return crypto.getRandomValues(new Uint8Array(length));
}

export function importAesKey(raw) {
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function deriveSyncKey(password, userId) {
  const base = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt: encoder.encode("connexia-sync-v1:" + userId), iterations: 100000, hash: "SHA-256" },
    base,
    256,
  );
  return new Uint8Array(bits);
}

export async function encryptString(plaintext, key) {
  const nonce = randomBytes(12);
  const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, encoder.encode(plaintext));
  const out = new Uint8Array(nonce.length + sealed.byteLength);
  out.set(nonce);
  out.set(new Uint8Array(sealed), nonce.length);
  return bytesToB64(out);
}

export async function decryptString(ciphertext, key) {
  const raw = b64ToBytes(ciphertext);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.subarray(0, 12) }, key, raw.subarray(12));
  return decoder.decode(plain);
}

class SshWriter {
  constructor() {
    this.parts = [];
  }

  uint32(n) {
    const b = new Uint8Array(4);
    new DataView(b.buffer).setUint32(0, n);
    this.parts.push(b);
    return this;
  }

  string(value) {
    const bytes = typeof value === "string" ? encoder.encode(value) : value;
    this.uint32(bytes.length);
    this.parts.push(bytes);
    return this;
  }

  mpint(bytes) {
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0) start++;
    let value = bytes.subarray(start);
    if (value[0] & 0x80) {
      value = concat([new Uint8Array([0]), value]);
    }
    return this.string(value);
  }

  raw(bytes) {
    this.parts.push(bytes);
    return this;
  }

  bytes() {
    return concat(this.parts);
  }
}

class SshReader {
  constructor(bytes) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.offset = 0;
  }

  uint32() {
    const n = this.view.getUint32(this.offset);
    this.offset += 4;
    return n;
  }

  string() {
    const length = this.uint32();
    const out = this.bytes.subarray(this.offset, this.offset + length);
    if (out.length !== length) throw new Error("truncated key");
    this.offset += length;
    return out;
  }
}

function concat(parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

const OPENSSH_MAGIC = "openssh-key-v1\0";

function opensshBody(pem) {
  const match = /-----BEGIN OPENSSH PRIVATE KEY-----([\s\S]*?)-----END OPENSSH PRIVATE KEY-----/.exec(pem || "");
  if (!match) return null;
  try {
    const bytes = b64ToBytes(match[1].replace(/\s+/g, ""));
    if (decoder.decode(bytes.subarray(0, OPENSSH_MAGIC.length)) !== OPENSSH_MAGIC) return null;
    return new SshReader(bytes.subarray(OPENSSH_MAGIC.length));
  } catch {
    return null;
  }
}

export function isEncryptedPrivateKey(pem) {
  if (/BEGIN ENCRYPTED PRIVATE KEY/.test(pem) || /Proc-Type:\s*4,ENCRYPTED/.test(pem)) {
    return true;
  }
  const reader = opensshBody(pem);
  if (!reader) return false;
  try {
    return decoder.decode(reader.string()) !== "none";
  } catch {
    return false;
  }
}

export function publicKeyFromPrivate(pem) {
  const reader = opensshBody(pem);
  if (!reader) return null;
  try {
    reader.string();
    reader.string();
    reader.string();
    if (reader.uint32() < 1) return null;
    const blob = reader.string();
    const type = decoder.decode(new SshReader(blob).string());
    return `${type} ${bytesToB64(blob)}`;
  } catch {
    return null;
  }
}

function pemWrap(bytes) {
  const b64 = bytesToB64(bytes);
  const lines = b64.match(/.{1,70}/g).join("\n");
  return `-----BEGIN OPENSSH PRIVATE KEY-----\n${lines}\n-----END OPENSSH PRIVATE KEY-----\n`;
}

function opensshPrivateKey(publicBlob, privateFields, comment) {
  const check = randomBytes(4);
  const section = new SshWriter().raw(check).raw(check).raw(privateFields).string(comment);
  let body = section.bytes();
  const padding = [];
  for (let i = 1; (body.length + padding.length) % 8 !== 0; i++) {
    padding.push(i);
  }
  body = concat([body, new Uint8Array(padding)]);

  const file = new SshWriter()
    .raw(encoder.encode(OPENSSH_MAGIC))
    .string("none")
    .string("none")
    .string(new Uint8Array(0))
    .uint32(1)
    .string(publicBlob)
    .string(body);
  return pemWrap(file.bytes());
}

const CURVES = {
  256: { webcrypto: "P-256", ssh: "nistp256" },
  384: { webcrypto: "P-384", ssh: "nistp384" },
  521: { webcrypto: "P-521", ssh: "nistp521" },
};

export async function generateSshKey({ type, bits, comment }) {
  if (type === "ED25519") {
    const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
    const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
    const pub = b64urlToBytes(jwk.x);
    const seed = b64urlToBytes(jwk.d);
    const blob = new SshWriter().string("ssh-ed25519").string(pub).bytes();
    const fields = new SshWriter().string("ssh-ed25519").string(pub).string(concat([seed, pub])).bytes();
    return { privatePem: opensshPrivateKey(blob, fields, comment), publicKey: `ssh-ed25519 ${bytesToB64(blob)} ${comment}` };
  }

  if (type === "ECDSA") {
    const curve = CURVES[bits];
    const keyType = "ecdsa-sha2-" + curve.ssh;
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: curve.webcrypto }, true, ["sign", "verify"]);
    const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
    const point = concat([new Uint8Array([4]), b64urlToBytes(jwk.x), b64urlToBytes(jwk.y)]);
    const blob = new SshWriter().string(keyType).string(curve.ssh).string(point).bytes();
    const fields = new SshWriter().string(keyType).string(curve.ssh).string(point).mpint(b64urlToBytes(jwk.d)).bytes();
    return { privatePem: opensshPrivateKey(blob, fields, comment), publicKey: `${keyType} ${bytesToB64(blob)} ${comment}` };
  }

  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: bits, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  const [n, e, d, p, q, qi] = [jwk.n, jwk.e, jwk.d, jwk.p, jwk.q, jwk.qi].map(b64urlToBytes);
  const blob = new SshWriter().string("ssh-rsa").mpint(e).mpint(n).bytes();
  const fields = new SshWriter().string("ssh-rsa").mpint(n).mpint(e).mpint(d).mpint(qi).mpint(p).mpint(q).bytes();
  return { privatePem: opensshPrivateKey(blob, fields, comment), publicKey: `ssh-rsa ${bytesToB64(blob)} ${comment}` };
}
