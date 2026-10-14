#!/usr/bin/env bash
# =============================================================================
#  Minimal k3s install  |  https://cemal.cloud  |  MIT
#  Source: https://github.com/cemal-demirci/k8s-debloat
#
#  A lean k3s node: only what a cluster needs to run your workloads.
#
#  Disabled by default       Why
#  -----------------------   -------------------------------------------------
#  traefik                   bring your own ingress (ingress-nginx, Gateway API)
#  servicelb (klipper-lb)    use MetalLB / cloud LB / hostNetwork instead
#  helm-controller           only needed for HelmChart CRDs (traefik uses it)
#  cloud-controller          bare metal / VMs do not need it
#
#  Kept by default           Why
#  -----------------------   -------------------------------------------------
#  coredns, flannel          cluster DNS and pod network
#  network-policy            NetworkPolicy enforcement (security)
#  metrics-server            kubectl top + HorizontalPodAutoscaler
#  local-storage             local-path PVs for single node setups
#
#  Hardening / hygiene added: secrets encryption at rest, kubeconfig 0600,
#  container log rotation, image GC thresholds, etcd snapshots (HA mode).
#
#  Usage:
#    sudo ./k3s-minimal-install.sh                       # single server
#    sudo ./k3s-minimal-install.sh --cluster-init        # first HA server (etcd)
#    sudo ./k3s-minimal-install.sh --server https://10.0.0.10:6443 --token XXX
#                                                        # extra server (HA)
#    sudo ./k3s-minimal-install.sh --agent --server https://10.0.0.10:6443 --token XXX
#    ./k3s-minimal-install.sh --dry-run                  # print config only
#
#  Options:
#    --agent                 install a worker node (needs --server and --token)
#    --server URL            join an existing cluster
#    --token TOKEN           cluster join token (/var/lib/rancher/k3s/server/token)
#    --cluster-init          start embedded etcd (first server of an HA cluster)
#    --version VER           pin a k3s version, e.g. v1.37.1+k3s1 (default: stable)
#    --tls-san NAME          extra API cert SAN (repeatable): LB IP, DNS name
#    --node-ip IP            node IP to advertise (multi-NIC hosts)
#    --flannel BACKEND       vxlan (default) | wireguard-native | host-gw | none
#    --no-metrics            also disable metrics-server
#    --no-local-storage      also disable local-path-provisioner
#    --keep-traefik          keep traefik
#    --keep-servicelb        keep klipper servicelb
#    --keep-helm-controller  keep the helm controller
#    --config-only           write /etc/rancher/k3s/config.yaml, do not install
#    --dry-run               print the config and installer command, change nothing
#    -h, --help              show this help
# =============================================================================
set -Eeuo pipefail

ROLE="server"; SERVER_URL=""; TOKEN=""; CLUSTER_INIT=0; K3S_VERSION=""
NODE_IP=""; FLANNEL="vxlan"; TLS_SANS=()
NO_METRICS=0; NO_LOCAL=0; KEEP_TRAEFIK=0; KEEP_SVCLB=0; KEEP_HELM=0
CONFIG_ONLY=0; DRY_RUN=0
CONFIG_DIR="${K3S_CONFIG_DIR:-/etc/rancher/k3s}"
CONFIG="$CONFIG_DIR/config.yaml"

c_b='\033[1;34m'; c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_0='\033[0m'
step() { printf "\n${c_b}==>${c_0} %s\n" "$*"; }
ok()   { printf "    ${c_g}+${c_0} %s\n" "$*"; }
warn() { printf "    ${c_y}!${c_0} %s\n" "$*" >&2; }
die()  { printf "${c_r}ERROR:${c_0} %s\n" "$*" >&2; exit 1; }
usage() { sed -n '/^#  Usage:/,/^# =====/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)                ROLE="agent" ;;
    --server)               SERVER_URL="${2:?}"; shift ;;
    --token)                TOKEN="${2:?}"; shift ;;
    --cluster-init)         CLUSTER_INIT=1 ;;
    --version)              K3S_VERSION="${2:?}"; shift ;;
    --tls-san)              TLS_SANS+=( "${2:?}" ); shift ;;
    --node-ip)              NODE_IP="${2:?}"; shift ;;
    --flannel)              FLANNEL="${2:?}"; shift ;;
    --no-metrics)           NO_METRICS=1 ;;
    --no-local-storage)     NO_LOCAL=1 ;;
    --keep-traefik)         KEEP_TRAEFIK=1 ;;
    --keep-servicelb)       KEEP_SVCLB=1 ;;
    --keep-helm-controller) KEEP_HELM=1 ;;
    --config-only)          CONFIG_ONLY=1 ;;
    --dry-run)              DRY_RUN=1 ;;
    -h|--help)              usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ "$ROLE" == "agent" && ( -z "$SERVER_URL" || -z "$TOKEN" ) ]] && die "--agent needs --server and --token"
[[ -n "$SERVER_URL" && -z "$TOKEN" ]] && die "--server needs --token"
[[ $CLUSTER_INIT -eq 1 && -n "$SERVER_URL" ]] && die "--cluster-init is only for the first server"
case "$FLANNEL" in vxlan|wireguard-native|host-gw|none) ;; *) die "invalid --flannel: $FLANNEL" ;; esac
[[ $DRY_RUN -eq 1 || $EUID -eq 0 ]] || die "run as root (sudo), or use --dry-run"

