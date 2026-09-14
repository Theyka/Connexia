import 'package:connexia/core/ssh/metrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String soh = '\u0001';
const String stx = '\u0002';
String marker(String name) => '$soh$name$stx';

final String fixtureText = [
  marker('CPU'),
  'cpu  104599 21 34838 4022991 10288 0 983 0 0 0',
  'cpu0 52299 10 17419 2011495 5144 0 491 0 0 0',
  marker('MEM'),
  'MemTotal:        3871332 kB',
  'MemFree:          221830 kB',
  'MemAvailable:    2012288 kB',
  'Buffers:          184452 kB',
  'Cached:          1638116 kB',
  'SwapTotal:       2097148 kB',
  'SwapFree:        2047604 kB',
  marker('DSK'),
  'Filesystem 1024-blocks     Used Available Capacity Mounted on',
  '/dev/sda1      40188920 12884712  25189808      34% /',
  'tmpfs           1935664        0   1935664       0% /dev/shm',
  '/dev/sdb1     102633372 51234567  46177205      53% /data',
  marker('NET'),
  'Inter-|   Receive                                                |  Transmit',
  ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed',
  '    lo: 221492423  131900    0    0    0     0          0         0  221492423  131900    0    0    0     0       0          0',
  '  eth0: 8214924235  981000    0    0    0     0          0         0 421492423  431900    0    0    0     0       0          0',
  marker('UPT'),
  '408100.31 812200.53',
  marker('LDA'),
  '0.42 0.35 0.30 2/412 8291',
  marker('PRC'),
  '187',
  marker('PRF'),
  '    PID %CPU %MEM    TIME+ COMMAND',
  '   1234 12.5  4.4 2-04:11 nginx',
  '   8901  3.2  1.0 04:12 sshd',
  marker('TMP'),
  'temp1 61000 acpitz',
  'thermal_zone2 46000 CPU',
  marker('PRT'),
  'Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process',
  'tcp   LISTEN 0      128          0.0.0.0:22      0.0.0.0:*    users:(("sshd",pid=8901,fd=3))',
  'tcp   LISTEN 0      511                *:80            *:*        users:(("nginx",pid=1234,fd=6))',
  'udp   UNCONN 0      0            0.0.0.0:68      0.0.0.0:*    users:(("NetworkManager",pid=200,fd=17))',
  marker('LOG'),
  'USER     TTY      FROM             LOGIN@   IDLE   WHAT',
  'vc       tty1                        Fri07   3:00m  -bash',
  marker('LST'),
  'vc       pts/0        10.1.13.6        Fri Sep 15 11:07 - 13:14  (2:07)',
  'reboot   system boot  6.1.68           Fri Sep 15 10:59 still running',
  'wtmp begins Tue Sep 12 09:15:00 2026',
  marker('SYS'),
  'HOSTNAME=app-server-01',
  'KERNEL=6.1.0-18-amd64',
  'ARCH=x86_64',
  'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"',
  'CPU_MODEL=Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz',
  'CORES=4',
].join('\n');

final String fixtureBusybox = [
  marker('CPU'),
  'cpu  99 0 50 1000 0 0 0 0 0 0',
  marker('MEM'),
  'MemTotal:        120000 kB',
  'MemFree:          21000 kB',
  'Buffers:          10000 kB',
  'Cached:          60000 kB',
  marker('DSK'),
  'Filesystem           1024-blocks    Used Available Capacity Mounted on',
  '/dev/vda1                8000000 4000000   4000000     50% /',
  marker('NET'),
  marker('UPT'),
  '786.30 1200.00',
  marker('LDA'),
  '0.10 0.09 0.08 1/50 9',
  marker('PRC'),
  '11',
  marker('PRF'),
  '  2340  1.0  2  00:01 busybox-httpd',
  marker('TMP'),
  marker('PRT'),
  'tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      7/httpd',
  'tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      88/sshd',
  marker('LOG'),
  'root       pts/0        10.0.0.2         Sep 15 11:07   :1',
  marker('LST'),
  'root       pts/0        10.0.0.2        Fri Sep 15 11:07   still logged in',
  marker('SYS'),
  'HOSTNAME=router',
  'KERNEL=5.10.0',
  'ARCH=arm64',
  'PRETTY_NAME="Alpine Linux v3.20"',
  'CORES=1',
].join('\n');

void main() {
  final ts = DateTime(2026, 9, 15, 12);

  test('parses a full GNU/systemd sample', () {
    final s = parseSample(fixtureText, ts);

    expect(s.cpuCounters, isNotNull);
    expect(s.cpuPct, isNull);
    expect(s.memTotalMb, closeTo(3780.6, 1));
    expect(s.memUsedMb, closeTo(1815.5, 1));
    expect(s.memPct, closeTo((1 - 2012288 / 3871332) * 100, 0.1));

    expect(s.disks, hasLength(2));
    expect(s.disks.first.mount, '/data');
    final root = s.disks.firstWhere((d) => d.mount == '/');
    expect(root.pct, 34);
    expect(root.totalMb, closeTo(40188920 / 1024, 1));

    expect(s.ifaces, hasLength(1));
    expect(s.ifaces.single.name, 'eth0');
    expect(s.ifaces.single.rxBytes, 8214924235);
    expect(s.ifaces.single.txBytes, 421492423);

    expect(s.uptimeSec, 408100);
    expect(s.load1, closeTo(0.42, 0.001));
    expect(s.load5, closeTo(0.35, 0.001));
    expect(s.load15, closeTo(0.30, 0.001));
    expect(s.procCount, 187);

    expect(s.procs, hasLength(2));
    expect(s.procs.first.name, 'nginx');
    expect(s.procs.first.cpu, closeTo(12.5, 0.01));

    expect(s.temps, hasLength(2));
    expect(s.temps[0].label, 'acpitz');
    expect(s.hottestTemp!.celsius, closeTo(61, 0.001));

    expect(s.ports, hasLength(3));
    final sshPort = s.ports.firstWhere((p) => p.port == 22);
    expect(sshPort.proto, 'tcp');
    expect(sshPort.process, 'sshd');
    final udp = s.ports.firstWhere((p) => p.proto == 'udp');
    expect(udp.port, 68);

    expect(s.logins.where((l) => l.active).map((l) => l.user), ['vc']);

    expect(s.logins.where((l) => !l.active), hasLength(1));

    expect(s.sysInfo!.hostname, 'app-server-01');
    expect(s.sysInfo!.kernel, '6.1.0-18-amd64');
    expect(s.sysInfo!.arch, 'x86_64');
    expect(s.sysInfo!.prettyName, 'Debian GNU/Linux 12 (bookworm)');
    expect(s.sysInfo!.cpuModel, 'Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz');
    expect(s.sysInfo!.cores, '4');
  });

  test('busybox fallback parses ports without -p metadata', () {
    final s = parseSample(fixtureBusybox, ts);
    expect(s.cpuCounters!.total, greaterThan(0));
    expect(s.memTotalMb, closeTo(117.2, 1));
    expect(s.ports, hasLength(2));
    final ssh = s.ports.firstWhere((p) => p.port == 22);
    expect(ssh.process, 'sshd');
    expect(s.sysInfo!.arch, 'arm64');
    expect(s.disks.single.pct, 50);
    expect(s.uptimeSec, 786);
  });

  test('empty output yields a benign sample', () {
    final s = parseSample('', ts);
    expect(s.memPct, 0);
    expect(s.disks, isEmpty);
    expect(s.ports, isEmpty);
    expect(s.sysInfo, isNull);
    expect(s.cpuPct, isNull);
  });
}
