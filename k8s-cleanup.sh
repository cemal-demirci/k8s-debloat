#!/usr/bin/env bash
# =============================================================================
#  Kubernetes cluster cleanup  |  https://cemal.cloud  |  MIT
#  Source: https://github.com/cemal-demirci/k8s-debloat
#
#  Works on any cluster (k3s, kubeadm, EKS, AKS, GKE...). DRY RUN by default:
#  nothing is deleted until you pass --apply.
#
#  Deletes (with --apply):
#    pods       Succeeded / Failed / Evicted pods
#    jobs       finished Jobs older than --older-than (CronJob-owned skipped,
#               the CronJob history limit manages those)
#    rs         ReplicaSets scaled to 0, keeping the newest --keep-rs per
#               Deployment (rollback history)
#    pv         Released / Failed PersistentVolumes, only with --delete-released-pv
#    images     unused images on THIS node via crictl, only with --prune-images
#
#  Reports only (never deleted, needs a human decision):
#    PVCs not mounted by any pod, ConfigMaps/Secrets not referenced by any
#    pod, empty namespaces, Helm release history beyond --keep-rs revisions
#
#  Usage:
#    ./k8s-cleanup.sh                       # dry run on current context
#    ./k8s-cleanup.sh --apply               # do it
#    ./k8s-cleanup.sh -n media --apply      # one namespace
#    ./k8s-cleanup.sh --context prod --older-than 72h
#
#  Options:
#    --apply                 actually delete (default: dry run)
#    -n, --namespace NS      limit to one namespace (default: all)
#    --context CTX           kubeconfig context
#    --older-than DUR        age for finished Jobs: 30m, 12h, 7d (default: 24h)
#    --keep-rs N             old ReplicaSets / Helm revisions to keep (default: 2)
#    --delete-released-pv    also delete Released/Failed PVs (backend data with
#                            reclaimPolicy Retain is NOT deleted)
#    --prune-images          run "crictl rmi --prune" on this node
#    --skip-reports          skip the report-only checks (faster on big clusters)
#    -h, --help              show this help
#
#  Requires: kubectl, jq
# =============================================================================
set -Eeuo pipefail

APPLY=0; NS=""; CONTEXT=""; OLDER="24h"; KEEP_RS=2
DEL_PV=0; PRUNE_IMAGES=0; SKIP_REPORTS=0
KUBECTL="${KUBECTL:-kubectl}"

c_b='\033[1;34m'; c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_d='\033[2m'; c_0='\033[0m'
step() { printf "\n${c_b}==>${c_0} %s\n" "$*"; }
ok()   { printf "    ${c_g}+${c_0} %s\n" "$*"; }
info() { printf "    %s\n" "$*"; }
rep()  { printf "    ${c_d}-${c_0} %s\n" "$*"; }
warn() { printf "    ${c_y}!${c_0} %s\n" "$*" >&2; }
die()  { printf "${c_r}ERROR:${c_0} %s\n" "$*" >&2; exit 1; }
usage() { sed -n '/^#  Usage:/,/^# =====/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)              APPLY=1 ;;
    -n|--namespace)       NS="${2:?}"; shift ;;
    --context)            CONTEXT="${2:?}"; shift ;;
    --older-than)         OLDER="${2:?}"; shift ;;
    --keep-rs)            KEEP_RS="${2:?}"; shift ;;
    --delete-released-pv) DEL_PV=1 ;;
    --prune-images)       PRUNE_IMAGES=1 ;;
    --skip-reports)       SKIP_REPORTS=1 ;;
    -h|--help)            usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

command -v jq >/dev/null || die "jq is required"
if ! command -v "$KUBECTL" >/dev/null; then
  command -v k3s >/dev/null && KUBECTL="k3s kubectl" || die "kubectl not found"
fi
[[ "$KEEP_RS" =~ ^[0-9]+$ ]] || die "--keep-rs must be a number"

to_seconds() {
  local v="$1"
  [[ "$v" =~ ^([0-9]+)([smhd])$ ]] || die "invalid duration: $v (use 30m, 12h, 7d)"
  local n="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in s) echo "$n" ;; m) echo $((n*60)) ;; h) echo $((n*3600)) ;; d) echo $((n*86400)) ;; esac
}
OLDER_S="$(to_seconds "$OLDER")"
NOW="$(date -u +%s)"

