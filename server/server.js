#!/usr/bin/env node
/**
 * Connexia sync server.
 *
 * Zero-knowledge design: the server only stores an encrypted blob per user
 * plus a scrypt password hash used to verify logins. It never sees the
 * snapshot plaintext; the client encrypts with a key derived from the
 * user's password (PBKDF2).
 *
 * Zero runtime dependencies - only Node.js built-ins (http, crypto, fs).
 *
 * Usage:
 *   PORT=8047 node server.js
 *
 * Storage (JSON files, atomic writes):
 *   <DATA_DIR>/users.json   - accounts, scrypt hashes, session tokens
 *   <DATA_DIR>/blobs/<id>.json - encrypted snapshot blobs + revisions
 */

'use strict';

const http = require('http');
const net = require('net');
const tls = require('tls');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 8047);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
const MAX_BODY_BYTES = 16 * 1024 * 1024; // 16 MB
const BLOB_LIMIT_BYTES = 6 * 1024 * 1024; // 6 MB

// ---------- Email / SMTP ----------
// Configure SMTP_HOST (+ SMTP_PORT, SMTP_SECURE=true for implicit TLS on 465,
// SMTP_USER, SMTP_PASS, SMTP_FROM) to deliver verification codes. Without
// SMTP the server prints the code to its console instead, which is handy for
// local testing.
const SMTP = {
  host: process.env.SMTP_HOST || '',
  port: Number(
    process.env.SMTP_PORT ||
      (process.env.SMTP_SECURE === 'true' ? 465 : 587)
  ),
  secure: process.env.SMTP_SECURE === 'true',
  user: process.env.SMTP_USER || '',
  pass: process.env.SMTP_PASS || '',
  from: process.env.SMTP_FROM || 'Connexia <noreply@connexia.local>',
};

const VERIFY_CODE_TTL_MS = 10 * 60 * 1000; // 10 minutes
const VERIFY_RESEND_MS = 60 * 1000; // 1 minute between sends
const TOTP_CHALLENGE_TTL_MS = 5 * 60 * 1000; // 5 minutes

const usersFile = () => path.join(DATA_DIR, 'users.json');
const blobFile = (id) => path.join(DATA_DIR, 'blobs', `${id}.json`);

let users = {}; // id -> { email, salt, hash, createdAt, sessions: {token: expiresIso} }
let blobs = {}; // id -> { revision, blob, updatedAt }

function loadJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return fallback;
  }
}

function saveJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file);
}

function load() {
  users = loadJson(usersFile(), {});
  fs.mkdirSync(path.dirname(blobFile('x')), { recursive: true });
  blobs = {};
  for (const id of Object.keys(users)) {
    const account = users[id];
    // Accounts created before email verification existed are treated as
    // verified; only new registrations must verify.
    if (account.emailVerified === undefined) account.emailVerified = true;
    blobs[id] = loadJson(blobFile(id), { revision: 0, blob: null, updatedAt: null });
  }
}

function persistUsers() {
  saveJson(usersFile(), users);
}

function persistBlob(id) {
  saveJson(blobFile(id), blobs[id]);
}

function scryptHash(password, salt) {
  return crypto.scryptSync(password, salt, 64);
}

// ---------- Email delivery (SMTP, no runtime dependencies) ----------

/**
 * Sends one plain-text message over SMTP. Supports implicit TLS (465) and
 * STARTTLS (587), authenticated with AUTH PLAIN. Returns a rejected promise
 * on transport errors so callers can log and continue.
 */
