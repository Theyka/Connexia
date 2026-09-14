import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:win32_registry/win32_registry.dart';

abstract class SecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class InMemorySecretStorage implements SecretStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class WindowsRegistrySecretStorage implements SecretStorage {
  static const String _registryPath = r'Software\Connexia';

  RegistryKey _openOrCreate() {
    final root = Registry.currentUser;
    final key = root.createKey(_registryPath);
    root.close();
    return key;
  }

  @override
  Future<String?> read(String key) async {
    final registryKey = _openOrCreate();
    try {
      return registryKey.getValueAsString(key);
    } finally {
      registryKey.close();
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final registryKey = _openOrCreate();
    try {
      registryKey.createValue(
        RegistryValue(key, RegistryValueType.string, value),
      );
    } finally {
      registryKey.close();
    }
  }

  @override
  Future<void> delete(String key) async {
    final registryKey = _openOrCreate();
    try {
      registryKey.deleteValue(key);
    } finally {
      registryKey.close();
    }
  }
}

class FileSecretStorage implements SecretStorage {
  final Directory directory;

  FileSecretStorage(this.directory);

  File _file(String key) {
    final name = key.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return File(p.join(directory.path, '$name.sec'));
  }

  Future<File> _ensureFile(String key) async {
    await directory.create(recursive: true);
    final file = _file(key);
    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['600', file.path]);
    }
    return file;
  }

  @override
  Future<String?> read(String key) async {
    final file = _file(key);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String key, String value) async {
    final file = await _ensureFile(key);
    await file.writeAsString(value, flush: true);
  }

  @override
  Future<void> delete(String key) async {
    final file = _file(key);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class PlatformSecretStorage implements SecretStorage {
  SecretStorage? _impl;

  Future<SecretStorage> _ensure() async {
    final existing = _impl;
    if (existing != null) return existing;

    final SecretStorage created;
    if (Platform.isWindows) {
      created = WindowsRegistrySecretStorage();
    } else {
      final directory = await getApplicationSupportDirectory();
      created = FileSecretStorage(directory);
    }
    _impl = created;
    return created;
  }

  @override
  Future<String?> read(String key) async => (await _ensure()).read(key);

  @override
  Future<void> write(String key, String value) async =>
      (await _ensure()).write(key, value);

  @override
  Future<void> delete(String key) async => (await _ensure()).delete(key);
}
