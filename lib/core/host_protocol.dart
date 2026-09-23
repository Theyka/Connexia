/// Connection protocol for a host.
///
/// SSH and Telnet are text protocols that render in the terminal; RDP and VNC
/// are graphical protocols that render into a framebuffer surface.
enum HostProtocol {
  ssh('ssh', 'SSH', 22),
  telnet('telnet', 'Telnet', 23),
  rdp('rdp', 'RDP', 3389),
  vnc('vnc', 'VNC', 5900);

  const HostProtocol(this.id, this.label, this.defaultPort);

  /// Stable value persisted in the database and sync payloads.
  final String id;
  final String label;
  final int defaultPort;

  bool get isText => this == ssh || this == telnet;
  bool get isGraphical => this == rdp || this == vnc;

  /// Whether the protocol encrypts credentials and traffic.
  bool get isEncrypted => this == ssh;

  static HostProtocol fromId(String? id) => HostProtocol.values.firstWhere(
    (p) => p.id == id,
    orElse: () => HostProtocol.ssh,
  );
}
