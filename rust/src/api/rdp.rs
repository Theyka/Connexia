//! RDP connectivity built on the IronRDP crate suite.
//!
//! Establishes the full connection sequence (security negotiation, TLS upgrade
//! and CredSSP/NLA authentication), streams framebuffer updates, forwards
//! keyboard/mouse input and reports connect/disconnect lifecycle events.
//!
//! The engine runs on a dedicated OS thread. Control messages are delivered to
//! the thread through a channel stored in a global registry keyed by the session
//! id chosen by the Dart side.

use std::collections::HashMap;
use std::io::Write as _;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::Context as _;

use ironrdp::connector::{self, ClientConnector, ConnectionResult, Credentials};
use ironrdp::pdu::gcc::KeyboardType;
use ironrdp::pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};
use ironrdp::pdu::input::mouse::PointerFlags;
use ironrdp::pdu::input::MousePdu;
use ironrdp::pdu::rdp::capability_sets::MajorPlatformType;
use ironrdp::session::image::DecodedImage;
use ironrdp::session::{ActiveStageBuilder, ActiveStageOutput, GracefulDisconnectReason};
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_pdu::geometry::{InclusiveRectangle, Rectangle as _};
use ironrdp_pdu::rdp::client_info::{CompressionType, PerformanceFlags, TimezoneInfo};
use sspi::network_client::reqwest_network_client::ReqwestNetworkClient;

use crate::frb_generated::StreamSink;
use crate::rdp_security::RdpSecurity;

const FRAME_INTERVAL: Duration = Duration::from_millis(16);

/// Everything required to open an RDP session.
#[derive(Debug, Clone)]
pub struct RdpConnectOptions {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    pub domain: Option<String>,
    pub width: u16,
    pub height: u16,
    /// Accept any server certificate. The UI is responsible for presenting the
    /// certificate fingerprint and asking the user to trust it before enabling
    /// this (matching the SSH host-key trust flow).
    pub accept_invalid_certificates: bool,
}

/// Events streamed from a live RDP session to the Flutter side.
#[derive(Debug, Clone)]
pub enum RdpEvent {
    Connected { width: u16, height: u16, certificate: Vec<u8> },
    /// Tightly packed RGBA pixels for the rectangle `(x, y, width, height)`.
    FrameUpdate {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        pixels: Vec<u8>,
    },
    Clipboard { text: String },
    /// Progress of a clipboard file transfer, for the UI overlay.
    ClipboardTransfer {
        sending: bool,
        file_name: String,
        index: u32,
        file_count: u32,
        transferred: u64,
        total: u64,
        complete: bool,
    },
    Disconnected { reason: String },
    Error { message: String },
}

enum Command {
    Key { code: u8, pressed: bool, extended: bool },
    Unicode { code: u16, pressed: bool },
    Pointer { x: u16, y: u16, buttons: u8, wheel: i16 },
    /// Toggles whether framebuffer updates are forwarded to the UI. Hidden
    /// sessions keep processing the protocol (so the desktop stays current) but
    /// stop crossing the FFI boundary with pixel data, which otherwise
    /// saturates the Dart isolate and freezes the app with several sessions.
    SetVisible(bool),
    /// Aborts an in-flight clipboard file transfer.
    CancelClipboardTransfer,
    Close,
}

type Registry = Mutex<HashMap<String, mpsc::Sender<Command>>>;

fn registry() -> &'static Registry {
    static REGISTRY: OnceLock<Registry> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn send_command(session_id: &str, command: Command) {
    let guard = registry().lock().unwrap();
    if let Some(tx) = guard.get(session_id) {
        let _ = tx.send(command);
    }
}

/// Starts an RDP session and returns its event stream to Dart.
///
/// The `session_id` is chosen by the caller and is used by the command
/// functions ([`rdp_send_key`], [`rdp_send_pointer`], ...).
pub fn rdp_start(
    session_id: String,
    options: RdpConnectOptions,
    sink: StreamSink<RdpEvent>,
) {
    let (tx, rx) = mpsc::channel::<Command>();
    registry().lock().unwrap().insert(session_id.clone(), tx);

    std::thread::spawn(move || {
        if let Err(e) = run_session(&options, &sink, &rx) {
            let _ = sink.add(RdpEvent::Error {
                message: format!("{e:#}"),
            });
        }
        registry().lock().unwrap().remove(&session_id);
        let _ = sink.add(RdpEvent::Disconnected {
            reason: "Session ended".to_owned(),
        });
    });
}

pub fn rdp_send_key(session_id: String, scancode: u8, pressed: bool, extended: bool) {
    send_command(
        &session_id,
        Command::Key {
            code: scancode,
            pressed,
            extended,
        },
    );
}

pub fn rdp_send_unicode(session_id: String, codepoint: u16, pressed: bool) {
    send_command(
        &session_id,
        Command::Unicode {
            code: codepoint,
            pressed,
        },
    );
}

/// `buttons` is a bitmask: bit 0 left, bit 1 right, bit 2 middle.
/// `wheel` is the signed wheel delta (positive scrolls up).
pub fn rdp_send_pointer(session_id: String, x: u16, y: u16, buttons: u8, wheel: i16) {
    send_command(
        &session_id,
        Command::Pointer {
            x,
            y,
            buttons,
            wheel,
        },
    );
}

/// Enables or suppresses framebuffer streaming for a session. Used to pause the
/// UI cost of background sessions while keeping the protocol running.
pub fn rdp_set_visible(session_id: String, visible: bool) {
    send_command(&session_id, Command::SetVisible(visible));
}

