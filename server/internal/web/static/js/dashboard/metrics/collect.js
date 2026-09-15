const D = "$";

export const METRICS_SCRIPT = String.raw`
if [ ! -r /proc/stat ]; then
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
    if [ -f "${D}{_f%_input}_label" ]; then _lab=$(cat "${D}{_f%_input}_label" 2>/dev/null); elif [ -f "$_d/label" ]; then _lab=$(cat "$_d/label" 2>/dev/null); elif [ -f "$_d/type" ]; then _lab=$(cat "$_d/type" 2>/dev/null); elif [ -f "$_d/name" ]; then _lab=$(cat "$_d/name" 2>/dev/null); fi
    printf '%s %s %s\n' "${D}{_f##*/}" "$_v" "$_lab"
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
`;

const INT = /^[-+]?\d+$/;
const NUM = /^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/;

const toInt = (s) => (INT.test(s ?? "") ? parseInt(s, 10) : null);
const toNum = (s) => (NUM.test(s ?? "") ? Number(s) : null);
const tokens = (line) => line.trim().split(/\s+/).filter(Boolean);

export async function runScript(handle, script, timeoutMs = 25000) {
  let timer = 0;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      handle.close();
      reject(new Error("Timed out"));
    }, timeoutMs);
  });
  try {
    return await Promise.race([handle.run("sh -s", script + "\n"), timeout]);
  } finally {
    clearTimeout(timer);
  }
}

export async function collectSample(handle) {
  const { stdout } = await runScript(handle, METRICS_SCRIPT);
  return parseSample(stdout, Date.now());
}

