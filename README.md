# k8 playground

You can run the k8-debian-ubuntu.sh install script locally or setup a remote target. The target requires a passwordless sudo user, e.g. ubuntu on ec2.

### local install
```bash
NET_DOMAIN=mydomainname NET_HOSTNAME=myhostname ./k8-debian-ubuntu.sh
```

### jumpbox install
```bash
# setup local environment file and configure target NET_API_IP and NET_JUMPHOST
cp env.local.k8 .env.local.k8
vi .env.local.k8

# install k8 on remote target through jumpbox
source .env.local.k8
cat .env.local.k8 k8-debian-ubuntu.sh | ssh -A -J ${NET_JUMPHOST_USER}@${NET_JUMPHOST} ${NET_API_HOSTNAME_USER}@${NET_API_IP} 'bash -s'

# add localhost alias for k8 api to local hosts file
source .env.local.k8
echo "127.0.0.1 ${NET_API_HOSTNAME}" | sudo tee -a /etc/hosts

# start k8 api tunnel to remote target
source .env.local.k8
ssh -A -J ${NET_JUMPHOST_USER}@${NET_JUMPHOST} ${NET_API_HOSTNAME_USER}@${NET_API_IP} -L 6443:${NET_API_HOSTNAME}:6443

# on a separate local terminal, install k8 client
./k8-client.sh
````
