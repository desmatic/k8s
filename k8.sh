NET_DOMAIN="localdomain"

### configure host
sudo apt-get update
sudo apt-get -y install jq vim git lvm2 iftop psmisc apt-transport-https ca-certificates curl open-iscsi
sudo update-alternatives --set editor /usr/bin/vim.basic
sudo systemctl enable --now iscsid
sudo cat /etc/iscsi/initiatorname.iscsi
systemctl status iscsid

### configure host networking
sudo hostnamectl set-hostname k8-ctrl1
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
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
#sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address $NET_API_LB

### configure access
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

## taint controller so we can schedule worker stuff
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-

### install network plugin
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

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

### openebs lvm storage
sudo truncate -s 1024G /var/openebs/lvmvg.img
sudo vgcreate lvmvg $(losetup -f /var/openebs/lvmvg.img --show)
cat > /etc/systemd/system/openebs-lvmvg.service <<EOF
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
kubectl apply -f https://openebs.github.io/charts/lvm-operator.yaml
kubectl get pods -n kube-system -l role=openebs-lvm
