import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class MetricSample {
  final DateTime ts;

  final CpuCounters? cpuCounters;
  final double? cpuPct;

  final double memPct;
  final double? memUsedMb;
  final double? memTotalMb;

  final List<DiskInfo> disks;
  final List<NetIface> ifaces;
  final double? load1;
  final double? load5;
  final double? load15;
  final List<TempReading> temps;
  final int? procCount;
  final int? uptimeSec;

  final List<PortRow> ports;
  final List<LoginRow> logins;
  final List<ProcRow> procs;
  final SysInfo? sysInfo;

  final double netRxRate;
  final double netTxRate;
  final double netRxCum;
  final double netTxCum;

  MetricSample({
    required this.ts,
    this.cpuCounters,
    this.cpuPct,
    required this.memPct,
    this.memUsedMb,
    this.memTotalMb,
    required this.disks,
    required this.ifaces,
    this.load1,
    this.load5,
    this.load15,
    required this.temps,
    this.procCount,
    this.uptimeSec,
    required this.ports,
    required this.logins,
    required this.procs,
    this.sysInfo,
    this.netRxRate = 0,
    this.netTxRate = 0,
    this.netRxCum = 0,
    this.netTxCum = 0,
  });

  TempReading? get hottestTemp {
    TempReading? hottest;
    for (final t in temps) {
      if (hottest == null || t.celsius > hottest.celsius) hottest = t;
    }
    return hottest;
  }
}

class CpuCounters {
  final int total;
  final int idle;
  final int user;
  final int system;

  CpuCounters({
    required this.total,
    required this.idle,
    required this.user,
    required this.system,
  });
}

class DiskInfo {
  final String mount;
  final String device;
  final double totalMb;
  final double usedMb;
  final double pct;

  DiskInfo({
    required this.mount,
    required this.device,
    required this.totalMb,
    required this.usedMb,
    required this.pct,
  });
}

class NetIface {
  final String name;
  final double rxBytes;
  final double txBytes;

  NetIface({required this.name, required this.rxBytes, required this.txBytes});
}

class TempReading {
  final String zone;

  final String label;
  final double celsius;

  TempReading({required this.zone, required this.label, required this.celsius});
}

class PortRow {
  final String proto;
  final String bind;
  final int port;
  final String process;

  PortRow({
    required this.proto,
    required this.bind,
    required this.port,
    required this.process,
  });
}

class LoginRow {
  final String user;
  final String detail;
  final bool active;

  LoginRow({required this.user, required this.detail, required this.active});
}

class ProcRow {
  final String pid;
  final double? cpu;
  final double? mem;
  final String elapsed;
  final String name;

  ProcRow({
    required this.pid,
    required this.cpu,
    required this.mem,
    required this.elapsed,
    required this.name,
  });
}

class SysInfo {
  final String hostname;
  final String kernel;
  final String arch;
  final String prettyName;
  final String cpuModel;
  final String cores;

  SysInfo({
    required this.hostname,
    required this.kernel,
    required this.arch,
    required this.prettyName,
    required this.cpuModel,
    required this.cores,
  });

  String get summary => [
    if (prettyName.isNotEmpty) prettyName,
    if (kernel.isNotEmpty) kernel,
    if (arch.isNotEmpty) arch,
  ].join(' · ');
}

const metricsScript = r'''
if [ ! -r /proc/stat ]; then
# FreeBSD / OPNsense / pfSense have no /proc: each section is rewritten into
# the Linux layout the parser already reads.
printf '\001CPU\002\n'
set -- $(sysctl -n kern.cp_time 2>/dev/null)
[ $# -ge 5 ] && printf 'cpu  %s %s %s %s 0 %s 0 0\n' "$1" "$2" "$3" "$5" "$4"
printf '\001MEM\002\n'
_ps=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
_tot=$(sysctl -n vm.stats.vm.v_page_count 2>/dev/null || echo 0)
_free=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo 0)
_inact=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null || echo 0)
_cache=$(sysctl -n vm.stats.vm.v_cache_count 2>/dev/null || echo 0)
_arc=$(sysctl -n kstat.zfs.misc.arcstats.size 2>/dev/null || echo 0)
echo "MemTotal: $((_tot * _ps / 1024)) kB"
echo "MemAvailable: $(((_free + _inact + _cache) * _ps / 1024 + _arc / 1024)) kB"
printf '\001DSK\002\n'
df -kP / 2>/dev/null
df -kP -t ufs 2>/dev/null
printf '\001NET\002\n'
netstat -ibn 2>/dev/null | awk '$3 ~ /^<Link/ && $1 !~ /^lo/ { if (NF >= 12) print $1": "$8" 0 0 0 0 0 0 0 "$11" 0 0 0 0 0 0 0"; else if (NF == 11) print $1": "$7" 0 0 0 0 0 0 0 "$10" 0 0 0 0 0 0 0" }'
printf '\001UPT\002\n'
_boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/^{ sec = \([0-9]*\),.*/\1/')
[ -n "$_boot" ] && echo $(( $(date +%s) - _boot ))
printf '\001LDA\002\n'
sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'
printf '\001PRC\002\n'
ps -axo pid= 2>/dev/null | wc -l
printf '\001PRF\002\n'
ps -axo pid,pcpu,pmem,etime,comm -r 2>/dev/null | head -11
printf '\001TMP\002\n'
sysctl dev.cpu hw.acpi.thermal 2>/dev/null | awk -F': ' '$1 ~ /temperature$/ && $2 ~ /^-?[0-9.]+C$/ { v = $2; sub(/C$/, "", v); lab = $1; if ($1 ~ /^dev\.cpu\.[0-9]+\./) { split($1, p, "."); lab = "Core " p[3] } else if ($1 ~ /thermal/) { lab = "acpitz" } printf "%s %d %s\n", $1, v * 1000, lab }'
printf '\001PRT\002\n'
sockstat -46l 2>/dev/null | awk 'NR > 1 && $5 ~ /^(tcp|udp)/ { print $5" 0 0 "$6" "$7" LISTEN "$3"/"$2 }' | head -400
printf '\001LOG\002\n'
who 2>/dev/null
printf '\001LST\002\n'
(last -n 12 2>/dev/null | head -16) || true
printf '\001SYS\002\n'
echo "HOSTNAME=$(hostname 2>/dev/null)"
echo "KERNEL=$(uname -r 2>/dev/null)"
echo "ARCH=$(uname -m 2>/dev/null)"
if command -v opnsense-version >/dev/null 2>&1; then
  echo "PRETTY_NAME=\"$(opnsense-version 2>/dev/null | sed 's/ (.*)$//')\""
elif [ -r /etc/platform ] && [ -r /etc/version ]; then
  echo "PRETTY_NAME=\"$(cat /etc/platform) $(cat /etc/version)\""
else
  echo "PRETTY_NAME=\"$(uname -s) $(freebsd-version 2>/dev/null || uname -r)\""
fi
echo "CPU_MODEL=$(sysctl -n hw.model 2>/dev/null)"
echo "CORES=$(sysctl -n hw.ncpu 2>/dev/null)"
exit 0
fi
printf '\001CPU\002\n'
head -n 2 /proc/stat 2>/dev/null
printf '\001MEM\002\n'
cat /proc/meminfo 2>/dev/null
printf '\001DSK\002\n'
df -kP 2>/dev/null
printf '\001NET\002\n'
cat /proc/net/dev 2>/dev/null
printf '\001UPT\002\n'
cat /proc/uptime 2>/dev/null
printf '\001LDA\002\n'
cat /proc/loadavg 2>/dev/null
printf '\001PRC\002\n'
ls /proc | grep -c '^[0-9]'
printf '\001PRF\002\n'
ps axo pid,pcpu,pmem,etime,comm --sort=-pcpu 2>/dev/null | head -11 || ps aux 2>/dev/null | head -11
printf '\001TMP\002\n'
for _f in /sys/class/hwmon/hwmon*/temp*_input /sys/class/thermal/thermal_zone*/temp; do
  if [ -r "$_f" ]; then
    _v=$(cat "$_f" 2>/dev/null)
    _d=$(dirname "$_f")
    _lab=""
    if [ -f "${_f%_input}_label" ]; then _lab=$(cat "${_f%_input}_label" 2>/dev/null); elif [ -f "$_d/label" ]; then _lab=$(cat "$_d/label" 2>/dev/null); elif [ -f "$_d/type" ]; then _lab=$(cat "$_d/type" 2>/dev/null); elif [ -f "$_d/name" ]; then _lab=$(cat "$_d/name" 2>/dev/null); fi
    printf '%s %s %s\n' "${_f##*/}" "$_v" "$_lab"
  fi
done
printf '\001PRT\002\n'
(ss -tulpn 2>/dev/null | head -400) || (netstat -tulpn 2>/dev/null | head -400) || true
printf '\001LOG\002\n'
who 2>/dev/null
printf '\001LST\002\n'
(last -n 12 -w 2>/dev/null | head -16) || true
printf '\001SYS\002\n'
echo "HOSTNAME=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)"
echo "KERNEL=$(uname -r 2>/dev/null)"
echo "ARCH=$(uname -m 2>/dev/null)"
grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null || true
echo "CPU_MODEL=$(grep -m1 -E '^(model name|Hardware)' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//')"
echo "CORES=$(nproc 2>/dev/null)"
''';

Future<SSHRunResult> _runResult(
  SSHClient client,
  String script, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final session = await client.execute('sh -s').timeout(timeout);
  try {
    session.stdin.add(Uint8List.fromList(utf8.encode('$script\n')));
    await session.stdin.close();
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    await Future.wait([
      session.stdout.forEach(out.add),
      session.stderr.forEach(err.add),
    ]).timeout(timeout);
    await session.done.timeout(timeout);
    final stdout = out.takeBytes();
    final stderr = err.takeBytes();
    return SSHRunResult(
      output: Uint8List.fromList([...stdout, ...stderr]),
      stdout: stdout,
      stderr: stderr,
      exitCode: session.exitCode,
      exitSignal: null,
    );
  } finally {
    session.close();
  }
}

Future<String> _run(
  SSHClient client,
  String script, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final result = await _runResult(client, script, timeout: timeout);
  return utf8.decode(result.stdout, allowMalformed: true);
}

Future<MetricSample> collectSample(SSHClient client) async {
  final raw = await _run(client, metricsScript);
  return parseSample(raw, DateTime.now());
}

MetricSample parseSample(String raw, DateTime ts) {
  final sections = <String, StringBuffer>{};
  String section = '';
  for (final line in const LineSplitter().convert(raw)) {
    if (line.length > 1 &&
        line.codeUnitAt(0) == 1 &&
        line.codeUnitAt(line.length - 1) == 2) {
      section = line.substring(1, line.length - 1);
    } else {
      (sections[section] ??= StringBuffer()).writeln(line);
    }
  }
  String bodyOf(String name) => (sections[name])?.toString() ?? '';

  CpuCounters? counters;
  for (final line in bodyOf('CPU').trim().split('\n')) {
    if (!RegExp(r'^cpu\s').hasMatch(line)) continue;
    final fields = line
        .split(RegExp(r'\s+'))
        .skip(1)
        .map(int.tryParse)
        .toList();
    if (fields.length < 4 || fields.any((f) => f == null)) continue;
    int at(int i) => i < fields.length ? fields[i]! : 0;
    counters = CpuCounters(
      total: at(0) + at(1) + at(2) + at(3) + at(4) + at(5) + at(6) + at(7),
      idle: at(3) + at(4),
      user: at(0),
      system: at(2),
    );
    break;
  }

  double memPct = 0;
  double? memUsedMb;
  double? memTotalMb;
  final memValues = <String, double>{};
  for (final line in bodyOf('MEM').split('\n')) {
    final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
    if (m != null) memValues[m.group(1)!] = double.parse(m.group(2)!) / 1024;
  }
  if ((memValues['MemTotal'] ?? 0) > 0) {
    final total = memValues['MemTotal']!;
    double used;
    if (memValues.containsKey('MemAvailable')) {
      used = total - memValues['MemAvailable']!;
    } else {
      used =
          total -
          (memValues['MemFree'] ?? 0) -
          (memValues['Buffers'] ?? 0) -
          (memValues['Cached'] ?? 0);
    }
    if (used >= 0) {
      memTotalMb = total;
      memUsedMb = used;
      memPct = used / total * 100;
    }
  }

  final disks = <DiskInfo>[];
  for (final line in bodyOf('DSK').trim().split('\n').skip(1)) {
    final t = line
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();

    if (t.length < 6) continue;
    final device = t[0];

    if (!(device.startsWith('/dev') || device.contains(':') || t[5] == '/')) {
      continue;
    }
    final totalBlocks = double.tryParse(t[1]);
    final usedBlocks = double.tryParse(t[2]);
    final pct = double.tryParse(t[4].replaceAll('%', ''));
    if (totalBlocks == null || usedBlocks == null || pct == null) continue;
    disks.add(
      DiskInfo(
        device: device,
        mount: t[5],
        totalMb: totalBlocks / 1024,
        usedMb: usedBlocks / 1024,
        pct: pct.clamp(0, 100).toDouble(),
      ),
    );
  }
  disks.sort((a, b) => b.totalMb.compareTo(a.totalMb));
  final seenMounts = <String>{};
  disks.retainWhere((d) => seenMounts.add(d.mount));

  final ifaces = <NetIface>[];
  for (final line in bodyOf('NET').split('\n')) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final name = line.substring(0, idx).trim();
    if (name == 'lo') continue;
    final cols = line
        .substring(idx + 1)
        .trim()
        .split(RegExp(r'\s+'))
        .map(double.tryParse)
        .toList();

    if (cols.length < 10 || cols[0] == null || cols[8] == null) continue;
    ifaces.add(NetIface(name: name, rxBytes: cols[0]!, txBytes: cols[8]!));
  }

  final upt = num.tryParse(bodyOf('UPT').trim().split(RegExp(r'\s+')).first);
  final uptimeSec = upt?.round();
  double? l1;
  double? l5;
  double? l15;
  final ldaT = bodyOf('LDA').trim().split(RegExp(r'\s+'));
  if (ldaT.length >= 3) {
    l1 = double.tryParse(ldaT[0]);
    l5 = double.tryParse(ldaT[1]);
    l15 = double.tryParse(ldaT[2]);
  }

  final procCount = int.tryParse(bodyOf('PRC').trim());
  final procs = <ProcRow>[];
  for (final line in bodyOf('PRF').trim().split('\n').skip(1)) {
    final t = line
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (t.isEmpty) continue;

    if (t.length >= 5 && RegExp(r'^\d+$').hasMatch(t[0])) {
      procs.add(
        ProcRow(
          pid: t[0],
          cpu: double.tryParse(t[1]),
          mem: double.tryParse(t[2]),
          elapsed: t[3],
          name: t.last,
        ),
      );
      continue;
    }

    if (t.length >= 3 && RegExp(r'^\d+$').hasMatch(t[1])) {
      procs.add(
        ProcRow(
          pid: t[1],
          cpu: double.tryParse(t[2]),
          mem: null,
          elapsed: '',
          name: t.last,
        ),
      );
    }
  }

  final temps = <TempReading>[];
  for (final line in bodyOf('TMP').split('\n')) {
    final t = line
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (t.length < 2) continue;
    final rawValue = double.tryParse(t[1]);
    if (rawValue == null) continue;
    final celsius = rawValue / 1000;
    if (celsius < -40 || celsius > 150) continue;
    temps.add(
      TempReading(
        zone: t[0],
        label: t.length > 2 ? t.sublist(2).join(' ') : '',
        celsius: celsius,
      ),
    );
  }

  final ports = <PortRow>[];
  for (final line in bodyOf('PRT').split('\n')) {
    final lt = line.trim();
    if (!lt.startsWith('tcp') && !lt.startsWith('udp')) continue;
    if (lt.contains('Local Address:Port') || lt.contains('Proto Recv-Q')) {
      continue;
    }
    final t = lt.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (t.length < 5) continue;
    final protoWord = t[0];

    final isNetstatPolicy = int.tryParse(t[1]) != null;
    final bind = isNetstatPolicy ? t[3] : t[4];
    final pm = RegExp(r'(\d+)$').firstMatch(bind);
    if (pm == null) continue;
    String process = '';
    final upm = RegExp(r'\("?"?([\w.\-+/]+)"?,?').firstMatch(lt);
    if (upm != null) process = upm.group(1)!;
    if (process.isEmpty) {
      final npm = RegExp(r'\d+/(\S+)').firstMatch(lt);
      if (npm != null) process = npm.group(1)!;
    }
    ports.add(
      PortRow(
        proto: protoWord.startsWith('u') ? 'udp' : 'tcp',
        bind: bind,
        port: int.parse(pm.group(1)!),
        process: process,
      ),
    );
  }
  final seenPorts = <String>{};
  ports.retainWhere((p) => seenPorts.add('${p.proto}:${p.port}:${p.process}'));

  final logins = <LoginRow>[];
  for (final line in bodyOf('LOG').trim().split('\n')) {
    final t = line
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (t.isEmpty) continue;
    if (t.first == 'USER' || t.first.startsWith('LOGIN@')) continue;
    logins.add(
      LoginRow(
        user: t.first,
        detail: t.length > 1 ? t.sublist(1).join('  ') : '',
        active: true,
      ),
    );
  }
  for (final line in bodyOf('LST').trim().split('\n')) {
    final l = line.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('Username') || l.contains(' begins ')) continue;
    if (l.startsWith('boot time') || l.startsWith('shutdown ')) continue;
    if (l.startsWith('reboot ') || l.startsWith('btmp begins')) continue;

    final t = l.split(RegExp(r'\s{2,}')).where((p) => p.isNotEmpty).toList();
    if (t.isEmpty) continue;
    final user = t.first.trim();
    if (user.isEmpty) continue;
    final detail = t.length > 1 ? t.sublist(1).join(' | ') : '';
    logins.add(LoginRow(user: user, detail: detail, active: false));
  }

  SysInfo? sys;
  final sysValues = <String, String>{};
  for (final line in bodyOf('SYS').split('\n')) {
    final m = RegExp(r'^([A-Z_]+)=(.*)$').firstMatch(line.trim());
    if (m != null) sysValues[m.group(1)!] = m.group(2)!.trim();
  }
  if (sysValues.isNotEmpty) {
    var pretty = sysValues['PRETTY_NAME'] ?? '';
    if (pretty.length >= 2 && pretty.startsWith('"') && pretty.endsWith('"')) {
      pretty = pretty.substring(1, pretty.length - 1);
    }
    final cores = sysValues['CORES'] ?? '';
    sys = SysInfo(
      hostname: sysValues['HOSTNAME'] ?? '',
      kernel: sysValues['KERNEL'] ?? '',
      arch: sysValues['ARCH'] ?? '',
      prettyName: pretty,
      cpuModel: sysValues['CPU_MODEL'] ?? '',
      cores: RegExp(r'^\d+$').hasMatch(cores) ? cores : '',
    );
  }

  return MetricSample(
    ts: ts,
    cpuCounters: counters,
    memPct: memPct,
    memUsedMb: memUsedMb,
    memTotalMb: memTotalMb,
    disks: disks,
    ifaces: ifaces,
    load1: l1,
    load5: l5,
    load15: l15,
    temps: temps,
    procCount: procCount,
    uptimeSec: uptimeSec,
    ports: ports,
    logins: logins,
    procs: procs,
    sysInfo: sys,
  );
}

