//! RDP clipboard redirection (`CLIPRDR` channel).
//!
//! Local clipboard changes are pushed to the remote session and remote changes
//! are applied to the local clipboard.
//!
//! On Windows the OS integration is provided by `ironrdp-cliprdr-native`,
//! which needs a Win32 message pump; that pump runs on a dedicated thread.
//! On other platforms a small text-only backend built on `arboard` polls the
//! local clipboard instead (files are Windows-only).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;

use ironrdp::cliprdr::backend::{ClipboardMessage, CliprdrBackend, CliprdrBackendFactory};
use ironrdp::cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardFormatName, ClipboardGeneralCapabilityFlags,
    FileContentsFlags, FileContentsRequest, FileContentsResponse, FileDescriptor,
    FormatDataRequest, FormatDataResponse, LockDataId,
};
use ironrdp::core::{impl_as_any, IntoOwned as _};
use ironrdp::session::ActiveStage;

/// Progress of a clipboard file transfer, surfaced to the UI so it can show an
/// overlay with the same information `mstsc`'s copy dialog does.
#[derive(Debug, Clone)]
pub struct FileTransferProgress {
    /// `true` when local files are being sent to the remote, `false` when
    /// remote files are being received.
    pub sending: bool,
    pub file_name: String,
    /// 1-based index of the file currently transferring.
    pub index: u32,
    pub file_count: u32,
    /// Bytes done for the current file.
    pub transferred: u64,
    /// Total bytes of the current file (`0` when unknown).
    pub total: u64,
    /// `true` for the final update, after which the UI may dismiss the overlay.
    pub complete: bool,
}

/// Owns the clipboard integration for the lifetime of a session (including
/// transparent reconnects).
pub struct ClipboardSession {
    factory: Option<Box<dyn CliprdrBackendFactory + Send>>,
    messages: Receiver<ClipboardMessage>,
    progress: Receiver<FileTransferProgress>,
    /// Set when the user aborts an in-flight file transfer; the backend answers
    /// further `FileContentsRequest`s with an error so the remote stops.
    cancelled: Arc<AtomicBool>,
    /// Set while we advertise a synthesized `FileGroupDescriptorW` (used when the
    /// shell put `CF_HDROP` on the clipboard without the OLE file formats).
    injected_descriptor: Arc<AtomicBool>,
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
        let (progress_tx, progress) = mpsc::channel::<FileTransferProgress>();
        let cancelled = Arc::new(AtomicBool::new(false));
        let injected_descriptor = Arc::new(AtomicBool::new(false));

        #[cfg(windows)]
        {
            if !enabled {
                let (_tx, messages) = mpsc::channel();
                return Self {
                    factory: None,
                    messages,
                    progress,
                    cancelled,
                    injected_descriptor,
                    thread: None,
                };
            }

            let (tx, messages) = mpsc::channel();
            let (factory, thread) = platform::start(
                tx,
                progress_tx,
                cancelled.clone(),
                injected_descriptor.clone(),
            );
            if factory.is_none() {
                tracing::warn!("RDP clipboard backend unavailable; clipboard redirection disabled");
            }
            crate::rdp_trace::clipboard(&format!(
                "clipboard: session started (factory={})",
                factory.is_some()
            ));

            Self {
                factory,
                messages,
                progress,
                cancelled,
                injected_descriptor,
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
                    progress,
                    cancelled,
                    injected_descriptor,
                    thread: None,
                    shared: platform::new_shared(),
                    last_polled: None,
                    last_poll: std::time::Instant::now(),
                };
            }

            let (tx, messages) = mpsc::channel();
            let (factory, shared) =
                platform::start(tx, progress_tx, cancelled.clone(), injected_descriptor.clone());
            crate::rdp_trace::clipboard(&format!(
                "clipboard: session started (factory={})",
                factory.is_some()
            ));

            Self {
                factory,
                messages,
                progress,
                cancelled,
                injected_descriptor,
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
        let inner = self.next_inner();
        let message = self.augment(inner);
        if let Some(message) = &message {
            crate::rdp_trace::clipboard(&format!("clipboard: backend message {message:?}"));
        }
        message
    }

