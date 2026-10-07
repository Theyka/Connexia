import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class UpdateException implements Exception {
  final String message;

  const UpdateException(this.message);

  @override
  String toString() => message;
}

/// The latest release as reported by the Connexia server's `/api/version`.
class ReleaseInfo {
  final String version;
  final String tag;
  final String url;
  final String notes;

  /// Download URLs keyed by platform (`windows`, `macos`, `linux`, `android`).
  final Map<String, String> assets;

  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.url,
    required this.notes,
    required this.assets,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    final rawAssets = json['assets'];
    final assets = <String, String>{};
    if (rawAssets is Map) {
      rawAssets.forEach((key, value) {
        if (key is String && value is String && value.isNotEmpty) {
          assets[key] = value;
        }
      });
    }
    return ReleaseInfo(
      version: (json['version'] as String? ?? '').trim(),
      tag: json['tag'] as String? ?? '',
      url: json['url'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      assets: assets,
    );
  }

  String? assetFor(String platform) => assets[platform];
}

/// Talks to the Connexia server for release metadata and downloads.
class UpdateService {
  final http.Client _client;

  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  /// Candidate `/api/version` URLs, preferring the user's configured sync
  /// server but always falling back to the official one.
  List<String> versionEndpoints({
    required String configuredServer,
    required String fallbackServer,
  }) {
    final urls = <String>[];
    void add(String base) {
      final normalized = base.trim().replaceAll(RegExp(r'/+$'), '');
      if (normalized.isEmpty) return;
      final url = '$normalized/api/version';
      if (!urls.contains(url)) urls.add(url);
    }

    add(configuredServer);
    add(fallbackServer);
    return urls;
  }

  /// Fetches release metadata from a full `/api/version` endpoint (as returned
  /// by [versionEndpoints]).
  Future<ReleaseInfo> fetchLatest(String endpoint) async {
    final res = await _client
        .get(Uri.parse(endpoint), headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw UpdateException('Update server returned ${res.statusCode}');
    }
    final body = jsonDecode(res.body);
    if (body is! Map<String, dynamic>) {
      throw const UpdateException('Unexpected update response');
    }
    final release = ReleaseInfo.fromJson(body);
    if (release.version.isEmpty) {
      throw const UpdateException('Update server did not report a version');
    }
    return release;
  }

  /// Downloads [url] into the downloads (or temp) directory, reporting progress
  /// as a 0..1 fraction when the server sends a Content-Length.
  Future<File> download(
    String url, {
    String? fileName,
    void Function(double progress)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw UpdateException('Download failed (HTTP ${response.statusCode})');
    }

    final name = (fileName == null || fileName.isEmpty)
        ? _fileNameFromUrl(url)
        : fileName;
    final dir = await _downloadDir();
    final file = File(p.join(dir.path, name));
    if (await file.exists()) await file.delete();

    final sink = file.openWrite();
    final total = response.contentLength;
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          onProgress?.call((received / total).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    onProgress?.call(1);
    return file;
  }

  Future<Directory> _downloadDir() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return getTemporaryDirectory();
    }
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {}
    return getTemporaryDirectory();
  }

  static String _fileNameFromUrl(String url) {
    final segments = Uri.parse(
      url,
    ).pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? 'connexia-update' : segments.last;
  }

  /// Hands the downloaded file to the operating system. Desktop only — mobile
  /// is sent to the website instead of installing in-app.
  Future<void> openDownloadedFile(String path) async {
    if (Platform.isWindows) {
      await Process.start(path, const [], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [p.dirname(path)]);
    }
  }
}
