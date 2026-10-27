#!/usr/bin/env python3
"""Sammelt Angebots- und Nutzungsstatistiken des WSLC Cache & Registry Hubs.

Laeuft als systemd-Dienst in der Cache-Distro und schreibt alle INTERVAL Sekunden
/srv/artifacts/stats.json, die von hub/index.html (nginx) abgefragt wird.

Quellen (nur lesend, es werden keine Pulls ausgeloest):
  - Registry-Dateisystem    -> gecachte Images, Tags, Groessen, Cache-Zeitpunkt
  - Registry-Container-Logs -> Pulls, ausgelieferte Bytes, Clients, letzter Zugriff
  - apt-cacher-ng-Log       -> aus dem Cache ausgelieferte vs. aus dem Internet geladene Bytes
  - nginx-Container-Log     -> Downloads der Artefakte
Zaehler werden in STATE persistiert und ueberleben Neustarts des Dienstes.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

CONFIG = os.environ.get("HUB_CONFIG", "/etc/hub-stats.json")
STATE = os.environ.get("HUB_STATE", "/var/lib/hub-stats/state.json")
OUT = os.environ.get("HUB_OUT", "/srv/artifacts/stats.json")
REGISTRY_ROOT = "/srv/registry"
ARTIFACT_DIR = "/srv/artifacts"
APT_LOG = "/var/log/apt-cacher-ng/apt-cacher.log"
APT_CACHE = "/var/cache/apt-cacher-ng"
SIZE_TTL = 300          # Verzeichnisgroessen nur alle 5 Minuten neu berechnen
DEDUP_SECONDS = 60      # HEAD+GET desselben Pulls nur einmal zaehlen
MAX_CLIENTS = 50

HIDDEN_ARTIFACTS = {"index.html", "stats.json"}
ARTIFACT_INFO = [
    (r"^nerdctl-", "nerdctl (Container-CLI fuer die wslc-VM)"),
    (r"^cni-plugins-", "Standard-CNI-Plugins (bridge, loopback, host-local ...)"),
    (r"^kube-flannel", "Flannel-CNI-Manifest"),
    (r"^nvidia-device-plugin", "NVIDIA Device Plugin Manifest"),
]

RE_KV = re.compile(r'(\S+?)=(?:"([^"]*)"|(\S+))')
RE_V2 = re.compile(r"^/v2/(.+)/(manifests|blobs)/([^?]+)")
RE_NGINX = re.compile(r'^(\S+) \S+ \S+ \[[^\]]+\] "(\w+) (\S+) [^"]*" (\d{3}) (\d+)')

_size_cache = {}
_blob_cache = {}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch_iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def dir_size(path):
    cached = _size_cache.get(path)
    if cached and time.time() - cached[0] < SIZE_TTL:
        return cached[1]
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    _size_cache[path] = (time.time(), total)
    return total


# ---------------------------------------------------------------- Registry --

def read_blob(base, digest):
    if not digest or ":" not in digest:
        return None
    algo, hexd = digest.split(":", 1)
    path = os.path.join(base, "blobs", algo, hexd[:2], hexd, "data")
    if path in _blob_cache:
        return _blob_cache[path]
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = None
    if len(_blob_cache) > 5000:
        _blob_cache.clear()
    _blob_cache[path] = data
    return data


def manifest_info(base, digest):
    """Liefert (Groesse in Bytes oder None, Plattformen) fuer ein Manifest oder einen Index."""
    doc = read_blob(base, digest)
    if not doc:
        return None, []
    platforms = []
    if "manifests" in doc:
        chosen = None
        for m in doc["manifests"]:
            plat = m.get("platform", {})
            if plat.get("os") in (None, "unknown") or plat.get("architecture") == "unknown":
                continue  # Attestations
            label = "{}/{}".format(plat.get("os", "?"), plat.get("architecture", "?"))
            if plat.get("variant"):
                label += "/" + plat["variant"]
            platforms.append(label)
            if label == "linux/amd64":
                chosen = m
        if chosen is None:
            return None, platforms
        child = read_blob(base, chosen.get("digest"))
        if not child:
            return None, platforms  # Plattform nicht lokal gecacht
        doc = child
    try:
        size = doc.get("config", {}).get("size", 0) + sum(l.get("size", 0) for l in doc.get("layers", []))
    except Exception:
        size = None
    return size, platforms


def scan_registry(volume):
    base = os.path.join(REGISTRY_ROOT, volume, "docker", "registry", "v2")
    repos_root = os.path.join(base, "repositories")
    images = []
    if not os.path.isdir(repos_root):
        return images
    for dirpath, dirnames, _files in os.walk(repos_root):
        if "_manifests" not in dirnames:
            continue
        repo = os.path.relpath(dirpath, repos_root).replace(os.sep, "/")
        tags_dir = os.path.join(dirpath, "_manifests", "tags")
        tags = []
        if os.path.isdir(tags_dir):
            for tag in sorted(os.listdir(tags_dir)):
                link = os.path.join(tags_dir, tag, "current", "link")
                try:
                    with open(link, "r", encoding="utf-8") as f:
                        digest = f.read().strip()
                    cached_at = os.stat(link).st_mtime
                except OSError:
                    continue
                size, platforms = manifest_info(base, digest)
                tags.append({"tag": tag, "size": size, "platforms": platforms,
                             "cached_at": epoch_iso(cached_at)})
        images.append({"repo": repo, "tags": tags})
        dirnames[:] = [d for d in dirnames if not d.startswith("_")]
    images.sort(key=lambda i: i["repo"])
    return images


def docker_logs(name, st):
    """Gibt neue Logzeilen (Zeitstempel, Text) seit dem letzten Lauf zurueck."""
    cid = run(["docker", "inspect", "-f", "{{.Id}}", name]).strip()
    if not cid:
        return []
    if st.get("cid") != cid:
        st["cid"] = cid
        st["last"] = ""
    cmd = ["docker", "logs", "-t"]
    if st.get("last"):
        cmd += ["--since", st["last"]]
    cmd.append(name)
    lines = []
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        for raw in proc.stdout:
            ts, _, rest = raw.rstrip("\n").partition(" ")
            if st.get("last") and ts <= st["last"]:
                continue
            st["last"] = max(st.get("last", ""), ts)
            lines.append((ts, rest))
        proc.wait(timeout=30)
    except Exception:
        pass
    return lines


def client_ip(addr):
    return addr.rsplit(":", 1)[0].strip("[]") if ":" in addr else addr


def update_registry_usage(reg, st):
    use = st.setdefault("usage", {"requests": 0, "pulls": 0, "bytes": 0, "last_access": None,
                                  "clients": {}, "repos": {}})
    recent = st.setdefault("recent", {})
    now = time.time()
    for key in [k for k, v in recent.items() if now - v > DEDUP_SECONDS * 2]:
        del recent[key]

    for ts, line in docker_logs(reg["container"], st):
        if 'msg="response completed"' not in line:
            continue
        kv = {m.group(1): (m.group(2) if m.group(2) is not None else m.group(3)) for m in RE_KV.finditer(line)}
        m = RE_V2.match(kv.get("http.request.uri", ""))
        if not m or kv.get("http.response.status") not in ("200", "206", "304"):
            continue
        method = kv.get("http.request.method", "")
        repo, kind, ref = m.group(1), m.group(2), m.group(3)
        ip = client_ip(kv.get("http.request.remoteaddr", "?"))
        written = int(kv.get("http.response.written", "0") or 0)
        r = use["repos"].setdefault(repo, {"pulls": 0, "bytes": 0, "last": None})

        use["requests"] += 1
        use["last_access"] = r["last"] = ts[:19] + "Z"
        if method == "GET":
            use["bytes"] += written
            r["bytes"] += written
        if kind == "manifests" and not ref.startswith("sha256:") and method in ("GET", "HEAD"):
            key = "{}|{}|{}".format(ip, repo, ref)
            try:
                tsec = datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
            except ValueError:
                tsec = now
            if tsec - recent.get(key, 0) > DEDUP_SECONDS:
                use["pulls"] += 1
                r["pulls"] += 1
                use["clients"][ip] = use["clients"].get(ip, 0) + 1
            recent[key] = tsec
    if len(use["clients"]) > MAX_CLIENTS:
        top = sorted(use["clients"].items(), key=lambda kv: -kv[1])[:MAX_CLIENTS]
        use["clients"] = dict(top)
    return use


def collect_registries(cfg, state, containers):
    result = []
    for reg in cfg.get("registries", []):
        entry = {k: reg.get(k) for k in ("id", "name", "port", "upstream", "mode", "description", "example", "badge", "url")}
        if reg.get("mode") == "external":
            result.append(entry)
            continue
        st = state.setdefault("registries", {}).setdefault(reg["id"], {})
        c = containers.get(reg["container"], {})
        entry["status"] = c.get("State", "missing")
        entry["status_text"] = c.get("Status", "nicht vorhanden")
        entry["online"] = c.get("State") == "running"
        entry["storage_bytes"] = dir_size(os.path.join(REGISTRY_ROOT, reg["volume"]))
        try:
            entry["images"] = scan_registry(reg["volume"])
        except Exception as exc:
            entry["images"] = []
            entry["error"] = str(exc)
        use = update_registry_usage(reg, st) if c else st.get("usage", {})
        entry["usage"] = {
            "requests": use.get("requests", 0), "pulls": use.get("pulls", 0),
            "bytes_served": use.get("bytes", 0), "last_access": use.get("last_access"),
            "clients": [{"ip": ip, "pulls": n} for ip, n in sorted(use.get("clients", {}).items(), key=lambda kv: -kv[1])],
        }
        repo_use = use.get("repos", {})
        for img in entry["images"]:
            ru = repo_use.get(img["repo"], {})
            img["pulls"] = ru.get("pulls", 0)
            img["bytes_served"] = ru.get("bytes", 0)
            img["last_pull"] = ru.get("last")
        result.append(entry)
    return result


# ------------------------------------------------------------------- APT ----

def collect_apt(cfg, state):
    apt = cfg.get("apt", {})
    st = state.setdefault("apt", {"offset": 0, "in_bytes": 0, "out_bytes": 0, "in_count": 0, "out_count": 0,
                                  "last_access": None})
    try:
        size = os.path.getsize(APT_LOG)
        if size < st["offset"]:
            st["offset"] = 0  # Log rotiert
        with open(APT_LOG, "rb") as f:
            f.seek(st["offset"])
            for raw in f:
                if not raw.endswith(b"\n"):
                    break  # unvollstaendige Zeile beim naechsten Lauf lesen
                st["offset"] += len(raw)
                parts = raw.decode("utf-8", errors="replace").rstrip("\n").split("|", 4)
                if len(parts) < 5 or not parts[2].isdigit():
                    continue
                if parts[1] == "I":
                    st["in_bytes"] += int(parts[2])
                    st["in_count"] += 1
                elif parts[1] == "O":
                    st["out_bytes"] += int(parts[2])
                    st["out_count"] += 1
                    try:
                        st["last_access"] = epoch_iso(int(parts[0]))
                    except ValueError:
                        pass
    except OSError:
        pass
    served, fetched = st["out_bytes"], st["in_bytes"]
    saved = max(served - fetched, 0)
    online = run(["systemctl", "is-active", "apt-cacher-ng"]).strip() == "active"
    return {
        "name": "APT-Cacher-NG", "port": apt.get("port"), "online": online,
        "storage_bytes": dir_size(APT_CACHE) if os.path.isdir(APT_CACHE) else 0,
        "bytes_served": served, "bytes_fetched": fetched, "bytes_saved": saved,
        "saved_ratio": round(saved / served, 4) if served else 0,
        "requests": st["out_count"], "last_access": st["last_access"],
    }


# ------------------------------------------------------------- Artefakte ----

def describe_artifact(name):
    for pattern, text in ARTIFACT_INFO:
        if re.search(pattern, name):
            return text
    return "Cluster-Komponente"


def collect_artifacts(cfg, state, containers):
    acfg = cfg.get("artifacts", {})
    cname = acfg.get("container", "artifact-cache")
    st = state.setdefault("artifacts", {})
    use = st.setdefault("usage", {"files": {}, "requests": 0, "bytes": 0, "last_access": None})
    c = containers.get(cname, {})
    if c:
        for ts, line in docker_logs(cname, st):
            m = RE_NGINX.match(line)
            if not m:
                continue
            _ip, method, path, status, sent = m.groups()
            name = os.path.basename(path.split("?")[0])
            if method != "GET" or status not in ("200", "206") or not name or name in HIDDEN_ARTIFACTS:
                continue
            f = use["files"].setdefault(name, {"downloads": 0, "bytes": 0, "last": None})
            f["downloads"] += 1
            f["bytes"] += int(sent)
            f["last"] = ts[:19] + "Z"
            use["requests"] += 1
            use["bytes"] += int(sent)
            use["last_access"] = ts[:19] + "Z"

    expected = set(acfg.get("expected", []))
    files, present = [], set()
    if os.path.isdir(ARTIFACT_DIR):
        for name in sorted(os.listdir(ARTIFACT_DIR)):
            path = os.path.join(ARTIFACT_DIR, name)
            if name in HIDDEN_ARTIFACTS or not os.path.isfile(path):
                continue
            present.add(name)
            u = use["files"].get(name, {})
            files.append({"name": name, "description": describe_artifact(name), "size": os.path.getsize(path),
                          "modified": epoch_iso(os.path.getmtime(path)),
                          "status": "current" if (not expected or name in expected) else "stale",
                          "downloads": u.get("downloads", 0), "bytes_served": u.get("bytes", 0),
                          "last_download": u.get("last")})
    for name in sorted(expected - present):
        files.append({"name": name, "description": describe_artifact(name), "size": None, "modified": None,
                      "status": "missing", "downloads": use["files"].get(name, {}).get("downloads", 0),
                      "bytes_served": 0, "last_download": None})
    return {"name": "HTTP Artefakt-Server", "port": acfg.get("port"), "online": c.get("State") == "running",
            "storage_bytes": sum(f["size"] or 0 for f in files), "files": files,
            "requests": use["requests"], "bytes_served": use["bytes"], "last_access": use["last_access"]}


# ------------------------------------------------------------------ Main ----

def docker_containers():
    out = {}
    for line in run(["docker", "ps", "-a", "--format", "{{json .}}"]).splitlines():
        try:
            c = json.loads(line)
            out[c["Names"]] = c
        except (ValueError, KeyError):
            pass
    return out


def collect_once():
    cfg = load_json(CONFIG, {})
    state = load_json(STATE, {})
    state.setdefault("since", now_iso())
    containers = docker_containers()

    disk = shutil.disk_usage("/srv")
    stats = {
        "generated": now_iso(),
        "since": state["since"],
        "title": cfg.get("title", "WSLC Cluster Cache & Registry Hub"),
        "ttl_hours": cfg.get("ttl_hours"),
        "disk": {"total": disk.total, "used": disk.used, "free": disk.free},
        "registries": collect_registries(cfg, state, containers),
        "apt": collect_apt(cfg, state),
        "artifacts": collect_artifacts(cfg, state, containers),
    }

    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    for path, data in ((STATE, state), (OUT, stats)):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    return stats


def main():
    interval = 0
    if "--loop" in sys.argv:
        idx = sys.argv.index("--loop")
        interval = int(sys.argv[idx + 1]) if idx + 1 < len(sys.argv) else 30
    while True:
        try:
            collect_once()
        except Exception as exc:  # Dienst darf nie wegen eines Einzelfehlers sterben
            print("hub-stats Fehler:", exc, file=sys.stderr, flush=True)
        if not interval:
            break
        time.sleep(interval)


if __name__ == "__main__":
    main()