    /// Ensures a local file copy is advertised to the remote even when the shell
    /// only exposed `CF_HDROP` (no `FileGroupDescriptorW`): CLIPRDR lists files
    /// through that format, so without it a file paste silently does nothing.
    #[cfg(windows)]
    fn augment(&self, message: Option<ClipboardMessage>) -> Option<ClipboardMessage> {
        let mut formats = match message {
            Some(ClipboardMessage::SendInitiateCopy(formats)) => formats,
            other => return other,
        };

        let present = formats.iter().any(|format| {
            format.name().map(ClipboardFormatName::value) == Some(ClipboardFormatName::FILE_LIST.value())
        });
        if present {
            self.injected_descriptor.store(false, Ordering::Release);
            return Some(ClipboardMessage::SendInitiateCopy(formats));
        }

        let files = platform::read_local_file_list();
        if files.is_empty() {
            self.injected_descriptor.store(false, Ordering::Release);
            return Some(ClipboardMessage::SendInitiateCopy(formats));
        }

        let id = platform::file_descriptor_format_id();
        formats.push(ClipboardFormat::new(ClipboardFormatId(id)).with_name(ClipboardFormatName::FILE_LIST));
        self.injected_descriptor.store(true, Ordering::Release);
        crate::rdp_trace::clipboard(&format!(
            "clipboard: synthesized FileGroupDescriptorW (id={id}) for {} local file(s)",
            files.len()
        ));
        Some(ClipboardMessage::SendInitiateCopy(formats))
    }

    #[cfg(not(windows))]
    fn augment(&self, message: Option<ClipboardMessage>) -> Option<ClipboardMessage> {
        message
    }

