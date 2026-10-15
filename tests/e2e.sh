#!/usr/bin/env bash
# Cemal.cloud k8s-debloat | end-to-end test on a disposable CI VM (root)
#
#   1. k3s-minimal-install.sh installs a real k3s node with the minimal config
#   2. k8s-cleanup.sh finds exactly the right objects in dry-run, deletes them
#      with --apply, and finds nothing on the next run
#   3. --waste finds a deployment that reserves 500m / 256Mi and uses ~0
#   4. --install-plugin makes it work as "kubectl debloat"
#   5. k3s uninstalls cleanly (after --apply and a repeat run)
#
# Do not run this on a machine you care about.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

FAILS=0; PASSES=0
pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASSES=$((PASSES + 1)); }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=e2e::$*"; return 0; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
# CI logs are not always reachable: say where an unexpected failure happened.
stopped() { local rc=$?; [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=e2e stopped::line $1 (exit $rc): $2"; return 0; }
trap 'stopped "$LINENO" "$BASH_COMMAND"' ERR
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k() { k3s kubectl "$@"; }
IMG=registry.k8s.io/e2e-test-images/busybox:1.36.1-1

# ---------------------------------------------------------------- 1. install
group "k3s-minimal-install.sh"
./k3s-minimal-install.sh --tls-san 127.0.0.1
endgroup
check "config.yaml is 0600" test "$(stat -c %a /etc/rancher/k3s/config.yaml)" = 600
check "kubeconfig is 0600" test "$(stat -c %a /etc/rancher/k3s/k3s.yaml)" = 600
check "node is Ready" bash -c "k3s kubectl get nodes --no-headers | grep -q ' Ready'"
# k3s creates the add-on Deployments shortly after the node is Ready; "kubectl wait" fails at once if they do not exist yet.
for _ in $(seq 1 60); do k -n kube-system get deploy coredns metrics-server local-path-provisioner >/dev/null 2>&1 && break; sleep 3; done
check "coredns, metrics-server, local-path available" \
  k3s kubectl -n kube-system wait --for=condition=Available deploy/coredns deploy/metrics-server deploy/local-path-provisioner --timeout=300s
check "traefik not installed" bash -c "! k3s kubectl -n kube-system get deploy traefik"
check "no servicelb daemonsets" bash -c "! k3s kubectl get ds -A -o name | grep -q svclb"
check "no helm-install jobs" bash -c "! k3s kubectl get jobs -A -o name | grep -q helm-install"
check "secrets encryption enabled" bash -c "k3s secrets-encrypt status | grep -q 'Encryption Status: Enabled'"
check "kubectl top works (metrics-server)" bash -c "for i in \$(seq 1 30); do k3s kubectl top node >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1"

K3S_VERSION="$(k3s --version | head -n1 | awk '{print $3}')"
SYS_PODS="$(k -n kube-system get pods --no-headers | awk '{print $1}' | sed -E 's/-[a-z0-9]+(-[a-z0-9]+)?$//' | sort -u | xargs)"
echo "k3s $K3S_VERSION, kube-system: $SYS_PODS"

# ---------------------------------------------------------------- 2. fixtures
group "fixtures"
k create ns e2e
k create ns empty-ns
k -n e2e create configmap app-cfg --from-literal=a=1
k -n e2e create configmap old-cfg --from-literal=a=1
k -n e2e create secret generic app-sec --from-literal=p=1
k -n e2e create secret generic old-sec --from-literal=p=1
cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata: {name: app, namespace: e2e}
spec:
  containers:
  - name: c
    image: registry.k8s.io/pause:3.9
    envFrom: [{configMapRef: {name: app-cfg}}]
    env: [{name: P, valueFrom: {secretKeyRef: {name: app-sec, key: p}}}]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: orphan, namespace: e2e}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}, storageClassName: manual}
---
apiVersion: v1
kind: PersistentVolume
metadata: {name: e2e-pv-released}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath: {path: /tmp/e2e-pv}
  claimRef: {namespace: e2e, name: gone, uid: 11111111-2222-3333-4444-555555555555}
EOF
k -n e2e run completed --image=$IMG --restart=Never --command -- true
k -n e2e run failed --image=$IMG --restart=Never --command -- false
k -n e2e create job job-old --image=$IMG -- true
k -n e2e create cronjob nightly --image=$IMG --schedule="0 3 * * *" -- true
k -n e2e create job cron-old --from=cronjob/nightly
k -n e2e create deployment web --image=registry.k8s.io/pause:3.9 --replicas=0
k -n e2e create deployment hog --image=registry.k8s.io/pause:3.9
k -n e2e set resources deployment/hog --requests=cpu=500m,memory=256Mi
for t in 3.8 3.7 3.6; do
  k -n e2e set image deployment/web pause=registry.k8s.io/pause:$t
  k -n e2e rollout status deployment/web --timeout=60s
done
for v in 1 2 3 4; do
  k -n e2e create secret generic sh.helm.release.v1.myrel.v$v --type=helm.sh/release.v1 --from-literal=release=x
  k -n e2e label secret sh.helm.release.v1.myrel.v$v owner=helm name=myrel version=$v status=superseded
done
k -n e2e wait --for=jsonpath='{.status.phase}'=Succeeded pod/completed --timeout=300s
k -n e2e wait --for=jsonpath='{.status.phase}'=Failed pod/failed --timeout=300s
k -n e2e wait --for=condition=complete job/job-old job/cron-old --timeout=300s
k -n e2e wait --for=condition=Ready pod/app --timeout=300s
k -n e2e rollout status deployment/hog --timeout=300s
for _ in $(seq 1 30); do
  [[ "$(k get pv e2e-pv-released -o jsonpath='{.status.phase}')" == Released ]] && break; sleep 2
done
echo "waiting 75 s so job-old is older than --older-than 60s"; sleep 75
k -n e2e create job job-new --image=$IMG -- true
k -n e2e wait --for=condition=complete job/job-new --timeout=300s
k -n e2e get pods,jobs,rs,pvc; k get pv
endgroup

# ---------------------------------------------------------------- 3. cleanup dry run
group "k8s-cleanup.sh (dry run)"
DRY="$(./k8s-cleanup.sh -n e2e --older-than 60s 2>&1)"; echo "$DRY"
endgroup
has()  { grep -qF -- "$1" <<<"$DRY"; }
hasnt(){ ! grep -qF -- "$1" <<<"$DRY"; }
check "dry run: Succeeded pod"            has "would delete pod e2e/completed"
check "dry run: Failed pod"               has "would delete pod e2e/failed"
check "dry run: running pod kept"         hasnt "pod e2e/app"
check "dry run: old Job"                  has "would delete job e2e/job-old"
check "dry run: new Job kept"             hasnt "job e2e/job-new"
check "dry run: CronJob-owned Job kept"   hasnt "job e2e/cron-old"
check "dry run: 2 of 4 ReplicaSets"       test "$(grep -c 'would delete replicaset e2e/web-' <<<"$DRY")" = 2
check "dry run: Released PV reported"     has "e2e-pv-released  Released  Retain"
check "report: unmounted PVC"             has "e2e/orphan"
check "report: unused ConfigMap"          has "configmap e2e/old-cfg"
check "report: used ConfigMap not listed" hasnt "configmap e2e/app-cfg"
check "report: unused Secret"             has "e2e/old-sec"
check "report: used Secret not listed"    hasnt "e2e/app-sec"
check "report: Helm history"              has "e2e/myrel: 4 revisions stored"
ALL="$(./k8s-cleanup.sh 2>&1)"
check "report: empty namespace (all-namespace run)" grep -qF "namespace empty-ns" <<<"$ALL"
check "dry run deleted nothing" k -n e2e get pod completed

# ---------------------------------------------------------------- 4. waste report
echo "waiting for metrics of the hog pod"
for _ in $(seq 1 36); do k -n e2e top pod -l app=hog --no-headers 2>/dev/null | grep -q hog && break; sleep 5; done
group "k8s-cleanup.sh --waste"
WASTE="$(./k8s-cleanup.sh --waste 2>&1)"; echo "$WASTE"
endgroup
FIRST="$(grep -A1 'WORKLOAD' <<<"$WASTE" | tail -n1)"
check "waste: hog deployment is the top idle reservation" grep -q 'e2e/deploy/hog .* 500m' <<<"$FIRST"
check "waste: hog was measured (not ?)" bash -c '! grep -q "?" <<<"$1"' _ "$FIRST"
check "waste: totals printed" grep -q 'idle reserved : CPU' <<<"$WASTE"
check "waste: pod without requests listed" grep -q 'no requests .*e2e/pod/app' <<<"$WASTE"
check "waste: system workloads included (all namespaces)" grep -q 'kube-system/deploy/coredns' <<<"$WASTE"
WNS="$(./k8s-cleanup.sh --waste -n e2e 2>&1)"
check "waste -n e2e: other namespaces left out" bash -c '! grep -q kube-system <<<"$1"' _ "$WNS"
check "waste deleted nothing" k -n e2e get pod completed
IDLE_LINE="$(grep 'idle reserved' <<<"$WASTE" | sed 's/^ *//')"
REQ_LINE="$(grep 'requested     :' <<<"$WASTE" | sed 's/^ *//')"

# ---------------------------------------------------------------- 5. kubectl plugin
./k8s-cleanup.sh --install-plugin
check "plugin installed" test -x /usr/local/bin/kubectl-debloat
KC=kubectl; command -v kubectl >/dev/null || KC="k3s kubectl"
check "kubectl sees the plugin" bash -c "$KC plugin list 2>/dev/null | grep -q kubectl-debloat"
PLUG="$($KC debloat -n e2e --older-than 60s 2>&1 || true)"
check "kubectl debloat runs the cleanup" grep -qF "would delete pod e2e/completed" <<<"$PLUG"
check "kubectl debloat --waste" bash -c "$KC debloat --waste -n e2e 2>&1 | grep -q 'e2e/deploy/hog'"

# ---------------------------------------------------------------- 6. apply
group "k8s-cleanup.sh --apply"
./k8s-cleanup.sh -n e2e --older-than 60s --delete-released-pv --skip-reports --apply
endgroup
sleep 5
check "Succeeded pod deleted"     bash -c "! k3s kubectl -n e2e get pod completed"
check "Failed pod deleted"        bash -c "! k3s kubectl -n e2e get pod failed"
check "running pod kept"          k -n e2e get pod app
check "old Job deleted"           bash -c "! k3s kubectl -n e2e get job job-old"
check "new Job kept"              k -n e2e get job job-new
check "CronJob-owned Job kept"    k -n e2e get job cron-old
check "2 ReplicaSets left"        test "$(k -n e2e get rs --no-headers | grep -c '^web-')" = 2
check "Released PV deleted"       bash -c "! k3s kubectl get pv e2e-pv-released"
check "unused ConfigMap NOT deleted (report only)" k -n e2e get configmap old-cfg
check "hog deployment untouched by --apply" k -n e2e get deployment hog

AGAIN="$(./k8s-cleanup.sh -n e2e --older-than 1h --skip-reports 2>&1)"
check "second run finds nothing" grep -q "pods 0  |  jobs 0  |  replicasets 0  |  pv 0" <<<"$AGAIN"
check "--prune-images on the node" ./k8s-cleanup.sh -n e2e --skip-reports --prune-images --apply

# ---------------------------------------------------------------- 7. uninstall
group "uninstall"
/usr/local/bin/k3s-uninstall.sh
endgroup
check "k3s removed" test ! -e /usr/local/bin/k3s
rm -f /usr/local/bin/kubectl-debloat

echo
if [[ $FAILS -gt 0 ]]; then echo "$FAILS check(s) failed, $PASSES passed"; exit 1; fi
echo "All end-to-end checks passed"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::notice title=k3s + cleanup end-to-end::$PASSES checks passed on k3s $K3S_VERSION. kube-system ran only: $SYS_PODS. Cleanup dry run, --apply and repeat run verified against real workloads. Waste report: $REQ_LINE / $IDLE_LINE. kubectl debloat plugin works."
  # the report itself, one notice line per row (header, top rows, totals)
  WREP="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$WASTE" | awk '/WORKLOAD/ {on = 1} on && NF {sub(/^    /, ""); print}' | head -n 12 | sed 's/%/%25/g' | paste -sd '|')"
  echo "::notice title=Waste report::$WREP"
fi
