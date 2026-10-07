import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/state/providers.dart';
import '../db/database.dart';
import '../sync/sync_controller.dart';
import 'app_version.dart';
import 'update_service.dart';

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  error,
}

class UpdateState {
  final UpdatePhase phase;
  final ReleaseInfo? release;
  final double? progress;
  final String? downloadedPath;
  final String? error;

  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.release,
    this.progress,
    this.downloadedPath,
    this.error,
  });

  bool get hasUpdate =>
      phase == UpdatePhase.available ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.ready;

  UpdateState copyWith({
    UpdatePhase? phase,
    ReleaseInfo? release,
    double? progress,
    String? downloadedPath,
    String? error,
    bool clearError = false,
    bool clearDownloaded = false,
  }) {
    return UpdateState(
      phase: phase ?? this.phase,
      release: release ?? this.release,
      progress: progress ?? this.progress,
      downloadedPath: clearDownloaded
          ? null
          : (downloadedPath ?? this.downloadedPath),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Checks the Connexia server for new releases and, on desktop, downloads the
/// installer for the running platform. Mobile never installs in-app; the UI
/// sends those users to the website instead.
class UpdateController extends Notifier<UpdateState> {
  static const _skippedKey = 'updateSkippedVersion';
  static const _lastCheckKey = 'updateLastCheckAt';

  final UpdateService _service = UpdateService();

  AppDatabase get _db => ref.read(appDatabaseProvider);

  @override
  UpdateState build() => const UpdateState();

  /// The running platform key used to pick a release asset.
  static String get platformName {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return '';
  }

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Fetches the latest release. When [silent] (the automatic startup check),
  /// failures and versions the user chose to skip are swallowed so we never
  /// interrupt them on launch.
  Future<UpdateState> check({bool silent = false}) async {
    if (state.phase == UpdatePhase.checking ||
        state.phase == UpdatePhase.downloading) {
      return state;
    }
    state = state.copyWith(phase: UpdatePhase.checking, clearError: true);
    try {
      final release = await _fetchLatest();
      await _db.setSetting(_lastCheckKey, DateTime.now().toIso8601String());

      if (!AppVersion.isNewer(release.version, AppVersion.name)) {
        state = UpdateState(phase: UpdatePhase.upToDate, release: release);
        return state;
      }

      if (silent && await _db.getSetting(_skippedKey) == release.version) {
        state = UpdateState(phase: UpdatePhase.upToDate, release: release);
        return state;
      }

      state = UpdateState(phase: UpdatePhase.available, release: release);
      return state;
    } catch (e) {
      if (silent) {
        state = const UpdateState();
        return state;
      }
      state = UpdateState(phase: UpdatePhase.error, error: _friendly(e));
      return state;
    }
  }

  Future<ReleaseInfo> _fetchLatest() async {
    final configured = ref.read(syncControllerProvider).serverUrl;
    final endpoints = _service.versionEndpoints(
      configuredServer: configured,
      fallbackServer: defaultSyncServerUrl,
    );
    Object? lastError;
    for (final endpoint in endpoints) {
      try {
        return await _service.fetchLatest(endpoint);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const UpdateException('No update server reachable');
  }

  /// Downloads the asset for this platform and leaves it ready to install.
  Future<void> download() async {
    final release = state.release;
    if (release == null) return;
    final asset = release.assetFor(platformName);
    if (asset == null) {
      state = state.copyWith(
        phase: UpdatePhase.error,
        error: 'No download is available for this platform yet.',
      );
      return;
    }
    state = state.copyWith(
      phase: UpdatePhase.downloading,
      progress: 0,
      clearError: true,
    );
    try {
      final file = await _service.download(
        asset,
        onProgress: (progress) => state = state.copyWith(progress: progress),
      );
      state = state.copyWith(
        phase: UpdatePhase.ready,
        downloadedPath: file.path,
        progress: 1,
      );
    } catch (e) {
      state = state.copyWith(phase: UpdatePhase.error, error: _friendly(e));
    }
  }

  /// Opens the downloaded installer/file in the OS. Windows callers should
  /// quit the app afterwards so the installer can replace the running exe.
  Future<void> openDownloaded() async {
    final path = state.downloadedPath;
    if (path == null) return;
    try {
      await _service.openDownloadedFile(path);
    } catch (e) {
      state = state.copyWith(error: _friendly(e));
    }
  }

  /// Remembers a version the user does not want to be prompted about again.
  Future<void> skipVersion() async {
    final version = state.release?.version;
    if (version != null) await _db.setSetting(_skippedKey, version);
    state = const UpdateState();
  }

  /// Clears a transient error so the card falls back to its idle state.
  void dismissError() {
    if (state.phase == UpdatePhase.error) {
      state = const UpdateState();
    }
  }

  String _friendly(Object e) {
    if (e is UpdateException) return e.message;
    if (e is TimeoutException) return 'Connection timed out.';
    if (e.toString().contains('SocketException')) {
      return 'Cannot reach the update server.';
    }
    return e.toString();
  }
}

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