    fn next_inner(&mut self) -> Option<ClipboardMessage> {
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

    /// Non-blocking: returns the next clipboard file-transfer progress update,
    /// if any.
    pub fn next_progress(&mut self) -> Option<FileTransferProgress> {
        self.progress.try_recv().ok()
    }

    /// Aborts an in-flight local-to-remote file transfer. The backend answers
    /// further `FileContentsRequest`s for the current data id with an error so
    /// the remote stops writing the file.
    pub fn cancel_transfer(&self) {
        crate::rdp_trace::clipboard("clipboard: file transfer cancelled by user");
        self.cancelled.store(true, Ordering::Release);
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
            crate::rdp_trace::clipboard("clipboard: CLIPRDR channel is not active; dropping message");
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

    crate::rdp_trace::clipboard(&format!("clipboard: dispatching frame ({} bytes)", frame.len()));

    Ok(Some(frame))
}

fn protocol_error(error: ironrdp::pdu::PduError) -> anyhow::Error {
    anyhow::anyhow!("clipboard protocol error: {error}")
}

/// Logging decorator around a platform clipboard backend. Every callback the
/// `CLIPRDR` processor makes on behalf of the server is written to the
/// always-on clipboard log, which makes it possible to tell whether the server
/// is asking for clipboard data or not.
/// Normalize line endings to CRLF (`\r\n`), the Windows clipboard convention.
///
/// Some local sources (notably Chromium) place LF-only text in
/// `CF_UNICODETEXT`; remote Windows apps then drop the lone LFs and paste
/// multi-line text as a single line.
fn normalize_crlf(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n").replace('\n', "\r\n")
}

#[derive(Debug)]
struct LoggingBackend {
    inner: Box<dyn CliprdrBackend>,
    tx: Sender<ClipboardMessage>,
    /// Per-`data_id` snapshot of the local clipboard file list.
    ///
    /// The remote locks a data id for the whole transfer and expects every
    /// `FileContentsRequest` carrying it to be served from the same file set.
    /// Re-reading the live clipboard for each 256 KiB request both breaks the
    /// transfer when the local clipboard changes mid-way (observed: an empty
    /// file list at 20.4 MiB, followed by "unspecified error" on the remote)
    /// and repeatedly contends `OpenClipboard` with the local shell, which
    /// stalls the session. Cache the resolved list instead and refresh only
    /// when a new data id is used.
    file_snapshots: HashMap<u32, Vec<String>>,
    progress: Sender<FileTransferProgress>,
    cancelled: Arc<AtomicBool>,
    injected_descriptor: Arc<AtomicBool>,
}

impl_as_any!(LoggingBackend);

impl CliprdrBackend for LoggingBackend {
    fn temporary_directory(&self) -> &str {
        self.inner.temporary_directory()
    }

    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        // The native backend advertises no file capabilities (it does not
        // implement file transfer itself), but we serve `FileContentsRequest`s
        // in `on_file_contents_request` — claim stream-based file clipboard
        // support so the remote actually attempts file paste.
        //
        // `CAN_LOCK_CLIPDATA` lets the remote lock the clipboard data and
        // keep several file contents requests outstanding simultaneously;
        // without it rdclip strictly serializes one 256 KiB request per
        // round trip, which limits throughput to a fraction of the link.
        let capabilities = self.inner.client_capabilities();

        #[cfg(windows)]
        let capabilities = capabilities
            | ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED
            | ClipboardGeneralCapabilityFlags::CAN_LOCK_CLIPDATA
            | ClipboardGeneralCapabilityFlags::HUGE_FILE_SUPPORT_ENABLED;

        crate::rdp_trace::clipboard(&format!("backend: client_capabilities -> {capabilities:?}"));
        capabilities
    }

    fn on_ready(&mut self) {
        crate::rdp_trace::clipboard("backend: on_ready");
        self.inner.on_ready();
    }

    fn on_request_format_list(&mut self) {
        crate::rdp_trace::clipboard("backend: on_request_format_list");
        self.inner.on_request_format_list();
    }

    fn on_format_list_response(&mut self, ok: bool) {
        crate::rdp_trace::clipboard(&format!("backend: on_format_list_response ok={ok}"));
        self.inner.on_format_list_response(ok);
    }

    fn on_process_negotiated_capabilities(&mut self, capabilities: ClipboardGeneralCapabilityFlags) {
        crate::rdp_trace::clipboard(&format!(
            "backend: on_process_negotiated_capabilities {capabilities:?}"
        ));
        self.inner.on_process_negotiated_capabilities(capabilities);
    }

    fn on_remote_copy(&mut self, available_formats: &[ClipboardFormat]) {
        crate::rdp_trace::clipboard(&format!(
            "backend: on_remote_copy ({} formats)",
            available_formats.len()
        ));
        self.inner.on_remote_copy(available_formats);
    }

    fn on_format_data_request(&mut self, request: FormatDataRequest) {
        crate::rdp_trace::clipboard(&format!(
            "backend: on_format_data_request format={:?}",
            request.format
        ));

        // Serve a file descriptor synthesized from `CF_HDROP` when the shell did
        // not put the OLE file formats on the clipboard (otherwise the remote
        // has no `FileGroupDescriptorW` to request and the paste does nothing).
        #[cfg(windows)]
        {
            if self.injected_descriptor.load(Ordering::Acquire)
                && request.format.0 == platform::file_descriptor_format_id()
            {
                let files = platform::read_local_file_list();
                let descriptor = platform::build_file_descriptor(&files);
                crate::rdp_trace::clipboard(&format!(
                    "backend: serving synthesized FileGroupDescriptorW ({} files, {} bytes)",
                    files.len(),
                    descriptor.len()
                ));
                let _ = self.tx.send(ClipboardMessage::SendFormatData(
                    FormatDataResponse::new_data(descriptor).into_owned(),
                ));
                return;
            }
        }

        // Serve text ourselves so line endings can be normalized to CRLF;
        // other formats fall through to the platform backend.
        if request.format == ClipboardFormatId::CF_UNICODETEXT {
            if let Some(response) = platform::serve_unicode_text() {
                let _ = self.tx.send(ClipboardMessage::SendFormatData(response));
                return;
            }
        }

        self.inner.on_format_data_request(request);
    }

    fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
        crate::rdp_trace::clipboard(&format!(
            "backend: on_format_data_response is_error={} len={}",
            response.is_error(),
            response.data().len()
        ));
        self.inner.on_format_data_response(response);
    }

