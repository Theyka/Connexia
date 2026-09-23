import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Minimal Telnet (RFC 854) client connection.
///
/// Handles IAC negotiation for the options needed to run an interactive shell
/// (ECHO, SGA, BINARY, TERMINAL-TYPE and NAWS), strips negotiation sequences
/// from the application stream, and exposes raw output bytes.
class TelnetConnection {
  TelnetConnection._(this._socket);

  static const int _iac = 0xFF;
  static const int _dont = 0xFE;
  static const int _do = 0xFD;
  static const int _wont = 0xFC;
  static const int _will = 0xFB;
  static const int _sb = 0xFA;
  static const int _se = 0xF0;

  static const int _optBinary = 0;
  static const int _optEcho = 1;
  static const int _optSga = 3;
  static const int _optTtype = 24;
  static const int _optNaws = 31;

  final Socket _socket;
  final StreamController<Uint8List> _output = StreamController.broadcast();
  final Completer<void> _done = Completer<void>();

  final _TelnetParser _parser = _TelnetParser();

  bool _closed = false;
  int _cols = 80;
  int _rows = 24;

  Stream<Uint8List> get output => _output.stream;
  Future<void> get done => _done.future;

  /// Negotiation bytes the client needs to send back to the server.
  final List<int> _pending = [];

  static Future<TelnetConnection> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 15),
    int cols = 80,
    int rows = 24,
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    final conn = TelnetConnection._(socket);
    conn._cols = cols;
    conn._rows = rows;
    conn._start();
    return conn;
  }

  void _start() {
    _parser.onCommand = _handleCommand;
    _parser.onSubnegotiation = _handleSubnegotiation;
    _socket.listen(
      (data) {
        final text = _parser.add(data);
        if (text.isNotEmpty && !_output.isClosed) {
          _output.add(Uint8List.fromList(text));
        }
        _flushPending();
      },
      onDone: _finish,
      onError: (_) => _finish(),
      cancelOnError: true,
    );

    // Ask the server which options it supports and announce our window size.
    _negotiate(_do, _optNaws);
    _negotiate(_do, _optTtype);
    _negotiate(_will, _optNaws);
    _negotiate(_will, _optTtype);
    _negotiate(_will, _optSga);
    _negotiate(_do, _optSga);
    _sendWindowSize();
    _flushPending();
  }

  void _negotiate(int command, int option) {
    _pending
      ..add(_iac)
      ..add(command)
      ..add(option);
  }

  void _flushPending() {
    if (_closed || _pending.isEmpty) return;
    _socket.add(_pending);
    _pending.clear();
  }

  void _handleCommand(int command, int option) {
    switch (command) {
      case _do:
        if (_acceptedRemoteOptions.contains(option)) {
          _negotiate(_will, option);
          if (option == _optNaws) _sendWindowSize();
        } else {
          _negotiate(_wont, option);
        }
      case _will:
        if (_acceptedLocalOptions.contains(option)) {
          _negotiate(_do, option);
        } else {
          _negotiate(_dont, option);
        }
      case _dont:
        _negotiate(_wont, option);
      case _wont:
        _negotiate(_dont, option);
    }
  }

  // Options we are willing to enable on the server side (IAC DO -> WILL).
  static const Set<int> _acceptedRemoteOptions = {
    _optBinary,
    _optEcho,
    _optSga,
    _optNaws,
    _optTtype,
  };

  // Options we are willing to enable on our side (IAC WILL -> DO).
  static const Set<int> _acceptedLocalOptions = {_optBinary, _optSga, _optEcho};

  void _handleSubnegotiation(int option, List<int> data) {
    if (option == _optTtype && data.isNotEmpty && data.first == 1) {
      final name = 'xterm-256color'.codeUnits;
      _pending
        ..add(_iac)
        ..add(_sb)
        ..add(_optTtype)
        ..add(0)
        ..addAll(name)
        ..add(_iac)
        ..add(_se);
    } else if (option == _optNaws && data.length >= 5 && data.first == 0) {
      // Already sent on negotiate; nothing else to do.
    }
  }

  void _sendWindowSize() {
    _pending
      ..add(_iac)
      ..add(_sb)
      ..add(_optNaws)
      ..add(0)
      ..add((_cols >> 8) & 0xFF)
      ..add(_cols & 0xFF)
      ..add((_rows >> 8) & 0xFF)
      ..add(_rows & 0xFF)
      ..add(_iac)
      ..add(_se);
  }

  void write(List<int> data) {
    if (_closed) return;
    final out = <int>[];
    for (final byte in data) {
      out.add(byte);
      if (byte == _iac) out.add(_iac);
    }
    _socket.add(out);
  }

  void resize(int cols, int rows) {
    if (_closed || (cols == _cols && rows == _rows)) return;
    _cols = cols;
    _rows = rows;
    _sendWindowSize();
    _flushPending();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    _finish();
  }

  void _finish() {
    if (!_output.isClosed) _output.close();
    if (!_done.isCompleted) _done.complete();
  }
}

/// Parses the Telnet command stream, forwarding application bytes and
/// reporting IAC commands/subnegotiations.
class _TelnetParser {
  static const int _iac = 0xFF;
  static const int _sb = 0xFA;
  static const int _se = 0xF0;

  void Function(int command, int option)? onCommand;
  void Function(int option, List<int> data)? onSubnegotiation;

  static const int _stateData = 0;
  static const int _stateIac = 1;
  static const int _stateCommand = 2;
  static const int _stateSbOption = 3;
  static const int _stateSbData = 4;
  static const int _stateSbIac = 5;

  int _state = _stateData;
  int _command = 0;
  int _sbOption = 0;
  final List<int> _sbData = [];

  List<int> add(List<int> bytes) {
    final out = <int>[];
    for (final byte in bytes) {
      switch (_state) {
        case _stateData:
          if (byte == _iac) {
            _state = _stateIac;
          } else {
            out.add(byte);
          }
        case _stateIac:
          if (byte == _iac) {
            out.add(_iac);
            _state = _stateData;
          } else if (byte == _sb) {
            _state = _stateSbOption;
          } else if (byte == 251 || byte == 252 || byte == 253 || byte == 254) {
            _command = byte;
            _state = _stateCommand;
          } else {
            _state = _stateData;
          }
        case _stateCommand:
          onCommand?.call(_command, byte);
          _state = _stateData;
        case _stateSbOption:
          _sbOption = byte;
          _sbData.clear();
          _state = _stateSbData;
        case _stateSbData:
          if (byte == _iac) {
            _state = _stateSbIac;
          } else {
            _sbData.add(byte);
          }
        case _stateSbIac:
          if (byte == _se) {
            onSubnegotiation?.call(_sbOption, List<int>.of(_sbData));
            _state = _stateData;
          } else if (byte == _iac) {
            _sbData.add(_iac);
            _state = _stateSbData;
          } else {
            _state = _stateData;
          }
      }
    }
    return out;
  }
}
