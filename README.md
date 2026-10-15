# Kubernetes Debloat · Cemal.cloud

[![Lisans: MIT](https://img.shields.io/badge/lisans-MIT-blue)](LICENSE)
[![Denetim](https://github.com/cemal-demirci/k8s-debloat/actions/workflows/ci.yml/badge.svg)](https://github.com/cemal-demirci/k8s-debloat/actions)
![k3s](https://img.shields.io/badge/k3s-stable-FFC61C)

**k3s'i ihtiyacınız olanla kurun. Cluster'da biriken çöpü ve boşa ayrılan CPU'yu silmeden önce görün.**

Varsayılan k3s kurulumu Traefik, kendi load balancer'ı ve Helm controller ile gelir. Çoğu kurulumda bunların yerine
ingress-nginx ya da MetalLB kullanılır; varsayılanlar ise boşuna çalışır, 80 ve 443 portlarını tutar. Aylar geçtikçe
de her cluster'da çöp birikir: bitmiş pod'lar, eski job'lar, her deploy'dan kalan ReplicaSet'ler, sahibi silinmiş
diskler.

Bu repoda iki küçük araç var:

- **`k3s-minimal-install.sh`**: resmi k3s kurucusunu sade bir ayarla çalıştırır. Gereksizleri kapatır, secret
  şifrelemeyi ve log rotasyonunu açar.
- **`k8s-cleanup.sh`**: her cluster'da çalışır. Varsayılan olarak **hiçbir şey silmez**, sadece neyin silineceğini
  gösterir. Silmek için `--apply` gerekir. `--waste` ile hangi iş yükünün CPU ve belleği ayırıp kullanmadığını
  listeler. `kubectl debloat` olarak da kurulabilir.

## Kurulum ve kullanım

```bash
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/k8s-debloat/main/k3s-minimal-install.sh
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/k8s-debloat/main/k8s-cleanup.sh
chmod +x k3s-minimal-install.sh k8s-cleanup.sh

sudo ./k3s-minimal-install.sh     # sade bir k3s node
./k8s-cleanup.sh                  # çöpü göster, hiçbir şey silinmez
./k8s-cleanup.sh --apply          # temizle
./k8s-cleanup.sh --waste          # ayrılmış ama boşta duran CPU / bellek
./k8s-cleanup.sh --install-plugin # bundan sonra: kubectl debloat, kubectl debloat --waste
```

## Varsayılan k3s mi, minimal kurulum mu?

| | Varsayılan k3s | k3s-minimal-install |
|---|---|---|
| CoreDNS, flannel, NetworkPolicy | ✅ | ✅ |
| metrics-server (`kubectl top`, otomatik ölçekleme) | ✅ | ✅ (`--no-metrics` ile kapanır) |
| local-path disk | ✅ | ✅ (`--no-local-storage` ile kapanır) |
| Traefik | ✅ | ❌ (`--keep-traefik` ile açılır) |
| ServiceLB | ✅ | ❌ (`--keep-servicelb` ile açılır) |
| Helm controller ve helm-install job'ları | ✅ | ❌ (`--keep-helm-controller` ile açılır) |
| Secret'lar diskte şifreli | ❌ | ✅ |
| Container log ve image temizliği | Varsayılan eşikler | Daha sıkı: 10 MB x 3 log, disk %80'de image temizliği |
| HA kurulumda etcd yedeği | 12 saatte bir, 5 adet saklanır | 6 saatte bir, 12 adet saklanır |

```bash
sudo ./k3s-minimal-install.sh                                                          # tek node
sudo ./k3s-minimal-install.sh --cluster-init --tls-san 10.0.0.10                        # HA: ilk server
sudo ./k3s-minimal-install.sh --server https://10.0.0.10:6443 --token <TOKEN>           # HA: ek server
sudo ./k3s-minimal-install.sh --agent --server https://10.0.0.10:6443 --token <TOKEN>   # worker
./k3s-minimal-install.sh --dry-run                                                      # sadece ayarı göster
```

Diğer seçenekler (`--version`, `--node-ip`, `--flannel` ...) için `--help`. Kaldırmak için `/usr/local/bin/k3s-uninstall.sh`.

## Cluster temizliği

`k8s-cleanup.sh` k3s, kubeadm, EKS, AKS ve GKE'de çalışır. Gereken tek şey `kubectl` (ya da `k3s kubectl`) ve `jq`.

| `--apply` ile silinen | Kural |
|---|---|
| Pod | Tamamlanmış, hata vermiş ya da tahliye edilmiş (Evicted) |
| Job | Bitmiş ve `--older-than` süresinden eski (varsayılan 24 saat). CronJob'lara ait job'lara dokunulmaz, onları CronJob kendisi yönetir. |
| ReplicaSet | Eski deploy'lardan kalanlar. Her Deployment için en yeni 2 tanesi geri dönüş için saklanır (`--keep-rs`). |
| PersistentVolume | Sahibi silinmiş (Released) diskler, yalnızca `--delete-released-pv` ile. Diskteki veri silinmez, sadece Kubernetes kaydı silinir. |
| Image | Node'daki kullanılmayan image'lar, yalnızca `--prune-images` ile |

Şunlar **asla otomatik silinmez**, sadece listelenir; karar sizindir: hiçbir pod'un kullanmadığı PVC'ler, ConfigMap
ve Secret'lar, boş namespace'ler, çok fazla geçmiş saklayan Helm release'leri (eski revizyonların kapladığı yerle
birlikte).

```bash
./k8s-cleanup.sh -n media --apply                  # tek namespace
./k8s-cleanup.sh --context prod --older-than 72h   # başka cluster, farklı süre
sudo ./k8s-cleanup.sh --prune-images --apply       # bu node'daki kullanılmayan image'lar
```

## Boşa ayrılan kaynak: `--waste`

Kubernetes bir pod'u yerleştirirken onun ne kullandığına değil, ne istediğine (`requests`) bakar. 2 CPU isteyip 50m
kullanan bir pod, o 2 CPU'yu başka hiçbir pod'a bırakmaz. Cluster dolu görünür, yeni node eklenir, fatura büyür.

`--waste` metrics-server'dan anlık kullanımı okur ve her iş yükü (Deployment, StatefulSet, DaemonSet, Job) için
istenen ile kullanılanı yan yana koyar. En çok boşa ayıran en üstte çıkar. CI'daki son çalıştırmanın çıktısı:

```
WORKLOAD                                 PODS   CPU req    used    idle   MEM req    used    idle
e2e/deploy/hog                              1      500m      0m    500m     256Mi     0Mi   256Mi
kube-system/deploy/coredns                  1      100m      2m     98m      70Mi    16Mi    54Mi
kube-system/deploy/metrics-server           1      100m      4m     96m      70Mi    23Mi    47Mi

requested     : CPU 700m of 4.0 allocatable (18%), memory 396Mi of 15.6Gi (2%) on 1 node(s)
actually used : CPU 6m (1% of requested), memory 39Mi (10% of requested)
idle reserved : CPU 694m, memory 357Mi  (held for these pods, unavailable to others)
no requests   : 2 workload(s), 2 pod(s): e2e/pod/app, kube-system/deploy/local-path-provisioner  (the scheduler cannot plan for them)
```

`requests` tanımlamamış iş yükleri de ayrıca listelenir; scheduler onlara yer planlayamaz. Bu bir anlık ölçümdür:
bir değeri düşürmeden önce yoğun bir saatte de bakın (`kubectl top pod`). `--waste` hiçbir şey silmez ve değiştirmez.
metrics-server kurulu değilse bunu söyleyip durur.

## kubectl eklentisi

```bash
./k8s-cleanup.sh --install-plugin   # root ise /usr/local/bin, değilse ~/.local/bin altına kubectl-debloat
kubectl debloat -n media            # aynı script, aynı seçenekler
kubectl debloat --waste --context prod
```

Kaldırmak için kurulumun yazdırdığı `kubectl-debloat` dosyasını silmeniz yeterli.

## Ne çalıştırır, nereye dokunur?

- **Kurulum:** `/etc/rancher/k3s/config.yaml` yazar (varsa önce yedekler) ve resmi `get.k3s.io` kurucusunu çalıştırır.
  k3s'i o kurucu indirir; script başka bir kaynak kullanmaz.
- **Temizlik:** `kubectl get` ile okur. Yalnızca `--apply` verilirse ve yalnızca yukarıdaki tabloda yazanları
  `kubectl delete` ile siler. ConfigMap, Secret, PVC ve namespace'lere hiçbir koşulda dokunmaz.
- **`--waste`:** pod ve node listesini ve metrics API'yi (`/apis/metrics.k8s.io`) okur, hiçbir şey yazmaz.

## Test ettik

Her commit'te GitHub Actions gerçek bir sanal makinede şunları yapar: `k3s-minimal-install.sh` ile k3s kurar, gerçek
iş yükleri oluşturur (biten ve hata veren pod'lar, eski ve yeni job'lar, CronJob, 4 revizyonlu Deployment, sahipsiz
disk, kullanılmayan ConfigMap ve Secret, Helm geçmişi, 500m CPU isteyip neredeyse hiç kullanmayan bir Deployment),
temizliği dry-run, `--apply` ve tekrar çalıştırma ile dener, `--waste` raporunu ve `kubectl debloat` eklentisini
kontrol eder, en sonda k3s'i kaldırır.

| Son çalıştırma | |
|---|---|
| Kontroller | 49 / 49 geçti |
| k3s sürümü | v1.36.5+k3s1 (stable kanal) |
| kube-system'de çalışan | Yalnızca CoreDNS, local-path ve metrics-server |
| Temizlik | Dry-run doğru nesneleri buldu, `--apply` yalnızca onları sildi, ikinci çalıştırma hiçbir şey bulmadı |
| `--waste` | Boşa ayıran Deployment listenin başında çıktı. İstenen 700m CPU'nun 694m'si boştaydı |
| `kubectl debloat` | Eklenti olarak kuruldu, temizlik ve `--waste` aynı sonucu verdi |

Dürüst not: CI tek node üzerinde çalışıyor. HA (`--cluster-init`, `--server`) ve worker (`--agent`) kurulumları
testin dışında.

## Lisans

[MIT](LICENSE). Kendi sorumluluğunuzda kullanın, önce test ortamında deneyin.

---

## English

Two small tools for leaner Kubernetes:

- **`k3s-minimal-install.sh`** writes `/etc/rancher/k3s/config.yaml` and runs the official installer. Traefik,
  ServiceLB, helm-controller and the cloud controller are off; CoreDNS, flannel, NetworkPolicy, metrics-server and
  local-path stay. Adds secrets encryption at rest, tighter container log rotation and image GC
  thresholds, and more frequent etcd snapshots in HA mode. Single server, HA (`--cluster-init`, `--server`) and agents.
- **`k8s-cleanup.sh`** works on any cluster and is a dry run by default. With `--apply` it deletes finished / evicted
  pods, finished Jobs older than `--older-than` (CronJob-owned ones are left alone), scaled-to-zero ReplicaSets beyond
  `--keep-rs`, and optionally Released PVs and unused node images. Unmounted PVCs, unreferenced ConfigMaps / Secrets,
  empty namespaces and long Helm histories are only reported.
- **`--waste`** compares requests with real usage from metrics-server per workload, sorted by idle reservation, with
  cluster totals and workloads that set no requests. Read-only; one snapshot, so check a busy period before lowering
  requests. Helm history reports include the size of old revisions.
- **`kubectl debloat`:** `--install-plugin` installs the script as a kubectl plugin.
- **Tested:** every commit installs a real k3s node with the script, creates workloads and checks the cleanup dry run,
  apply and repeat run, the waste report and the plugin (49/49; kube-system runs only CoreDNS, local-path and
  metrics-server). HA and agent modes are not covered by CI.
- **License:** MIT.
