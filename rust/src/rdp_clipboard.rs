//! RDP clipboard redirection (`CLIPRDR` channel).
//!
//! Local clipboard changes are pushed to the remote session and remote changes
//! are applied to the local clipboard.
//!
//! On Windows the OS integration is provided by `ironrdp-cliprdr-native`,
//! which needs a Win32 message pump; that pump runs on a dedicated thread.
//! On other platforms a small text-only backend built on `arboard` polls the
//! local clipboard instead (files are Windows-only).

use std::sync::mpsc::{self, Receiver};

use ironrdp::cliprdr::backend::{ClipboardMessage, CliprdrBackendFactory};
use ironrdp::session::ActiveStage;

/// Owns the clipboard integration for the lifetime of a session (including
/// transparent reconnects).
pub struct ClipboardSession {
    factory: Option<Box<dyn CliprdrBackendFactory + Send>>,
    messages: Receiver<ClipboardMessage>,
    #[allow(dead_code)]
    thread: Option<platform::Thread>,
    #[cfg(not(windows))]
    shared: platform::SharedState,
    #[cfg(not(windows))]
    last_polled: Option<String>,
    #[cfg(not(windows))]
    last_poll: std::time::Instant,
}

impl ClipboardSession {
    /// Starts the clipboard integration. Failures are non-fatal: the returned
    /// session simply has no backend and clipboard redirection is disabled.
    pub fn new(enabled: bool) -> Self {
        #[cfg(windows)]
        {
            if !enabled {
                let (_tx, messages) = mpsc::channel();
                return Self {
                    factory: None,
                    messages,
                    thread: None,
                };
            }

            let (tx, messages) = mpsc::channel();
            let (factory, thread) = platform::start(tx);
            if factory.is_none() {
                tracing::warn!("RDP clipboard backend unavailable; clipboard redirection disabled");
            }

            Self {
                factory,
                messages,
                thread,
            }
        }

        #[cfg(not(windows))]
        {
            let (_tx, messages) = mpsc::channel();

            if !enabled {
                return Self {
                    factory: None,
                    messages,
                    thread: None,
                    shared: platform::new_shared(),
                    last_polled: None,
                    last_poll: std::time::Instant::now(),
                };
            }

            let (tx, messages) = mpsc::channel();
            let (factory, shared) = platform::start(tx);

            Self {
                factory,
                messages,
                thread: None,
                shared,
                last_polled: None,
                last_poll: std::time::Instant::now(),
            }
        }
    }

    pub fn factory(&self) -> Option<&(dyn CliprdrBackendFactory + Send)> {
        self.factory.as_deref()
    }

    /// Non-blocking: returns the next message queued by the OS backend, or a
    /// locally-detected clipboard change on platforms without an event loop.
    pub fn next(&mut self) -> Option<ClipboardMessage> {
        if let Ok(message) = self.messages.try_recv() {
            return Some(message);
        }

        #[cfg(not(windows))]
        {
            platform::poll_local(&self.shared, &mut self.last_polled, &mut self.last_poll)
        }

        #[cfg(windows)]
        {
            None
        }
    }
}

/// Relays one backend message to the session's `CLIPRDR` processor and returns
/// the encoded frame that must be written to the wire, if any.
pub fn dispatch(
    active_stage: &mut ActiveStage,
    message: ClipboardMessage,
) -> anyhow::Result<Option<Vec<u8>>> {
    use ironrdp::cliprdr::CliprdrClient;

    let svc_messages = {
        let Some(cliprdr) = active_stage.get_svc_processor_mut::<CliprdrClient>() else {
            return Ok(None);
        };

        match message {
            ClipboardMessage::SendInitiateCopy(formats) => {
                cliprdr.initiate_copy(&formats).map_err(protocol_error)?
            }
            ClipboardMessage::SendFormatData(response) => {
                cliprdr.submit_format_data(response).map_err(protocol_error)?
            }
            ClipboardMessage::SendInitiatePaste(format) => {
                cliprdr.initiate_paste(format).map_err(protocol_error)?
            }
            ClipboardMessage::SendFileContentsRequest(request) => {
                cliprdr.request_file_contents(request).map_err(protocol_error)?
            }
            ClipboardMessage::SendFileContentsResponse(response) => {
                cliprdr.submit_file_contents(response).map_err(protocol_error)?
            }
            ClipboardMessage::SendInitiateFileCopy(files) => {
                cliprdr.initiate_file_copy(files).map_err(protocol_error)?
            }
            ClipboardMessage::Error(error) => {
                tracing::warn!("RDP clipboard backend error: {error}");
                return Ok(None);
            }
        }
    };

    let frame = active_stage
        .process_svc_processor_messages(svc_messages)
        .map_err(|error| anyhow::anyhow!("encode clipboard frame: {error}"))?;

    Ok(Some(frame))
}

