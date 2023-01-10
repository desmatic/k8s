NET_SUBNET=117
NET_SUBDOMAIN=okd4
NET_TLD=kvm
NET_MACPREFIX="52:54:00:$(openssl rand -hex 1):$(openssl rand -hex 1)"
echo "NET_MACPREFIX=${NET_MACPREFIX}"

dnf install -y httpd
sed -i 's/Listen 80/Listen 8080/' /etc/httpd/conf/httpd.conf
setsebool -P httpd_read_user_content 1
systemctl enable --now httpd.service
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=8443/tcp
firewall-cmd --reload

sudo mkdir -p /var/www/html/redhat/fcos
sudo echo '/var/lib/libvirt/iso/fedora-coreos-37.20221211.3.0-live.x86_64.iso /var/www/html/redhat/fcos auto ro,loop  0 0' >> /etc/fstab
sudo mount /var/www/html/redhat/fcos

sudo cat >> /etc/hosts <<EOF
192.168.${NET_SUBNET}.1 api.${NET_SUBDOMAIN}.${NET_TLD} api-int.${NET_SUBDOMAIN}.${NET_TLD} http.${NET_SUBDOMAIN}.${NET_TLD}
192.168.${NET_SUBNET}.9 bootstrap.${NET_SUBDOMAIN}.${NET_TLD} bootstrap
192.168.${NET_SUBNET}.10 master0.${NET_SUBDOMAIN}.${NET_TLD} master0
192.168.${NET_SUBNET}.11 master1.${NET_SUBDOMAIN}.${NET_TLD} master1
192.168.${NET_SUBNET}.12 master2.${NET_SUBDOMAIN}.${NET_TLD} master2
192.168.${NET_SUBNET}.13 worker0.${NET_SUBDOMAIN}.${NET_TLD} worker0
192.168.${NET_SUBNET}.14 worker1.${NET_SUBDOMAIN}.${NET_TLD} worker1
EOF

cat > ${NET_SUBDOMAIN}.xml <<EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${NET_SUBDOMAIN}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${NET_SUBDOMAIN}' stp='on' delay='0'/>
  <domain name='${NET_SUBDOMAIN}.${NET_TLD}' localOnly='no'/>
  <dns>
    <host ip='192.168.${NET_SUBNET}.1'>
      <hostname>ns1.${NET_SUBDOMAIN}.${NET_TLD}</hostname>
    </host>
  </dns>
  <dnsmasq:options>
    <dnsmasq:option value='address=/apps.${NET_SUBDOMAIN}.${NET_TLD}/192.168.${NET_SUBNET}.1'/>
  </dnsmasq:options>
  <ip family='ipv4' address='192.168.${NET_SUBNET}.1' prefix='24'>
    <dhcp>
      <range start='192.168.${NET_SUBNET}.128' end='192.168.${NET_SUBNET}.254'/>
      <bootp file='http://http.${NET_SUBDOMAIN}.${NET_TLD}:8080/pxe/fcos/pxelinux.0'/>
      <host mac='${NET_MACPREFIX}:09' ip='192.168.${NET_SUBNET}.9'/>
      <host mac='${NET_MACPREFIX}:10' ip='192.168.${NET_SUBNET}.10'/>
      <host mac='${NET_MACPREFIX}:11' ip='192.168.${NET_SUBNET}.11'/>
      <host mac='${NET_MACPREFIX}:12' ip='192.168.${NET_SUBNET}.12'/>
      <host mac='${NET_MACPREFIX}:13' ip='192.168.${NET_SUBNET}.13'/>
      <host mac='${NET_MACPREFIX}:14' ip='192.168.${NET_SUBNET}.14'/>
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-define ${NET_SUBDOMAIN}.xml
sudo virsh net-start ${NET_SUBDOMAIN}
sudo virsh net-autostart ${NET_SUBDOMAIN}

dnf install haproxy -y
sudo cat > /etc/haproxy/haproxy.${NET_SUBDOMAIN}.cfg <<EOF
global
  log         /dev/log local2
  pidfile     /var/run/haproxy.pid
  maxconn     4000
  daemon

defaults
  mode                    tcp
  log                     global
  option                  dontlognull
  option http-server-close
  option                  redispatch
  retries                 3
  timeout http-request    10s
  timeout queue           1m
  timeout connect         10s
  timeout client          1m
  timeout server          1m
  timeout http-keep-alive 10s
  timeout check           10s
  maxconn                 3000

