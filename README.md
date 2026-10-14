# Kubernetes Debloat · Cemal.cloud

İki küçük araç: gereksiz bileşenler olmadan sade bir k3s cluster kurar, çalışan bir cluster'da biriken çöpü bulup temizler.

[![ci](https://github.com/cemal-demirci/k8s-debloat/actions/workflows/ci.yml/badge.svg)](https://github.com/cemal-demirci/k8s-debloat/actions/workflows/ci.yml)
![license](https://img.shields.io/badge/license-MIT-blue)

## Neden?

**k3s** varsayılan olarak Traefik, kendi load balancer'ı (ServiceLB) ve Helm controller ile gelir. Çoğu kurulumda bunların yerine ingress-nginx veya MetalLB gibi kendi seçtiğiniz araçlar kullanılır. Varsayılanlar ise boşuna kaynak harcar ve çakışma yaratır.

Zamanla her cluster'da **çöp birikir**: bitmiş pod'lar, eski job'lar, her deploy'dan geriye kalan ReplicaSet'ler, sahipsiz diskler, kullanılmayan image'lar. Bunlar etcd'yi şişirir, `kubectl get` çıktısını kalabalıklaştırır ve node'ların diskini doldurur.

## Hızlı başlangıç

```bash
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/k8s-debloat/main/k3s-minimal-install.sh
curl -fsSLO https://raw.githubusercontent.com/cemal-demirci/k8s-debloat/main/k8s-cleanup.sh
chmod +x k3s-minimal-install.sh k8s-cleanup.sh

sudo ./k3s-minimal-install.sh     # sade bir k3s node kur
./k8s-cleanup.sh                  # cluster'daki çöpü göster (hiçbir şey silmez)
./k8s-cleanup.sh --apply          # temizle
```

## k3s-minimal-install.sh

Resmi k3s kurucusunu sade bir ayar dosyasıyla (`/etc/rancher/k3s/config.yaml`) çalıştırır.

| Kapatılan | Neden | Geri açmak için |
|---|---|---|
| Traefik | Kendi ingress'inizi kullanın (ingress-nginx, Gateway API) | `--keep-traefik` |
| ServiceLB | MetalLB, bulut load balancer'ı veya hostNetwork kullanın | `--keep-servicelb` |
| Helm controller | Sadece HelmChart kaynakları için gerekli | `--keep-helm-controller` |
| Cloud controller | Fiziksel sunucu ve sanal makinede gereksiz | |

**Kalanlar:** CoreDNS, flannel (pod ağı), NetworkPolicy desteği, metrics-server (`kubectl top` ve otomatik ölçekleme için), local-path (tek node'da disk). İsterseniz `--no-metrics` ve `--no-local-storage` ile bunlar da kapatılır.

**Eklenenler:** secret'lar diskte şifreli saklanır, kubeconfig'i sadece root okuyabilir, container logları döndürülür (10 MB x 3), disk dolmaya başlayınca kullanılmayan image'lar silinir, HA kurulumda 6 saatte bir etcd yedeği alınır.

```bash
sudo ./k3s-minimal-install.sh                                                          # tek node
sudo ./k3s-minimal-install.sh --cluster-init --tls-san 10.0.0.10                        # HA: ilk server
sudo ./k3s-minimal-install.sh --server https://10.0.0.10:6443 --token <TOKEN>           # HA: ek server
sudo ./k3s-minimal-install.sh --agent --server https://10.0.0.10:6443 --token <TOKEN>   # worker
./k3s-minimal-install.sh --dry-run                                                      # sadece ayarı göster
```

Diğer seçenekler (`--version`, `--node-ip`, `--flannel` ...) için `--help`. Kaldırmak için `/usr/local/bin/k3s-uninstall.sh`.

## k8s-cleanup.sh

Her Kubernetes cluster'ında çalışır: k3s, kubeadm, EKS, AKS, GKE. Varsayılan olarak **hiçbir şey silmez**, sadece neyin silineceğini gösterir. Silmek için `--apply` eklemeniz gerekir.

| Silinenler (`--apply` ile) | Kural |
|---|---|
| Pod | Tamamlanmış, hata vermiş veya tahliye edilmiş (Evicted) |
| Job | Bitmiş ve `--older-than` süresinden eski (varsayılan 24 saat). CronJob'lara ait job'lar atlanır, onları CronJob kendisi yönetir. |
| ReplicaSet | Eski deploy'lardan kalanlar. Her Deployment için en yeni 2 tanesi geri dönüş için saklanır (`--keep-rs`). |
| PersistentVolume | Sahibi silinmiş (Released) diskler, sadece `--delete-released-pv` ile. Diskteki veri silinmez, sadece Kubernetes kaydı silinir. |
| Image | Node'daki kullanılmayan image'lar, sadece `--prune-images` ile |

Şunlar **asla otomatik silinmez**, sadece listelenir, karar size kalır: hiçbir pod'un kullanmadığı PVC'ler, ConfigMap ve Secret'lar, boş namespace'ler, çok fazla geçmiş saklayan Helm release'leri.

```bash
./k8s-cleanup.sh -n media --apply                  # tek namespace
./k8s-cleanup.sh --context prod --older-than 72h   # başka cluster, farklı süre
sudo ./k8s-cleanup.sh --prune-images --apply       # bu node'daki kullanılmayan image'lar
```

Gereksinim: `kubectl` (veya `k3s kubectl`) ve `jq`.

## Nasıl test ediliyor?

Her değişiklikte GitHub Actions, `k3s-minimal-install.sh` ile gerçek bir k3s node'u kurar. Traefik ve ServiceLB'nin gelmediğini, secret şifrelemenin açık olduğunu, `kubectl top`'un çalıştığını kontrol eder. Ardından gerçek iş yükleri oluşturup temizlik scriptini dry-run, `--apply` ve tekrar çalıştırma ile dener, en sonda k3s'i kaldırır.

## Lisans

[MIT](LICENSE). Kendi sorumluluğunuzda kullanın, önce test ortamında deneyin.

---

<details>
<summary><b>English</b></summary>

- **`k3s-minimal-install.sh`**: writes `/etc/rancher/k3s/config.yaml` and runs the official installer. Traefik, ServiceLB, helm-controller and the cloud controller are off; CoreDNS, flannel, NetworkPolicy, metrics-server and local-path stay. Adds secrets encryption at rest, a 0600 kubeconfig, container log rotation, image GC thresholds and etcd snapshots in HA mode. Single server, HA (`--cluster-init`, `--server`) and agents.
- **`k8s-cleanup.sh`**: works on any cluster, dry run by default. With `--apply` it deletes finished / evicted pods, finished Jobs older than `--older-than` (CronJob-owned ones are left to their history limit), scaled-to-zero ReplicaSets beyond `--keep-rs`, and optionally Released PVs and unused node images. Unmounted PVCs, unreferenced ConfigMaps / Secrets, empty namespaces and long Helm histories are only reported.

CI installs a real k3s node with the script, creates workloads, and checks the cleanup dry run, apply and repeat run for every commit.

</details>