    fn on_file_contents_request(&mut self, request: FileContentsRequest) {
        crate::rdp_trace::clipboard(&format!(
            "backend: on_file_contents_request index={} stream_id={} flags={:?} position={} size={} data_id={:?}",
            request.index,
            request.stream_id,
            request.flags,
            request.position,
            request.requested_size,
            request.data_id
        ));

        // `ironrdp-cliprdr-native` does not implement file contents transfer, so
        // serve the request from the local filesystem ourselves. The file list
        // is read back from the OS clipboard (CF_HDROP), which is what the
        // remote's `FileGroupDescriptorW` request was answered from.
        #[cfg(windows)]
        {
            // Serve from a stable per-`data_id` snapshot: the remote may keep
            // the same data id locked for the whole transfer, and the local
            // clipboard changing part-way through must not swap the files out
            // from under it (nor block `OpenClipboard` on each request). A new
            // data id also clears a previous user cancellation.
            let files = match request.data_id {
                Some(data_id) => {
                    if !self.file_snapshots.contains_key(&data_id) {
                        self.cancelled.store(false, Ordering::Release);
                        // An empty read is usually a transient clipboard lock
                        // (the shell still rendering the copy); do not cache it,
                        // so the next request retries instead of failing the
                        // whole transfer.
                        let list = platform::read_local_file_list();
                        if !list.is_empty() {
                            self.file_snapshots.insert(data_id, list);
                        }
                    }
                    self.file_snapshots
                        .get(&data_id)
                        .cloned()
                        .unwrap_or_default()
                }
                None => platform::read_local_file_list(),
            };

            if self.cancelled.load(Ordering::Acquire) {
                crate::rdp_trace::clipboard("file contents: aborting transfer (user cancelled)");
                let _ = self
                    .tx
                    .send(ClipboardMessage::SendFileContentsResponse(
                        FileContentsResponse::new_error(request.stream_id),
                    ));
                return;
            }

            let response = platform::serve_file_contents(&request, &files);

            // Report transfer progress for the UI overlay.
            let index = usize::try_from(request.index).unwrap_or(usize::MAX);
            if let (false, Some(path)) = (response.is_error(), files.get(index)) {
                let total = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
                let chunk = response.data().len() as u64;
                let transferred = if request.flags.contains(FileContentsFlags::RANGE) {
                    (request.position + chunk).min(total)
                } else {
                    0
                };
                let _ = self.progress.send(FileTransferProgress {
                    sending: true,
                    file_name: std::path::Path::new(path)
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_else(|| path.clone()),
                    index: u32::try_from(request.index).unwrap_or(0).max(1),
                    file_count: files.len() as u32,
                    transferred,
                    total,
                    complete: total > 0 && transferred >= total,
                });
            }

            let _ = self
                .tx
                .send(ClipboardMessage::SendFileContentsResponse(response));
        }

        #[cfg(not(windows))]
        {
            self.inner.on_file_contents_request(request);
        }
    }

    fn on_file_contents_response(&mut self, response: FileContentsResponse<'_>) {
        crate::rdp_trace::clipboard(&format!(
            "backend: on_file_contents_response stream_id={} len={}",
            response.stream_id(),
            response.data().len()
        ));
        self.inner.on_file_contents_response(response);
    }

    fn on_lock(&mut self, data_id: LockDataId) {
        crate::rdp_trace::clipboard(&format!("backend: on_lock {data_id:?}"));
        self.inner.on_lock(data_id);
    }

    fn on_unlock(&mut self, data_id: LockDataId) {
        crate::rdp_trace::clipboard(&format!("backend: on_unlock {data_id:?}"));
        self.file_snapshots.remove(&data_id.0);
        self.inner.on_unlock(data_id);
    }

    fn on_remote_file_list(&mut self, files: &[FileDescriptor], clip_data_id: Option<u32>) {
        crate::rdp_trace::clipboard(&format!(
            "backend: on_remote_file_list ({} files)",
            files.len()
        ));
        self.inner.on_remote_file_list(files, clip_data_id);
    }

    fn on_outgoing_locks_cleared(&mut self, clip_data_ids: &[LockDataId]) {
        self.inner.on_outgoing_locks_cleared(clip_data_ids);
    }

    fn on_outgoing_locks_expired(&mut self, clip_data_ids: &[LockDataId]) {
        self.inner.on_outgoing_locks_expired(clip_data_ids);
    }

    fn now_ms(&self) -> u64 {
        self.inner.now_ms()
    }

    fn elapsed_ms(&self, since: u64) -> u64 {
        self.inner.elapsed_ms(since)
    }
}

/// Wraps a platform backend factory so every produced backend is logged.
struct LoggingFactory {
    inner: Box<dyn CliprdrBackendFactory + Send>,
    tx: Sender<ClipboardMessage>,
    progress: Sender<FileTransferProgress>,
    cancelled: Arc<AtomicBool>,
    injected_descriptor: Arc<AtomicBool>,
}

impl CliprdrBackendFactory for LoggingFactory {
    fn build_cliprdr_backend(&self) -> Box<dyn CliprdrBackend> {
        Box::new(LoggingBackend {
            inner: self.inner.build_cliprdr_backend(),
            tx: self.tx.clone(),
            file_snapshots: HashMap::new(),
            progress: self.progress.clone(),
            cancelled: self.cancelled.clone(),
            injected_descriptor: self.injected_descriptor.clone(),
        })
    }
}