function smtpSend({ to, subject, text }) {
  return new Promise((resolve, reject) => {
    const smtpHost = SMTP.host;
    if (!smtpHost) {
      console.log(`[smtp] no SMTP_HOST configured; would email ${to}:`);
      console.log(`[smtp] subject: ${subject}`);
      console.log(`[smtp] body:\n${text}`);
      resolve();
      return;
    }
    let socket = (SMTP.secure ? tls : net).connect(
      { host: smtpHost, port: SMTP.port, servername: smtpHost }
    );
    let buffer = '';
    let ended = false;
    const timeout = setTimeout(() => {
      finish(new Error('SMTP timeout'));
    }, 20000);

    const queue = [];

    function send(line) {
      socket.write(line + '\r\n');
    }

    function finish(err) {
      if (ended) return;
      ended = true;
      clearTimeout(timeout);
      try {
        socket.end();
      } catch (_) {}
      if (err) reject(err);
      else resolve();
    }

    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      let idx;
      while ((idx = buffer.indexOf('\r\n')) >= 0) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);
        if (line.length < 3) continue;
        const code = Number(line.slice(0, 3));
        // Multi-line replies ("250-...") only end on "250 ...".
        if (line.length > 3 && line[3] !== ' ') continue;
        const step = queue.shift();
        if (!step) return;
        if (step.code !== null && code !== step.code) {
          finish(new Error(`SMTP ${code}: ${line}`));
          return;
        }
        step.run(code, line);
      }
    });

    socket.on('error', (err) => finish(err));
    socket.on('close', () => {
      if (!ended) finish(new Error('SMTP connection closed'));
    });

    const authPlain =
      'AUTH PLAIN ' +
      Buffer.from('\0' + SMTP.user + '\0' + SMTP.pass).toString('base64');

    // Queue: (expected code -> next action) for the whole conversation.
    const mailFrom = () => send('MAIL FROM:<' + SMTP.from + '>');
    const authIfConfigured = () => {
      if (SMTP.user) {
        queue.push({ code: 235, run: mailFrom });
        send(authPlain);
      } else {
        mailFrom();
      }
    };

    queue.push({ code: 220, run: () => send('EHLO connexia.local') });
    queue.push({
      code: 250,
      run: () => {
        if (SMTP.secure) {
          authIfConfigured();
        } else {
          queue.push({
            code: 220,
            run: () => {
              socket = tls.connect(
                { socket, servername: smtpHost },
                () => {
                  queue.push({ code: 250, run: authIfConfigured });
                  send('EHLO connexia.local');
                }
              );
              socket.on('error', (err) => finish(err));
            },
          });
          send('STARTTLS');
        }
      },
    });

    queue.push({ code: 250, run: () => send('RCPT TO:<' + to + '>') });
    queue.push({ code: 250, run: () => send('DATA') });
    queue.push({ code: 354, run: () => send(messageBody()) });
    queue.push({ code: 250, run: () => send('QUIT') });
    queue.push({ code: 221, run: () => finish(null) });

    function messageBody() {
      const dotStuffed = text
        .replace(/\r\n/g, '\n')
        .split('\n')
        .map((line) => (line === '.' ? '..' : line))
        .join('\r\n');
      return (
        'From: ' +
        SMTP.from +
        '\r\nTo: ' +
        to +
        '\r\nSubject: ' +
        subject +
        '\r\nMIME-Version: 1.0\r\n' +
        'Content-Type: text/plain; charset=utf-8\r\n' +
        'Content-Transfer-Encoding: 8bit\r\n' +
        '\r\n' +
        dotStuffed +
        '\r\n.\r\n'
      );
    }
  });
}

function newVerifyCode() {
  return {
    code: crypto.randomInt(0, 1000000).toString().padStart(6, '0'),
    expiresAt: new Date(Date.now() + VERIFY_CODE_TTL_MS).toISOString(),
  };
}

function verifyCodeValid(account, code) {
  return (
    account.verifyCode &&
    account.verifyCode.code === String(code || '') &&
    new Date(account.verifyCode.expiresAt).getTime() > Date.now()
  );
}

function canResend(account) {
  return (
    !account.lastVerifySentAt ||
    Date.now() - new Date(account.lastVerifySentAt).getTime() >= VERIFY_RESEND_MS
  );
}

function sendVerificationEmail(email, code) {
  smtpSend({
    to: email,
    subject: 'Your Connexia verification code',
    text:
      'Your Connexia verification code is: ' +
      code +
      '\n\nEnter it in the app to verify your email. ' +
      'The code expires in 10 minutes.\n\nIf you did not create a ' +
      'Connexia account, you can ignore this email.',
  }).catch((err) => console.error('[smtp] ' + err.message));
}

// ---------- TOTP (RFC 6238), implemented with node:crypto ----------

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function base32Encode(buf) {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of buf) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

