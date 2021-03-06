#!/bin/bash
# Copyright 2017 The Bootkube-CI Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
### PREPARE THE ENVIRONMENT:
source ../.bootkube_env                                      ### COLLECT VARS FROM ENV FILE    ###
export MARIADB_SIZE=15Gi                                     ### COLLECT VARS FROM ENV FILE    ###
export OSH_BRANCH='239b83b1b51f20091fd88bcff7b1994406488adf' ### GIT COMMIT HAS OR BRANCH NAME ###
# export SIGIL_VERSION='0.4.0'                               ### SIGIL VERSION                 ###

### APPLY DEVELOPMENT RBAC POLICY:
kubectl apply -f $BOOTKUBE_DIR/bootkube-ci/deploy-rbac/dev.yaml --validate=false

### PREPARE DEPENDENCIES:
sudo apt-get install -y python-minimal ceph-common
git clone https://github.com/openstack/openstack-helm.git $BOOTKUBE_DIR/bootkube-ci/openstack-helm && cd $BOOTKUBE_DIR/bootkube-ci/openstack-helm && git checkout $OSH_BRANCH
# git apply ../deploy-addons/changes.patch
# v1k0d3n: Do we really need a variable below?
curl -L https://github.com/gliderlabs/sigil/releases/download/v0.4.0/sigil_0.4.0_Linux_x86_64.tgz | sudo tar -zxC /usr/local/bin

### LABEL THE NODES:
kubectl label nodes openstack-control-plane=enabled --all --overwrite
kubectl label nodes ceph-storage=enabled --all --overwrite
kubectl label nodes openvswitch=enabled --all --overwrite
kubectl label nodes openstack-compute-node=enabled --all --overwrite

### PREPARE HELM:
helm init
helm serve &
helm repo remove stable
helm repo add local "http://localhost:8879/charts"
sudo mkdir -p /var/lib/nova/instances
export osd_cluster_network=$KUBE_POD_CIDR
export osd_public_network=$KUBE_POD_CIDR
cd $BOOTKUBE_DIR/bootkube-ci/openstack-helm/helm-toolkit/utils/secret-generator
./generate_secrets.sh all `./generate_secrets.sh fsid`
cd $BOOTKUBE_DIR/bootkube-ci/openstack-helm/
make

### BRING UP THE ENVIRONMENT:
# NOTE: The line below would replace the ceph install just below in cases that favor a large /home/ and small / partitions.
# If this is your case, uncomment the line below and comment the second ceph install line.
# helm install --name=ceph local/ceph --set images.daemon=quay.io/v1k0d3n/ceph-daemon:tag-build-master-jewel-ubuntu-16.04 --set network.public="$KUBE_POD_CIDR" --set storage.osd_directory=/home/ceph/osd,storage.var_directory=/home/ceph/var,storage.mon_directory=/home/ceph/mon --namespace=ceph
helm install --name=ceph local/ceph --set images.daemon=quay.io/v1k0d3n/ceph-daemon:tag-build-master-jewel-ubuntu-16.04 --set network.public="$KUBE_POD_CIDR" --namespace=ceph
helm install --name=bootstrap-ceph local/bootstrap --namespace=ceph
helm install --name=bootstrap-openstack local/bootstrap --namespace=openstack
# NOTE: The following lines create the claims in ceph for Glance (images) and cinder (volumes).
echo -e -n "Waiting for all Ceph components to be in a running state..."
while true; do
  running_count=$(sudo kubectl --kubeconfig=/etc/kubernetes/kubeconfig get pods -n ceph --no-headers 2>/dev/null | grep "Running" | grep "ceph" | wc -l)
  ### Expect all components to be out of a "ContainerCreating" state before collecting log data (this includes CrashLoopBackOff states):
  if [ "$running_count" -ge 6 ]; then
    break
  fi
  echo -n "."
  sleep 1
done
helm install --name=mariadb local/mariadb --set volume.size=$MARIADB_SIZE --namespace=openstack
kubectl exec -n ceph -it ceph-mon-0 ceph osd pool create volumes 25
kubectl exec -n ceph -it ceph-mon-0 ceph osd pool create images 15
helm install --name=rabbitmq local/rabbitmq --namespace=openstack
helm install --name=rabbitmq-etcd local/etcd --namespace=openstack
helm install --name=memcached local/memcached --namespace=openstack
helm install --name=keystone local/keystone network.node_port_enable=true --namespace=openstack
helm install --name=glance local/glance --namespace=openstack
helm install --name=heat local/heat --namespace=openstack
helm install --name=cinder local/cinder --namespace=openstack
helm install --name=nova local/nova --namespace=openstack
helm install --name=neutron local/neutron --namespace=openstack
helm install --name=horizon local/horizon network.node_port_enable=true --namespace=openstack
# Remove the exit statement if you wish any of the following Charts
exit
helm install --name=barbican local/barbican --namespace=openstack
helm install --name=mistral local/mistral --namespace=openstack
helm install --name=magnum local/magnum --namespace=openstack