#[cfg(windows)]
mod platform {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc::{channel, Sender};
    use std::sync::Arc;
    use std::time::Duration;

    use std::io::{Read as _, Seek as _, SeekFrom};

    use ironrdp::cliprdr::backend::{ClipboardMessage, ClipboardMessageProxy, CliprdrBackendFactory};
    use ironrdp::cliprdr::pdu::{
        FileContentsFlags, FileContentsRequest, FileContentsResponse, FormatDataResponse,
        OwnedFormatDataResponse,
    };
    use ironrdp::core::IntoOwned as _;
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

    /// The `ironrdp-cliprdr-native` backend only forwards local clipboard
    /// changes while it believes its hidden window is *inactive* (it suppresses
    /// changes caused by the remote while the client owns the clipboard). That
    /// flag starts as `true` and is normally cleared by `WM_ACTIVATEAPP`, which
    /// is not delivered to a window on our dedicated thread. Post `WM_ACTIVATE`
    /// with `WA_INACTIVE` to clear it so local copies reach the remote.
    fn mark_hidden_window_inactive() {
        use windows::core::BOOL;
        use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
        use windows::Win32::System::Threading::GetCurrentThreadId;
        use windows::Win32::UI::WindowsAndMessaging::{EnumThreadWindows, PostMessageW, WM_ACTIVATE};

        // Return FALSE to stop the enumeration after the first window.
        unsafe extern "system" fn post_inactive(window: HWND, _: LPARAM) -> BOOL {
            // SAFETY: posting to a valid window handle owned by this thread.
            let _ = unsafe { PostMessageW(Some(window), WM_ACTIVATE, WPARAM(0), LPARAM(0)) };
            BOOL(0)
        }

        // SAFETY: the callback only posts to windows of the current thread.
        unsafe {
            let _ = EnumThreadWindows(GetCurrentThreadId(), Some(post_inactive), LPARAM(0));
        }
    }

    /// Read `CF_UNICODETEXT` from the local clipboard, normalized to CRLF
    /// line endings. Returns `None` when the clipboard is busy or holds no
    /// text, so the caller can fall back to the native backend.
    pub(super) fn serve_unicode_text() -> Option<OwnedFormatDataResponse> {
        use clipboard_win::{formats, Clipboard, Getter};

        let _clip = Clipboard::new_attempts(10).ok()?;
        let mut text = String::new();
        formats::Unicode.read_clipboard(&mut text).ok()?;

        if text.is_empty() {
            return None;
        }

        let normalized = super::normalize_crlf(&text);
        crate::rdp_trace::clipboard(&format!(
            "text: serving {} chars, {} CRLF",
            normalized.chars().count(),
            normalized.matches("\r\n").count()
        ));
        Some(FormatDataResponse::new_unicode_string(&normalized).into_owned())
    }

    /// Read the current file list from the local (CF_HDROP) clipboard.
    pub(super) fn read_local_file_list() -> Vec<String> {
        use clipboard_win::{formats, Clipboard, Getter};

        let mut files = Vec::new();
        match Clipboard::new_attempts(10) {
            Ok(_clip) => {
                let _ = formats::FileList.read_clipboard(&mut files);
            }
            Err(error) => {
                crate::rdp_trace::clipboard(&format!("file list: open clipboard failed: {error}"));
            }
        }

        // Log what our side sees so a remote request that fails can be traced
        // back to the clipboard contents (e.g. a file copied from inside an
        // archive may not expose a plain `CF_HDROP` path).
        let names: Vec<String> = files
            .iter()
            .map(|path| {
                std::path::Path::new(path)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.clone())
            })
            .collect();
        crate::rdp_trace::clipboard(&format!(
            "file list: read {} file(s){}",
            files.len(),
            if names.is_empty() {
                String::new()
            } else {
                format!(": {}", names.join(", "))
            }
        ));