/// Aborts an in-flight clipboard file transfer for a session.
pub fn rdp_cancel_clipboard_transfer(session_id: String) {
    send_command(&session_id, Command::CancelClipboardTransfer);
}

pub fn rdp_close(session_id: String) {
    send_command(&session_id, Command::Close);
}

/// A connection attempt can fail either during security negotiation (which we
/// may recover from by retrying with legacy Standard RDP Security) or for any
/// other reason (which is final).
enum ConnectFailure {
    Negotiation(ironrdp::pdu::nego::FailureCode),
    Other(anyhow::Error),
}

impl ConnectFailure {
    fn into_anyhow(self) -> anyhow::Error {
        match self {
            Self::Negotiation(code) => describe_negotiation_code(code),
            Self::Other(error) => error,
        }
    }
}

fn describe_connect_error(error: connector::ConnectorError) -> anyhow::Error {
    if let connector::ConnectorErrorKind::Negotiation(failure) = error.kind() {
        return describe_negotiation_code(failure.code());
    }

    anyhow::anyhow!("begin RDP connection: {error}")
}

fn describe_negotiation_code(code: ironrdp::pdu::nego::FailureCode) -> anyhow::Error {
    use ironrdp::pdu::nego::FailureCode;

    let help = if code == FailureCode::SSL_NOT_ALLOWED_BY_SERVER {
        Some(
            "This server requires Standard RDP Security (legacy RC4), which Connexia \
             could not negotiate. Ensure the server allows Network Level \
             Authentication (NLA), TLS, or no RDP-level encryption.",
        )
    } else if code == FailureCode::SSL_CERT_NOT_ON_SERVER {
        Some(
            "The server cannot provide a certificate for Enhanced RDP Security. \
             Install a certificate on the server or enable Network Level \
             Authentication (NLA).",
        )
    } else if code == FailureCode::SSL_WITH_USER_AUTH_REQUIRED_BY_SERVER {
        Some("The server requires TLS client-certificate authentication, which is not supported.")
    } else if code == FailureCode::INCONSISTENT_FLAGS {
        Some("The server and client could not agree on a security protocol.")
    } else if code == FailureCode::HYBRID_REQUIRED_BY_SERVER {
        Some(
            "The server requires Network Level Authentication (NLA), but it could \
             not be completed. Check the username, password and domain.",
        )
    } else if code == FailureCode::SSL_REQUIRED_BY_SERVER {
        Some(
            "The server requires Enhanced RDP Security (TLS/CredSSP) with TLS 1.0, \
             1.1 or 1.2 that the client could not negotiate.",
        )
    } else {
        None
    };

    match help {
        Some(help) => anyhow::anyhow!("{help}"),
        None => anyhow::anyhow!("RDP security negotiation failed (code: {code:?})."),
    }
}

fn error_chain(error: &(dyn std::error::Error + 'static)) -> String {
    let mut out = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        out.push_str(" - ");
        out.push_str(&cause.to_string());
        source = cause.source();
    }
    out
}

fn describe_finalize_error(error: connector::ConnectorError) -> anyhow::Error {
    let text = error_chain(&error);
    if text.contains("can't satisfy server security settings") {
        return anyhow::anyhow!(
            "This server requires RDP-level encryption (RC4 Standard RDP Security), \
             which Connexia does not support. Configure the server to use Network \
             Level Authentication (NLA), TLS, or no RDP-level encryption."
        );
    }

    anyhow::anyhow!("finalize RDP connection: {text}")
}

