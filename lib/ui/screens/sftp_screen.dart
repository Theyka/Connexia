import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/db/database.dart';
import '../../core/ssh/host_key_store.dart';
import '../state/connection_helpers.dart';
import '../../core/sync/team_providers.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';

/// Two-pane SFTP file manager section: local files are always shown on the
/// left, the right pane shows the remote files once a host is connected, or
/// a host picker (groups and hosts with a search bar) when idle.
class SftpScreen extends ConsumerStatefulWidget {
  const SftpScreen({super.key});

  @override
  ConsumerState<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends ConsumerState<SftpScreen> {
  final _hostSearchController = TextEditingController();

  SSHClient? _client;
  SftpClient? _sftp;
  Host? _connectedHost;
  bool _connecting = false;
  String? _connectError;
  bool _showPicker = false;
  String? _pickerGroupId;
  String _remotePath = '.';
  List<SftpName> _remoteItems = [];
  bool _remoteLoading = false;
  String? _remoteError;

  String _localPath = '';
  List<FileSystemEntity> _localItems = [];
  bool _localLoading = false;
  String? _localError;

  // Left pane can act as a second remote host for host-to-host transfers.
  bool _leftIsRemote = false;
  bool _leftShowPicker = false;
  String? _leftPickerGroupId;
  SSHClient? _leftClient;
  SftpClient? _leftSftp;
  Host? _leftHost;
  bool _leftConnecting = false;
  String? _leftConnectError;
  String _leftRemotePath = '.';
  List<SftpName> _leftRemoteItems = [];
  bool _leftRemoteLoading = false;
  String? _leftRemoteError;

  final List<_TransferTask> _transfers = [];

  bool _osDragLocal = false;
  bool _osDragRemote = false;

  final _leftHostSearchController = TextEditingController();

  String get _displayRemotePath => _remotePath == '.' ? '/' : _remotePath;

  String get _displayLeftRemotePath =>
      _leftRemotePath == '.' ? '/' : _leftRemotePath;

  @override
  void initState() {
    super.initState();
    _localPath = _defaultLocalPath();
    _listLocal();
  }

  /// A sensible starting directory for the local pane, depending on the
  /// platform. Windows has no HOME-style variable in the same way and
  /// Android has no `C:\` drive at all.
  String _defaultLocalPath() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? r'C:\';
    }
    if (Platform.isAndroid) {
      return '/storage/emulated/0';
    }
    return Platform.environment['HOME'] ?? '/';
  }

  @override
  void dispose() {
    _hostSearchController.dispose();
    _leftHostSearchController.dispose();
    _client?.close();
    _leftClient?.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------

  Future<void> _connectTo(Host host, {bool left = false}) async {
    final db = ref.read(appDatabaseProvider);
    await db.updateHostLastConnected(host.id, DateTime.now());

    setState(() {
      if (left) {
        _leftConnecting = true;
        _leftConnectError = null;
        _leftHost = host;
        _leftShowPicker = false;
      } else {
        _connecting = true;
        _connectError = null;
        _connectedHost = host;
      }
    });

    try {
      var resolved = await resolveCredentials(ref, host);
      String? username = resolved?.username;
      String? password = resolved?.password;
      String? keyId = resolved?.keyId;

      if (username == null || username.isEmpty) {
        if (!mounted) return;
        final result = await promptCredentials(context, ref, host);
        if (result == null) {
          if (mounted) {
            setState(() {
              if (left) {
                _leftConnecting = false;
                _leftHost = null;
              } else {
                _connecting = false;
              }
            });
          }
          return;
        }
        username = result.username;
        password = result.password;
      }

      final keyMaterial = await resolveKeyMaterial(ref, keyId);
      final store = ref.read(hostKeyStoreProvider);
      final ssh = ref.read(sshServiceProvider);

      final client = await ssh.connectClient(
        host: host.address,
        port: host.port,
        username: username,
        password: password,
        privateKeys: keyMaterial.$1,
        passphrase: keyMaterial.$2,
        onVerifyHostKey: (type, fingerprint) =>
            _verifyHostKey(store, host, type, fingerprint),
      );
      if (!mounted) return;

      unawaited(
        ref
            .read(sessionManagerProvider)
            .detectOs(client, host.address, host.port),
      );

      final sftp = await client.sftp();
      if (!mounted) {
        client.close();
        return;
      }
      setState(() {
        if (left) {
          _leftClient = client;
          _leftSftp = sftp;
          _leftConnecting = false;
          _leftIsRemote = true;
          _leftRemotePath = '.';
          _leftRemoteItems = [];
          _leftRemoteError = null;
        } else {
          _client = client;
          _sftp = sftp;
          _connecting = false;
          _remotePath = '.';
          _remoteItems = [];
          _remoteError = null;
        }
      });
      if (left) {
        await _listLeftRemote();
      } else {
        await _listRemote();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (left) {
          _leftConnecting = false;
          _leftConnectError = _friendlyError(e);
        } else {
          _connecting = false;
          _connectError = _friendlyError(e);
        }
      });
    }
  }

  Future<bool> _verifyHostKey(
    HostKeyStore store,
    Host host,
    String type,
    String fingerprint,
  ) async {
    try {
      final trusted = await store.isTrusted(
        address: host.address,
        port: host.port,
        keyType: type,
        fingerprint: fingerprint,
      );
      if (trusted) return true;
    } on HostKeyMismatchError catch (e) {
      if (mounted) _showError(e.toString());
      return false;
    }
    final autoAccept =
        ref.read(settingsControllerProvider).settings.autoAcceptHostKeys;
    if (autoAccept) {
      await store.trust(
        address: host.address,
        port: host.port,
        keyType: type,
        fingerprint: fingerprint,
      );
      return true;
    }
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify host key'),
        content: Text(
          'The authenticity of "${host.address}" cannot be established.\n\n'
          '$type key fingerprint is:\n$fingerprint\n\n'
          'Connect anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await store.trust(
        address: host.address,
        port: host.port,
        keyType: type,
        fingerprint: fingerprint,
      );
    }
    return accepted == true;
  }

  void _disconnect() {
    _sftp = null;
    _client?.close();
    _client = null;
    setState(() {
      _connectedHost = null;
      _connecting = false;
      _connectError = null;
      _remotePath = '.';
      _remoteItems = [];
      _remoteError = null;
      for (final task in List.of(_transfers)) {
        task.canceled = true;
        task.cancel?.call();
      }
      _transfers.clear();
      for (final t in _errorTimers.values) {
        t.cancel();
      }
      _errorTimers.clear();
      _errors.clear();
    });
  }

  String _friendlyError(Object e) {
    if (e is SSHAuthFailError) {
      return 'Authentication failed. Check the username, password or key.';
    }
    if (e is SSHHandshakeError) {
      return 'SSH handshake failed: ${e.message}';
    }
    if (e is SSHHostkeyError) {
      return 'Host key verification failed.';
    }
    if (e is SSHSocketError) {
      return 'Connection error: ${e.error}';
    }
    if (e is SocketException) {
      return 'Cannot reach ${e.address?.host ?? 'host'}: '
          '${e.osError?.message ?? e.message}';
    }
    if (e is TimeoutException) {
      return 'Connection timed out.';
    }
    return 'Connection failed: $e';
  }

  @override
  Widget build(BuildContext context) {
    final Widget rightPane;
    if (_connectedHost == null) {
      rightPane = _idlePane();
    } else if (_connecting) {
      rightPane = _connectingView(_connectedHost!.name);
    } else if (_connectError != null) {
      rightPane = _connectErrorView(_connectError!);
    } else {
      rightPane = _remotePane();
    }

    return Column(
      children: [
        Expanded(
          child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _leftPane()),
                  Container(width: 1, color: AppColors.border),
                  Expanded(child: rightPane),
                ],
          ),
        ),
        _transfersBar(),
        _errorOverlay(),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Local pane
  // ---------------------------------------------------------------------

  void _sortLocalItems(List<FileSystemEntity> items) {
    items.sort((a, b) {
      final aDir = a is Directory;
      final bDir = b is Directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
  }

  void _sortRemoteItems(List<SftpName> items) {
    items.sort((a, b) {
      final aDir = a.attr.isDirectory;
      final bDir = b.attr.isDirectory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    });
  }

  Future<void> _listLocal() async {
    setState(() {
      _localLoading = true;
      _localError = null;
    });
    try {
      final entries = await Directory(_localPath).list().toList();
      _sortLocalItems(entries);
      if (!mounted) return;
      setState(() {
        _localItems = entries;
        _localLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _localLoading = false;
        _localError = 'Failed to list: $e';
      });
    }
  }

  void _enterLocalDir(Directory dir) {
    setState(() {
      _localPath = dir.path;
      _localItems = [];
    });
    _listLocal();
  }

  void _goUpLocal() {
    final parent = p.dirname(_localPath);
    if (parent != _localPath) {
      setState(() {
        _localPath = parent;
        _localItems = [];
      });
      _listLocal();
    }
  }

  void _refreshLocal() {
    setState(() => _localItems = []);
    _listLocal();
  }

  Future<void> _newFolderLocal() async {
    final name = await _promptText('New folder', 'Folder name');
    if (name == null || name.isEmpty) return;
    try {
      await Directory(p.join(_localPath, name)).create();
      setState(() {
        _localItems.add(Directory(p.join(_localPath, name)));
        _sortLocalItems(_localItems);
      });
    } catch (e) {
      _showError('Failed to create folder: $e');
    }
  }

  Future<void> _renameLocal(FileSystemEntity entity) async {
    final current = p.basename(entity.path);
    final name = await _promptText('Rename', 'New name', initial: current);
    if (name == null || name.isEmpty || name == current) return;
    try {
      await entity.rename(p.join(_localPath, name));
      final replaced = entity is Directory
          ? Directory(p.join(_localPath, name)) as FileSystemEntity
          : File(p.join(_localPath, name));
      setState(() {
        final idx = _localItems.indexWhere((e) => e.path == entity.path);
        if (idx >= 0) {
          _localItems[idx] = replaced;
          _sortLocalItems(_localItems);
        }
      });
    } catch (e) {
      _showError('Rename failed: $e');
    }
  }

  Future<void> _deleteLocal(FileSystemEntity entity) async {
    final isDir = entity is Directory;
    final name = p.basename(entity.path);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete?'),
        content: Text(
          isDir
              ? 'Delete directory "$name"? This cannot be undone.'
              : 'Delete file "$name"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (isDir) {
        await entity.delete(recursive: true);
      } else {
        await entity.delete();
      }
      setState(() {
        _localItems.removeWhere((e) => e.path == entity.path);
      });
    } catch (e) {
      _showError('Delete failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Remote pane
  // ---------------------------------------------------------------------

  Future<void> _listRemote() async {
    final sftp = _sftp;
    if (sftp == null) return;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
    });
    try {
      final names =
          await sftp.listdir(_remotePath == '.' ? '/' : '/$_remotePath');
      final items = names
          .where((n) => n.filename != '.' && n.filename != '..')
          .toList();
      _sortRemoteItems(items);
      if (!mounted) return;
      setState(() {
        _remoteItems = items;
        _remoteLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _remoteLoading = false;
        _remoteError = 'Failed to list: $e';
      });
    }
  }

  void _enterRemoteDir(SftpName dir) {
    final next = _remotePath == '.' ? dir.filename : '$_remotePath/${dir.filename}';
    setState(() {
      _remotePath = next;
      _remoteItems = [];
    });
    _listRemote();
  }

  void _goUpRemote() {
    final parent = p.posix.dirname(_remotePath == '.' ? '/' : _remotePath);
    setState(() {
      _remotePath = parent == '/' ? '.' : parent;
      _remoteItems = [];
    });
    _listRemote();
  }

  void _refreshRemote() {
    setState(() => _remoteItems = []);
    _listRemote();
  }

  String _remoteTarget(String name) =>
      _remotePath == '.' ? '/$name' : '/$_remotePath/$name';

  // ---------------------------------------------------------------------
  // Transfers
  // ---------------------------------------------------------------------

  Future<void> _upload(FileSystemEntity entity) async {
    final sftp = _sftp;
    if (sftp == null || entity is! File) return;
    final name = p.basename(entity.path);
    final task =
        _beginTransfer(name, 'Uploading...', total: _fileSize(entity) ?? 0);

    try {
      final remote = await sftp.open(
        _remoteTarget(name),
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      if (task.canceled) {
        await remote.close();
        return;
      }
      final uploader = remote.write(
        entity.openRead().cast(),
        onProgress: (bytes) => _updateTransfer(task, bytes),
      );
      task.cancel = () async {
        await uploader.abort();
        await remote.close();
      };
      await uploader.done;
      if (!remote.isClosed) await remote.close();
      if (task.canceled) return;
      await _listRemote();
    } catch (e) {
      if (!task.canceled) _showError('Upload "$name" failed: $e');
    } finally {
      _endTransfer(task);
    }
  }

  Future<void> _download(SftpName item) async {
    final sftp = _sftp;
    if (sftp == null) return;
    final name = item.filename;
    final destPath = p.join(_localPath, name);
    final task = _beginTransfer(
      name,
      'Downloading...',
      total: item.attr.size ?? 0,
    );

    try {
      final remote = await sftp.open(
        _remoteTarget(name),
        mode: SftpFileOpenMode.read,
      );
      if (task.canceled) {
        await remote.close();
        return;
      }
      final sink = File(destPath).openWrite();
      final completer = Completer<void>();
      final sub = remote
          .read(onProgress: (bytes) => _updateTransfer(task, bytes))
          .listen(
            sink.add,
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (e) {
              if (!completer.isCompleted) completer.completeError(e);
            },
            cancelOnError: true,
          );
      task.cancel = () async {
        await sub.cancel();
        await sink.close();
        if (!remote.isClosed) await remote.close();
        try {
          if (await File(destPath).exists()) {
            await File(destPath).delete();
          }
        } catch (_) {}
        if (!completer.isCompleted) completer.complete();
      };
      await completer.future;
      if (task.canceled) return;
      await sink.close();
      await remote.close();
      await _listLocal();
    } catch (e) {
      if (!task.canceled) _showError('Download "$name" failed: $e');
    } finally {
      _endTransfer(task);
    }
  }

  // ---------------------------------------------------------------------
  // Remote file operations
  // ---------------------------------------------------------------------

  Future<void> _newFolder() async {
    final sftp = _sftp;
    if (sftp == null) return;
    final name = await _promptText('New folder', 'Folder name');
    if (name == null || name.isEmpty) return;
    try {
      await sftp.mkdir(_remoteTarget(name));
      setState(() {
        _remoteItems.add(SftpName(
          filename: name,
          longname: name,
          attr: SftpFileAttrs(
            mode: SftpFileMode.value(16877),
            size: 0,
          ),
        ));
        _sortRemoteItems(_remoteItems);
      });
    } catch (e) {
      _showError('Failed to create folder: $e');
    }
  }

  Future<void> _rename(SftpName item) async {
    final sftp = _sftp;
    if (sftp == null) return;
    final name = await _promptText('Rename', 'New name', initial: item.filename);
    if (name == null || name.isEmpty || name == item.filename) return;
    try {
      await sftp.rename(_remoteTarget(item.filename), _remoteTarget(name));
      setState(() {
        final idx = _remoteItems.indexWhere((i) => i.filename == item.filename);
        if (idx >= 0) {
          _remoteItems[idx] = SftpName(
            filename: name,
            longname: item.longname,
            attr: item.attr,
          );
          _sortRemoteItems(_remoteItems);
        }
      });
    } catch (e) {
      _showError('Rename failed: $e');
    }
  }

  Future<void> _chmod(SftpName item) async {
    final sftp = _sftp;
    if (sftp == null) return;
    final mode = item.attr.mode;
    final current = mode != null ? mode.value.toRadixString(8) : '644';
    final controller = TextEditingController(text: current);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Permissions for "${item.filename}"'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Mode (octal, e.g. 644 or 755)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (result == null) return;

    final value = int.tryParse(result.trim(), radix: 8);
    if (value == null) {
      _showError('Invalid octal mode');
      return;
    }
    try {
      await sftp.setStat(
        _remoteTarget(item.filename),
        SftpFileAttrs(mode: SftpFileMode.value(value)),
      );
      await _listRemote();
    } catch (e) {
      _showError('chmod failed: $e');
    }
  }

  Future<void> _delete(SftpName item) async {
    final sftp = _sftp;
    if (sftp == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete?'),
        content: Text(
          item.attr.isDirectory
              ? 'Delete directory "${item.filename}"?'
              : 'Delete file "${item.filename}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final target = _remoteTarget(item.filename);
      if (item.attr.isDirectory) {
        await sftp.rmdir(target);
      } else {
        await sftp.remove(target);
      }
      setState(() {
        _remoteItems.removeWhere((i) => i.filename == item.filename);
      });
    } catch (e) {
      _showError('Delete failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Left pane remote (second host)
  // ---------------------------------------------------------------------

  void _disconnectLeft() {
    _leftSftp = null;
    _leftClient?.close();
    _leftClient = null;
    setState(() {
      _leftIsRemote = false;
      _leftHost = null;
      _leftConnecting = false;
      _leftConnectError = null;
      _leftRemotePath = '.';
      _leftRemoteItems = [];
      _leftRemoteError = null;
      _leftShowPicker = false;
    });
  }

  Future<void> _listLeftRemote() async {
    final sftp = _leftSftp;
    if (sftp == null) return;
    setState(() {
      _leftRemoteLoading = true;
      _leftRemoteError = null;
    });
    try {
      final names =
          await sftp.listdir(_leftRemotePath == '.' ? '/' : '/$_leftRemotePath');
      final items = names
          .where((n) => n.filename != '.' && n.filename != '..')
          .toList();
      _sortRemoteItems(items);
      if (!mounted) return;
      setState(() {
        _leftRemoteItems = items;
        _leftRemoteLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _leftRemoteLoading = false;
        _leftRemoteError = 'Failed to list: $e';
      });
    }
  }

  void _enterLeftRemoteDir(SftpName dir) {
    final next = _leftRemotePath == '.'
        ? dir.filename
        : '$_leftRemotePath/${dir.filename}';
    setState(() {
      _leftRemotePath = next;
      _leftRemoteItems = [];
    });
    _listLeftRemote();
  }

  void _goUpLeftRemote() {
    final parent = p.posix.dirname(
      _leftRemotePath == '.' ? '/' : _leftRemotePath,
    );
    setState(() {
      _leftRemotePath = parent == '/' ? '.' : parent;
      _leftRemoteItems = [];
    });
    _listLeftRemote();
  }

  void _refreshLeftRemote() {
    setState(() => _leftRemoteItems = []);
    _listLeftRemote();
  }

  // ---------------------------------------------------------------------
  // Path navigation (breadcrumbs + typed paths)
  // ---------------------------------------------------------------------

  void _navigateLocalTo(String input) {
    var path = input.trim();
    if (path.isEmpty) return;
    if (!p.isAbsolute(path)) {
      path = p.join(_localPath, path);
    }
    setState(() {
      _localPath = p.normalize(path);
      _localItems = [];
    });
    _listLocal();
  }

  void _navigateRemoteTo(String input) {
    var path = input.trim();
    if (path.isEmpty) return;
    path = p.posix.normalize(path);
    if (path.startsWith('/')) path = path.substring(1);
    setState(() {
      _remotePath = path.isEmpty ? '.' : path;
      _remoteItems = [];
    });
    _listRemote();
  }

  void _navigateLeftRemoteTo(String input) {
    var path = input.trim();
    if (path.isEmpty) return;
    path = p.posix.normalize(path);
    if (path.startsWith('/')) path = path.substring(1);
    setState(() {
      _leftRemotePath = path.isEmpty ? '.' : path;
      _leftRemoteItems = [];
    });
    _listLeftRemote();
  }

  List<String> _remoteCrumbs(String path) {
    final normalized = p.posix.normalize(path == '.' ? '/' : '/$path');
    final parts = normalized.split('/').where((s) => s.isNotEmpty).toList();
    return ['/', ...parts];
  }

  void _goToRemoteCrumb(int index) {
    final crumbs = _remoteCrumbs(_remotePath);
    final path = index == 0 ? '.' : crumbs.sublist(1, index + 1).join('/');
    setState(() {
      _remotePath = path;
      _remoteItems = [];
    });
    _listRemote();
  }

  void _goToLeftRemoteCrumb(int index) {
    final crumbs = _remoteCrumbs(_leftRemotePath);
    final path = index == 0 ? '.' : crumbs.sublist(1, index + 1).join('/');
    setState(() {
      _leftRemotePath = path;
      _leftRemoteItems = [];
    });
    _listLeftRemote();
  }

  List<String> _localCrumbs(String path) {
    final normalized = p.normalize(path);
    final prefix = p.rootPrefix(normalized);
    final rest = p.split(p.relative(normalized, from: prefix));
    return [prefix.replaceAll('\\', '/'), ...rest];
  }

  void _goToLocalCrumb(int index) {
    final crumbs = _localCrumbs(_localPath);
    final String target;
    if (index == 0) {
      target = p.rootPrefix(p.normalize(_localPath));
    } else {
      target = p.joinAll(
        [p.rootPrefix(p.normalize(_localPath)), ...crumbs.sublist(1, index + 1)],
      );
    }
    setState(() {
      _localPath = target;
      _localItems = [];
    });
    _listLocal();
  }

  String _leftRemoteTarget(String name) =>
      _leftRemotePath == '.' ? '/$name' : '/$_leftRemotePath/$name';

  Future<void> _newFolderLeft() async {
    final sftp = _leftSftp;
    if (sftp == null) return;
    final name = await _promptText('New folder', 'Folder name');
    if (name == null || name.isEmpty) return;
    try {
      await sftp.mkdir(_leftRemoteTarget(name));
      setState(() {
        _leftRemoteItems.add(SftpName(
          filename: name,
          longname: name,
          attr: SftpFileAttrs(
            mode: SftpFileMode.value(16877),
            size: 0,
          ),
        ));
        _sortRemoteItems(_leftRemoteItems);
      });
    } catch (e) {
      _showError('Failed to create folder: $e');
    }
  }

  Future<void> _renameLeft(SftpName item) async {
    final sftp = _leftSftp;
    if (sftp == null) return;
    final name = await _promptText('Rename', 'New name', initial: item.filename);
    if (name == null || name.isEmpty || name == item.filename) return;
    try {
      await sftp.rename(
        _leftRemoteTarget(item.filename),
        _leftRemoteTarget(name),
      );
      setState(() {
        final idx = _leftRemoteItems
            .indexWhere((i) => i.filename == item.filename);
        if (idx >= 0) {
          _leftRemoteItems[idx] = SftpName(
            filename: name,
            longname: item.longname,
            attr: item.attr,
          );
          _sortRemoteItems(_leftRemoteItems);
        }
      });
    } catch (e) {
      _showError('Rename failed: $e');
    }
  }

  Future<void> _chmodLeft(SftpName item) async {
    final sftp = _leftSftp;
    if (sftp == null) return;
    final mode = item.attr.mode;
    final current = mode != null ? mode.value.toRadixString(8) : '644';
    final controller = TextEditingController(text: current);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Permissions for "${item.filename}"'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Mode (octal, e.g. 644 or 755)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (result == null) return;

    final value = int.tryParse(result.trim(), radix: 8);
    if (value == null) {
      _showError('Invalid octal mode');
      return;
    }
    try {
      await sftp.setStat(
        _leftRemoteTarget(item.filename),
        SftpFileAttrs(mode: SftpFileMode.value(value)),
      );
    } catch (e) {
      _showError('chmod failed: $e');
    }
  }

  Future<void> _deleteLeft(SftpName item) async {
    final sftp = _leftSftp;
    if (sftp == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete?'),
        content: Text(
          item.attr.isDirectory
              ? 'Delete directory "${item.filename}"?'
              : 'Delete file "${item.filename}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final target = _leftRemoteTarget(item.filename);
      if (item.attr.isDirectory) {
        await sftp.rmdir(target);
      } else {
        await sftp.remove(target);
      }
      setState(() {
        _leftRemoteItems.removeWhere((i) => i.filename == item.filename);
      });
    } catch (e) {
      _showError('Delete failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Drag & drop transfers
  // ---------------------------------------------------------------------

  Future<void> _uploadPath(String path) => _upload(File(path));

  void _onLeftPaneDrop(_RemoteDragData data) {
    if (_leftIsRemote) {
      _copyRightToLeftRemote(data.name);
    } else {
      _downloadName(data.name);
    }
  }

  void _onRightPaneDrop(_LeftDragData data) {
    if (data.isLocal) {
      _uploadPath(data.path!);
    } else {
      _copyLeftRemoteToRight(data.name);
    }
  }

  void _transferRightItemOut(String name) {
    if (_leftIsRemote) {
      _copyRightToLeftRemote(name);
    } else {
      _downloadName(name);
    }
  }

  Future<void> _downloadName(String name) async {
    final sftp = _sftp;
    if (sftp == null) return;
    final item = _remoteItems.where((i) => i.filename == name).firstOrNull;
    if (item == null) return;
    await _download(item);
  }

  Future<void> _uploadDropped(List<DropItem> files) async {
    for (final file in files) {
      final source = File(file.path);
      try {
        if (!await source.exists()) continue;
        if (await FileSystemEntity.type(file.path) ==
            FileSystemEntityType.directory) {
          continue;
        }
        await _uploadPath(file.path);
      } catch (e) {
        _showError('Upload "${file.path}" failed: $e');
      }
    }
    await _listRemote();
  }

  // ---------------------------------------------------------------------
  // Host-to-host transfers
  // ---------------------------------------------------------------------

  Future<void> _copyLeftRemoteToRight(String name) async {
    final src = _leftSftp;
    final dst = _sftp;
    if (src == null || dst == null) return;
    await _copyBetween(
      src,
      _leftRemoteTarget(name),
      dst,
      _remoteTarget(name),
      name,
    );
  }

  Future<void> _copyRightToLeftRemote(String name) async {
    final src = _sftp;
    final dst = _leftSftp;
    if (src == null || dst == null) return;
    await _copyBetween(
      src,
      _remoteTarget(name),
      dst,
      _leftRemoteTarget(name),
      name,
    );
  }

  Future<void> _copyBetween(
    SftpClient src,
    String srcPath,
    SftpClient dst,
    String dstPath,
    String name,
  ) async {
    final task = _beginTransfer(name, 'Host to host...');
    SftpFile? srcFile;
    SftpFile? dstFile;
    try {
      srcFile = await src.open(srcPath, mode: SftpFileOpenMode.read);
      final attrs = await srcFile.stat();
      final size = attrs.size;
      if (size != null) task.total = size;
      if (task.canceled) return;
      dstFile = await dst.open(
        dstPath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      task.cancel = () async {
        await dstFile?.close();
        await srcFile?.close();
      };
      var writeOffset = 0;
      await for (final chunk
          in srcFile.read(
        onProgress: (bytes) => _updateTransfer(task, bytes),
        chunkSize: 64 * 1024,
        maxPendingRequests: 128,
      )) {
        if (task.canceled) break;
        await dstFile.writeBytes(chunk, offset: writeOffset);
        writeOffset += chunk.length;
      }
      if (task.canceled) return;
      await _listRemote();
      await _listLeftRemote();
    } catch (e) {
      if (!task.canceled) _showError('Transfer "$name" failed: $e');
    } finally {
      _endTransfer(task);
      try {
        await dstFile?.close();
      } catch (_) {}
      try {
        await srcFile?.close();
      } catch (_) {}
    }
  }

  Future<void> _importLocalFiles(List<DropItem> files) async {
    for (final file in files) {
      final path = file.path;
      try {
        final source = File(path);
        if (!await source.exists()) continue;
        await source.copy(p.join(_localPath, p.basename(path)));
      } catch (e) {
        _showError('Import "$path" failed: $e');
      }
    }
    await _listLocal();
  }

  Widget _dragWrap(bool highlighted, {required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        border: highlighted
            ? Border.all(color: AppColors.accent, width: 1.5)
            : null,
      ),
      child: child,
    );
  }

  Widget _dragFeedback(IconData icon, String name, String hint) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.accentBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0x44000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: AppColors.accent),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              hint,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Idle pane: intro prompt + host/group picker with search
  // ---------------------------------------------------------------------

  Widget _idlePane() {
    return _showPicker
        ? _hostPicker(
            searchController: _hostSearchController,
            groupId: _pickerGroupId,
            onGroupIdChanged: (id) => setState(() => _pickerGroupId = id),
            onConnect: (host) => _connectTo(host),
          )
        : _introPane();
  }

  Widget _introPane() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.accentBorder),
            ),
            child: Icon(
              Icons.cloud_off_outlined,
              size: 30,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Connect to host',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            'Pick a saved host to browse its files, move them between '
            'hosts, and sync with your local machine.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => setState(() => _showPicker = true),
            icon: const Icon(Icons.dns_outlined, size: 16),
            label: const Text('Select host'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hostPicker({
    required TextEditingController searchController,
    required String? groupId,
    required void Function(String?) onGroupIdChanged,
    required ValueChanged<Host> onConnect,
  }) {
    final hosts = ref.watch(scopedHostsProvider).valueOrNull ?? const <Host>[];
    final groups = ref.watch(scopedGroupsProvider).valueOrNull ?? const <Group>[];
    final query = searchController.text.trim().toLowerCase();
    final searching = query.isNotEmpty;

    bool matches(Host h) =>
        h.name.toLowerCase().contains(query) ||
        h.address.toLowerCase().contains(query);

    final inGroup = groupId != null && !searching;
    final group =
        inGroup ? groups.where((g) => g.id == groupId).firstOrNull : null;

    final List<Group> visibleGroups;
    final List<Host> visibleHosts;
    if (group != null) {
      visibleGroups = const [];
      visibleHosts = hosts.where((h) => h.groupId == group.id).toList();
    } else {
      visibleGroups = groups
          .where((g) =>
              g.name.toLowerCase().contains(query) ||
              hosts.any((h) => h.groupId == g.id && matches(h)))
          .toList();
      visibleHosts = hosts.where(matches).toList();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            controller: searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search hosts and groups...',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        searchController.clear();
                        setState(() {});
                      },
                    ),
            ),
          ),
        ),
        Expanded(
          child: hosts.isEmpty && groups.isEmpty
              ? const Center(child: Text('No saved hosts yet'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  children: [
                    if (group != null) _backRow(group.name, onBack: () => onGroupIdChanged(null)),
                    if (visibleGroups.isNotEmpty) ...[
                      const _PickerSectionLabel('GROUPS'),
                      _pickerGrid(
                        itemCount: visibleGroups.length,
                        itemBuilder: (context, index) => _SftpGroupCard(
                          group: visibleGroups[index],
                          hostCount: hosts
                              .where((h) =>
                                  h.groupId == visibleGroups[index].id)
                              .length,
                          onOpen: () => onGroupIdChanged(
                            visibleGroups[index].id,
                          ),
                        ),
                      ),
                    ],
                    if (visibleHosts.isNotEmpty) ...[
                      const _PickerSectionLabel('HOSTS'),
                      _pickerGrid(
                        itemCount: visibleHosts.length,
                        itemBuilder: (context, index) => _SftpHostCard(
                          host: visibleHosts[index],
                          onConnect: () => onConnect(visibleHosts[index]),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _pickerGrid({
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 300,
        mainAxisExtent: 60,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );
  }

  Widget _backRow(String groupName, {required VoidCallback onBack}) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to all groups',
            icon: const Icon(Icons.arrow_back, size: 17),
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              groupName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Views
  // ---------------------------------------------------------------------

  Widget _connectingView(String hostName) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 16),
          Text(
            'Connecting to $hostName...',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _connectErrorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: 16),
            Text(
              'Failed to connect to ${_connectedHost?.name ?? 'host'}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => setState(() {
                _connectedHost = null;
                _connectError = null;
                _showPicker = true;
                _pickerGroupId = null;
              }),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back to hosts'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _leftPane() {
    if (_leftShowPicker) return _leftPickerPane();
    if (_leftIsRemote && _leftConnecting) {
      return _connectingView(_leftHost?.name ?? '');
    }
    if (_leftIsRemote && _leftConnectError != null) {
      return _leftConnectErrorView();
    }
    if (_leftIsRemote) {
      return _pane(
        icon: Icons.dns_outlined,
        title: _leftHost?.name ?? 'Host',
        headerActions: [
          IconButton(
            tooltip: 'Back to local files',
            icon: const Icon(Icons.folder_outlined, size: 17),
            visualDensity: VisualDensity.compact,
            onPressed: _disconnectLeft,
          ),
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off, size: 17),
            visualDensity: VisualDensity.compact,
            onPressed: _disconnectLeft,
          ),
        ],
        pathBar: _pathBar(
          crumbs: _remoteCrumbs(_leftRemotePath),
          onCrumbTap: _goToLeftRemoteCrumb,
          onUp: _leftRemotePath == '.' ? null : _goUpLeftRemote,
          onRefresh: _refreshLeftRemote,
          onEditPath: () async {
            final input = await _promptText(
              'Go to path',
              'Path',
              initial: _displayLeftRemotePath,
            );
            if (input != null) _navigateLeftRemoteTo(input);
          },
          trailing: IconButton(
            tooltip: 'New folder',
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: _newFolderLeft,
          ),
        ),
        content: _wrapPaneMenu(
          _leftRemoteContent(),
          onNewFolder: _newFolderLeft,
          onRefresh: _refreshLeftRemote,
          editPath: () => _promptText(
            'Go to path',
            'Path',
            initial: _displayLeftRemotePath,
          ),
          onNavigate: _navigateLeftRemoteTo,
          isEmpty: _leftRemoteItems.isEmpty && _leftRemoteError == null,
        ),
      );
    }
    return _pane(
      icon: Icons.computer_outlined,
      title: 'Local',
      headerActions: [
        IconButton(
          tooltip: 'Browse remote host',
          icon: const Icon(Icons.dns_outlined, size: 17),
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() => _leftShowPicker = true),
        ),
      ],
        pathBar: _pathBar(
          crumbs: _localCrumbs(_localPath),
          onCrumbTap: _goToLocalCrumb,
          onUp: _goUpLocal,
          onRefresh: _refreshLocal,
          onEditPath: () async {
            final input = await _promptText(
              'Go to path',
              'Path',
              initial: _localPath,
            );
            if (input != null) _navigateLocalTo(input);
          },
          trailing: IconButton(
            tooltip: 'New folder',
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: _newFolderLocal,
          ),
        ),
        content: _wrapPaneMenu(
          _localContent(),
          onNewFolder: _newFolderLocal,
          onRefresh: _refreshLocal,
          editPath: () => _promptText('Go to path', 'Path', initial: _localPath),
          onNavigate: _navigateLocalTo,
          isEmpty: _localItems.isEmpty && _localError == null,
        ),
    );
  }

  Widget _leftPickerPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to local files',
                icon: const Icon(Icons.arrow_back, size: 17),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _leftShowPicker = false),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Select source host',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _hostPicker(
            searchController: _leftHostSearchController,
            groupId: _leftPickerGroupId,
            onGroupIdChanged: (id) => setState(() => _leftPickerGroupId = id),
            onConnect: (host) => _connectTo(host, left: true),
          ),
        ),
      ],
    );
  }

  Widget _leftConnectErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: 16),
            Text(
              'Failed to connect to ${_leftHost?.name ?? 'host'}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _leftConnectError!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => setState(() {
                _leftHost = null;
                _leftConnectError = null;
                _leftShowPicker = true;
                _leftPickerGroupId = null;
              }),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back to hosts'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _remotePane() {
    if (_sftp == null && _remoteError == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _pane(
      icon: Icons.dns_outlined,
      title: _connectedHost?.name ?? 'Host',
      headerActions: [
        IconButton(
          tooltip: 'Disconnect',
          icon: const Icon(Icons.link_off, size: 17),
          visualDensity: VisualDensity.compact,
          onPressed: _disconnect,
        ),
      ],
        pathBar: _pathBar(
          crumbs: _remoteCrumbs(_remotePath),
          onCrumbTap: _goToRemoteCrumb,
          onUp: _remotePath == '.' ? null : _goUpRemote,
          onRefresh: _refreshRemote,
          onEditPath: () async {
            final input = await _promptText(
              'Go to path',
              'Path',
              initial: _displayRemotePath,
            );
            if (input != null) _navigateRemoteTo(input);
          },
          trailing: IconButton(
            tooltip: 'New folder',
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: _newFolder,
          ),
        ),
        content: _wrapPaneMenu(
          _remoteContent(),
          onNewFolder: _newFolder,
          onRefresh: _refreshRemote,
          editPath: () => _promptText(
            'Go to path',
            'Path',
            initial: _displayRemotePath,
          ),
          onNavigate: _navigateRemoteTo,
          isEmpty: _remoteItems.isEmpty && _remoteError == null,
        ),
    );
  }

  Widget _pane({
    required IconData icon,
    required String title,
    List<Widget> headerActions = const [],
    required Widget pathBar,
    required Widget content,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              if (headerActions.isNotEmpty) ...[
                const Spacer(),
                ...headerActions,
              ],
            ],
          ),
        ),
        pathBar,
        const Divider(height: 1),
        Expanded(child: content),
      ],
    );
  }

  Widget _pathBar({
    required List<String> crumbs,
    required void Function(int index) onCrumbTap,
    required VoidCallback onRefresh,
    VoidCallback? onUp,
    Widget? trailing,
    required VoidCallback onEditPath,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Up',
            icon: const Icon(Icons.arrow_upward, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: onUp,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: onRefresh,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < crumbs.length; i++) ...[
                    if (i > 0)
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(
                          Icons.chevron_right,
                          size: 13,
                          color: AppColors.textFaint,
                        ),
                      ),
                    InkWell(
                      onTap: () => onCrumbTap(i),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 2,
                        ),
                        child: Text(
                          crumbs[i],
                          style: TextStyle(
                            fontSize: 12.5,
                            fontFamily: 'JetBrainsMono',
                            color: i == crumbs.length - 1
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                            fontWeight: i == crumbs.length - 1
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Go to path',
            icon: const Icon(Icons.edit_outlined, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: onEditPath,
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _localContent() {
    if (_localLoading && _localItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_localError != null) {
      return _paneError(_localError!);
    }
    return DragTarget<_RemoteDragData>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) => _onLeftPaneDrop(details.data),
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty;
        return _dragWrap(
          highlighted,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _osDragLocal = true),
            onDragExited: (_) => setState(() => _osDragLocal = false),
            onDragDone: (detail) {
              setState(() => _osDragLocal = false);
              _importLocalFiles(detail.files);
            },
            child: _dragWrap(
              highlighted || _osDragLocal,
              child: _localItems.isEmpty
                  ? const Center(child: Text('Empty folder'))
                  : ListView.builder(
                      itemCount: _localItems.length,
                      itemBuilder: (context, index) {
                        final entity = _localItems[index];
                        final isDir = entity is Directory;
                        final name = p.basename(entity.path);
                        final row = _fileRow(
                          name: name,
                          isDir: isDir,
                          subtitle: isDir
                              ? null
                              : _formatSize(
                                  entity is File ? _fileSize(entity) : null),
                          icon: isDir ? Icons.folder : _fileIcon(name),
                          onTap: isDir ? () => _enterLocalDir(entity) : null,
                          onContextMenu: (position) => _showRowContextMenu(
                            position,
                            [
                              if (!isDir)
                                const PopupMenuItem(
                                  value: 'transfer',
                                  child: Text('Transfer to host'),
                                ),
                              const PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                              const PopupMenuItem(
                                value: 'refresh',
                                child: Text('Refresh'),
                              ),
                            ],
                            (action) {
                              switch (action) {
                                case 'transfer':
                                  _upload(entity);
                                  break;
                                case 'rename':
                                  _renameLocal(entity);
                                  break;
                                case 'delete':
                                  _deleteLocal(entity);
                                  break;
                                case 'refresh':
                                  _refreshLocal();
                                  break;
                              }
                            },
                          ),
                          hoverActions: [
                            if (!isDir)
                              _paneAction(
                                tooltip: 'Upload to host',
                                icon: Icons.upload_outlined,
                                onTap: () => _upload(entity),
                              ),
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: PopupMenuButton<String>(
                                tooltip: 'More',
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.more_horiz, size: 16),
                                onSelected: (action) {
                                  switch (action) {
                                    case 'rename':
                                      _renameLocal(entity);
                                      break;
                                    case 'delete':
                                      _deleteLocal(entity);
                                      break;
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                        if (isDir) return row;
                        return Draggable<_LeftDragData>(
                          data: _LeftDragData(name, entity.path),
                          dragAnchorStrategy: pointerDragAnchorStrategy,
                          feedback: _dragFeedback(
                            _fileIcon(name),
                            name,
                            _leftIsRemote ? 'Transfer to host' : 'Upload to host',
                          ),
                          childWhenDragging: Opacity(opacity: 0.35, child: row),
                          child: row,
                        );
                      },
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _remoteContent() {
    if (_remoteError != null) {
      return _paneError(_remoteError!);
    }
    if (_remoteLoading && _remoteItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return DragTarget<_LeftDragData>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) => _onRightPaneDrop(details.data),
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty;
        return _dragWrap(
          highlighted,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _osDragRemote = true),
            onDragExited: (_) => setState(() => _osDragRemote = false),
            onDragDone: (detail) {
              setState(() => _osDragRemote = false);
              _uploadDropped(detail.files);
            },
            child: _dragWrap(
              highlighted || _osDragRemote,
              child: _remoteItems.isEmpty
                  ? const Center(child: Text('Empty directory'))
                  : ListView.builder(
                      itemCount: _remoteItems.length,
                      itemBuilder: (context, index) {
                        final item = _remoteItems[index];
                        final isDir = item.attr.isDirectory;
                        final row = _fileRow(
                          name: item.filename,
                          isDir: isDir,
                          subtitle: isDir ? null : _formatSize(item.attr.size),
                          icon: isDir ? Icons.folder : _fileIcon(item.filename),
                          onTap: isDir ? () => _enterRemoteDir(item) : null,
                          onContextMenu: (position) => _showRowContextMenu(
                            position,
                            [
                              if (!isDir)
                                PopupMenuItem(
                                  value: 'transfer',
                                  child: Text(
                                    _leftIsRemote
                                        ? 'Transfer to left host'
                                        : 'Transfer to local',
                                  ),
                                ),
                              const PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                              const PopupMenuItem(
                                value: 'chmod',
                                child: Text('Permissions'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                              const PopupMenuItem(
                                value: 'refresh',
                                child: Text('Refresh'),
                              ),
                            ],
                            (action) {
                              switch (action) {
                                case 'transfer':
                                  _transferRightItemOut(item.filename);
                                  break;
                                case 'rename':
                                  _rename(item);
                                  break;
                                case 'chmod':
                                  _chmod(item);
                                  break;
                                case 'delete':
                                  _delete(item);
                                  break;
                                case 'refresh':
                                  _refreshRemote();
                                  break;
                              }
                            },
                          ),
                          hoverActions: [
                            if (!isDir)
                              _paneAction(
                                tooltip: _leftIsRemote
                                    ? 'Transfer to left host'
                                    : 'Download to local',
                                icon: Icons.download_outlined,
                                onTap: () =>
                                    _transferRightItemOut(item.filename),
                              ),
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: PopupMenuButton<String>(
                                tooltip: 'More',
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.more_horiz, size: 16),
                                onSelected: (action) {
                                  switch (action) {
                                    case 'rename':
                                      _rename(item);
                                      break;
                                    case 'chmod':
                                      _chmod(item);
                                      break;
                                    case 'delete':
                                      _delete(item);
                                      break;
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'chmod',
                                    child: Text('Permissions'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                        if (isDir) return row;
                        return Draggable<_RemoteDragData>(
                          data: _RemoteDragData(item.filename),
                          dragAnchorStrategy: pointerDragAnchorStrategy,
                          feedback: _dragFeedback(
                            _fileIcon(item.filename),
                            item.filename,
                            _leftIsRemote
                                ? 'Transfer to left host'
                                : 'Download to local',
                          ),
                          childWhenDragging: Opacity(opacity: 0.35, child: row),
                          child: row,
                        );
                      },
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _leftRemoteContent() {
    if (_leftRemoteError != null) {
      return _paneError(_leftRemoteError!);
    }
    if (_leftRemoteLoading && _leftRemoteItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return DragTarget<_RemoteDragData>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) => _onLeftPaneDrop(details.data),
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty;
        return _dragWrap(
          highlighted,
          child: _leftRemoteItems.isEmpty
              ? const Center(child: Text('Empty directory'))
              : ListView.builder(
                  itemCount: _leftRemoteItems.length,
                  itemBuilder: (context, index) {
                    final item = _leftRemoteItems[index];
                    final isDir = item.attr.isDirectory;
                    final row = _fileRow(
                      name: item.filename,
                      isDir: isDir,
                      subtitle: isDir ? null : _formatSize(item.attr.size),
                      icon: isDir ? Icons.folder : _fileIcon(item.filename),
                      onTap: isDir ? () => _enterLeftRemoteDir(item) : null,
                      onContextMenu: (position) => _showRowContextMenu(
                        position,
                        [
                          if (!isDir)
                            const PopupMenuItem(
                              value: 'transfer',
                              child: Text('Transfer to right host'),
                            ),
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Rename'),
                          ),
                          const PopupMenuItem(
                            value: 'chmod',
                            child: Text('Permissions'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                          const PopupMenuItem(
                            value: 'refresh',
                            child: Text('Refresh'),
                          ),
                        ],
                        (action) {
                          switch (action) {
                            case 'transfer':
                              _copyLeftRemoteToRight(item.filename);
                              break;
                            case 'rename':
                              _renameLeft(item);
                              break;
                            case 'chmod':
                              _chmodLeft(item);
                              break;
                            case 'delete':
                              _deleteLeft(item);
                              break;
                            case 'refresh':
                              _refreshLeftRemote();
                              break;
                          }
                        },
                      ),
                      hoverActions: [
                        if (!isDir)
                          _paneAction(
                            tooltip: 'Transfer to host',
                            icon: Icons.upload_outlined,
                            onTap: () =>
                                _copyLeftRemoteToRight(item.filename),
                          ),
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: PopupMenuButton<String>(
                            tooltip: 'More',
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.more_horiz, size: 16),
                            onSelected: (action) {
                              switch (action) {
                                case 'rename':
                                  _renameLeft(item);
                                  break;
                                case 'chmod':
                                  _chmodLeft(item);
                                  break;
                                case 'delete':
                                  _deleteLeft(item);
                                  break;
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                              const PopupMenuItem(
                                value: 'chmod',
                                child: Text('Permissions'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                    if (isDir) return row;
                    return Draggable<_LeftDragData>(
                      data: _LeftDragData(item.filename),
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      feedback: _dragFeedback(
                        _fileIcon(item.filename),
                        item.filename,
                        'Transfer to host',
                      ),
                      childWhenDragging: Opacity(opacity: 0.35, child: row),
                      child: row,
                    );
                  },
                ),
        );
      },
    );
  }

  Widget _fileRow({
    required String name,
    required bool isDir,
    required IconData icon,
    required String? subtitle,
    required VoidCallback? onTap,
    ValueChanged<Offset>? onContextMenu,
    required List<Widget> hoverActions,
  }) {
    return _HoverRow(
      builder: (context, hovered) => InkWell(
        onTap: onTap,
        onSecondaryTapDown: onContextMenu == null
            ? null
            : (details) => onContextMenu(details.globalPosition),
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: isDir ? Colors.amber : AppColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textFaint,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (hovered) ...[
                  for (final action in hoverActions) ...[
                    action,
                    const SizedBox(width: 4),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _paneAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.border),
          ),
          child: Icon(icon, size: 15, color: AppColors.accent),
        ),
      ),
    );
  }

  Widget _paneError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 36),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _transfersBar() {
    if (_transfers.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 4 * 30.0),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _transfers.length,
          itemBuilder: (context, index) {
            final task = _transfers[index];
            return SizedBox(
              height: 30,
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      '${task.name} — ${task.message}',
                      style: const TextStyle(fontSize: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: task.indeterminate ? null : task.progress,
                        minHeight: 6,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Cancel',
                    child: InkWell(
                      onTap: () => _cancelTransfer(task),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: const Icon(
                          Icons.close,
                          size: 14,
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<String?> _promptText(
    String title,
    String label, {
    String? initial,
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  final List<String> _errors = [];
  final Map<String, Timer> _errorTimers = {};

  void _showError(String message) {
    if (!mounted) return;
    if (_errors.contains(message)) {
      _errorTimers[message]?.cancel();
    } else {
      setState(() => _errors.add(message));
    }
    _errorTimers[message] = Timer(const Duration(seconds: 6), () {
      _dismissError(message);
    });
  }

  void _dismissError(String message) {
    _errorTimers.remove(message)?.cancel();
    if (!mounted) return;
    setState(() => _errors.remove(message));
  }

  Widget _errorOverlay() {
    if (_errors.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
            constraints: const BoxConstraints(maxHeight: 176),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _errors.length,
              itemBuilder: (context, index) {
                final message = _errors[index];
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.danger,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          message,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () => _dismissError(message),
                        borderRadius: BorderRadius.circular(4),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            Icons.close,
                            size: 16,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
    );
  }

  _TransferTask _beginTransfer(String name, String message, {int total = 0}) {
    final task = _TransferTask(name: name, message: message, total: total);
    setState(() => _transfers.add(task));
    return task;
  }

  DateTime? _lastTransferTick;

  void _updateTransfer(_TransferTask task, int bytes) {
    if (task.total <= 0 || !mounted) return;
    final now = DateTime.now();
    if (_lastTransferTick != null &&
        now.difference(_lastTransferTick!) < const Duration(milliseconds: 200)) {
      return;
    }
    _lastTransferTick = now;
    setState(() {
      task.progress = (bytes / task.total).clamp(0.0, 1.0);
    });
  }

  void _endTransfer(_TransferTask task) {
    if (!mounted) return;
    setState(() => _transfers.remove(task));
  }

  void _cancelTransfer(_TransferTask task) {
    if (task.canceled) return;
    task.canceled = true;
    task.cancel?.call();
  }

  Future<void> _showRowContextMenu(
    Offset position,
    List<PopupMenuEntry<String>> entries,
    ValueChanged<String> onSelected,
  ) async {
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: entries,
    );
    if (action == null) return;
    onSelected(action);
  }

  /// Context menu shown when right-clicking the empty area of a pane (not a
  /// file row). The file rows keep their own [InkWell] secondary-tap menus; the
  /// row recognizer wins the gesture arena on rows, so this background menu
  /// only fires for clicks that miss every row.
  void _showPaneMenu(
    Offset position, {
    required VoidCallback onNewFolder,
    required VoidCallback onRefresh,
    required Future<String?> Function() editPath,
    required void Function(String) onNavigate,
  }) {
    _showRowContextMenu(
      position,
      [
        const PopupMenuItem(value: 'newfolder', child: Text('New folder')),
        const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
        const PopupMenuItem(value: 'gotopath', child: Text('Go to path...')),
      ],
      (action) async {
        switch (action) {
          case 'newfolder':
            onNewFolder();
            break;
          case 'refresh':
            onRefresh();
            break;
          case 'gotopath':
            final input = await editPath();
            if (input != null) onNavigate(input);
            break;
        }
      },
    );
  }

  /// Wraps a pane's content so a right-click on its empty area opens the
  /// pane context menu. File rows keep their own per-row menus; we render
  /// the background menu only when the list is empty so the two never
  /// overlap.
  Widget _wrapPaneMenu(
    Widget child, {
    required VoidCallback onNewFolder,
    required VoidCallback onRefresh,
    required Future<String?> Function() editPath,
    required void Function(String) onNavigate,
    required bool isEmpty,
  }) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        // Only the empty-directory overlay carries the pane-level menu:
        // when files are listed, right-clicking anywhere already hits a
        // row first, so layering another handler here would open two
        // context menus at once.
        if (isEmpty)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onSecondaryTapDown: (d) => _showPaneMenu(
                d.globalPosition,
                onNewFolder: onNewFolder,
                onRefresh: onRefresh,
                editPath: editPath,
                onNavigate: onNavigate,
              ),
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }

  int? _fileSize(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return null;
    }
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  IconData _fileIcon(String name) {
    final ext = p.extension(name).toLowerCase();
    switch (ext) {
      case '.sh':
      case '.bash':
        return Icons.terminal;
      case '.zip':
      case '.tar':
      case '.gz':
      case '.bz2':
        return Icons.archive_outlined;
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.svg':
        return Icons.image_outlined;
      case '.md':
      case '.txt':
      case '.log':
        return Icons.description_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}

class _LeftDragData {
  final String name;
  final String? path;

  const _LeftDragData(this.name, [this.path]);

  bool get isLocal => path != null;
}

class _RemoteDragData {
  final String name;

  const _RemoteDragData(this.name);
}

class _TransferTask {
  _TransferTask({
    required this.name,
    required this.message,
    this.total = 0,
  });

  final String name;
  final String message;
  int total = 0;
  double progress = 0;
  bool canceled = false;
  Future<void> Function()? cancel;

  bool get indeterminate => total <= 0 || progress <= 0;
}

class _PickerSectionLabel extends StatelessWidget {
  final String text;

  const _PickerSectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: AppColors.textFaint,
        ),
      ),
    );
  }
}

class _SftpHostCard extends StatefulWidget {
  final Host host;
  final VoidCallback onConnect;

  const _SftpHostCard({
    required this.host,
    required this.onConnect,
  });

  @override
  State<_SftpHostCard> createState() => _SftpHostCardState();
}

class _SftpHostCardState extends State<_SftpHostCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final accent = host.color != null ? Color(host.color!) : AppColors.accent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onConnect,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.surfaceAlt : AppColors.card,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(Icons.dns_outlined, size: 15, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            host.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (host.favorite) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.star,
                            size: 12,
                            color: AppColors.warning,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      host.username.isNotEmpty
                          ? '${host.username}@${host.address}'
                          : host.address,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                        color: AppColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (_hovered)
                _SftpCardAction(
                  icon: Icons.arrow_forward,
                  tooltip: 'Connect',
                  onTap: widget.onConnect,
                )
              else
                const SizedBox(width: 28),
            ],
          ),
        ),
      ),
    );
  }
}

class _SftpGroupCard extends StatefulWidget {
  final Group group;
  final int hostCount;
  final VoidCallback onOpen;

  const _SftpGroupCard({
    required this.group,
    required this.hostCount,
    required this.onOpen,
  });

  @override
  State<_SftpGroupCard> createState() => _SftpGroupCardState();
}

class _SftpGroupCardState extends State<_SftpGroupCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onOpen,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.surfaceAlt : AppColors.card,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.accentMuted,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  Icons.folder_outlined,
                  size: 15,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.hostCount == 1
                          ? '1 host'
                          : '${widget.hostCount} hosts',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (_hovered)
                _SftpCardAction(
                  icon: Icons.chevron_right,
                  tooltip: 'Open group',
                  onTap: widget.onOpen,
                )
              else
                const SizedBox(width: 28),
            ],
          ),
        ),
      ),
    );
  }
}

class _SftpCardAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _SftpCardAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.border),
          ),
          child: Icon(icon, size: 13.5, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

class _HoverRow extends StatefulWidget {  final Widget Function(BuildContext context, bool hovered) builder;

  const _HoverRow({required this.builder});

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        color: _hovered ? AppColors.surfaceAlt : Colors.transparent,
        child: widget.builder(context, _hovered),
      ),
    );
  }
}