        files
    }

    /// Clipboard format id for `FileGroupDescriptorW`, registering it in this
    /// session if it has not been used yet. The id is stable for the process.
    pub(super) fn file_descriptor_format_id() -> u32 {
        clipboard_win::raw::register_format("FileGroupDescriptorW")
            .map(|id| id.get())
            .unwrap_or(0)
    }

    /// Builds a `FILEGROUPDESCRIPTORW` blob describing `files`.
    ///
    /// Used when the shell exposed only `CF_HDROP`: CLIPRDR lists files through
    /// `FileGroupDescriptorW`, so we synthesize it instead of relying on
    /// Explorer to place the OLE file formats on the clipboard.
    pub(super) fn build_file_descriptor(files: &[String]) -> Vec<u8> {
        const FILEDESCRIPTORW_SIZE: usize = 592;
        const FD_ATTRIBUTES: u32 = 0x0000_0004;
        const FD_FILESIZE: u32 = 0x0000_0040;
        const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x0000_0010;
        const FILE_ATTRIBUTE_NORMAL: u32 = 0x0000_0080;
        // Offsets within `FILEDESCRIPTORW`.
        const AT_ATTRIBUTES: usize = 36;
        const AT_SIZE_HIGH: usize = 64;
        const AT_SIZE_LOW: usize = 68;
        const AT_NAME: usize = 72;

        let mut out = Vec::with_capacity(4 + files.len() * FILEDESCRIPTORW_SIZE);
        out.extend_from_slice(&(files.len() as u32).to_le_bytes());

        for path in files {
            let path = std::path::Path::new(path);
            let name = path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            let metadata = std::fs::metadata(path).ok();
            let size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);
            let attributes = metadata
                .as_ref()
                .map(|m| {
                    if m.is_dir() {
                        FILE_ATTRIBUTE_DIRECTORY
                    } else {
                        FILE_ATTRIBUTE_NORMAL
                    }
                })
                .unwrap_or(FILE_ATTRIBUTE_NORMAL);

            let mut item = [0u8; FILEDESCRIPTORW_SIZE];
            item[0..4].copy_from_slice(&(FD_ATTRIBUTES | FD_FILESIZE).to_le_bytes());
            item[AT_ATTRIBUTES..AT_ATTRIBUTES + 4].copy_from_slice(&attributes.to_le_bytes());
            item[AT_SIZE_HIGH..AT_SIZE_HIGH + 4].copy_from_slice(&((size >> 32) as u32).to_le_bytes());
            item[AT_SIZE_LOW..AT_SIZE_LOW + 4]
                .copy_from_slice(&((size & 0xFFFF_FFFF) as u32).to_le_bytes());
            // `cFileName` is a null-terminated `WCHAR[260]`; keep the last unit
            // zero by truncating to 259 code units.
            for (index, unit) in name.encode_utf16().take(259).enumerate() {
                let offset = AT_NAME + index * 2;
                item[offset..offset + 2].copy_from_slice(&unit.to_le_bytes());
            }
            out.extend_from_slice(&item);
        }

        out
    }

    /// Answer a remote `FileContentsRequest` from a resolved local file list.
    /// Returns an error response when the file is unknown or unreadable, so the
    /// remote paste fails cleanly instead of hanging.
    pub(super) fn serve_file_contents(
        request: &FileContentsRequest,
        files: &[String],
    ) -> FileContentsResponse<'static> {
        let path = files
            .get(usize::try_from(request.index).unwrap_or(usize::MAX))
            .map(std::path::PathBuf::from);

        let Some(path) = path else {
            crate::rdp_trace::clipboard(&format!(
                "file contents: index {} out of range ({} files)",
                request.index,
                files.len()
            ));
            return FileContentsResponse::new_error(request.stream_id);
        };

        if path.is_dir() {
            crate::rdp_trace::clipboard(&format!(
                "file contents: '{}' is a directory, unsupported",
                path.display()
            ));
            return FileContentsResponse::new_error(request.stream_id);
        }

        if request.flags.contains(FileContentsFlags::SIZE) {
            return match std::fs::metadata(&path) {
                Ok(metadata) => {
                    FileContentsResponse::new_size_response(request.stream_id, metadata.len())
                }
                Err(error) => {
                    crate::rdp_trace::clipboard(&format!(
                        "file contents: metadata '{}' failed: {error}",
                        path.display()
                    ));
                    FileContentsResponse::new_error(request.stream_id)
                }
            };
        }

        if request.flags.contains(FileContentsFlags::RANGE) {
            let mut file = match std::fs::File::open(&path) {
                Ok(file) => file,
                Err(error) => {
                    crate::rdp_trace::clipboard(&format!(
                        "file contents: open '{}' failed: {error}",
                        path.display()
                    ));
                    return FileContentsResponse::new_error(request.stream_id);
                }
            };

            if let Err(error) = file.seek(SeekFrom::Start(request.position)) {
                crate::rdp_trace::clipboard(&format!(
                    "file contents: seek '{}' failed: {error}",
                    path.display()
                ));
                return FileContentsResponse::new_error(request.stream_id);
            }

            // Cap a single response; the remote asks for the remainder in
            // subsequent requests. The cap also bounds writer-queue memory.
            const MAX_CHUNK: usize = 4 * 1024 * 1024;
            let capacity = usize::try_from(request.requested_size)
                .unwrap_or(MAX_CHUNK)
                .min(MAX_CHUNK);
            let mut buffer = vec![0u8; capacity];
            let mut filled = 0;
            while filled < buffer.len() {
                match file.read(&mut buffer[filled..]) {
                    Ok(0) => break,
                    Ok(read) => filled += read,
                    Err(error) => {
                        crate::rdp_trace::clipboard(&format!(
                            "file contents: read '{}' failed: {error}",
                            path.display()
                        ));
                        return FileContentsResponse::new_error(request.stream_id);
                    }
                }
            }
            buffer.truncate(filled);

            crate::rdp_trace::clipboard(&format!(
                "file contents: served {} bytes from '{}' at offset {}",
                buffer.len(),
                path.display(),
                request.position
            ));
            return FileContentsResponse::new_data_response(request.stream_id, buffer);
        }

        FileContentsResponse::new_error(request.stream_id)
    }

    pub fn start(
        tx: Sender<ClipboardMessage>,
        progress: Sender<super::FileTransferProgress>,
        cancelled: Arc<AtomicBool>,
        injected_descriptor: Arc<AtomicBool>,
    ) -> (
        Option<Box<dyn CliprdrBackendFactory + Send>>,
        Option<Thread>,
    ) {
        let (factory_tx, factory_rx) = channel();
        let shutdown = Arc::new(AtomicBool::new(false));
        let thread_shutdown = shutdown.clone();
        // The backend wrapper needs its own sender to serve file contents.
        let proxy_tx = tx.clone();

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

                mark_hidden_window_inactive();

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

        let factory: Option<Box<dyn CliprdrBackendFactory + Send>> = factory_rx
            .recv_timeout(Duration::from_secs(5))
            .ok()
            .and_then(Result::ok)
            .map(|inner| {
                Box::new(super::LoggingFactory {
                    inner,
                    tx: proxy_tx,
                    progress,
                    cancelled,
                    injected_descriptor,
                }) as Box<dyn CliprdrBackendFactory + Send>
            });

        let thread = join.map(|join| Thread {
            shutdown,
            join: Some(join),
        });

        (factory, thread)
    }
}