/// Drive the remainder of the connection sequence for Standard RDP Security.
///
/// This mirrors [`ironrdp_blocking::connect_finalize`] without the CredSSP step
/// (which is never needed for standard security) and additionally performs the
/// RDP Security Commencement phase (Security Exchange PDU + RC4 key
/// establishment) and transparently encrypts/decrypts every subsequent PDU.
fn finalize_standard(
    mut connector: ClientConnector,
    framed: &mut ClientFramed,
) -> Result<(ConnectionResult, RdpSecurity), ConnectFailure> {
    use ironrdp::connector::{ClientConnectorState, Sequence as _, State as _};

    crate::rdp_trace::line("finalize_standard: begin");

    let mut buf = ironrdp::core::WriteBuf::new();
    let mut security: Option<RdpSecurity> = None;

    loop {
        // `WriteBuf` appends at a moving cursor while `&buf[..len]` slices
        // from the start, so the buffer must be reset every iteration
        // (mirrors `ironrdp_blocking::single_sequence_step`).
        buf.clear();

        // RDP Security Commencement: send the Security Exchange PDU right
        // before the Client Info PDU, then derive the RC4 keys.
        if let ClientConnectorState::SecureSettingsExchange {
            io_channel_id,
            user_channel_id,
        } = &connector.state
        {
            if security.is_none() {
                let (io_channel_id, user_channel_id) = (*io_channel_id, *user_channel_id);

                let server = connector.server_security_data.clone().ok_or_else(|| {
                    ConnectFailure::Other(anyhow::anyhow!(
                        "server selected Standard RDP Security without providing security data"
                    ))
                })?;
                let server_random = server.server_random.ok_or_else(|| {
                    ConnectFailure::Other(anyhow::anyhow!(
                        "server selected Standard RDP Security without a server random"
                    ))
                })?;
                let method = RdpSecurity::select_method(server.encryption_method)
                    .map_err(ConnectFailure::Other)?;

                let client_random = RdpSecurity::generate_client_random();
                let exchange = RdpSecurity::security_exchange_pdu(
                    user_channel_id,
                    io_channel_id,
                    &client_random,
                    &server.server_cert,
                )
                .map_err(ConnectFailure::Other)?;

                framed.write_all(&exchange).map_err(|e| {
                    ConnectFailure::Other(
                        anyhow::Error::new(e).context("write Security Exchange PDU"),
                    )
                })?;

                let security_state =
                    crate::rdp_security::establish(&client_random, &server_random, method);
                security_state.trace_keys("Standard security keys");
                crate::rdp_trace::line(&format!(
                    "server encryption_method={:?} server_cert_len={}",
                    server.encryption_method,
                    server.server_cert.len(),
                ));
                crate::rdp_trace::hex("client_random", &client_random);
                crate::rdp_trace::hex("server_random", &server_random);
                crate::rdp_trace::hex("server_cert", &server.server_cert);
                security = Some(security_state);
            }
        }

        let state = connector.state.name().to_owned();

        // Client Info, licensing and auto-detect PDUs carry an embedded
        // `BasicSecurityHeader` that becomes the outer security header on the
        // wire. Everything else (share-control PDUs) has none.
        let has_embedded_security_header = matches!(
            &connector.state,
            ClientConnectorState::SecureSettingsExchange { .. }
                | ClientConnectorState::ConnectTimeAutoDetection { .. }
                | ClientConnectorState::LicensingExchange { .. }
        );

        let written = if let Some(hint) = connector.next_pdu_hint() {
            let raw = framed.read_by_hint(hint).map_err(|e| {
                ConnectFailure::Other(
                    anyhow::Error::new(e).context(format!("read frame while {state}")),
                )
            })?;

            let input = match security.as_mut() {
                Some(security) => security
                    .decrypt_slow_path(&raw, has_embedded_security_header)
                    .map_err(ConnectFailure::Other)?,
                None => raw.to_vec(),
            };

            connector.step(&input, &mut buf).map_err(|e| {
                ConnectFailure::Other(describe_finalize_error(e).context(format!("while {state}")))
            })?
        } else {
            connector.step_no_input(&mut buf).map_err(|e| {
                ConnectFailure::Other(describe_finalize_error(e).context(format!("while {state}")))
            })?
        };

        if let Some(response_len) = written.size() {
            let plaintext = &buf[..response_len];
            let out = match security.as_mut() {
                Some(security) => security
                    .encrypt_slow_path(plaintext, has_embedded_security_header)
                    .map_err(ConnectFailure::Other)?,
                None => plaintext.to_vec(),
            };

            framed.write_all(&out).map_err(|e| {
                ConnectFailure::Other(
                    anyhow::Error::new(e).context(format!("write frame while {state}")),
                )
            })?;
        }

        if let ClientConnectorState::Connected { result } = connector.state {
            let security = security.ok_or_else(|| {
                ConnectFailure::Other(anyhow::anyhow!(
                    "connection completed without establishing RC4 keys"
                ))
            })?;
            return Ok((result, security));
        }
    }
}

/// Result of a single connection attempt driven by [`run_session`].
enum SessionOutcome {
    /// The session finished normally (closed by either side).
    Ended,
    /// The server rejected auto-logon and dropped the session; reconnect
    /// without `INFO_AUTOLOGON` so the user reaches the logon screen.
    RetryWithoutAutologon,
}

fn run_session(
    options: &RdpConnectOptions,
    sink: &StreamSink<RdpEvent>,
    rx: &mpsc::Receiver<Command>,
) -> anyhow::Result<()> {
    // Auto-logon is attempted first. Some servers (notably Oracle Cloud VMs
    // still using the initial account that mandates a password change) reject it
    // and immediately drop the session; transparently reconnect without
    // `INFO_AUTOLOGON` so the interactive logon screen is shown instead.
    let mut autologon = true;

    // Clipboard redirection outlives individual connection attempts, so the
    // Win32 message pump / backend factory is created once here and reused
    // across transparent reconnects.
    let mut clipboard = crate::rdp_clipboard::ClipboardSession::new(true);

    loop {
        crate::rdp_trace::line(&format!(
            "run_session: new connection attempt (autologon={autologon})"
        ));

        match run_session_once(options, sink, rx, autologon, &mut clipboard)? {
            SessionOutcome::Ended => return Ok(()),
            SessionOutcome::RetryWithoutAutologon => {
                tracing::info!(
                    "auto-logon rejected by the server; reconnecting to the logon screen"
                );
                autologon = false;
            }
        }
    }
}

/// True when a graceful disconnect looks like a rejected auto-logon attempt
/// (the server failed to complete the logon and reported a Standard RDP
/// Security error rather than rendering a desktop).
fn is_autologon_rejection(reason: &GracefulDisconnectReason) -> bool {
    matches!(reason, GracefulDisconnectReason::Other(_))
}

/// True when a read failed only because the socket read timeout elapsed with no
/// data available. Windows surfaces a `SO_RCVTIMEO` expiry as `WSAETIMEDOUT`
/// (`TimedOut`), while Unix reports `WouldBlock`; both are retried by the
/// session loop rather than treated as fatal.
fn is_read_timeout(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    )
}

