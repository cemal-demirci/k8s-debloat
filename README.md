<div align="center">

```
  ____                     _       _                 _
 / ___|___ _ __ ___   __ _| |  ___| | ___  _   _  __| |
| |   / _ \ '_ ` _ \ / _` | | / __| |/ _ \| | | |/ _` |
| |__|  __/ | | | | | (_| | || (__| | (_) | |_| | (_| |
 \____\___|_| |_| |_|\__,_|_(_)___|_|\___/ \__,_|\__,_|
```

# Kubernetes Debloat

**Traefik ve ServiceLB olmadan sade k3s kurulumu ve her cluster için varsayılanı dry-run olan temizlik scripti.**

[![ci](https://github.com/cemal-demirci/k8s-debloat/actions/workflows/ci.yml/badge.svg)](https://github.com/cemal-demirci/k8s-debloat/actions/workflows/ci.yml)
![license](https://img.shields.io/badge/license-MIT-blue)

[cemal.cloud](https://cemal.cloud)

</div>

---

İki araç:

- **`k3s-minimal-install.sh`**: sadece iş yükünüzü çalıştırmak için gerekenlerle sade bir k3s node'u kurar.
- **`k8s-cleanup.sh`**: herhangi bir cluster'da (k3s, kubeadm, EKS, AKS, GKE) birikmiş çöpü bulur. Varsayılanı dry-run'dır.

## İndirme

```bash
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/k8s-debloat/main/k3s-minimal-install.sh
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/k8s-debloat/main/k8s-cleanup.sh
chmod +x k3s-minimal-install.sh k8s-cleanup.sh
```

---

## k3s-minimal-install.sh

```bash
sudo ./k3s-minimal-install.sh                                    # tek server
sudo ./k3s-minimal-install.sh --cluster-init --tls-san 10.0.0.10 # HA: ilk server (embedded etcd)
sudo ./k3s-minimal-install.sh --server https://10.0.0.10:6443 --token <TOKEN>          # HA: ek server
sudo ./k3s-minimal-install.sh --agent --server https://10.0.0.10:6443 --token <TOKEN>  # worker
./k3s-minimal-install.sh --dry-run                               # sadece config'i göster
```

`/etc/rancher/k3s/config.yaml` yazar (varsa önce yedekler) ve resmi `get.k3s.io` kurucusunu çalıştırır. Kurucu bu dosyayı kendisi okur.

### Ne kapatılır, ne kalır

| Kapalı (varsayılan) | Neden | Geri açmak |
|---|---|---|
| traefik | Kendi ingress'inizi getirin (ingress-nginx, Gateway API) | `--keep-traefik` |
| servicelb (klipper-lb) | MetalLB, bulut LB veya hostNetwork kullanın | `--keep-servicelb` |
| helm-controller | Sadece HelmChart CRD'leri için gerekli | `--keep-helm-controller` |
| cloud-controller | Fiziksel sunucu ve VM'de gereksiz | (yok) |

| Açık (varsayılan) | Neden | Kapatmak |
|---|---|---|
| coredns, flannel | Cluster DNS ve pod ağı | `--flannel none` (kendi CNI'niz için) |
| network-policy | NetworkPolicy desteği (güvenlik) | (yok) |
| metrics-server | `kubectl top` ve HPA | `--no-metrics` |
| local-storage | Tek node'da local-path PV | `--no-local-storage` |

**Eklenen sağlamlaştırma:** secrets'lar etcd'de şifreli (`secrets-encryption`), kubeconfig `0600`, container log rotasyonu (10 MiB x 3), image GC eşikleri (%80 / %60), HA modunda 6 saatte bir etcd snapshot (12 adet saklanır).

| Diğer parametreler | |
|---|---|
| `--version v1.37.1+k3s1` | Sürüm sabitle (varsayılan: stable kanal) |
| `--node-ip IP` | Çok NIC'li sunucuda duyurulacak IP |
| `--flannel BACKEND` | `vxlan` (varsayılan), `wireguard-native`, `host-gw`, `none` |
| `--config-only` | Sadece config yazar, kurmaz |

Kaldırmak için: `/usr/local/bin/k3s-uninstall.sh` (agent'ta `k3s-agent-uninstall.sh`).

---

## k8s-cleanup.sh

```bash
./k8s-cleanup.sh                          # dry-run, tüm namespace'ler
./k8s-cleanup.sh --apply                  # uygula
./k8s-cleanup.sh -n media --apply         # tek namespace
./k8s-cleanup.sh --context prod --older-than 72h
sudo ./k8s-cleanup.sh --prune-images --apply   # node üzerinde kullanılmayan image'lar
```

Gereksinim: `kubectl` (veya `k3s kubectl`) ve `jq`.

### Silinenler (`--apply` ile)

| Kaynak | Kural |
|---|---|
| Pod | `Succeeded`, `Failed` veya `Evicted` |
| Job | Bitmiş ve `--older-than`'dan eski (varsayılan 24h). CronJob'a ait olanlar atlanır, onları CronJob'un history limiti yönetir. |
| ReplicaSet | 0'a ölçeklenmiş eski revizyonlar. Her Deployment için en yeni `--keep-rs` kadarı (varsayılan 2) rollback için saklanır. |
| PersistentVolume | `Released` / `Failed` olanlar, sadece `--delete-released-pv` ile. `Retain` politikalı diskteki veri silinmez, sadece PV nesnesi silinir. |
| Image | Node'daki kullanılmayan image'lar, sadece `--prune-images` ile (`crictl rmi --prune`) |

### Sadece raporlananlar

Bunlar asla otomatik silinmez, karar insana kalır:

- Hiçbir pod'un bağlamadığı PVC'ler
- Hiçbir pod'un referans vermediği ConfigMap ve Secret'lar (operatörler bunları doğrudan kullanıyor olabilir)
- İçinde iş yükü olmayan namespace'ler
- `--keep-rs` sayısından fazla revizyon saklayan Helm release'leri

### Test

Her commit'te GitHub Actions'ta uçtan uca çalıştırılır: `k3s-minimal-install.sh` gerçek bir k3s node'u kurar (Traefik, ServiceLB ve helm-install job'larının gelmediği, secrets şifrelemenin açık olduğu, `kubectl top`'un çalıştığı doğrulanır), ardından gerçek iş yükleriyle temizlik scripti dry-run, `--apply` ve tekrar çalıştırma ile test edilir, en sonda k3s kaldırılır.

Ayrıca k3s v1.37 API'sine karşı elle test edildi: bitmiş ve evicted pod'lar, eski ve yeni Job'lar, CronJob'a ait Job, 4 revizyonlu Deployment, Released PV, bağlanmamış PVC, kullanılmayan ConfigMap / Secret, boş namespace ve 4 revizyonlu Helm release. Dry-run, `--apply` ve tekrar çalıştırma (0 değişiklik) doğrulandı.

## Prensipler

1. **Önce göster.** Dry-run modu ile neyin değişeceğini önce görün.
2. **Yedek al.** Değişiklikten önce yedek ve geri alma dosyası yazılır.
3. **Geri alınabilir.** Her değişikliğin geri dönüş yolu var.
4. **Kritik olana dokunma.** Sistemi ayakta tutan parçalar korunur.
5. **Sessiz hata yok.** Kontrol yapılamıyorsa script güvenli tarafta kalır ve durur.

## Sorumluluk

Bu scriptler sistem ayarlarını değiştirir ve yazılım kaldırır. Kendi sorumluluğunuzda kullanın, önce test ortamında deneyin. Kurumsal yönetilen cihazlarda BT ekibinizle konuşmadan çalıştırmayın.

## Diğer Cemal.cloud araçları

| Repo | |
|---|---|
| [`win11-debloat`](https://github.com/cemal-demirci/win11-debloat) | Copilot, Recall, reklam ve telemetriyi kaldıran, her değişikliği geri alınabilir şekilde kaydeden Windows 11 temizliği. |
| [`ubuntu-server-debloat`](https://github.com/cemal-demirci/ubuntu-server-debloat) | snap, telemetri ve gereksiz servisleri kaldırır. Kritik bir paketi etkileyecekse hiçbir şey yapmadan durur. |
| [`ffmpeg-broadcast`](https://github.com/cemal-demirci/ffmpeg-broadcast) | Yayıncılık için sade FFmpeg build'i ve 19 hazır yayın preseti: XDCAM, AVC-Intra, IMX, ProRes, DNxHD, DVB, HLS, SRT. |

## Lisans

[MIT](LICENSE)

---

<details>
<summary><b>English</b></summary>

- **`k3s-minimal-install.sh`**: writes `/etc/rancher/k3s/config.yaml` and runs the official installer. Traefik, ServiceLB, helm-controller and the cloud controller are off; CoreDNS, flannel, NetworkPolicy, metrics-server and local-path stay. Adds secrets encryption at rest, a 0600 kubeconfig, container log rotation, image GC thresholds and etcd snapshots in HA mode. Single server, HA (`--cluster-init`, `--server`) and agents.
- **`k8s-cleanup.sh`**: works on any cluster, dry run by default. With `--apply` it deletes finished / evicted pods, finished Jobs older than `--older-than` (CronJob-owned ones are left to their history limit), scaled-to-zero ReplicaSets beyond `--keep-rs`, and optionally Released PVs and unused node images. Unmounted PVCs, unreferenced ConfigMaps / Secrets, empty namespaces and long Helm histories are only reported.

CI installs a real k3s node with the script, creates workloads, and checks the cleanup dry run, apply and repeat run for every commit.

</details>