fn protocol_error(error: ironrdp::pdu::PduError) -> anyhow::Error {
    anyhow::anyhow!("clipboard protocol error: {error}")
}

#[cfg(windows)]
mod platform {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc::{channel, Sender};
    use std::sync::Arc;
    use std::time::Duration;

    use ironrdp::cliprdr::backend::{ClipboardMessage, ClipboardMessageProxy, CliprdrBackendFactory};
    use ironrdp_cliprdr_native::WinClipboard;

    pub struct Thread {
        shutdown: Arc<AtomicBool>,
        join: Option<std::thread::JoinHandle<()>>,
    }

    impl Drop for Thread {
        fn drop(&mut self) {
            self.shutdown.store(true, Ordering::Relaxed);
            if let Some(join) = self.join.take() {
                let _ = join.join();
            }
        }
    }

    #[derive(Debug)]
    struct Proxy {
        tx: Sender<ClipboardMessage>,
    }

    impl ClipboardMessageProxy for Proxy {
        fn send_clipboard_message(&self, message: ClipboardMessage) {
            let _ = self.tx.send(message);
        }
    }

    pub fn start(
        tx: Sender<ClipboardMessage>,
    ) -> (
        Option<Box<dyn CliprdrBackendFactory + Send>>,
        Option<Thread>,
    ) {
        let (factory_tx, factory_rx) = channel();
        let shutdown = Arc::new(AtomicBool::new(false));
        let thread_shutdown = shutdown.clone();

        let join = std::thread::Builder::new()
            .name("connexia-rdp-clipboard".to_owned())
            .spawn(move || {
                let clipboard = match WinClipboard::new(Proxy { tx }) {
                    Ok(clipboard) => clipboard,
                    Err(error) => {
                        let _ = factory_tx.send(Err(format!("{error}")));
                        return;
                    }
                };

                if factory_tx.send(Ok(clipboard.backend_factory())).is_err() {
                    return;
                }

                use windows::Win32::UI::WindowsAndMessaging::{
                    DispatchMessageW, PeekMessageW, TranslateMessage, MSG, PM_REMOVE,
                };

                let mut message = MSG::default();
                while !thread_shutdown.load(Ordering::Relaxed) {
                    // SAFETY: the message queue belongs to this thread, which
                    // also created the clipboard window.
                    while unsafe { PeekMessageW(&mut message, None, 0, 0, PM_REMOVE) }.as_bool() {
                        // SAFETY: `message` was filled by `PeekMessageW`.
                        unsafe {
                            let _ = TranslateMessage(&message);
                            DispatchMessageW(&message);
                        }
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }

                drop(clipboard);
            })
            .ok();

        let factory = factory_rx
            .recv_timeout(Duration::from_secs(5))
            .ok()
            .and_then(Result::ok);

        let thread = join.map(|join| Thread {
            shutdown,
            join: Some(join),
        });

        (factory, thread)
    }
}

#[cfg(not(windows))]
mod platform {
    use std::sync::mpsc::Sender;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use ironrdp::cliprdr::backend::{
        ClipboardMessage, CliprdrBackend, CliprdrBackendFactory,
    };
    use ironrdp::cliprdr::pdu::{
        ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FileContentsRequest,
        FileContentsResponse, FormatDataRequest, FormatDataResponse, LockDataId,
    };
    use ironrdp::core::{impl_as_any, IntoOwned as _};

    const POLL_INTERVAL: Duration = Duration::from_millis(500);

    #[derive(Debug, Default)]
    pub struct Shared {
        /// Text last written locally on behalf of the remote, so it is not
        /// echoed straight back as a local copy.
        suppress: Option<String>,
    }

    pub type SharedState = Arc<Mutex<Shared>>;

    pub fn new_shared() -> SharedState {
        Arc::new(Mutex::new(Shared::default()))
    }

    /// The non-Windows backend needs no dedicated thread; the session loop
    /// polls the local clipboard. This is a never-constructed placeholder so
    /// the cross-platform session type has a uniform shape.
    pub struct Thread;