fn run_session_once(
    options: &RdpConnectOptions,
    sink: &StreamSink<RdpEvent>,
    rx: &mpsc::Receiver<Command>,
    autologon: bool,
    clipboard: &mut crate::rdp_clipboard::ClipboardSession,
) -> anyhow::Result<SessionOutcome> {
    let (connection_result, mut framed, certificate, mut security) = connect(
        options,
        options.host.clone(),
        options.port,
        autologon,
        clipboard.factory(),
    )?;

    // Move socket writes to a background thread when possible so large
    // clipboard (file transfer) responses cannot stall input processing.
    let writer = Writer::spawn(&framed);
    crate::rdp_trace::clipboard(&format!(
        "writer: socket writes on background thread = {}",
        writer.is_some()
    ));

    let width = connection_result.desktop_size.width;
    let height = connection_result.desktop_size.height;

    sink.add(RdpEvent::Connected {
        width,
        height,
        certificate,
    })
    .ok();

    let mut image = DecodedImage::new(PixelFormat::RgbA32, width, height);

    let mut active_stage = ActiveStageBuilder {
        static_channels: connection_result.static_channels,
        user_channel_id: connection_result.user_channel_id,
        io_channel_id: connection_result.io_channel_id,
        message_channel_id: connection_result.message_channel_id,
        share_id: connection_result.share_id,
        compression_type: connection_result.compression_type,
        enable_server_pointer: connection_result.enable_server_pointer,
        pointer_software_rendering: connection_result.pointer_software_rendering,
    }
    .build();

    crate::rdp_trace::clipboard(&format!(
        "clipboard: CLIPRDR channel active={}",
        active_stage
            .get_svc_processor_mut::<ironrdp::cliprdr::CliprdrClient>()
            .is_some()
    ));

    let mut dirty: Option<InclusiveRectangle> = None;
    let mut last_frame = Instant::now()
        .checked_sub(FRAME_INTERVAL)
        .unwrap_or_else(Instant::now);
    let mut last_buttons: u8 = 0;
    let mut visible = true;
    let mut just_became_visible = false;
    // Whether the server has painted anything in this attempt. If auto-logon is
    // rejected, the disconnect arrives before any graphics update.
    let mut saw_graphics = false;

    loop {
        // 1. Drain pending input commands.
        let mut events: Vec<FastPathInputEvent> = Vec::new();
        let mut should_close = false;
        while let Ok(command) = rx.try_recv() {
            match command {
                Command::SetVisible(now_visible) => {
                    if now_visible && !visible {
                        // The framebuffer was not forwarded while hidden, so the
                        // client missed every update since. Send the full current
                        // desktop on the next tick.
                        just_became_visible = true;
                    }
                    visible = now_visible;
                }
                Command::CancelClipboardTransfer => clipboard.cancel_transfer(),
                Command::Key {
                    code,
                    pressed,
                    extended,
                } => {
                    let mut flags = KeyboardFlags::empty();
                    if !pressed {
                        flags |= KeyboardFlags::RELEASE;
                    }
                    if extended {
                        flags |= KeyboardFlags::EXTENDED;
                    }
                    events.push(FastPathInputEvent::KeyboardEvent(flags, code));
                }
                Command::Unicode { code, pressed } => {
                    let mut flags = KeyboardFlags::empty();
                    if !pressed {
                        flags |= KeyboardFlags::RELEASE;
                    }
                    events.push(FastPathInputEvent::UnicodeKeyboardEvent(flags, code));
                }
                Command::Pointer {
                    x,
                    y,
                    buttons,
                    wheel,
                } => {
                    // Button transitions must keep the button bit set:
                    // press = BUTTON|DOWN, release = BUTTON (no DOWN). Sending
                    // a release without the button bit leaves the button stuck
                    // down, so clicks never register.
                    let pressed = buttons & !last_buttons;
                    let released = last_buttons & !buttons;

                    if pressed & 1 != 0 {
                        events.push(mouse_event(
                            x,
                            y,
                            PointerFlags::LEFT_BUTTON | PointerFlags::DOWN,
                            0,
                        ));
                    }
                    if released & 1 != 0 {
                        events.push(mouse_event(x, y, PointerFlags::LEFT_BUTTON, 0));
                    }
                    if pressed & 2 != 0 {
                        events.push(mouse_event(
                            x,
                            y,
                            PointerFlags::RIGHT_BUTTON | PointerFlags::DOWN,
                            0,
                        ));
                    }
                    if released & 2 != 0 {
                        events.push(mouse_event(x, y, PointerFlags::RIGHT_BUTTON, 0));
                    }
                    if pressed & 4 != 0 {
                        events.push(mouse_event(
                            x,
                            y,
                            PointerFlags::MIDDLE_BUTTON_OR_WHEEL | PointerFlags::DOWN,
                            0,
                        ));
                    }
                    if released & 4 != 0 {
                        events.push(mouse_event(
                            x,
                            y,
                            PointerFlags::MIDDLE_BUTTON_OR_WHEEL,
                            0,
                        ));
                    }

                    if wheel != 0 {
                        events.push(mouse_event(x, y, PointerFlags::VERTICAL_WHEEL, wheel));
                    } else if pressed == 0 && released == 0 {
                        // Pure move. Button state is tracked by the server from
                        // the press/release events, so it must not be repeated
                        // here: a move carrying a button bit without PTRFLAGS_DOWN
                        // is interpreted as a button release.
                        events.push(mouse_event(x, y, PointerFlags::MOVE, 0));
                    }

                    last_buttons = buttons;
                }
                Command::Close => {
                    should_close = true;
                }
            }
        }

        if should_close {
            if let Ok(outputs) = active_stage.graceful_shutdown() {
                for out in outputs {
                    if let ActiveStageOutput::ResponseFrame(frame) = out {
                        write_frame(
                            &mut framed,
                            &mut security,
                            writer.as_ref(),
                            &frame,
                            "write shutdown frame",
                        )?;
                    }
                }
            }
            break;
        }

        if !events.is_empty() {
            // A fast-path input PDU can carry at most 255 events. Mouse moves
            // can easily exceed that between two loop iterations, and
            // over-filling the batch fails validation, so send them in chunks.
            for chunk in events.chunks(128) {
                let outputs = active_stage
                    .process_fastpath_input(&mut image, chunk)
                    .map_err(|e| anyhow::anyhow!("encode input: {e}"))?;
                for out in outputs {
                    match out {
                        ActiveStageOutput::ResponseFrame(frame) => {
                            write_frame(
                                &mut framed,
                                &mut security,
                                writer.as_ref(),
                                &frame,
                                "write input frame",
                            )?;
                        }
                        ActiveStageOutput::GraphicsUpdate(rect) => {
                            saw_graphics = true;
                            dirty = Some(match dirty {
                                Some(current) => union(&current, &rect),
                                None => rect,
                            });
                        }
                        ActiveStageOutput::Terminate(reason) => {
                            crate::rdp_trace::line(&format!(
                                "session Terminate (from input): reason={reason:?}"
                            ));
                            return Ok(SessionOutcome::Ended);
                        }
                        _ => {}
                    }
                }
            }
        }

        // 1b. Relay clipboard changes between the local OS clipboard and the
        //     remote session's CLIPRDR channel.
        while let Some(message) = clipboard.next() {
            if let Some(frame) = crate::rdp_clipboard::dispatch(&mut active_stage, message)? {
                if !frame.is_empty() {
                    write_frame(
                        &mut framed,
                        &mut security,
                        writer.as_ref(),
                        &frame,
                        "write clipboard frame",
                    )?;
                }
            }
        }

        // 1c. Forward clipboard file-transfer progress to the UI.
        while let Some(progress) = clipboard.next_progress() {
            let _ = sink.add(RdpEvent::ClipboardTransfer {
                sending: progress.sending,
                file_name: progress.file_name,
                index: progress.index,
                file_count: progress.file_count,
                transferred: progress.transferred,
                total: progress.total,
                complete: progress.complete,
            });
        }

        // 2. Read and process one server PDU (non-blocking thanks to the read
        //    timeout).
        match framed.read_pdu() {
            Ok((action, payload)) => {
                let payload = match security.as_mut() {
                    Some(security) => security
                        .decrypt_frame(&payload)
                        .context("decrypt server frame")?,
                    None => payload.to_vec(),
                };
                let outputs = match active_stage.process(&mut image, action, &payload) {
                    Ok(outputs) => outputs,
                    Err(e) => match e.kind() {
                        ironrdp::session::SessionErrorKind::Decode(_)
                        | ironrdp::session::SessionErrorKind::Pdu(_) => {
                            // A single malformed PDU must not kill the whole
                            // session: framing is handled below this layer, so
                            // drop the frame and keep going. `Display` on these
                            // errors omits the reason, so log the full chain.
                            crate::rdp_trace::clipboard(&format!(
                                "session: skipped undecodable server PDU ({} bytes): {}",
                                payload.len(),
                                e.report()
                            ));
                            let head: String = payload
                                .iter()
                                .take(48)
                                .map(|b| format!("{b:02x}"))
                                .collect();
                            crate::rdp_trace::clipboard(&format!(
                                "session: payload head: {head}"
                            ));
                            Vec::new()
                        }
                        _ => return Err(anyhow::anyhow!("process server frame: {}", e.report())),
                    },
                };
                for out in outputs {
                    match out {
                        ActiveStageOutput::ResponseFrame(frame) => {
                            write_frame(
                                &mut framed,
                                &mut security,
                                writer.as_ref(),
                                &frame,
                                "write response frame",
                            )?;
                        }
                        ActiveStageOutput::GraphicsUpdate(rect) => {
                            saw_graphics = true;
                            dirty = Some(match dirty {
                                Some(current) => union(&current, &rect),
                                None => rect,
                            });
                        }
                        ActiveStageOutput::Terminate(reason) => {
                            crate::rdp_trace::line(&format!(
                                "session Terminate: reason={reason:?} autologon={autologon} saw_graphics={saw_graphics}"
                            ));
                            if autologon && !saw_graphics && is_autologon_rejection(&reason) {
                                return Ok(SessionOutcome::RetryWithoutAutologon);
                            }
                            let _ = sink.add(RdpEvent::Disconnected {
                                reason: reason.description(),
                            });
                            return Ok(SessionOutcome::Ended);
                        }
                        _ => {}
                    }
                }
            }
            Err(e) if is_read_timeout(&e) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                let _ = sink.add(RdpEvent::Disconnected {
                    reason: "Connection closed by server".to_owned(),
                });
                return Ok(SessionOutcome::Ended);
            }
            Err(e) => return Err(anyhow::Error::new(e).context("read RDP frame")),
        }

        // 3. Emit a coalesced frame update when the framebuffer changed.
        if just_became_visible {
            // The session was hidden while the desktop changed; the client
            // missed those deltas, so resend the whole desktop once.
            just_became_visible = false;
            dirty = None;
            last_frame = Instant::now();
            if visible {
                let full = InclusiveRectangle {
                    left: 0,
                    top: 0,
                    right: width.saturating_sub(1),
                    bottom: height.saturating_sub(1),
                };
                let pixels = pack_rect(&image, &full);
                sink.add(RdpEvent::FrameUpdate {
                    x: full.left,
                    y: full.top,
                    width: full.width(),
                    height: full.height(),
                    pixels,
                })
                .ok();
            }
        } else if visible {
            if let Some(rect) = dirty.take() {
                if last_frame.elapsed() >= FRAME_INTERVAL {
                    let pixels = pack_rect(&image, &rect);
                    sink.add(RdpEvent::FrameUpdate {
                        x: rect.left,
                        y: rect.top,
                        width: rect.width(),
                        height: rect.height(),
                        pixels,
                    })
                    .ok();
                    last_frame = Instant::now();
                } else {
                    dirty = Some(rect);
                }
            }
        }

    }

    Ok(SessionOutcome::Ended)
}