function base32Decode(input) {
  const clean = String(input).toUpperCase().replace(/[^A-Z2-7]/g, '');
  const out = [];
  let bits = 0;
  let value = 0;
  for (const ch of clean) {
    const idx = BASE32.indexOf(ch);
    if (idx < 0) continue;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

function totpAt(secretB32, timeSec) {
  const key = base32Decode(secretB32);
  const counter = Math.floor(timeSec / 30);
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(counter));
  const hmac = crypto.createHmac('sha1', key).update(buf).digest();
  const offset = hmac[hmac.length - 1] & 0x0f;
  const code =
    (((hmac[offset] & 0x7f) << 24) |
      (hmac[offset + 1] << 16) |
      (hmac[offset + 2] << 8) |
      hmac[offset + 3]) %
    1000000;
  return code.toString().padStart(6, '0');
}

function verifyTotp(secretB32, code) {
  const now = Math.floor(Date.now() / 1000);
  for (let i = -1; i <= 1; i++) {
    if (totpAt(secretB32, now + i * 30) === String(code || '')) return true;
  }
  return false;
}

function newTotpSecret() {
  return base32Encode(crypto.randomBytes(20));
}

function otpauthUrl(email, secret) {
  return (
    'otpauth://totp/Connexia:' +
    encodeURIComponent(email) +
    '?secret=' +
    secret +
    '&issuer=Connexia&digits=6&period=30'
  );
}

function issueSession(account) {
  const token = crypto.randomBytes(32).toString('hex');
  const expires = new Date(Date.now() + SESSION_TTL_MS).toISOString();
  account.sessions[token] = expires;
  // Keep the session map small.
  for (const [t, e] of Object.entries(account.sessions)) {
    if (new Date(e).getTime() < Date.now()) delete account.sessions[t];
  }
  return token;
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  });
  res.end(payload);
}

function sendError(res, status, message) {
  sendJson(res, status, { error: message });
}

function readBody(req, onDone) {
  let size = 0;
  const chunks = [];
  req.on('data', (chunk) => {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      onDone(new Error('payload too large'));
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });
  req.on('end', () => {
    try {
      onDone(null, Buffer.concat(chunks).toString('utf8'));
    } catch (err) {
      onDone(err);
    }
  });
  req.on('error', (err) => onDone(err));
}

function auth(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Bearer ')) return null;
  const token = header.slice(7);
  for (const [id, account] of Object.entries(users)) {
    const expires = account.sessions ? account.sessions[token] : null;
    if (expires && new Date(expires).getTime() > Date.now()) return id;
  }
  return null;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    });
    res.end();
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/health') {
    sendJson(res, 200, { ok: true, time: new Date().toISOString() });
    return;
  }

  // POST /api/register { email, password }
  if (req.method === 'POST' && url.pathname === '/api/register') {
    readBody(req, (err, body) => {
      if (err) return sendError(res, 400, 'invalid body');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        return sendError(res, 400, 'invalid JSON');
      }
      const email = String(parsed.email || '').trim().toLowerCase();
      const password = String(parsed.password || '');
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return sendError(res, 400, 'invalid email');
      }
      if (password.length < 8) {
        return sendError(res, 400, 'password must be at least 8 characters');
      }
      const existing = Object.values(users).find((u) => u.email === email);
      if (existing) return sendError(res, 409, 'an account with this email already exists');

      const id = crypto.randomUUID();
      const salt = crypto.randomBytes(16).toString('hex');
      const verifyCode = newVerifyCode();
      users[id] = {
        email,
        salt,
        hash: scryptHash(password, Buffer.from(salt, 'hex')).toString('hex'),
        createdAt: new Date().toISOString(),
        emailVerified: false,
        verifyCode,
        lastVerifySentAt: new Date().toISOString(),
        sessions: {},
      };
      blobs[id] = { revision: 0, blob: null, updatedAt: null };
      persistUsers();
      persistBlob(id);
      sendVerificationEmail(email, verifyCode.code);
      console.log(`[${new Date().toISOString()}] registered ${email} (${id})`);
      sendJson(res, 201, { userId: id, emailVerified: false });
    });
    return;
  }

  // POST /api/login { email, password }
  if (req.method === 'POST' && url.pathname === '/api/login') {
    readBody(req, (err, body) => {
      if (err) return sendError(res, 400, 'invalid body');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        return sendError(res, 400, 'invalid JSON');
      }
      const email = String(parsed.email || '').trim().toLowerCase();
      const password = String(parsed.password || '');
      const account = Object.values(users).find((u) => u.email === email);
      const salt = account ? Buffer.from(account.salt, 'hex') : crypto.randomBytes(16);
      const expected = account
        ? Buffer.from(account.hash, 'hex')
        : Buffer.alloc(64);
      const actual = scryptHash(password, salt);
      if (!account || !crypto.timingSafeEqual(expected, actual)) {
        return sendError(res, 401, 'invalid email or password');
      }
      if (account.emailVerified === false) {
        // Resend the code so the user can complete verification right away
        // (rate-limited, so repeated sign-ins cannot spam the inbox).
        if (canResend(account)) {
          account.verifyCode = newVerifyCode();
          account.lastVerifySentAt = new Date().toISOString();
          persistUsers();
          sendVerificationEmail(account.email, account.verifyCode.code);
        }
        return sendJson(res, 403, { error: 'emailNotVerified' });
      }
      if (account.totpSecret) {
        const challenge = crypto.randomBytes(32).toString('hex');
        account.challenge = {
          token: challenge,
          expiresAt: new Date(
            Date.now() + TOTP_CHALLENGE_TTL_MS
          ).toISOString(),
        };
        persistUsers();
        return sendJson(res, 200, {
          needsTotp: true,
          challengeToken: challenge,
        });
      }
      const token = issueSession(account);
      persistUsers();
      console.log(`[${new Date().toISOString()}] login ${email}`);
      sendJson(res, 200, { token, userId: accountIdOf(account) });
    });
    return;
  }

  // POST /api/verify-email { email, code }
  if (req.method === 'POST' && url.pathname === '/api/verify-email') {
    readBody(req, (err, body) => {
      if (err) return sendError(res, 400, 'invalid body');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        return sendError(res, 400, 'invalid JSON');
      }
      const email = String(parsed.email || '').trim().toLowerCase();
      const account = Object.values(users).find((u) => u.email === email);
      if (!account || account.emailVerified) {
        return sendError(res, 404, 'no pending verification for this email');
      }
      if (!verifyCodeValid(account, parsed.code)) {
        return sendError(res, 400, 'invalid or expired code');
      }
      account.emailVerified = true;
      delete account.verifyCode;
      delete account.lastVerifySentAt;
      persistUsers();
      console.log(`[${new Date().toISOString()}] verified ${email}`);
      sendJson(res, 200, { verified: true });
    });
    return;
  }

  // POST /api/resend-verification { email }
  if (req.method === 'POST' && url.pathname === '/api/resend-verification') {
    readBody(req, (err, body) => {
      if (err) return sendError(res, 400, 'invalid body');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        return sendError(res, 400, 'invalid JSON');
      }
      const email = String(parsed.email || '').trim().toLowerCase();
      const account = Object.values(users).find((u) => u.email === email);
      if (!account || account.emailVerified) {
        return sendError(res, 404, 'no pending verification for this email');
      }
      if (!canResend(account)) {
        return sendError(res, 429, 'wait a minute before requesting another code');
      }
      account.verifyCode = newVerifyCode();
      account.lastVerifySentAt = new Date().toISOString();
      persistUsers();
      sendVerificationEmail(account.email, account.verifyCode.code);
      sendJson(res, 200, { resent: true });
    });
    return;
  }

  // POST /api/login/2fa { challengeToken, code }
  if (req.method === 'POST' && url.pathname === '/api/login/2fa') {
    readBody(req, (err, body) => {
      if (err) return sendError(res, 400, 'invalid body');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        return sendError(res, 400, 'invalid JSON');
      }
      const token = String(parsed.challengeToken || '');
      const account = Object.values(users).find(
        (u) => u.challenge && u.challenge.token === token
      );
      if (!account) {
        return sendError(res, 400, 'invalid or expired challenge');
      }
      if (new Date(account.challenge.expiresAt).getTime() < Date.now()) {
        delete account.challenge;
        persistUsers();
        return sendError(res, 400, 'invalid or expired challenge');
      }
      if (!account.totpSecret || !verifyTotp(account.totpSecret, parsed.code)) {
        return sendError(res, 401, 'invalid code');
      }
      delete account.challenge;
      const session = issueSession(account);
      persistUsers();
      console.log(`[${new Date().toISOString()}] login ${account.email} (2fa)`);
      sendJson(res, 200, {
        token: session,
        userId: accountIdOf(account),
      });
    });
    return;
  }

  const userId = auth(req);
  if (!userId) {
    return sendError(res, 401, 'missing or invalid session token');
  }
  const account = users[userId];
  if (!account) return sendError(res, 401, 'unknown account');
  if (account.emailVerified === false) {
    return sendError(res, 403, 'email not verified');
  }

  // GET /api/account -> verification & 2FA status
  if (req.method === 'GET' && url.pathname === '/api/account') {
    sendJson(res, 200, {
      email: account.email,
      emailVerified: account.emailVerified !== false,
      totpEnabled: !!account.totpSecret,
    });
    return;
  }

  // POST /api/enable-2fa -> generates a fresh TOTP secret (pending until
  // confirmed with a code from the authenticator app)
  if (req.method === 'POST' && url.pathname === '/api/enable-2fa') {
    const secret = newTotpSecret();
    account.totpPending = { secret, createdAt: new Date().toISOString() };
    persistUsers();
    sendJson(res, 200, { secret, otpauthUrl: otpauthUrl(account.email, secret) });
    return;
  }

  // POST /api/confirm-2fa { code }
  if (req.method === 'POST' && url.pathname === '/api/confirm-2fa') {
    readBody(req, (err, body) => {
      if (err) return sendError(res, 400, 'invalid body');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        return sendError(res, 400, 'invalid JSON');
      }
      if (!account.totpPending) {
        return sendError(res, 400, 'no pending 2FA setup');
      }
      if (!verifyTotp(account.totpPending.secret, parsed.code)) {
        return sendError(res, 400, 'invalid code');
      }
      account.totpSecret = account.totpPending.secret;
      delete account.totpPending;
      persistUsers();
      console.log(`[${new Date().toISOString()}] 2FA enabled for ${account.email}`);
      sendJson(res, 200, { enabled: true });
    });
    return;
  }

  // POST /api/disable-2fa { code }
  if (req.method === 'POST' && url.pathname === '/api/disable-2fa') {
    readBody(req, (err, body) => {
      if (err) return sendError(res, 400, 'invalid body');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        return sendError(res, 400, 'invalid JSON');
      }
      if (!account.totpSecret) {
        return sendError(res, 400, '2FA is not enabled');
      }
      if (!verifyTotp(account.totpSecret, parsed.code)) {
        return sendError(res, 400, 'invalid code');
      }
      delete account.totpSecret;
      persistUsers();
      console.log(`[${new Date().toISOString()}] 2FA disabled for ${account.email}`);
      sendJson(res, 200, { disabled: true });
    });
    return;
  }

  // GET /api/sync -> latest encrypted snapshot
  if (req.method === 'GET' && url.pathname === '/api/sync') {
    const blob = blobs[userId] || { revision: 0, blob: null, updatedAt: null };
    sendJson(res, 200, {
      revision: blob.revision || 0,
      blob: blob.blob,
      updatedAt: blob.updatedAt,
    });
    return;
  }

  // POST /api/sync { revision, blob } - optimistic concurrency on revision
  if (req.method === 'POST' && url.pathname === '/api/sync') {
    readBody(req, (err, body) => {
      if (err) return sendError(res, 400, 'invalid body');
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (_) {
        return sendError(res, 400, 'invalid JSON');
      }
      const revision = Number(parsed.revision);
      const blob = String(parsed.blob || '');
      if (!Number.isInteger(revision) || revision < 0) {
        return sendError(res, 400, 'invalid revision');
      }
      if (Buffer.byteLength(blob, 'base64') > BLOB_LIMIT_BYTES) {
        return sendError(res, 413, 'blob too large');
      }
      const current = blobs[userId] || { revision: 0, blob: null, updatedAt: null };
      if (revision !== (current.revision || 0)) {
        return sendError(res, 409, 'revision conflict', current.revision);
      }
      blobs[userId] = {
        revision: (current.revision || 0) + 1,
        blob,
        updatedAt: new Date().toISOString(),
      };
      persistBlob(userId);
      console.log(
        `[${new Date().toISOString()}] sync ${account.email} -> revision ${blobs[userId].revision}`
      );
      sendJson(res, 200, { revision: blobs[userId].revision });
    });
    return;
  }

  sendError(res, 404, 'not found');
});

function accountIdOf(account) {
  for (const [id, a] of Object.entries(users)) {
    if (a === account) return id;
  }
  return null;
}

load();
server.listen(PORT, () => {
  console.log(`Connexia sync server listening on http://0.0.0.0:${PORT}`);
  console.log(`Data directory: ${DATA_DIR}`);
});
