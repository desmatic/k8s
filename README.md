# k8 playground

You can run the k8-debian-ubuntu.sh install script locally or setup a remote target. The target requires a passwordless sudo user, e.g. ubuntu on ec2.

```bash
# setup local environment file
cp env.local.k8 .env.local.k8
vi .env.local.k8

# install k8 on remote target through jumpbox
cat .env.local.k8 k8-debian-ubuntu.sh | ssh -A -J myusr@jumphost appusr@${NET_DOMAIN}.${NET_HOSTNAME} 'bash -s'

# add localhost alias for k8 api to hosts file
source .env.local.k8
echo "127.0.0.1 ${NET_API_HOSTNAME}" | sudo tee -a /etc/hosts

# start k8 api tunnel to remote target
source .env.local.k8
ssh -A -J ${NET_JUMPHOST_USER}@${NET_JUMPHOST} ${NET_API_HOSTNAME_USER}@${NET_API_IP} -L 6443:${NET_API_HOSTNAME}:6443

# on a separate local terminal, install k8 client
source .env.local.k8
./k8-client.sh
````
