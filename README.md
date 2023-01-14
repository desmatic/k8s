# k8 playground

You can run the k8-debian-ubuntu.sh install script locally or setup a remote target. The target requires a passwordless sudo user, e.g. ubuntu on ec2.

### local install
```bash

# install k8
export NET_DOMAIN=mydomainname NET_HOSTNAME=myhostname
./k8-debian-ubuntu.sh && ./k8-client.sh

# systemd user start,stop,restart,status for proxies
systemctl --user status kube-proxy.service
systemctl --user status grafana.service
systemctl --user status prometheus.service
systemctl --user status alertmanager.service
```

### jumpbox install
```bash
# setup local environment file and configure target NET_API_IP and NET_JUMPHOST
cp env.local.k8 .env.local.k8
vi .env.local.k8

# install k8 on remote target through jumpbox
source .env.local.k8
cat .env.local.k8 k8-debian-ubuntu.sh | ssh -A -J ${NET_JUMPHOST_USER}@${NET_JUMPHOST} ${NET_HOST_USER}@${NET_HOST} 'bash -s'

# add localhost alias for k8 api to local hosts file
source .env.local.k8
echo "127.0.0.1 ${NET_API_HOSTNAME}" | sudo tee -a /etc/hosts

# install kubectl and chrome on your local host and run
./k8-client-remote.sh

# systemd user start,stop,restart,status for proxies
systemctl --user status k8-api-tunnel.service
systemctl --user status kube-proxy.service
systemctl --user status grafana.service
systemctl --user status prometheus.service
systemctl --user status alertmanager.service
````