frontend stats
  bind 192.168.${NET_SUBNET}.1:1936
  mode            http
  log             global
  maxconn 10
  stats enable
  stats hide-version
  stats refresh 30s
  stats show-node
  stats show-desc Stats for ocp4 cluster
  stats auth admin:ocp4
  stats uri /stats

listen api-server-6443
  bind 192.168.${NET_SUBNET}.1:6443
  mode tcp
  server bootstrap bootstrap.${NET_SUBDOMAIN}.${NET_TLD}:6443 check inter 1s backup
  server master0 master0.${NET_SUBDOMAIN}.${NET_TLD}:6443 check inter 1s
  server master1 master1.${NET_SUBDOMAIN}.${NET_TLD}:6443 check inter 1s
  server master2 master2.${NET_SUBDOMAIN}.${NET_TLD}:6443 check inter 1s

listen machine-config-server-22623
  bind 192.168.${NET_SUBNET}.1:22623
  mode tcp
  server bootstrap bootstrap.${NET_SUBDOMAIN}.${NET_TLD}:22623 check inter 1s backup
  server master0 master0.${NET_SUBDOMAIN}.${NET_TLD}:22623 check inter 1s
  server master1 master1.${NET_SUBDOMAIN}.${NET_TLD}:22623 check inter 1s
  server master2 master2.${NET_SUBDOMAIN}.${NET_TLD}:22623 check inter 1s

listen ingress-router-443
  bind 192.168.${NET_SUBNET}.1:443
  mode tcp
  balance source
  server worker0 worker0.${NET_SUBDOMAIN}.${NET_TLD}:443 check inter 1s
  server worker1 worker1.${NET_SUBDOMAIN}.${NET_TLD}:443 check inter 1s

listen ingress-router-80
  bind 192.168.${NET_SUBNET}.1:80
  mode tcp
  balance source
  server worker0 worker0.${NET_SUBDOMAIN}.${NET_TLD}:80 check inter 1s
  server worker1 worker1.${NET_SUBDOMAIN}.${NET_TLD}:80 check inter 1s
EOF

firewall-cmd --permanent --add-port=6443/tcp
firewall-cmd --permanent --add-port=22623/tcp
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload

firewall-cmd --permanent --add-port=6443/tcp --zone=libvirt
firewall-cmd --permanent --add-port=22623/tcp --zone=libvirt
firewall-cmd --permanent --add-service=http --zone=libvirt
firewall-cmd --permanent --add-service=https --zone=libvirt
firewall-cmd --reload

setsebool -P haproxy_connect_any 1
systemctl enable --now haproxy

dig +noall +answer @192.168.${NET_SUBNET}.1 api.${NET_SUBDOMAIN}.${NET_TLD}
dig +noall +answer @192.168.${NET_SUBNET}.1 api-int.${NET_SUBDOMAIN}.${NET_TLD}
dig +noall +answer @192.168.${NET_SUBNET}.1 random.apps.${NET_SUBDOMAIN}.${NET_TLD}
dig +noall +answer @192.168.${NET_SUBNET}.1 -x 192.168.${NET_SUBNET}.1
dig +noall +answer @192.168.${NET_SUBNET}.1 bootstrap.${NET_SUBDOMAIN}.${NET_TLD}
dig +noall +answer @192.168.${NET_SUBNET}.1 master0.${NET_SUBDOMAIN}.${NET_TLD}
dig +noall +answer @192.168.${NET_SUBNET}.1 master1.${NET_SUBDOMAIN}.${NET_TLD}
dig +noall +answer @192.168.${NET_SUBNET}.1 master2.${NET_SUBDOMAIN}.${NET_TLD}
dig +noall +answer @192.168.${NET_SUBNET}.1 worker0.${NET_SUBDOMAIN}.${NET_TLD}
dig +noall +answer @192.168.${NET_SUBNET}.1 worker1.${NET_SUBDOMAIN}.${NET_TLD}