    pub fn start(
        tx: Sender<ClipboardMessage>,
    ) -> (Option<Box<dyn CliprdrBackendFactory + Send>>, SharedState) {
        let shared = new_shared();
        let factory = Factory {
            tx,
            shared: shared.clone(),
        };
        (Some(Box::new(factory)), shared)
    }

    pub fn poll_local(
        shared: &SharedState,
        last_polled: &mut Option<String>,
        last_poll: &mut Instant,
    ) -> Option<ClipboardMessage> {
        if last_poll.elapsed() < POLL_INTERVAL {
            return None;
        }
        *last_poll = Instant::now();

        let current = read_text()?;
        if last_polled.as_deref() == Some(current.as_str()) {
            return None;
        }

        if let Ok(shared) = shared.lock() {
            if shared.suppress.as_deref() == Some(current.as_str()) {
                *last_polled = Some(current);
                return None;
            }
        }

        *last_polled = Some(current);

        Some(ClipboardMessage::SendInitiateCopy(vec![text_format()]))
    }

    struct Factory {
        tx: Sender<ClipboardMessage>,
        shared: SharedState,
    }

    impl std::fmt::Debug for Factory {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.debug_struct("ArboardClipboardFactory").finish_non_exhaustive()
        }
    }

    impl CliprdrBackendFactory for Factory {
        fn build_cliprdr_backend(&self) -> Box<dyn CliprdrBackend> {
            Box::new(Backend {
                tx: self.tx.clone(),
                shared: self.shared.clone(),
                temporary_directory: std::env::temp_dir().to_string_lossy().into_owned(),
            })
        }
    }

    struct Backend {
        tx: Sender<ClipboardMessage>,
        shared: SharedState,
        temporary_directory: String,
    }

    impl std::fmt::Debug for Backend {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.debug_struct("ArboardClipboardBackend").finish_non_exhaustive()
        }
    }

    impl_as_any!(Backend);

    impl CliprdrBackend for Backend {
        fn temporary_directory(&self) -> &str {
            &self.temporary_directory
        }

        fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
            ClipboardGeneralCapabilityFlags::empty()
        }

        fn on_ready(&mut self) {}

        fn on_request_format_list(&mut self) {
            if let Some(text) = read_text() {
                if !text.is_empty() {
                    let _ = self
                        .tx
                        .send(ClipboardMessage::SendInitiateCopy(vec![text_format()]));
                }
            }
        }

        fn on_process_negotiated_capabilities(&mut self, _: ClipboardGeneralCapabilityFlags) {}

        fn on_remote_copy(&mut self, available_formats: &[ClipboardFormat]) {
            if available_formats
                .iter()
                .any(|format| format.id == ClipboardFormatId::CF_UNICODETEXT)
            {
                let _ = self
                    .tx
                    .send(ClipboardMessage::SendInitiatePaste(ClipboardFormatId::CF_UNICODETEXT));
            }
        }

        fn on_format_data_request(&mut self, request: FormatDataRequest) {
            let response = if request.format == ClipboardFormatId::CF_UNICODETEXT {
                match read_text() {
                    Some(text) => FormatDataResponse::new_unicode_string(&text).into_owned(),
                    None => FormatDataResponse::new_error().into_owned(),
                }
            } else {
                FormatDataResponse::new_error().into_owned()
            };

            let _ = self.tx.send(ClipboardMessage::SendFormatData(response));
        }

        fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
            if response.is_error() {
                return;
            }

            if let Ok(text) = response.to_unicode_string() {
                if let Ok(mut shared) = self.shared.lock() {
                    shared.suppress = Some(text.clone());
                }
                write_text(&text);
            }
        }

        fn on_file_contents_request(&mut self, request: FileContentsRequest) {
            let _ = self.tx.send(ClipboardMessage::SendFileContentsResponse(
                FileContentsResponse::new_error(request.stream_id).into_owned(),
            ));
        }

        fn on_file_contents_response(&mut self, _: FileContentsResponse<'_>) {}

        fn on_lock(&mut self, _: LockDataId) {}

        fn on_unlock(&mut self, _: LockDataId) {}
    }

    fn text_format() -> ClipboardFormat {
        ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)
    }

    fn read_text() -> Option<String> {
        arboard::Clipboard::new().ok()?.get_text().ok()
    }

    fn write_text(text: &str) {
        if let Ok(mut clipboard) = arboard::Clipboard::new() {
            let _ = clipboard.set_text(text.to_owned());
        }
    }
}
