import 'package:connexia/core/ssh/metrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

String marker(String name) => '\u0001$name\u0002';

/// Output of the collector's FreeBSD / OPNsense branch, which rewrites
/// sysctl, netstat -ibn and sockstat into the Linux-style layout the parser
/// reads.
final String fixtureOpnsense = [
  marker('CPU'),
  'cpu  1000 0 500 8000 0 20 0 0',
  marker('MEM'),
  'MemTotal: 8000000 kB',
  'MemAvailable: 6000000 kB',
  marker('DSK'),
  'Filesystem 1024-blocks Used Avail Capacity Mounted on',
  'zroot/ROOT/default 100000000 2000000 98000000 2% /',
  'Filesystem 1024-blocks Used Avail Capacity Mounted on',
  marker('NET'),
  'vtnet0: 123456 0 0 0 0 0 0 0 654321 0 0 0 0 0 0 0',
  marker('UPT'),
  '3600',
  marker('LDA'),
  ' 0.25 0.30 0.28 ',
  marker('PRC'),
  '      42',
  marker('PRF'),
  '  PID %CPU %MEM ELAPSED COMMAND',
  '  123  5.0  1.2 01:02:03 php-cgi',
  marker('TMP'),
  'dev.cpu.0.temperature 45000 Core 0',
  marker('PRT'),
  'tcp4 0 0 *:22 *:* LISTEN 123/sshd',
  'udp6 0 0 ::1:53 *:* LISTEN 456/unbound',
  marker('LOG'),
  'root             pts/0        Sep 14 12:00 (192.168.1.10)',
  marker('LST'),
  'root     pts/0    192.168.1.10     Mon Sep 14 12:00 - 12:30  (00:30)',
  'boot time                          Mon Sep 14 10:00',
  'utx.log begins Mon Sep  1 00:00:00 UTC 2026',
  marker('SYS'),
  'HOSTNAME=2',
  'KERNEL=15.1-RELEASE-p3',
  'ARCH=amd64',
  'PRETTY_NAME="OPNsense 26.7.3_11"',
  'CPU_MODEL=Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz',
  'CORES=28',
].join('\n');

void main() {
  test('parses the FreeBSD / OPNsense collector output', () {
    final s = parseSample(fixtureOpnsense, DateTime(2026, 9, 14, 12));

    expect(s.cpuCounters!.total, 9520);
    expect(s.cpuCounters!.idle, 8000);
    expect(s.memTotalMb, closeTo(8000000 / 1024, 1));
    expect(s.memPct, closeTo(25, 0.1));

    // ZFS root dataset is kept even though it isn't a /dev device.
    expect(s.disks, hasLength(1));
    expect(s.disks.single.mount, '/');
    expect(s.disks.single.pct, 2);

    expect(s.ifaces.single.name, 'vtnet0');
    expect(s.ifaces.single.rxBytes, 123456);
    expect(s.ifaces.single.txBytes, 654321);

    expect(s.uptimeSec, 3600);
    expect(s.load1, closeTo(0.25, 0.001));
    expect(s.procCount, 42);
    expect(s.procs.single.name, 'php-cgi');
    expect(s.hottestTemp!.celsius, closeTo(45, 0.001));

    expect(s.ports, hasLength(2));
    expect(s.ports.firstWhere((p) => p.port == 22).process, 'sshd');
    final dns = s.ports.firstWhere((p) => p.port == 53);
    expect(dns.proto, 'udp');
    expect(dns.process, 'unbound');

    expect(s.logins.where((l) => l.active).map((l) => l.user), ['root']);
    // "boot time" and "utx.log begins" are not sign-ins.
    expect(s.logins.where((l) => !l.active), hasLength(1));

    // A numeric hostname must not be mistaken for the core count.
    expect(s.sysInfo!.hostname, '2');
    expect(s.sysInfo!.kernel, '15.1-RELEASE-p3');
    expect(s.sysInfo!.arch, 'amd64');
    expect(s.sysInfo!.prettyName, 'OPNsense 26.7.3_11');
    expect(s.sysInfo!.cpuModel, 'Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz');
    expect(s.sysInfo!.cores, '28');
  });
}
