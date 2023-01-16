# k8 playground

You can run the k8-debian-ubuntu.sh install script locally or setup a remote target. The target requires a passwordless sudo user, e.g. ubuntu on ec2.

### local install
```bash

# install k8
export NET_DOMAIN=mydomainname NET_HOSTNAME=myhostname
./k8-debian-ubuntu.sh && ./k8-client.sh
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

### systemd user start,stop,restart,status for ssh tunnel
systemctl --user status k8-api-tunnel.service       # http://localhost:6443
````

### systemd user start,stop,restart,status for client proxies
```bash
systemctl --user status kube-proxy.service          # http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
systemctl --user status grafana.service             # http://localhost:9097
systemctl --user status prometheus.service          # http://localhost:9090
systemctl --user status alertmanager.service        # http://localhost:9093
systemctl --user status argocd.service              # https://localhost:9095
```