sudo mkdir -p /var/www/html/pxe/fcos/pxelinux.cfg/
sudo ln -s ../../redhat/fcos/ /var/www/html/pxe/fcos/iso
sudo ln -s /usr/share/syslinux/ldlinux.c32 /var/www/html/pxe/fcos/
sudo ln -s /usr/share/syslinux/libutil.c32 /var/www/html/pxe/fcos/
sudo ln -s /usr/share/syslinux/menu.c32 /var/www/html/pxe/fcos/
sudo ln -s /usr/share/syslinux/pxelinux.0 /var/www/html/pxe/fcos/

cat >> /var/www/html/pxe/fcos/pxelinux.cfg/default <<EOF
DEFAULT menu.c32
TIMEOUT 360
PROMPT 0
IPAPPEND 2
LABEL fcos
    MENU LABEL Fedora CoreOS
    KERNEL iso/images/pxeboot/vmlinuz
    APPEND initrd=iso/images/pxeboot/initrd.img,iso/images/pxeboot/rootfs.img coreos.inst.install_dev=/dev/vda coreos.inst.ignition_url=http://http.localdomain:8080/pxe/fcos/ssh.ign
LABEL worker
    MENU LABEL OKD4 worker
    KERNEL iso/images/pxeboot/vmlinuz
    APPEND initrd=iso/images/pxeboot/initrd.img,iso/images/pxeboot/rootfs.img coreos.inst.install_dev=/dev/vda coreos.inst.ignition_url=http://http.localdomain:8080/pxe/fcos/worker.ign
LABEL master
    MENU LABEL OKD4 master
    KERNEL iso/images/pxeboot/vmlinuz
    APPEND initrd=iso/images/pxeboot/initrd.img,iso/images/pxeboot/rootfs.img coreos.inst.install_dev=/dev/vda coreos.inst.ignition_url=http://http.localdomain:8080/pxe/fcos/master.ign
LABEL bootstrap
    MENU LABEL OKD4 bootstrap
    KERNEL iso/images/pxeboot/vmlinuz
    APPEND initrd=iso/images/pxeboot/initrd.img,iso/images/pxeboot/rootfs.img coreos.inst.install_dev=/dev/vda coreos.inst.ignition_url=http://http.localdomain:8080/pxe/fcos/bootstrap.ign
EOF

cat >install-config-${NET_SUBDOMAIN}.yaml<<EOF
apiVersion: v1
baseDomain: ${NET_TLD}
compute:
- hyperthreading: Enabled
  name: worker
  replicas: 0
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: 3
metadata:
  name: ${NET_SUBDOMAIN}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