class ServiceInfo {
  final String unit;
  final String active;
  final String sub;
  final String description;

  ServiceInfo({
    required this.unit,
    required this.active,
    required this.sub,
    required this.description,
  });

  bool get isRunning => active == 'active';
  bool get isFailed => active == 'failed';
}

Future<List<ServiceInfo>> listServiceUnits(SSHClient client) async {
  final list = await _run(
    client,
    "systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null | head -300",
    timeout: const Duration(seconds: 15),
  );
  final services = <ServiceInfo>[];
  for (final line in list.trim().split('\n')) {
    final t = line.trim().split(RegExp(r'\s+'));
    if (t.length < 4) continue;
    services.add(
      ServiceInfo(
        unit: t[0],
        active: t[2],
        sub: t[3],
        description: t.length > 4 ? t.sublist(4).join(' ') : '',
      ),
    );
  }
  return services;
}

Future<String?> runServiceAction(
  SSHClient client,
  String unit,
  String action, {
  String? sudoPassword,
}) async {
  assert(
    const ['start', 'stop', 'restart', 'enable', 'disable'].contains(action),
  );
  final command = 'systemctl $action ${_shQuote(unit)} --no-pager 2>&1';
  String outputOf(SSHRunResult r) =>
      utf8.decode(r.stdout, allowMalformed: true).trim();
  bool failed(SSHRunResult r) => r.exitCode != null && r.exitCode != 0;

  var result = await _runResult(
    client,
    command,
    timeout: const Duration(seconds: 40),
  );
  if (failed(result) &&
      sudoPassword != null &&
      RegExp(
        r'authentication required|access denied|permission denied|not permitted',
        caseSensitive: false,
      ).hasMatch(outputOf(result))) {
    result = await _runResult(
      client,
      "sudo -S -p '' $command <<'CONNEXIA_SUDO_EOF'\n$sudoPassword\nCONNEXIA_SUDO_EOF",
      timeout: const Duration(seconds: 40),
    );
  }
  if (failed(result)) {
    final out = outputOf(result);
    return out.isEmpty ? 'systemctl $action failed' : out;
  }
  return null;
}

Future<String> readCrontab(SSHClient client) async {
  final result = await _runResult(client, 'crontab -l 2>&1');
  final out = utf8.decode(result.stdout, allowMalformed: true);
  if (RegExp(r'no crontab for', caseSensitive: false).hasMatch(out)) {
    return '';
  }
  return out;
}

Future<String?> writeCrontab(SSHClient client, String body) async {
  final result = await _runResult(
    client,
    "crontab - 2>&1 <<'CONNEXIA_CRONTAB_EOF'\n$body\nCONNEXIA_CRONTAB_EOF",
    timeout: const Duration(seconds: 20),
  );
  final err = utf8.decode(result.stderr, allowMalformed: true).trim();
  if (result.exitCode != null && result.exitCode != 0) {
    return err.isEmpty ? 'crontab write failed' : err;
  }
  final all = utf8.decode(result.output, allowMalformed: true).trim();
  if (err.isEmpty && all.isNotEmpty) return all;
  return null;
}

String _shQuote(String v) => "'${v.replaceAll("'", "'\\''")}'";
