set -ex

### UI jump access to k8 API
#
# kube proxy runs on localhost, so for remote systems use ssh tunnels
# ssh -v -N appusr@appserver -J myusr@jumphost -L 6443:${NET_API_HOSTNAME}:6443
#
###############################################################################

### environment configuration
NET_DOMAIN=${NET_DOMAIN:-"localdomain"}
NET_HOSTNAME=${NET_HOSTNAME:-"k8-single"}
NET_API_HOSTNAME=${NET_API_HOSTNAME:-"api"}
NET_API_IP=${NET_API_IP:-$(ip route get 8.8.8.8 | awk '{ for (nn=1;nn<=NF;nn++) if ($nn~"src") print $(nn+1) }' | cut -d '.' -f1-3).101}
NET_API_IF=${NET_API_IF:-$(ip route get 8.8.8.8 | awk '{ for (nn=1;nn<=NF;nn++) if ($nn~"dev") print $(nn+1) }')}

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
ExecStart=/usr/sbin/ip address add ${NET_API_IP}/32 dev ${NET_API_IF}
ExecStop=/usr/sbin/ip address del ${NET_API_IP}/32 dev ${NET_API_IF}

[Install]
WantedBy=local-fs.target
Also=systemd-udevd.service
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now k8vip.service
echo "${NET_API_IP} ${NET_API_HOSTNAME}.${NET_DOMAIN} ${NET_API_HOSTNAME}" | sudo tee -a /etc/hosts

### or configure static VIP for k8 api with network manager (fairly blah solution)
#nmcli con add con-name "k8vip" \
#    type ethernet \
#    ifname ${NET_API_IF} \
#    ipv4.address ${NET_API_LB}/32 \
#    ipv4.method manual \
#    connection.autoconnect yes

### configure host
sudo apt-get update
sudo apt-get -y install jq vim git lvm2 iftop psmisc apt-transport-https ca-certificates curl open-iscsi
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
dm-snapshot
EOF
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo modprobe -a overlay br_netfilter dm-snapshot
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
#sudo kubeadm init --pod-network-cidr=10.244.0.0/16
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=${NET_API_IP} \
  --apiserver-cert-extra-sans=${NET_API_HOSTNAME},${NET_API_HOSTNAME}.${NET_DOMAIN}

### configure access
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

## taint controller so we can schedule worker stuff
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-

### install network plugin
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
#kubectl apply -f https://projectcalico.docs.tigera.io/manifests/calico.yam

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
helm install openebs --namespace openebs openebs/openebs --create-namespace
while [ ! -d /var/openebs ]; do echo waiting for openebs dir to be created; sleep 5; done

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
mkdir -p ~/.config/systemd/user/
cat <<EOF | tee ~/.config/systemd/user/kube-proxy.service
[Unit]
Description=Kubernetes API Proxy Server
Documentation=https://kubernetes.io/docs/tasks/extend-kubernetes/http-proxy-access-api/
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
TimeoutStopSec=30
ExecStart=kubectl proxy
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now kube-proxy.service
loginctl enable-linger
systemctl --user status --full kube-proxy.service
kubectl -n kubernetes-dashboard create token admin-user
google-chrome http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/

### install kube prometheus
git clone https://github.com/prometheus-operator/kube-prometheus.git
cd kube-prometheus
kubectl apply --server-side -f manifests/setup
kubectl wait \
	--for condition=Established \
	--all CustomResourceDefinition \
	--namespace=monitoring
kubectl apply -f manifests/
cd -

### install loki
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki-stack --namespace monitoring

# access grafana ui
mkdir -p ~/.config/systemd/user/
cat <<EOF | tee ~/.config/systemd/user/grafana.service
[Unit]
Description=Grafana
Documentation=https://github.com/prometheus-operator/kube-prometheus
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
TimeoutStopSec=30
ExecStart=kubectl --namespace monitoring port-forward svc/grafana 3000
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now grafana.service
loginctl enable-linger
systemctl --user status --full grafana.service
google-chrome http://localhost:3000/ # username: admin, password: admin

# access prometheus ui
cat <<EOF | tee ~/.config/systemd/user/prometheus.service
[Unit]
Description=Prometheus
Documentation=https://github.com/prometheus-operator/kube-prometheus
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
TimeoutStopSec=30
ExecStart=kubectl --namespace monitoring port-forward svc/prometheus-k8s 9090
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now prometheus.service
loginctl enable-linger
systemctl --user status --full prometheus.service
google-chrome http://localhost:9090/

# access alert manager ui
cat <<EOF | tee ~/.config/systemd/user/alertmanager.service
[Unit]
Description=Alert Manager
Documentation=https://github.com/prometheus-operator/kube-prometheus
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
TimeoutStopSec=30
ExecStart=kubectl --namespace monitoring port-forward svc/alertmanager-main 9093
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now alertmanager.service
loginctl enable-linger
systemctl --user status --full alertmanager.service
google-chrome http://localhost:9093