pullSecret: '{"auths":{"cloud.openshift.com":{"auth":"b3BlbnNoaWZ0LXJlbGVhc2UtZGV2K29jbV9hY2Nlc3NfZDgyNjU2ZWFiNmE4NGIyYWFhZGJlMzhiMDVjNzA3OWQ6U0lTQk8zR1k0QzNDVTdMWFVGNFFGSFZCMzlUNFBVWVVURzk1N1NKSU4xV1paUVdUNkNOSldCRlFTWEk0RUY5MA==","email":"desmatic@gmail.com"},"quay.io":{"auth":"b3BlbnNoaWZ0LXJlbGVhc2UtZGV2K29jbV9hY2Nlc3NfZDgyNjU2ZWFiNmE4NGIyYWFhZGJlMzhiMDVjNzA3OWQ6U0lTQk8zR1k0QzNDVTdMWFVGNFFGSFZCMzlUNFBVWVVURzk1N1NKSU4xV1paUVdUNkNOSldCRlFTWEk0RUY5MA==","email":"desmatic@gmail.com"},"registry.connect.redhat.com":{"auth":"fHVoYy1wb29sLTg0MzlkNTUxLTYzZmQtNGI0ZS1hNWNlLTM3MGFiMmZjMmQyODpleUpoYkdjaU9pSlNVelV4TWlKOS5leUp6ZFdJaU9pSTRaVGRrTTJFM01EWTVNekEwTUdJNFlUZ3dOR1V4WWpVMU1EQTJZemd3WWlKOS5pbl8xVjRlVTdBN1loWlQ5eGZpcWh3d1hPb0tncU5QNmJsRWxaVHFld3I4NDk3d2FoV2VRS3FxMzFjc1h0NGRORTR6enFSTHoxbllsaHpOc1ZjYktWeVRCckJLdkpzM2tpNzB1bVBmblotSUlPUUVIUkFDWjRobTFjSXFOZGY0YjNDVGM3WWhOa2tDNE9EUWlKQjlEYVV0NVlXU2FNb19tTGF0NXJVT3NVWk9mWTRpQ3hWeW1nMnpFRm1nbllyaVpPcFJqa24teFB2b1RMUk9DSHR1dXZGVDhwZnd4N3loQzVjTkYzbDZJYnlzNVRXY015M0ZGRk5SVzN6STBNSlFTdHVjakE1dGcxZG5yaFhYbmsya1htcFMtWEpNVEJBVkNFTkhqOXZwWnNvSkU1X05TSXR3UEdKR0RTMVpiZ3ZQRUpGamJFT1hWN1J4SE1kUllNazFJWkU4YmczNkhHUXdscFk0aEFnZnZCV3BaLVpDeUFNZHc2ejVnR2o4SDBFVjBReFBRZ1JpdW05WldzSENSU3FWV0FldzFuQTF0UUY5b25xYUp1RkszRjRtMWNOLUhPM0E1R2hkNDdmaGFYQ0kxMkFYODkwRzIxVDdHRnA3ZUxlTHlZNGoyN0k1ay1IWm9pamhteFg4d3JOUXJoQVI2OGdYdDQ2LXJQWlYxQlFmdlY4cUNVd3dzNGZWVjZ2SHMzSTBDOHhDaUdhMmgxX2dWUlR6T05tN2gzUUs1eGJra1dKQW9pZ3RpMk5QUy1DZi0tTThuNThGbmw3ZTBKRVlyMkNodlUwOUlnSzAyZXFVbV9yaU9XMHAzUnhta1JnQnlxeFFiSXo3T204N2UxdXVLZU1rdkhWVlhrVDlHXzVZdm04cVFyTXNXWWhHQTBBV18tSDlQVlVJTWg4bw==","email":"desmatic@gmail.com"},"registry.redhat.io":{"auth":"fHVoYy1wb29sLTg0MzlkNTUxLTYzZmQtNGI0ZS1hNWNlLTM3MGFiMmZjMmQyODpleUpoYkdjaU9pSlNVelV4TWlKOS5leUp6ZFdJaU9pSTRaVGRrTTJFM01EWTVNekEwTUdJNFlUZ3dOR1V4WWpVMU1EQTJZemd3WWlKOS5pbl8xVjRlVTdBN1loWlQ5eGZpcWh3d1hPb0tncU5QNmJsRWxaVHFld3I4NDk3d2FoV2VRS3FxMzFjc1h0NGRORTR6enFSTHoxbllsaHpOc1ZjYktWeVRCckJLdkpzM2tpNzB1bVBmblotSUlPUUVIUkFDWjRobTFjSXFOZGY0YjNDVGM3WWhOa2tDNE9EUWlKQjlEYVV0NVlXU2FNb19tTGF0NXJVT3NVWk9mWTRpQ3hWeW1nMnpFRm1nbllyaVpPcFJqa24teFB2b1RMUk9DSHR1dXZGVDhwZnd4N3loQzVjTkYzbDZJYnlzNVRXY015M0ZGRk5SVzN6STBNSlFTdHVjakE1dGcxZG5yaFhYbmsya1htcFMtWEpNVEJBVkNFTkhqOXZwWnNvSkU1X05TSXR3UEdKR0RTMVpiZ3ZQRUpGamJFT1hWN1J4SE1kUllNazFJWkU4YmczNkhHUXdscFk0aEFnZnZCV3BaLVpDeUFNZHc2ejVnR2o4SDBFVjBReFBRZ1JpdW05WldzSENSU3FWV0FldzFuQTF0UUY5b25xYUp1RkszRjRtMWNOLUhPM0E1R2hkNDdmaGFYQ0kxMkFYODkwRzIxVDdHRnA3ZUxlTHlZNGoyN0k1ay1IWm9pamhteFg4d3JOUXJoQVI2OGdYdDQ2LXJQWlYxQlFmdlY4cUNVd3dzNGZWVjZ2SHMzSTBDOHhDaUdhMmgxX2dWUlR6T05tN2gzUUs1eGJra1dKQW9pZ3RpMk5QUy1DZi0tTThuNThGbmw3ZTBKRVlyMkNodlUwOUlnSzAyZXFVbV9yaU9XMHAzUnhta1JnQnlxeFFiSXo3T204N2UxdXVLZU1rdkhWVlhrVDlHXzVZdm04cVFyTXNXWWhHQTBBV18tSDlQVlVJTWg4bw==","email":"desmatic@gmail.com"}}}'
sshKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOg1zo/LNT/lSXd4TfrTvbHbGVc5kl1fRTwBX4OPdnqT okd4@lollipop.localdomain'
capabilities:
  baselineCapabilitySet: v4.11