# kubectl wrapper with optional context
k() {
  local cmd; read -r -a cmd <<<"$KUBECTL"
  if [[ -n "$CONTEXT" ]]; then "${cmd[@]}" --context "$CONTEXT" "$@"; else "${cmd[@]}" "$@"; fi
}
scope() { if [[ -n "$NS" ]]; then echo "-n $NS"; else echo "-A"; fi; }

CTX_NAME="${CONTEXT:-$(k config current-context 2>/dev/null || echo default)}"
printf "${c_b}Cemal.cloud${c_0} | k8s cleanup  context=%s  scope=%s  %s\n" \
  "$CTX_NAME" "${NS:-all namespaces}" "$([[ $APPLY -eq 1 ]] && echo 'MODE=APPLY' || echo 'MODE=dry-run')"
k version --request-timeout=10s >/dev/null 2>&1 || k get --raw /version --request-timeout=10s >/dev/null || die "cannot reach the cluster"

declare -A COUNT=( [pods]=0 [jobs]=0 [rs]=0 [pv]=0 )

# delete_items KIND  then "ns/name" lines on stdin (ns may be empty for cluster-scoped)
delete_items() {
  local kind="$1" key="$2" line ns name
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ns="${line%%/*}"; name="${line#*/}"
    COUNT[$key]=$(( ${COUNT[$key]} + 1 ))
    if [[ $APPLY -eq 1 ]]; then
      if [[ -n "$ns" ]]; then
        k delete "$kind" "$name" -n "$ns" --wait=false >/dev/null 2>&1 && ok "deleted $kind $ns/$name" || warn "failed $kind $ns/$name"
      else
        k delete "$kind" "$name" --wait=false >/dev/null 2>&1 && ok "deleted $kind $name" || warn "failed $kind $name"
      fi
    else
      info "would delete $kind ${ns:+$ns/}$name"
    fi
  done
}

# Fetch once, reuse.
# shellcheck disable=SC2046
PODS_JSON="$(k get pods $(scope) -o json)"

