set -ex

### run install script on remote target through jumpbox
#
# cat .env.local.k8 k8-debian-ubuntu.sh | ssh -A -J myusr@jumphost appusr@${NET_DOMAIN}.${NET_HOSTNAME} 'bash -s'
#
###############################################################################

### environment configuration
NET_DOMAIN=${NET_DOMAIN:-"localdomain"}
NET_HOSTNAME=${NET_HOSTNAME:-"k8-single"}
NET_API_HOSTNAME=${NET_API_HOSTNAME:-"api"}
NET_API_IF=${NET_API_IF:-$(ip route get 8.8.8.8 | awk '{ for (nn=1;nn<=NF;nn++) if ($nn~"dev") print $(nn+1) }')}

ADVERTISE_ADDRESS=""
if [ ! -z "${NET_API_VIP}" ]; then

### configure dynamic VIP for k8 api with systemd (good lazy solution)
cat <<EOF | sudo tee /etc/systemd/system/k8vip.service
[Unit]
Description=Setup k8 virtual IP
DefaultDependencies=no
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip address add ${NET_API_VIP}/32 dev ${NET_API_IF}
ExecStop=/usr/sbin/ip address del ${NET_API_VIP}/32 dev ${NET_API_IF}

[Install]
WantedBy=local-fs.target
Also=systemd-udevd.service
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now k8vip.service
echo "${NET_API_VIP} ${NET_API_HOSTNAME}.${NET_DOMAIN} ${NET_API_HOSTNAME}" | sudo tee -a /etc/hosts
ADVERTISE_ADDRESS="--apiserver-advertise-address=${NET_API_VIP}"

fi

if [ ! -z "${NET_API_LBIP}" ]; then
  ADVERTISE_ADDRESS="--apiserver-advertise-address=${NET_API_LBIP}"
fi

### or configure static VIP for k8 api with network manager (fairly blah solution)
#nmcli con add con-name "k8vip" \
#    type ethernet \
#    ifname ${NET_API_IF} \
#    ipv4.address ${NET_API_LB}/32 \
#    ipv4.method manual \
#    connection.autoconnect yes

### configure host
sudo apt-get update
sudo apt-get -y install lvm2 policykit-1 apt-transport-https ca-certificates open-iscsi \
  vim jq curl git iftop psmisc screen tmux
sudo update-alternatives --set editor /usr/bin/vim.basic
sudo systemctl enable --now iscsid
sudo cat /etc/iscsi/initiatorname.iscsi
systemctl status iscsid

### configure host networking
sudo hostnamectl set-hostname ${NET_HOSTNAME}
echo "$(ip route get 8.8.8.8 | awk '{ for (nn=1;nn<=NF;nn++) if ($nn~"src") print $(nn+1) }') $(hostname).${NET_DOMAIN} $(hostname)" | sudo tee -a /etc/hosts
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
ip6table_mangle
ip6table_nat
ip6table_raw
iptable_mangle
iptable_nat
iptable_raw
xt_REDIRECT
xt_connmark
xt_conntrack
xt_mark
xt_owner
xt_tcpudp
dm-snapshot
EOF
sudo modprobe -a $(cat /etc/modules-load.d/k8s.conf)
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

### install containerd
curl -fsSLo containerd-config.toml \
  https://gist.githubusercontent.com/oradwell/31ef858de3ca43addef68ff971f459c2/raw/5099df007eb717a11825c3890a0517892fa12dbf/containerd-config.toml
sudo mkdir /etc/containerd
sudo mv containerd-config.toml /etc/containerd/config.toml
curl -fsSLo containerd-1.6.14-linux-amd64.tar.gz \
  https://github.com/containerd/containerd/releases/download/v1.6.14/containerd-1.6.14-linux-amd64.tar.gz
sudo tar Cxzvf /usr/local containerd-1.6.14-linux-amd64.tar.gz
sudo curl -fsSLo /etc/systemd/system/containerd.service \
  https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