export function parseSample(raw, ts) {
  const sections = new Map();
  let section = "";
  const lines = raw.split(/\r\n|\r|\n/);
  if (lines.length && lines[lines.length - 1] === "") lines.pop();
  for (const line of lines) {
    if (line.length > 1 && line.charCodeAt(0) === 1 && line.charCodeAt(line.length - 1) === 2) {
      section = line.slice(1, -1);
    } else {
      sections.set(section, (sections.get(section) ?? "") + line + "\n");
    }
  }
  const bodyOf = (name) => sections.get(name) ?? "";

  let cpuCounters = null;
  for (const line of bodyOf("CPU").trim().split("\n")) {
    if (!/^cpu\s/.test(line)) continue;
    const fields = line.split(/\s+/).slice(1).map(toInt);
    if (fields.length < 4 || fields.some((f) => f == null)) continue;
    const at = (i) => (i < fields.length ? fields[i] : 0);
    cpuCounters = {
      total: at(0) + at(1) + at(2) + at(3) + at(4) + at(5) + at(6) + at(7),
      idle: at(3) + at(4),
      user: at(0),
      system: at(2),
    };
    break;
  }

  let memPct = 0;
  let memUsedMb = null;
  let memTotalMb = null;
  const mem = new Map();
  for (const line of bodyOf("MEM").split("\n")) {
    const m = /^(\w+):\s+(\d+)/.exec(line);
    if (m) mem.set(m[1], Number(m[2]) / 1024);
  }
  if ((mem.get("MemTotal") ?? 0) > 0) {
    const total = mem.get("MemTotal");
    const used = mem.has("MemAvailable")
      ? total - mem.get("MemAvailable")
      : total - (mem.get("MemFree") ?? 0) - (mem.get("Buffers") ?? 0) - (mem.get("Cached") ?? 0);
    if (used >= 0) {
      memTotalMb = total;
      memUsedMb = used;
      memPct = (used / total) * 100;
    }
  }

  let disks = [];
  for (const line of bodyOf("DSK").trim().split("\n").slice(1)) {
    const t = tokens(line);
    if (t.length < 6) continue;
    const device = t[0];
    if (!(device.startsWith("/dev") || device.includes(":") || t[5] === "/")) continue;
    const totalBlocks = toNum(t[1]);
    const usedBlocks = toNum(t[2]);
    const pct = toNum(t[4].replaceAll("%", ""));
    if (totalBlocks == null || usedBlocks == null || pct == null) continue;
    disks.push({ device, mount: t[5], totalMb: totalBlocks / 1024, usedMb: usedBlocks / 1024, pct: Math.min(100, Math.max(0, pct)) });
  }
  disks.sort((a, b) => b.totalMb - a.totalMb);
  const seenMounts = new Set();
  disks = disks.filter((d) => !seenMounts.has(d.mount) && seenMounts.add(d.mount));

  const ifaces = [];
  for (const line of bodyOf("NET").split("\n")) {
    const idx = line.indexOf(":");
    if (idx <= 0) continue;
    const name = line.slice(0, idx).trim();
    if (name === "lo") continue;
    const cols = line.slice(idx + 1).trim().split(/\s+/).map(toNum);
    if (cols.length < 10 || cols[0] == null || cols[8] == null) continue;
    ifaces.push({ name, rxBytes: cols[0], txBytes: cols[8] });
  }

  const upt = toNum(bodyOf("UPT").trim().split(/\s+/)[0]);
  const uptimeSec = upt == null ? null : Math.round(upt);
  let load1 = null;
  let load5 = null;
  let load15 = null;
  const lda = bodyOf("LDA").trim().split(/\s+/);
  if (lda.length >= 3) {
    load1 = toNum(lda[0]);
    load5 = toNum(lda[1]);
    load15 = toNum(lda[2]);
  }

  const procCount = toInt(bodyOf("PRC").trim());
  const procs = [];
  for (const line of bodyOf("PRF").trim().split("\n").slice(1)) {
    const t = tokens(line);
    if (t.length === 0) continue;
    if (t.length >= 5 && /^\d+$/.test(t[0])) {
      procs.push({ pid: t[0], cpu: toNum(t[1]), mem: toNum(t[2]), elapsed: t[3], name: t[t.length - 1] });
      continue;
    }
    if (t.length >= 3 && /^\d+$/.test(t[1])) {
      procs.push({ pid: t[1], cpu: toNum(t[2]), mem: null, elapsed: "", name: t[t.length - 1] });
    }
  }

  const temps = [];
  for (const line of bodyOf("TMP").split("\n")) {
    const t = tokens(line);
    if (t.length < 2) continue;
    const value = toNum(t[1]);
    if (value == null) continue;
    const celsius = value / 1000;
    if (celsius < -40 || celsius > 150) continue;
    temps.push({ zone: t[0], label: t.length > 2 ? t.slice(2).join(" ") : "", celsius });
  }

  let ports = [];
  for (const line of bodyOf("PRT").split("\n")) {
    const lt = line.trim();
    if (!lt.startsWith("tcp") && !lt.startsWith("udp")) continue;
    if (lt.includes("Local Address:Port") || lt.includes("Proto Recv-Q")) continue;
    const t = tokens(lt);
    if (t.length < 5) continue;
    const bind = toInt(t[1]) != null ? t[3] : t[4];
    const pm = /(\d+)$/.exec(bind);
    if (!pm) continue;
    let process = /\("?"?([\w.\-+/]+)"?,?/.exec(lt)?.[1] ?? "";
    if (!process) process = /\d+\/(\S+)/.exec(lt)?.[1] ?? "";
    ports.push({ proto: t[0].startsWith("u") ? "udp" : "tcp", bind, port: parseInt(pm[1], 10), process });
  }
  const seenPorts = new Set();
  ports = ports.filter((p) => {
    const key = `${p.proto}:${p.port}:${p.process}`;
    return !seenPorts.has(key) && seenPorts.add(key);
  });

  const logins = [];
  for (const line of bodyOf("LOG").trim().split("\n")) {
    const t = tokens(line);
    if (t.length === 0 || t[0] === "USER" || t[0].startsWith("LOGIN@")) continue;
    logins.push({ user: t[0], detail: t.slice(1).join("  "), active: true });
  }
  for (const line of bodyOf("LST").trim().split("\n")) {
    const l = line.trim();
    if (!l || l.startsWith("Username") || l.includes(" begins ")) continue;
    if (l.startsWith("boot time") || l.startsWith("shutdown ") || l.startsWith("reboot ") || l.startsWith("btmp begins")) continue;
    const t = l.split(/\s{2,}/).filter(Boolean);
    const user = t[0]?.trim();
    if (!user) continue;
    logins.push({ user, detail: t.slice(1).join(" | "), active: false });
  }

  let sysInfo = null;
  const sys = new Map();
  for (const line of bodyOf("SYS").split("\n")) {
    const m = /^([A-Z_]+)=(.*)$/.exec(line.trim());
    if (m) sys.set(m[1], m[2].trim());
  }
  if (sys.size > 0) {
    let pretty = sys.get("PRETTY_NAME") ?? "";
    if (pretty.length >= 2 && pretty.startsWith('"') && pretty.endsWith('"')) pretty = pretty.slice(1, -1);
    const cores = sys.get("CORES") ?? "";
    sysInfo = {
      hostname: sys.get("HOSTNAME") ?? "",
      kernel: sys.get("KERNEL") ?? "",
      arch: sys.get("ARCH") ?? "",
      prettyName: pretty,
      cpuModel: sys.get("CPU_MODEL") ?? "",
      cores: /^\d+$/.test(cores) ? cores : "",
    };
  }

  return {
    ts,
    cpuCounters,
    cpuPct: null,
    memPct,
    memUsedMb,
    memTotalMb,
    disks,
    ifaces,
    load1,
    load5,
    load15,
    temps,
    procCount,
    uptimeSec,
    ports,
    logins,
    procs,
    sysInfo,
    netRxRate: 0,
    netTxRate: 0,
    netRxCum: 0,
    netTxCum: 0,
  };
}

export function hottestTemp(sample) {
  let hottest = null;
  for (const t of sample?.temps ?? []) {
    if (!hottest || t.celsius > hottest.celsius) hottest = t;
  }
  return hottest;
}

export async function listServiceUnits(handle) {
  const { stdout } = await runScript(handle, "systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null | head -300", 15000);
  const services = [];
  for (const line of stdout.trim().split("\n")) {
    const t = line.trim().replace(/^[●*○×]\s*/, "").split(/\s+/);
    if (t.length < 4) continue;
    services.push({ unit: t[0], active: t[2], sub: t[3], description: t.slice(4).join(" ") });
  }
  return services;
}

export const shQuote = (value) => `'${value.replaceAll("'", "'\\''")}'`;

const failed = (result) => result.code > 0;

export async function runServiceAction(handle, unit, action, sudoPassword) {
  if (!["start", "stop", "restart", "enable", "disable"].includes(action)) throw new Error("Unknown action");
  const command = `systemctl ${action} ${shQuote(unit)} --no-pager 2>&1`;
  let result = await runScript(handle, command, 40000);
  if (failed(result) && sudoPassword != null && /authentication required|access denied|permission denied|not permitted/i.test(result.stdout.trim())) {
    result = await runScript(handle, `sudo -S -p '' ${command} <<'CONNEXIA_SUDO_EOF'\n${sudoPassword}\nCONNEXIA_SUDO_EOF`, 40000);
  }
  if (failed(result)) {
    const out = result.stdout.trim();
    return out || `systemctl ${action} failed`;
  }
  return null;
}

export async function readCrontab(handle) {
  const { stdout } = await runScript(handle, "crontab -l 2>&1");
  return /no crontab for/i.test(stdout) ? "" : stdout;
}

export async function writeCrontab(handle, body) {
  const result = await runScript(handle, `crontab - 2>&1 <<'CONNEXIA_CRONTAB_EOF'\n${body}\nCONNEXIA_CRONTAB_EOF`, 20000);
  const err = result.stderr.trim();
  if (failed(result)) {
    const out = (result.stdout + result.stderr).trim();
    return err || out || "crontab write failed";
  }
  const all = (result.stdout + result.stderr).trim();
  if (!err && all) return all;
  return null;
}