# ----------------------------------------------------------------------------
# 1. Finished pods
# ----------------------------------------------------------------------------
step "Finished pods (Succeeded / Failed / Evicted)"
delete_items pod pods < <(jq -r '
  .items[]
  | select(.status.phase == "Succeeded" or .status.phase == "Failed")
  | select(.metadata.deletionTimestamp == null)
  | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$PODS_JSON")
[[ ${COUNT[pods]} -eq 0 ]] && info "none"

# ----------------------------------------------------------------------------
# 2. Finished Jobs
# ----------------------------------------------------------------------------
step "Finished Jobs older than $OLDER (not owned by a CronJob)"
# shellcheck disable=SC2046
delete_items job jobs < <(k get jobs $(scope) -o json | jq -r --argjson now "$NOW" --argjson age "$OLDER_S" '
  .items[]
  | select([.metadata.ownerReferences[]? | select(.kind == "CronJob")] | length == 0)
  | select(any(.status.conditions[]?; (.type == "Complete" or .type == "Failed") and .status == "True"))
  | (.status.completionTime // ([.status.conditions[]? | select(.type == "Failed") | .lastTransitionTime] | first)) as $t
  | select($t != null and ($now - ($t | fromdateiso8601)) > $age)
  | "\(.metadata.namespace)/\(.metadata.name)"')
[[ ${COUNT[jobs]} -eq 0 ]] && info "none"

# ----------------------------------------------------------------------------
# 3. Old ReplicaSets
# ----------------------------------------------------------------------------
step "ReplicaSets scaled to 0 (keeping newest $KEEP_RS per Deployment)"
# shellcheck disable=SC2046
delete_items replicaset rs < <(k get rs $(scope) -o json | jq -r --argjson keep "$KEEP_RS" '
  [.items[]
   | select((.spec.replicas // 0) == 0 and (.status.replicas // 0) == 0)
   | . as $rs
   | ([.metadata.ownerReferences[]? | select(.kind == "Deployment") | .name] | first) as $owner
   | select($owner != null)
   | {ns: .metadata.namespace, name: .metadata.name, owner: $owner,
      rev: ((.metadata.annotations["deployment.kubernetes.io/revision"] // "0") | tonumber)}]
  | group_by([.ns, .owner])[]
  | sort_by(.rev) | reverse | .[$keep:][]
  | "\(.ns)/\(.name)"')
[[ ${COUNT[rs]} -eq 0 ]] && info "none"

# ----------------------------------------------------------------------------
# 4. Released / Failed PVs (cluster scoped)
# ----------------------------------------------------------------------------
step "Released / Failed PersistentVolumes"
PV_LIST="$(k get pv -o json | jq -r '.items[] | select(.status.phase == "Released" or .status.phase == "Failed")
  | "\(.metadata.name)\t\(.status.phase)\t\(.spec.persistentVolumeReclaimPolicy)\t\(.spec.capacity.storage // "?")\t\(.spec.claimRef.namespace // "")/\(.spec.claimRef.name // "")"')"
if [[ -z "$PV_LIST" ]]; then
  info "none"
elif [[ $DEL_PV -eq 1 ]]; then
  delete_items pv pv < <(cut -f1 <<<"$PV_LIST" | sed 's|^|/|')
else
  while IFS=$'\t' read -r name phase policy size claim; do
    rep "$name  $phase  $policy  $size  (was $claim)"
  done <<<"$PV_LIST"
  info "use --delete-released-pv to remove these PV objects"
fi

# ----------------------------------------------------------------------------
# 5. Reports
# ----------------------------------------------------------------------------
if [[ $SKIP_REPORTS -eq 0 ]]; then
  step "Report: PVCs not mounted by any pod"
  # shellcheck disable=SC2046
  PVC_JSON="$(k get pvc $(scope) -o json)"
  unused_pvc="$(jq -r --argjson pods "$PODS_JSON" '
    ([$pods.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | .metadata.namespace as $ns | .spec.volumes[]? | select(.persistentVolumeClaim)
      | "\($ns)/\(.persistentVolumeClaim.claimName)"] | unique) as $used
    | .items[] | "\(.metadata.namespace)/\(.metadata.name)" as $id
    | select(($used | index($id)) == null)
    | "\($id)  \(.status.capacity.storage // "?")  \(.spec.storageClassName // "-")"' <<<"$PVC_JSON")"
  if [[ -n "$unused_pvc" ]]; then while IFS= read -r l; do rep "$l"; done <<<"$unused_pvc"; else info "none"; fi

  step "Report: ConfigMaps / Secrets not referenced by any pod"
  REFS="$(jq -r '
    .items[] | .metadata.namespace as $ns | .spec as $s
    | ( [$s.volumes[]? | (.configMap.name // empty), (.secret.secretName // empty),
          (.projected.sources[]? | (.configMap.name // empty), (.secret.name // empty))]
      + [ ($s.containers[]?, $s.initContainers[]?, $s.ephemeralContainers[]?)
          | (.env[]?.valueFrom | (.configMapKeyRef.name // empty), (.secretKeyRef.name // empty)),
            (.envFrom[]? | (.configMapRef.name // empty), (.secretRef.name // empty)) ]
      + [ $s.imagePullSecrets[]?.name ] )[]
    | "\($ns)/\(.)"' <<<"$PODS_JSON" | sort -u)"
  # shellcheck disable=SC2046
  unused_cm="$(k get configmaps $(scope) -o json | jq -r --arg refs "$REFS" '
    ($refs | split("\n")) as $r
    | .items[] | select(.metadata.name != "kube-root-ca.crt")
    | select(.metadata.namespace != "kube-system" and .metadata.namespace != "kube-public")
    | "\(.metadata.namespace)/\(.metadata.name)" as $id | select(($r | index($id)) == null)
    | "configmap \($id)"')"
  # shellcheck disable=SC2046
  unused_sec="$(k get secrets $(scope) -o json | jq -r --arg refs "$REFS" '
    ($refs | split("\n")) as $r
    | .items[]
    | select(.type != "kubernetes.io/service-account-token" and (.type | startswith("helm.sh/") | not)
             and .type != "kubernetes.io/tls" and .type != "bootstrap.kubernetes.io/token")
    | select(.metadata.namespace != "kube-system" and .metadata.namespace != "kube-public")
    | "\(.metadata.namespace)/\(.metadata.name)" as $id | select(($r | index($id)) == null)
    | "secret    \($id)  (\(.type))"')"
  if [[ -n "$unused_cm$unused_sec" ]]; then
    { [[ -n "$unused_cm" ]] && echo "$unused_cm"; [[ -n "$unused_sec" ]] && echo "$unused_sec"; } | while IFS= read -r l; do rep "$l"; done
    info "note: also used by operators/controllers directly; verify before deleting"
  else
    info "none"
  fi

  if [[ -z "$NS" ]]; then
    step "Report: empty namespaces"
    NS_WITH_STUFF="$( { jq -r '.items[].metadata.namespace' <<<"$PODS_JSON"
                        k get deploy,sts,ds,cronjob,svc,pvc -A -o json \
                          | jq -r '.items[] | select(.metadata.name != "kubernetes" or .metadata.namespace != "default") | .metadata.namespace'
                      } | sort -u)"
    empty_ns="$(k get ns -o json | jq -r --arg used "$NS_WITH_STUFF" '
      ($used | split("\n")) as $u
      | .items[] | .metadata.name as $n
      | select($n != "default" and $n != "kube-system" and $n != "kube-public" and $n != "kube-node-lease")
      | select(($u | index($n)) == null) | $n')"
    if [[ -n "$empty_ns" ]]; then while IFS= read -r l; do rep "namespace $l"; done <<<"$empty_ns"; else info "none"; fi
  fi

  step "Report: Helm release history beyond $KEEP_RS revisions"
  # shellcheck disable=SC2046
  helm_old="$(k get secrets $(scope) -l owner=helm -o json | jq -r --argjson keep "$KEEP_RS" '
    [.items[] | {ns: .metadata.namespace, rel: .metadata.labels.name,
                 ver: ((.metadata.labels.version // "0") | tonumber)}]
    | group_by([.ns, .rel])[]
    | sort_by(.ver) | reverse
    | select(length > $keep)
    | "\(.[0].ns)/\(.[0].rel): \(length) revisions stored (helm upgrade --history-max \($keep))"')"
  if [[ -n "$helm_old" ]]; then while IFS= read -r l; do rep "$l"; done <<<"$helm_old"; else info "none"; fi
fi

# ----------------------------------------------------------------------------
# 6. Node images
# ----------------------------------------------------------------------------
if [[ $PRUNE_IMAGES -eq 1 ]]; then
  step "Unused container images on this node"
  CRICTL=""
  if command -v crictl >/dev/null; then CRICTL="crictl"
  elif command -v k3s >/dev/null; then CRICTL="k3s crictl"; fi
  if [[ -z "$CRICTL" ]]; then
    warn "crictl not found on this host (run this on a node)"
  elif [[ $APPLY -eq 1 ]]; then
    [[ $EUID -eq 0 ]] || die "--prune-images needs root"
    before="$(du -sh /var/lib/rancher/k3s/agent/containerd /var/lib/containerd 2>/dev/null | awk '{print $1}' | head -n1)"
    $CRICTL rmi --prune
    after="$(du -sh /var/lib/rancher/k3s/agent/containerd /var/lib/containerd 2>/dev/null | awk '{print $1}' | head -n1)"
    ok "image store: ${before:-?} -> ${after:-?}"
  else
    info "would run: $CRICTL rmi --prune"
  fi
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
step "Summary ($([[ $APPLY -eq 1 ]] && echo deleted || echo 'would delete'))"
printf "    pods %s  |  jobs %s  |  replicasets %s  |  pv %s\n" \
  "${COUNT[pods]}" "${COUNT[jobs]}" "${COUNT[rs]}" "${COUNT[pv]}"
[[ $APPLY -eq 0 ]] && info "dry run: re-run with --apply to delete"
exit 0
