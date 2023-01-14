set -ex

### Client k8 UI and API access using ssh tunnel
#
# ssh -A -J ${NET_JUMPHOST_USER}@${NET_JUMPHOST} ${NET_API_HOSTNAME_USER}@${NET_API_IP} -L 6443:${NET_API_HOSTNAME}:6443
#
###############################################################################

### source environment file
if [ -f .env.local.k8 ]; then source .env.local.k8; fi

### turn off systemd pager
export SYSTEMD_PAGER=

### configure access
mkdir -p $HOME/.kube
scp -J ${NET_JUMPHOST_USER}@${NET_JUMPHOST} ${NET_API_HOSTNAME_USER}@${NET_HOSTIP}:~/.kube/config $HOME/.kube/config
sed -i "s@^\(\s*server:\s*https://\)\(.*\):\(.*\)@\1${NET_API_HOSTNAME}:\3@" $HOME/.kube/config

### ssh api tunnel
mkdir -p ~/.config/systemd/user/
cat <<EOF | tee ~/.config/systemd/user/k8-api-tunnel.service
[Unit]
Description=SSH k8 api tunnel
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
TimeoutStopSec=30
RestartSec=90
ExecStart=ssh -N -J ${NET_JUMPHOST_USER}@${NET_JUMPHOST} ${NET_API_HOSTNAME_USER}@${NET_HOSTIP} -L 6443:${NET_API_HOSTNAME}:6443
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now k8-api-tunnel.service
systemctl --user restart k8-api-tunnel.service
loginctl enable-linger
systemctl --user status --full k8-api-tunnel.service

### run client script
exec ./k8-client.sh