EOF

ssh-keygen -t ed25519 -N ''

mkdir -p ${NET_SUBDOMAIN}.${NET_TLD}
cp install-config-${NET_SUBDOMAIN}.yaml ./${NET_SUBDOMAIN}.${NET_TLD}/install-config.yaml
openshift-install create manifests --dir ./${NET_SUBDOMAIN}.${NET_TLD}
sed -i 's/mastersSchedulable: true/mastersSchedulable: false/' ./${NET_SUBDOMAIN}.${NET_TLD}/manifests/cluster-scheduler-02-config.yml
openshift-install create ignition-configs --dir ./${NET_SUBDOMAIN}.${NET_TLD}
chmod 644 ./${NET_SUBDOMAIN}.${NET_TLD}/*ign
sudo cp ./${NET_SUBDOMAIN}.${NET_TLD}/*ign /var/www/html/pxe/fcos/


sudo virt-install --name bootstrap --os-variant=fedora-coreos-stable \
    --pxe --network=bridge=${NET_SUBDOMAIN},mac=${NET_MACPREFIX}:09 \
    --memory 12288 --vcpus 8 --disk size=64

sudo virt-install --name master0 --os-variant=fedora-coreos-stable \
    --pxe --network=bridge=${NET_SUBDOMAIN},mac=${NET_MACPREFIX}:10 \
    --memory 16384 --vcpus 8 --disk size=64

sudo virt-install --name master1 --os-variant=fedora-coreos-stable \
    --pxe --network=bridge=${NET_SUBDOMAIN},mac=${NET_MACPREFIX}:11 \
    --memory 16384 --vcpus 8 --disk size=64

sudo virt-install --name master2 --os-variant=fedora-coreos-stable \
    --pxe --network=bridge=${NET_SUBDOMAIN},mac=${NET_MACPREFIX}:12 \
    --memory 16384 --vcpus 8 --disk size=64

sudo virt-install --name worker0 --os-variant=fedora-coreos-stable \
    --pxe --network=bridge=${NET_SUBDOMAIN},mac=${NET_MACPREFIX}:13 \
    --memory 6144 --vcpus 4 --disk size=64

sudo virt-install --name worker1 --os-variant=fedora-coreos-stable \
    --pxe --network=bridge=${NET_SUBDOMAIN},mac=${NET_MACPREFIX}:14 \
    --memory 6144 --vcpus 4 --disk size=64

nc -z api.${NET_SUBDOMAIN}.${NET_TLD} 6443
nc -z api-int.${NET_SUBDOMAIN}.${NET_TLD} 6443
nc -z bootstrap.${NET_SUBDOMAIN}.${NET_TLD} 6443
nc -z master0.${NET_SUBDOMAIN}.${NET_TLD} 6443
nc -z master1.${NET_SUBDOMAIN}.${NET_TLD} 6443
nc -z master2.${NET_SUBDOMAIN}.${NET_TLD} 6443

nc -z api.${NET_SUBDOMAIN}.${NET_TLD} 22623
nc -z api-int.${NET_SUBDOMAIN}.${NET_TLD} 22623
nc -z bootstrap.${NET_SUBDOMAIN}.${NET_TLD} 22623
nc -z master0.${NET_SUBDOMAIN}.${NET_TLD} 22623
nc -z master1.${NET_SUBDOMAIN}.${NET_TLD} 22623
nc -z master2.${NET_SUBDOMAIN}.${NET_TLD} 22623

openshift-install --dir ./${NET_SUBDOMAIN}.${NET_TLD} wait-for bootstrap-complete --log-level=debug
export KUBECONFIG=~/${NET_SUBDOMAIN}.${NET_TLD}/auth/kubeconfig

oc get nodes
watch -n5 oc get clusteroperators
oc get pods --all-namespaces

openshift-install destroy cluster --dir ./${NET_SUBDOMAIN}.${NET_TLD}
rm -rf ./${NET_SUBDOMAIN}.${NET_TLD}