/// Background socket writer.
///
/// A single clipboard file-contents response (hundreds of KiB) can take
/// seconds to push up a slow link; writing it inline stalls the session
/// loop and starves input/graphics processing (the session feels laggy for
/// the whole transfer). All outgoing frames are therefore handed to a
/// dedicated thread through a bounded FIFO, which preserves ordering while
/// keeping the session loop responsive. Only plain-TCP transports
/// (Standard RDP Security) can be shared this way; TLS writes stay inline.
struct Writer {
    tx: Option<mpsc::SyncSender<Vec<u8>>>,
    /// Duplicate handle used only to abort a wedged write on drop.
    abort: Option<TcpStream>,
    join: Option<std::thread::JoinHandle<()>>,
    done: Arc<AtomicBool>,
}

impl Writer {
    /// Creates a background writer over a duplicated write handle of the
    /// framed transport. Returns `None` when the transport cannot be shared
    /// (TLS), in which case writes remain inline.
    fn spawn(framed: &ClientFramed) -> Option<Self> {
        let RdpStream::Plain(stream) = framed.get_inner().0 else {
            return None;
        };
        let mut write_sock = stream.try_clone().ok()?;
        let abort = stream.try_clone().ok()?;

        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(8);
        let done = Arc::new(AtomicBool::new(false));
        let thread_done = done.clone();

        let join = std::thread::Builder::new()
            .name("connexia-rdp-writer".to_owned())
            .spawn(move || {
                while let Ok(buf) = rx.recv() {
                    let len = buf.len();
                    let started = Instant::now();
                    let result = write_sock.write_all(&buf);
                    if len >= 64 * 1024 {
                        crate::rdp_trace::clipboard(&format!(
                            "writer: wrote {} KiB in {} ms",
                            len / 1024,
                            started.elapsed().as_millis()
                        ));
                    }
                    if result.is_err() {
                        break;
                    }
                }
                thread_done.store(true, Ordering::Release);
            })
            .ok()?;

        Some(Self {
            tx: Some(tx),
            abort: Some(abort),
            join: Some(join),
            done,
        })
    }

