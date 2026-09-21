#!/bin/bash
# ============================================================================
#  registry-mirrors.sh
#
#  Hilfsfunktionen, die den WSLC-k8s-Stack an den lokalen Registry-Cache binden.
#
#  Verwendung: entweder in setup-nodes.sh einbinden
#      source "$(dirname "$0")/registry-mirrors.sh"
#  oder den Inhalt direkt in setup-nodes.sh einfuegen.
#
#  Erwartete Umgebungsvariablen (werden von create-cluster.ps1 aus
#  cluster-config.registry.ps1 durchgereicht):
#
#      REGISTRY_ENABLE          true|false
#      REGISTRY_HOST            registry.local
#      REGISTRY_IP              z.B. 172.28.128.1
#      REGISTRY_PORT_DOCKERHUB  5000
#      REGISTRY_PORT_K8S        5001
#      REGISTRY_PORT_GHCR       5002
#      REGISTRY_PORT_NVCR       5003
#      REGISTRY_PORT_LOCAL      5010
#      APT_PROXY                http://registry.local:3142
#      ARTIFACT_PROXY           http://registry.local:8080
# ============================================================================

REGISTRY_ENABLE="${REGISTRY_ENABLE:-false}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.local}"
REGISTRY_IP="${REGISTRY_IP:-}"
REGISTRY_PORT_DOCKERHUB="${REGISTRY_PORT_DOCKERHUB:-5000}"
REGISTRY_PORT_K8S="${REGISTRY_PORT_K8S:-5001}"
REGISTRY_PORT_GHCR="${REGISTRY_PORT_GHCR:-5002}"
REGISTRY_PORT_NVCR="${REGISTRY_PORT_NVCR:-5003}"
REGISTRY_PORT_LOCAL="${REGISTRY_PORT_LOCAL:-5010}"
APT_PROXY="${APT_PROXY:-}"
ARTIFACT_PROXY="${ARTIFACT_PROXY:-}"

# ----------------------------------------------------------------------------
# registry_available
#
# Prueft einmalig, ob der Cache erreichbar ist. Ist er es nicht, wird der
# gesamte Mirror-Pfad deaktiviert und der Stack laeuft wie bisher direkt gegen
# die Upstreams weiter. Der Cache darf nie zum Single Point of Failure werden.
# ----------------------------------------------------------------------------
registry_available() {
    [ "$REGISTRY_ENABLE" = "true" ] || return 1

    check_ip() {
        local test_ip="$1"
        local code
        code=$(curl -4 -sS -m 3 -o /dev/null -w '%{http_code}' \
            "http://${test_ip}:${REGISTRY_PORT_DOCKERHUB}/v2/" 2>/dev/null || echo 000)
        echo "$code"
        case "$code" in
            200|401) return 0 ;;
            *) return 1 ;;
        esac
    }

    local code="000"
    if [ -n "$REGISTRY_IP" ]; then
        code=$(check_ip "$REGISTRY_IP") || true
    fi

    # Fallback: Falls die konfigurierte IP nicht erreichbar ist, Default-Gateway ermitteln
    if [ "$code" != "200" ] && [ "$code" != "401" ]; then
        local gw
        gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
        if [ -n "$gw" ] && [ "$gw" != "$REGISTRY_IP" ]; then
            echo "Pruefe Default-Gateway ${gw} als Registry-IP..."
            local gw_code
            gw_code=$(check_ip "$gw") || true
            if [ "$gw_code" = "200" ] || [ "$gw_code" = "401" ]; then
                echo "Registry-Cache dynamisch ueber Default-Gateway ${gw} gefunden."
                REGISTRY_IP="$gw"
                code="$gw_code"
            fi
        fi
    fi

    case "$code" in
        200|401)
            echo "Registry-Cache erreichbar unter ${REGISTRY_IP}:${REGISTRY_PORT_DOCKERHUB} (HTTP ${code})."
            return 0
            ;;
        *)
            echo "WARNUNG: Registry-Cache nicht erreichbar (HTTP ${code}). Verwende direkte Upstreams."
            REGISTRY_ENABLE=false
            return 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# registry_add_hosts_entry <ziel>
#
# Traegt registry.local in /etc/hosts ein.
#   registry_add_hosts_entry vm              -> in der Session-VM
#   registry_add_hosts_entry <containername> -> im Node-Container
# ----------------------------------------------------------------------------
registry_add_hosts_entry() {
    local target="$1"
    local line="${REGISTRY_IP}  ${REGISTRY_HOST}"

    if [ "$target" = "vm" ]; then
        grep -q "[[:space:]]${REGISTRY_HOST}\$" /etc/hosts 2>/dev/null \
            || echo "$line" >> /etc/hosts
    else
        nerdctl exec "$target" sh -c \
            "grep -q '[[:space:]]${REGISTRY_HOST}\$' /etc/hosts || echo '${line}' >> /etc/hosts"
    fi
}

# ----------------------------------------------------------------------------
# registry_configure_vm
#
# Konfiguriert den nerdctl-Client der Session-VM, damit schon der Pull des
# kindest/node-Images ueber den Cache laeuft.
#
# Kein containerd-Neustart noetig: nerdctl loest hosts.toml clientseitig auf.
# Deshalb muessen die Pull-Aufrufe in setup-nodes.sh die Option
#   --hosts-dir=/etc/containerd/certs.d
# tragen (siehe REGISTRY.md, Patch 2).
# ----------------------------------------------------------------------------
registry_configure_vm() {
    registry_available || return 0

    registry_add_hosts_entry vm

    mkdir -p /etc/containerd/certs.d/docker.io
    cat > /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://registry-1.docker.io"

[host."http://${REGISTRY_HOST}:${REGISTRY_PORT_DOCKERHUB}"]
  capabilities = ["pull", "resolve"]
EOF

    echo "Session-VM: docker.io-Mirror konfiguriert."
}