#[cfg(not(windows))]
mod platform {
    use std::sync::atomic::AtomicBool;
    use std::sync::mpsc::Sender;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use ironrdp::cliprdr::backend::{
        ClipboardMessage, CliprdrBackend, CliprdrBackendFactory,
    };
    use ironrdp::cliprdr::pdu::{
        ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FileContentsRequest,
        FileContentsResponse, FormatDataRequest, FormatDataResponse, LockDataId,
        OwnedFormatDataResponse,
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
        progress: Sender<super::FileTransferProgress>,
        cancelled: Arc<AtomicBool>,
        injected_descriptor: Arc<AtomicBool>,
    ) -> (Option<Box<dyn CliprdrBackendFactory + Send>>, SharedState) {
        let shared = new_shared();
        let log_tx = tx.clone();
        let inner = Box::new(Factory {
            tx,
            shared: shared.clone(),
        });
        let factory = Box::new(super::LoggingFactory {
            inner,
            tx: log_tx,
            progress,
            cancelled,
            injected_descriptor,
        }) as Box<dyn CliprdrBackendFactory + Send>;
        (Some(factory), shared)
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

    /// Read local text for a remote `CF_UNICODETEXT` request, normalized to
    /// CRLF line endings. Returns `None` when there is no local text, so the
    /// caller can fall back to the platform backend.
    pub(super) fn serve_unicode_text() -> Option<OwnedFormatDataResponse> {
        let text = read_text()?;
        if text.is_empty() {
            return None;
        }
        let normalized = super::normalize_crlf(&text);
        Some(FormatDataResponse::new_unicode_string(&normalized).into_owned())
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
                FileContentsResponse::new_error(request.stream_id),
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