printf "${c_b}Cemal.cloud${c_0} | minimal k3s %s%s\n" "$ROLE" "$([[ $DRY_RUN -eq 1 ]] && echo '  (DRY RUN)')"

# ----------------------------------------------------------------------------
# Build config.yaml
# ----------------------------------------------------------------------------
DISABLE=()
[[ $KEEP_TRAEFIK -eq 0 ]] && DISABLE+=( traefik )
[[ $KEEP_SVCLB   -eq 0 ]] && DISABLE+=( servicelb )
[[ $NO_METRICS   -eq 1 ]] && DISABLE+=( metrics-server )
[[ $NO_LOCAL     -eq 1 ]] && DISABLE+=( local-storage )

yaml_list() { local i; for i in "$@"; do printf '  - "%s"\n' "$i"; done; }

render_config() {
  echo "# Cemal.cloud minimal k3s ($ROLE) - generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Docs: https://docs.k3s.io/installation/configuration"
  [[ -n "$SERVER_URL" ]] && echo "server: \"$SERVER_URL\""
  [[ -n "$TOKEN"      ]] && echo "token: \"$TOKEN\""
  [[ -n "$NODE_IP"    ]] && echo "node-ip: \"$NODE_IP\""

  if [[ "$ROLE" == "server" ]]; then
    [[ $CLUSTER_INIT -eq 1 ]] && echo "cluster-init: true"
    echo "write-kubeconfig-mode: \"0600\""
    echo "secrets-encryption: true"
    echo "disable-cloud-controller: true"
    [[ $KEEP_HELM -eq 0 ]] && echo "disable-helm-controller: true"
    echo "flannel-backend: \"$FLANNEL\""
    if [[ ${#DISABLE[@]} -gt 0 ]]; then echo "disable:"; yaml_list "${DISABLE[@]}"; fi
    if [[ ${#TLS_SANS[@]} -gt 0 ]]; then echo "tls-san:"; yaml_list "${TLS_SANS[@]}"; fi
    if [[ $CLUSTER_INIT -eq 1 || -n "$SERVER_URL" ]]; then
      echo "etcd-snapshot-schedule-cron: \"0 */6 * * *\""
      echo "etcd-snapshot-retention: 12"
    fi
  fi

  echo "kubelet-arg:"
  yaml_list "container-log-max-size=10Mi" "container-log-max-files=3" \
            "image-gc-high-threshold=80" "image-gc-low-threshold=60" \
            "serialize-image-pulls=false"
}

CONFIG_TEXT="$(render_config)"

step "Config ($CONFIG)"
sed 's/^token: .*/token: "<hidden>"/' <<<"$CONFIG_TEXT" | sed 's/^/    /'

INSTALL_ENV=( "INSTALL_K3S_EXEC=$ROLE" )
if [[ -n "$K3S_VERSION" ]]; then INSTALL_ENV+=( "INSTALL_K3S_VERSION=$K3S_VERSION" )
else INSTALL_ENV+=( "INSTALL_K3S_CHANNEL=stable" ); fi

if [[ $DRY_RUN -eq 1 ]]; then
  step "Would run"
  echo "    curl -sfL https://get.k3s.io | ${INSTALL_ENV[*]} sh -"
  exit 0
fi

# ----------------------------------------------------------------------------
# Write config (keep a backup of an existing one)
# ----------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG" ]]; then
  cp -a "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
  warn "existing config backed up"
fi
umask 077
printf '%s\n' "$CONFIG_TEXT" > "$CONFIG"
ok "config written"

[[ $CONFIG_ONLY -eq 1 ]] && { ok "--config-only: done"; exit 0; }

# ----------------------------------------------------------------------------
# Install via the official installer (reads config.yaml automatically)
# ----------------------------------------------------------------------------
command -v curl >/dev/null || die "curl is required"
step "Installing k3s"
curl -sfL https://get.k3s.io | env "${INSTALL_ENV[@]}" sh -

if [[ "$ROLE" == "server" ]]; then
  step "Waiting for the node to become Ready"
  for _ in $(seq 1 60); do
    if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then break; fi
    sleep 2
  done
  k3s kubectl get nodes -o wide || true
  echo
  k3s kubectl get pods -A || true
  echo
  ok "kubeconfig : /etc/rancher/k3s/k3s.yaml (root only)"
  ok "join token : /var/lib/rancher/k3s/server/token"
  if [[ ${#DISABLE[@]} -gt 0 ]]; then ok "disabled   : ${DISABLE[*]}"; fi
  rss="$(ps -o rss= -C k3s-server 2>/dev/null | awk '{s+=$1} END {if (s) printf "%.0f MiB", s/1024}')"
  [[ -n "$rss" ]] && ok "k3s server memory: $rss"
else
  ok "agent installed, check on a server: kubectl get nodes"
fi
ok "uninstall  : /usr/local/bin/k3s-uninstall.sh (agent: k3s-agent-uninstall.sh)"