# ----------------------------------------------------------------------------
# registry_configure_node <containername>
#
# Schreibt die hosts.toml fuer alle vier Upstreams plus die eigene Registry in
# einen Node-Container und startet dessen containerd neu.
#
# WICHTIG: Muss VOR 'kubeadm init' bzw. 'kubeadm join' laufen. Sobald das
# Kubelet startet, zieht es Images, und dann ist es zu spaet.
# ----------------------------------------------------------------------------
registry_configure_node() {
    local node="$1"
    [ "$REGISTRY_ENABLE" = "true" ] || return 0

    registry_add_hosts_entry "$node"

    _write_mirror() {
        local upstream_host="$1" upstream_url="$2" port="$3"
        nerdctl exec "$node" mkdir -p "/etc/containerd/certs.d/${upstream_host}"
        nerdctl exec -i "$node" tee "/etc/containerd/certs.d/${upstream_host}/hosts.toml" >/dev/null <<EOF
server = "${upstream_url}"

[host."http://${REGISTRY_HOST}:${port}"]
  capabilities = ["pull", "resolve"]
EOF
    }

    _write_mirror docker.io       https://registry-1.docker.io "$REGISTRY_PORT_DOCKERHUB"
    _write_mirror registry.k8s.io https://registry.k8s.io      "$REGISTRY_PORT_K8S"
    _write_mirror ghcr.io         https://ghcr.io              "$REGISTRY_PORT_GHCR"
    _write_mirror nvcr.io         https://nvcr.io              "$REGISTRY_PORT_NVCR"

    # Eigene Registry: laeuft ueber HTTP, deshalb ein expliziter Eintrag.
    # Ein 'insecure-registry'-Flag ist bei diesem Mechanismus nicht noetig.
    nerdctl exec "$node" mkdir -p "/etc/containerd/certs.d/${REGISTRY_HOST}:${REGISTRY_PORT_LOCAL}"
    nerdctl exec -i "$node" tee "/etc/containerd/certs.d/${REGISTRY_HOST}:${REGISTRY_PORT_LOCAL}/hosts.toml" >/dev/null <<EOF
server = "http://${REGISTRY_HOST}:${REGISTRY_PORT_LOCAL}"

[host."http://${REGISTRY_HOST}:${REGISTRY_PORT_LOCAL}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

    # kindest/node setzt config_path bereits, aber nicht jede Image-Variante tut das.
    if ! nerdctl exec "$node" grep -q 'config_path *= *"/etc/containerd/certs.d"' /etc/containerd/config.toml 2>/dev/null; then
        echo "  config_path fehlt in ${node}, wird ergaenzt."
        nerdctl exec "$node" sh -c 'cat >> /etc/containerd/config.toml <<EOF

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
EOF'
    fi

    nerdctl exec "$node" systemctl restart containerd

    # Warten, bis containerd wieder ansprechbar ist.
    local i
    for i in $(seq 1 30); do
        if nerdctl exec "$node" ctr version >/dev/null 2>&1; then
            echo "  ${node}: Registry-Mirror aktiv."
            return 0
        fi
        sleep 1
    done
    echo "  WARNUNG: containerd in ${node} nach Neustart nicht ansprechbar."
}

# ----------------------------------------------------------------------------
# registry_configure_apt <containername>
#
# Setzt den apt-Proxy. Muss vor jedem 'apt-get update' im Node laufen,
# also in setup-nodes.sh vor der NVIDIA-Toolkit-Installation und in
# update-nodes.sh vor dem Upgrade-Block.
# ----------------------------------------------------------------------------
registry_configure_apt() {
    local node="$1"
    [ "$REGISTRY_ENABLE" = "true" ] || return 0
    [ -n "$APT_PROXY" ] || return 0

    nerdctl exec "$node" sh -c "cat > /etc/apt/apt.conf.d/01proxy <<EOF
Acquire::http::Proxy \"${APT_PROXY}\";
Acquire::https::Proxy \"${APT_PROXY}\";
Acquire::Retries \"3\";
EOF"
    echo "  ${node}: apt-Proxy ${APT_PROXY} gesetzt."
}

# ----------------------------------------------------------------------------
# registry_artifact_url <dateiname> <fallback-url>
#
# Liefert die Cache-URL, wenn der Artefakt-Cache die Datei vorhaelt,
# sonst die Original-URL.
# ----------------------------------------------------------------------------
registry_artifact_url() {
    local filename="$1" fallback="$2"

    if [ "$REGISTRY_ENABLE" = "true" ] && [ -n "$ARTIFACT_PROXY" ]; then
        local code
        code=$(curl -4 -sS -m 4 -o /dev/null -w '%{http_code}' -I \
            "${ARTIFACT_PROXY}/${filename}" 2>/dev/null || echo 000)
        if [ "$code" = "200" ]; then
            echo "${ARTIFACT_PROXY}/${filename}"
            return 0
        fi
    fi
    echo "$fallback"
}
