set -ex

### Client k8 UI and API access using ssh
#
# ssh -v -N appusr@appserver -J myusr@jumphost -L 6443:${NET_API_HOSTNAME}:6443
#
###############################################################################

### environment configuration
NET_DOMAIN=${NET_DOMAIN:-"localdomain"}
NET_HOSTNAME=${NET_HOSTNAME:-"k8-single"}
NET_API_HOSTNAME=${NET_API_HOSTNAME:-"api"}

### configure access
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

### kube proxy
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
# google-chrome http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/

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
# google-chrome http://localhost:3000/ # username: admin, password: admin

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
# google-chrome http://localhost:9090/

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
# google-chrome http://localhost:9093