    /// Queues a frame for the writer thread. Blocks when the queue is full,
    /// applying backpressure for transfers that outrun the link.
    fn send(&self, buf: Vec<u8>) -> anyhow::Result<()> {
        let Some(tx) = &self.tx else {
            return Ok(());
        };
        tx.send(buf)
            .map_err(|_| anyhow::anyhow!("background writer stopped"))
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        self.tx.take();

        // Give the writer a moment to drain what is already queued (the
        // graceful shutdown path relies on this), then force-abort the
        // connection so a wedged write cannot hang session teardown.
        for _ in 0..30 {
            if self.done.load(Ordering::Acquire) {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        if let Some(sock) = self.abort.take() {
            let _ = sock.shutdown(std::net::Shutdown::Both);
        }
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

/// Writes an outgoing frame, applying Standard RDP Security encryption when it
/// is in use.
fn write_frame(
    framed: &mut ClientFramed,
    security: &mut Option<RdpSecurity>,
    writer: Option<&Writer>,
    frame: &[u8],
    context: &str,
) -> anyhow::Result<()> {
    // The active stage always emits a `ResponseFrame` for Fast-Path input,
    // even when there is nothing to reply with: skip empty frames.
    if frame.is_empty() {
        return Ok(());
    }

    crate::rdp_trace::line(&format!(
        "write_frame ({context}): len={} first={:#04x}",
        frame.len(),
        frame.first().copied().unwrap_or(0),
    ));

    let out = match security.as_mut() {
        Some(security) => security.encrypt_frame(frame).context("encrypt frame")?,
        None => frame.to_vec(),
    };

    match writer {
        Some(writer) => writer.send(out),
        None => framed
            .write_all(&out)
            .map_err(|e| anyhow::Error::new(e).context(context.to_owned())),
    }
}

fn mouse_event(x: u16, y: u16, flags: PointerFlags, wheel: i16) -> FastPathInputEvent {
    FastPathInputEvent::MouseEvent(MousePdu {
        flags,
        number_of_wheel_rotation_units: wheel,
        x_position: x,
        y_position: y,
    })
}

fn union(a: &InclusiveRectangle, b: &InclusiveRectangle) -> InclusiveRectangle {
    InclusiveRectangle {
        left: a.left.min(b.left),
        top: a.top.min(b.top),
        right: a.right.max(b.right),
        bottom: a.bottom.max(b.bottom),
    }
}

fn pack_rect(image: &DecodedImage, rect: &InclusiveRectangle) -> Vec<u8> {
    let bpp = image.bytes_per_pixel();
    let stride = image.stride();
    let width = usize::from(rect.width());
    let height = usize::from(rect.height());
    let data = image.data();

    let mut out = Vec::with_capacity(width * height * bpp);
    for row in 0..height {
        let y = usize::from(rect.top) + row;
        let start = usize::from(rect.left) * bpp + y * stride;
        let end = start + width * bpp;
        out.extend_from_slice(&data[start..end]);
    }
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SecurityMode {
    /// Offer TLS/CredSSP (NLA) first.
    Enhanced,
    /// Offer legacy Standard RDP Security (`PROTOCOL_RDP`) only. IronRDP
    /// supports the no-encryption (`ENCRYPTION_LEVEL_NONE`) variant.
    Standard,
}

fn build_config(options: &RdpConnectOptions, mode: SecurityMode, autologon: bool) -> connector::Config {
    connector::Config {
        desktop_size: connector::DesktopSize {
            width: options.width,
            height: options.height,
        },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: mode == SecurityMode::Enhanced,
        enable_standard_rdp_security: mode == SecurityMode::Standard,
        credentials: Credentials::UsernamePassword {
            username: options.username.clone(),
            password: options.password.clone(),
        },
        domain: options.domain.clone(),
        client_build: 0,
        client_name: "connexia".to_owned(),
        keyboard_type: KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        platform: platform(),
        hardware_id: None,
        request_data: None,
        autologon,
        enable_audio_playback: false,
        performance_flags: PerformanceFlags::default(),
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        compression_type: Some(CompressionType::Rdp61),
        enable_server_pointer: true,
        pointer_software_rendering: true,
        multitransport_flags: None,
    }
}

fn platform() -> MajorPlatformType {
    #[cfg(target_os = "windows")]
    {
        MajorPlatformType::WINDOWS
    }
    #[cfg(target_os = "macos")]
    {
        MajorPlatformType::MACINTOSH
    }
    #[cfg(target_os = "ios")]
    {
        MajorPlatformType::IOS
    }
    #[cfg(target_os = "android")]
    {
        MajorPlatformType::ANDROID
    }
    #[cfg(any(target_os = "linux", target_os = "freebsd"))]
    {
        MajorPlatformType::UNIX
    }
}

/// The transport under the RDP framing layer: either a TLS-upgraded stream
/// (enhanced security) or the raw TCP stream (legacy Standard RDP Security).
enum RdpStream {
    Tls(tokio_rustls::rustls::StreamOwned<tokio_rustls::rustls::ClientConnection, TcpStream>),
    Plain(TcpStream),
}

impl std::io::Read for RdpStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Self::Tls(stream) => stream.read(buf),
            Self::Plain(stream) => stream.read(buf),
        }
    }
}

impl std::io::Write for RdpStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Self::Tls(stream) => stream.write(buf),
            Self::Plain(stream) => stream.write(buf),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Self::Tls(stream) => stream.flush(),
            Self::Plain(stream) => stream.flush(),
        }
    }
}

impl RdpStream {
    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        match self {
            Self::Tls(stream) => stream.sock.set_read_timeout(timeout),
            Self::Plain(stream) => stream.set_read_timeout(timeout),
        }
    }
}

type ClientFramed = ironrdp_blocking::Framed<RdpStream>;

/// Connect with automatic legacy fallback: try TLS/NLA first; if the server
/// only offers Standard RDP Security, retry advertising `PROTOCOL_RDP`.
fn connect(
    options: &RdpConnectOptions,
    server_name: String,
    port: u16,
    autologon: bool,
    clipboard_factory: Option<&(dyn ironrdp::cliprdr::backend::CliprdrBackendFactory + Send)>,
) -> anyhow::Result<(ConnectionResult, ClientFramed, Vec<u8>, Option<RdpSecurity>)> {
    match connect_attempt(
        options,
        &server_name,
        port,
        SecurityMode::Enhanced,
        autologon,
        clipboard_factory,
    ) {
        Ok(result) => {
            crate::rdp_trace::line("connect: Enhanced attempt succeeded");
            Ok(result)
        }
        Err(ConnectFailure::Negotiation(code)) => {
            use ironrdp::pdu::nego::FailureCode;
            crate::rdp_trace::line(&format!(
                "connect: Enhanced attempt negotiation failure {code:?}"
            ));
            if code != FailureCode::SSL_NOT_ALLOWED_BY_SERVER {
                return Err(describe_negotiation_code(code));
            }

            crate::rdp_trace::line(
                "Enhanced attempt rejected (SSL_NOT_ALLOWED_BY_SERVER); retrying with Standard RDP Security",
            );

            let result = connect_attempt(
                options,
                &server_name,
                port,
                SecurityMode::Standard,
                autologon,
                clipboard_factory,
            )
            .map_err(ConnectFailure::into_anyhow);
            match &result {
                Ok(_) => crate::rdp_trace::line("connect: Standard attempt succeeded"),
                Err(error) => crate::rdp_trace::line(&format!(
                    "connect: Standard attempt FAILED: {error:#}"
                )),
            }
            result
        }
        Err(failure) => Err(failure.into_anyhow()),
    }
}

fn connect_attempt(
    options: &RdpConnectOptions,
    server_name: &str,
    port: u16,
    mode: SecurityMode,
    autologon: bool,
    clipboard_factory: Option<&(dyn ironrdp::cliprdr::backend::CliprdrBackendFactory + Send)>,
) -> Result<(ConnectionResult, ClientFramed, Vec<u8>, Option<RdpSecurity>), ConnectFailure> {
    let config = build_config(options, mode, autologon);

    let server_addr = (server_name, port)
        .to_socket_addrs()
        .map_err(|e| ConnectFailure::Other(anyhow::Error::new(e).context("resolve server address")))?
        .next()
        .ok_or_else(|| {
            ConnectFailure::Other(anyhow::anyhow!("no socket address found for {server_name}"))
        })?;

    let tcp_stream = TcpStream::connect(server_addr)
        .map_err(|e| ConnectFailure::Other(anyhow::Error::new(e).context("TCP connect")))?;
    // The short read timeout is only meant for the interactive session loop.
    // Applying it during the connection sequence aborts `connect_finalize`
    // whenever a server response takes longer than the timeout, so use a
    // generous deadline while connecting and switch afterwards.
    tcp_stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .map_err(|e| ConnectFailure::Other(anyhow::Error::new(e).context("set read timeout")))?;
    tcp_stream
        .set_nodelay(true)
        .map_err(|e| ConnectFailure::Other(anyhow::Error::new(e).context("set nodelay")))?;

    let client_addr = tcp_stream
        .local_addr()
        .map_err(|e| ConnectFailure::Other(anyhow::Error::new(e).context("local address")))?;

    let mut framed = ironrdp_blocking::Framed::new(tcp_stream);
    let mut connector = ClientConnector::new(config, client_addr);

    if let Some(factory) = clipboard_factory {
        connector.attach_static_channel(ironrdp::cliprdr::Cliprdr::new(
            factory.build_cliprdr_backend(),
        ));
    }

    let should_upgrade = match ironrdp_blocking::connect_begin(&mut framed, &mut connector) {
        Ok(upgrade) => upgrade,
        Err(error) => {
            return Err(match error.kind() {
                connector::ConnectorErrorKind::Negotiation(failure) => {
                    ConnectFailure::Negotiation(failure.code())
                }
                _ => ConnectFailure::Other(describe_connect_error(error)),
            });
        }
    };

    let initial_stream = framed.into_inner_no_leftover();
    let (stream, server_public_key, server_certificate) = match mode {
        // Legacy Standard RDP Security has no TLS/CredSSP front-end.
        SecurityMode::Standard => (RdpStream::Plain(initial_stream), Vec::new(), Vec::new()),
        SecurityMode::Enhanced => {
            let (tls_stream, public_key, certificate) =
                tls_upgrade(initial_stream, server_name.to_owned()).map_err(ConnectFailure::Other)?;
            (RdpStream::Tls(tls_stream), public_key, certificate)
        }
    };

    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
    let mut upgraded_framed = ironrdp_blocking::Framed::new(stream);

    let (connection_result, security) = match mode {
        SecurityMode::Standard => {
            let (result, security) = finalize_standard(connector, &mut upgraded_framed)?;
            (result, Some(security))
        }
        SecurityMode::Enhanced => {
            let mut network_client = ReqwestNetworkClient;
            let result = ironrdp_blocking::connect_finalize(
                upgraded,
                connector,
                &mut upgraded_framed,
                &mut network_client,
                server_name.to_owned().into(),
                server_public_key,
                None,
            )
            .map_err(|e| ConnectFailure::Other(describe_finalize_error(e)))?;
            (result, None)
        }
    };

    // Connection sequence is done: make reads non-blocking for the session
    // loop, which polls input and drains server updates on a short timeout.
    upgraded_framed
        .get_inner()
        .0
        .set_read_timeout(Some(Duration::from_millis(8)))
        .map_err(|e| {
            ConnectFailure::Other(anyhow::Error::new(e).context("set session read timeout"))
        })?;

    Ok((connection_result, upgraded_framed, server_certificate, security))
}

fn tls_upgrade(
    stream: TcpStream,
    server_name: String,
) -> anyhow::Result<(
    tokio_rustls::rustls::StreamOwned<tokio_rustls::rustls::ClientConnection, TcpStream>,
    Vec<u8>,
    Vec<u8>,
)> {
    let mut config = tokio_rustls::rustls::client::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(danger::NoCertificateVerification))
        .with_no_client_auth();
    config.resumption = tokio_rustls::rustls::client::Resumption::disabled();

    let config = Arc::new(config);
    let server_name = server_name
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid server name"))?;
    let client = tokio_rustls::rustls::ClientConnection::new(config, server_name)
        .map_err(|e| anyhow::Error::new(e).context("create TLS client"))?;

    let mut tls_stream = tokio_rustls::rustls::StreamOwned::new(client, stream);
    tls_stream
        .flush()
        .map_err(|e| anyhow::Error::new(e).context("TLS flush"))?;

    let certificate = tls_stream
        .conn
        .peer_certificates()
        .and_then(|certificates| certificates.first())
        .ok_or_else(|| anyhow::anyhow!("server certificate is missing"))?
        .to_vec();

    let server_public_key = extract_server_public_key(&certificate)?;

    Ok((tls_stream, server_public_key, certificate))
}

fn extract_server_public_key(certificate: &[u8]) -> anyhow::Result<Vec<u8>> {
    use x509_cert::der::Decode as _;

    let cert = x509_cert::Certificate::from_der(certificate)
        .map_err(|e| anyhow::Error::new(e).context("parse server certificate"))?;

    let key = cert
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .ok_or_else(|| anyhow::anyhow!("subject public key bit string is not aligned"))?;

    Ok(key.to_vec())
}

mod danger {
    use tokio_rustls::rustls::client::danger::{
        HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier,
    };
    use tokio_rustls::rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use tokio_rustls::rustls::{DigitallySignedStruct, Error, SignatureScheme};

    #[derive(Debug)]
    pub(super) struct NoCertificateVerification;

    impl ServerCertVerifier for NoCertificateVerification {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp_response: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            vec![
                SignatureScheme::RSA_PKCS1_SHA1,
                SignatureScheme::ECDSA_SHA1_Legacy,
                SignatureScheme::RSA_PKCS1_SHA256,
                SignatureScheme::ECDSA_NISTP256_SHA256,
                SignatureScheme::RSA_PKCS1_SHA384,
                SignatureScheme::ECDSA_NISTP384_SHA384,
                SignatureScheme::RSA_PKCS1_SHA512,
                SignatureScheme::ECDSA_NISTP521_SHA512,
                SignatureScheme::RSA_PSS_SHA256,
                SignatureScheme::RSA_PSS_SHA384,
                SignatureScheme::RSA_PSS_SHA512,
                SignatureScheme::ED25519,
                SignatureScheme::ED448,
            ]
        }
    }
}
