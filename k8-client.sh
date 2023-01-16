set -ex

### source environment file
if [ -f .env.local.k8 ]; then source .env.local.k8; fi

### turn off systemd pager
export SYSTEMD_PAGER=

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
RestartSec=90
ExecStart=kubectl proxy
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now kube-proxy.service
systemctl --user restart kube-proxy.service
loginctl enable-linger
systemctl --user status --full kube-proxy.service
google-chrome http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/ || echo "skipping browser" &

### access grafana ui
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
RestartSec=90
ExecStart=kubectl --namespace monitoring port-forward svc/grafana 9097:3000
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now grafana.service
systemctl --user restart grafana.service
loginctl enable-linger
systemctl --user status --full grafana.service
google-chrome http://localhost:9097  || echo "skipping browser" & # username: admin, password: admin

### access prometheus ui
cat <<EOF | tee ~/.config/systemd/user/prometheus.service
[Unit]
Description=Prometheus
RestartSec=90
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
systemctl --user restart prometheus.service
loginctl enable-linger
systemctl --user status --full prometheus.service
google-chrome http://localhost:9090/  || echo "skipping browser" &

### access alert manager ui
cat <<EOF | tee ~/.config/systemd/user/alertmanager.service
[Unit]
Description=Alert Manager
Documentation=https://github.com/prometheus-operator/kube-prometheus
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
TimeoutStopSec=30
RestartSec=90
ExecStart=kubectl --namespace monitoring port-forward svc/alertmanager-main 9093
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now alertmanager.service
systemctl --user restart alertmanager.service
loginctl enable-linger
systemctl --user status --full alertmanager.service
google-chrome http://localhost:9093 || echo "skipping browser" &

### access argocd
cat <<EOF | tee ~/.config/systemd/user/argocd.service
[Unit]
Description=Argo CD
Documentation=https://argo-cd.readthedocs.io/en/stable/getting_started/
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
TimeoutStopSec=30
RestartSec=90
ExecStart=kubectl --namespace argocd port-forward svc/argocd-server 9095:443
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now argocd.service
systemctl --user restart argocd.service
loginctl enable-linger
systemctl --user status --full argocd.service
google-chrome https://localhost:9095 || echo "skipping browser" &

### generate k8 dashboard token
kubectl -n kubernetes-dashboard create token admin-user

###
echo "argocd user: admin"
echo "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d"