### install runc
curl -fsSLo runc.amd64 \
  https://github.com/opencontainers/runc/releases/download/v1.1.3/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

### install network plugin
curl -fsSLo cni-plugins-linux-amd64-v1.1.1.tgz \
  https://github.com/containernetworking/plugins/releases/download/v1.1.1/cni-plugins-linux-amd64-v1.1.1.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.1.1.tgz

### add kubernetes repo
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg \
  https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get -y install kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

### configure crictl
sudo crictl config runtime-endpoint unix:///var/run/containerd/containerd.sock
sudo crictl config image-endpoint unix:///var/run/containerd/containerd.sock
sudo crictl config --set timeout=20
sudo crictl config --set pull-image-on-create=true

### initialize control plane
sudo kubeadm config images pull
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 ${ADVERTISE_ADDRESS} \
  --apiserver-cert-extra-sans=${NET_API_HOSTNAME},${NET_API_HOSTNAME}.${NET_DOMAIN}

### configure access
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

## taint controller so we can schedule worker stuff
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-

### install network plugin
#kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
kubectl apply -f https://projectcalico.docs.tigera.io/manifests/calico.yaml

### install helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

### add bash completion
kubeadm completion bash | sudo tee /etc/bash_completion.d/kubeadm
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl
crictl completion bash | sudo tee /etc/bash_completion.d/crictl
helm completion bash | sudo tee /etc/bash_completion.d/helm

### install openebs
helm repo add openebs https://openebs.github.io/charts
helm repo update
helm install openebs openebs/openebs --create-namespace --namespace openebs --wait

### openebs lvm storage
sudo truncate -s 1024G /var/openebs/lvmvg.img
sudo bash -c 'vgcreate lvmvg $(losetup -f /var/openebs/lvmvg.img --show)'
cat <<EOF | sudo tee /etc/systemd/system/openebs-lvmvg.service
[Unit]
Description=Setup openebs lvmvg loop device
DefaultDependencies=no
Conflicts=umount.target
After=systemd-udev-settle.service
Before=lvm2-activation-early.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/sbin/losetup -f /var/openebs/lvmvg.img --show
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
Also=systemd-udevd.service
EOF
sudo systemctl daemon-reload
sudo systemctl enable openebs-lvmvg.service
sudo vgdisplay -v lvmvg
kubectl apply -f https://openebs.github.io/charts/lvm-operator.yaml
kubectl get pods -n kube-system -l role=openebs-lvm
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-lvmpv
parameters:
  storage: "lvm"
  volgroup: "lvmvg"
provisioner: local.csi.openebs.io
EOF
cat <<EOF | kubectl apply -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: csi-lvmpv
spec:
  storageClassName: openebs-lvmpv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 16Gi
EOF
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: fio
spec:
  restartPolicy: Never
  containers:
  - name: perfrunner
    image: openebs/tests-fio
    command: ["/bin/bash"]
    args: ["-c", "sleep infinity"]
    volumeMounts:
       - mountPath: /datadir
         name: fio-vol
    tty: true
  volumes:
  - name: fio-vol
    persistentVolumeClaim:
      claimName: csi-lvmpv
EOF

### install istio
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
helm install istio-base istio/base --namespace istio-system --create-namespace --wait
helm install istiod istio/istiod --namespace istio-system --wait

### install metallb
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: privileged
  name: metallb-system
EOF
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm install metallb metallb/metallb --namespace metallb-system --wait

### install loki
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki-stack --create-namespace --namespace loki --wait

### install grafana
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.16/samples/addons/grafana.yaml

### install prometheus
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.16/samples/addons/prometheus.yaml

### install kaili
helm install \
  --namespace istio-system \
  --set auth.strategy="anonymous" \
  --repo https://kiali.org/helm-charts \
  kiali-server \
  kiali-server

### install argo cd
helm repo add argocd https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argocd/argo-cd --namespace=argocd  --create-namespace

### ui dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
EOF
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF
