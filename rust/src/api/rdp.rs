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
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use ironrdp::connector::{self, ClientConnector, ConnectionResult, Credentials};
use ironrdp::pdu::gcc::KeyboardType;
use ironrdp::pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};
use ironrdp::pdu::input::mouse::PointerFlags;
use ironrdp::pdu::input::MousePdu;
use ironrdp::pdu::rdp::capability_sets::MajorPlatformType;
use ironrdp::session::image::DecodedImage;
use ironrdp::session::{ActiveStageBuilder, ActiveStageOutput};
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_pdu::geometry::{InclusiveRectangle, Rectangle as _};
use ironrdp_pdu::rdp::client_info::{CompressionType, PerformanceFlags, TimezoneInfo};
use sspi::network_client::reqwest_network_client::ReqwestNetworkClient;

use crate::frb_generated::StreamSink;

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

pub fn rdp_close(session_id: String) {
    send_command(&session_id, Command::Close);
}

fn run_session(
    options: &RdpConnectOptions,
    sink: &StreamSink<RdpEvent>,
    rx: &mpsc::Receiver<Command>,
) -> anyhow::Result<()> {
    let config = build_config(options);
    let (connection_result, mut framed, certificate) =
        connect(config, options.host.clone(), options.port)?;

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

    let mut dirty: Option<InclusiveRectangle> = None;
    let mut last_frame = Instant::now()
        .checked_sub(FRAME_INTERVAL)
        .unwrap_or_else(Instant::now);
    let mut last_buttons: u8 = 0;
    let mut visible = true;
    let mut just_became_visible = false;

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
            let _ = active_stage.graceful_shutdown();
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
                            framed
                                .write_all(&frame)
                                .map_err(|e| anyhow::Error::new(e).context("write input frame"))?;
                        }
                        ActiveStageOutput::GraphicsUpdate(rect) => {
                            dirty = Some(match dirty {
                                Some(current) => union(&current, &rect),
                                None => rect,
                            });
                        }
                        ActiveStageOutput::Terminate(_) => {
                            return Ok(());
                        }
                        _ => {}
                    }
                }
            }
        }

        // 2. Read and process one server PDU (non-blocking thanks to the read
        //    timeout).
        match framed.read_pdu() {
            Ok((action, payload)) => {
                let outputs = active_stage
                    .process(&mut image, action, &payload)
                    .map_err(|e| anyhow::anyhow!("process server frame: {e}"))?;
                for out in outputs {
                    match out {
                        ActiveStageOutput::ResponseFrame(frame) => {
                            framed
                                .write_all(&frame)
                                .map_err(|e| anyhow::Error::new(e).context("write response frame"))?;
                        }
                        ActiveStageOutput::GraphicsUpdate(rect) => {
                            dirty = Some(match dirty {
                                Some(current) => union(&current, &rect),
                                None => rect,
                            });
                        }
                        ActiveStageOutput::Terminate(reason) => {
                            let _ = sink.add(RdpEvent::Disconnected {
                                reason: reason.description(),
                            });
                            return Ok(());
                        }
                        _ => {}
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                let _ = sink.add(RdpEvent::Disconnected {
                    reason: "Connection closed by server".to_owned(),
                });
                return Ok(());
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

    Ok(())
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

fn build_config(options: &RdpConnectOptions) -> connector::Config {
    connector::Config {
        desktop_size: connector::DesktopSize {
            width: options.width,
            height: options.height,
        },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
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
        autologon: false,
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

type ClientFramed = ironrdp_blocking::Framed<
    tokio_rustls::rustls::StreamOwned<tokio_rustls::rustls::ClientConnection, TcpStream>,
>;

fn connect(
    config: connector::Config,
    server_name: String,
    port: u16,
) -> anyhow::Result<(ConnectionResult, ClientFramed, Vec<u8>)> {
    let server_addr = (server_name.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| anyhow::Error::new(e).context("resolve server address"))?
        .next()
        .ok_or_else(|| anyhow::anyhow!("no socket address found for {server_name}"))?;

    let tcp_stream =
        TcpStream::connect(server_addr).map_err(|e| anyhow::Error::new(e).context("TCP connect"))?;
    // The short read timeout is only meant for the interactive session loop.
    // Applying it during the connection sequence aborts `connect_finalize`
    // whenever a server response takes longer than the timeout, so use a
    // generous deadline while connecting and switch afterwards.
    tcp_stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .map_err(|e| anyhow::Error::new(e).context("set read timeout"))?;
    tcp_stream
        .set_nodelay(true)
        .map_err(|e| anyhow::Error::new(e).context("set nodelay"))?;

    let client_addr = tcp_stream
        .local_addr()
        .map_err(|e| anyhow::Error::new(e).context("local address"))?;

    let mut framed = ironrdp_blocking::Framed::new(tcp_stream);
    let mut connector = ClientConnector::new(config, client_addr);

    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|e| anyhow::anyhow!("begin RDP connection: {e}"))?;

    let initial_stream = framed.into_inner_no_leftover();
    let (upgraded_stream, server_public_key, server_certificate) =
        tls_upgrade(initial_stream, server_name.clone())?;

    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
    let mut upgraded_framed = ironrdp_blocking::Framed::new(upgraded_stream);

    let mut network_client = ReqwestNetworkClient;
    let connection_result = ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut upgraded_framed,
        &mut network_client,
        server_name.into(),
        server_public_key,
        None,
    )
    .map_err(|e| anyhow::anyhow!("finalize RDP connection: {e}"))?;

    // Connection sequence is done: make reads non-blocking for the session
    // loop, which polls input and drains server updates on a short timeout.
    upgraded_framed
        .get_inner()
        .0
        .sock
        .set_read_timeout(Some(Duration::from_millis(8)))
        .map_err(|e| anyhow::Error::new(e).context("set session read timeout"))?;

    Ok((connection_result, upgraded_framed, server_certificate))
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
