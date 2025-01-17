#!/usr/bin/env bash

# Copyright 2021 The Rook Authors. All rights reserved.
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

set -xe

#############
# VARIABLES #
#############
BLOCK=$(sudo lsblk --paths | awk '/14G/ {print $1}' | head -1)

#############
# FUNCTIONS #
#############

function install_deps() {
    sudo wget https://github.com/mikefarah/yq/releases/download/3.4.1/yq_linux_amd64 -O /usr/bin/yq
    sudo chmod +x /usr/bin/yq
}

function print_k8s_cluster_status() {
    kubectl cluster-info
    kubectl get pods -n kube-system
}

function use_local_disk() {
    BLOCK_DATA_PART=${BLOCK}1
    sudo dmsetup version || true
    sudo swapoff --all --verbose
    sudo umount /mnt
    # search for the device since it keeps changing between sda and sdb
    sudo wipefs --all --force "$BLOCK_DATA_PART"
    sudo lsblk
}

function use_local_disk_for_integration_test() {
    sudo swapoff --all --verbose
    sudo umount /mnt
    # search for the device since it keeps changing between sda and sdb
    PARTITION="${BLOCK}1"
    sudo wipefs --all --force "$PARTITION"
    sudo lsblk
    # add a udev rule to force the disk partitions to ceph
    # we have observed that some runners keep detaching/re-attaching the additional disk overriding the permissions to the default root:disk
    # for more details see: https://github.com/rook/rook/issues/7405
    echo "SUBSYSTEM==\"block\", ATTR{size}==\"29356032\", ACTION==\"add\", RUN+=\"/bin/chown 167:167 $PARTITION\"" | sudo tee -a /etc/udev/rules.d/01-rook.rules
}

function create_partitions_for_osds() {
    tests/scripts/create-bluestore-partitions.sh --disk "$BLOCK" --osd-count 2
    sudo lsblk
}

function create_bluestore_partitions_and_pvcs() {
    BLOCK_PART="$BLOCK"2
    DB_PART="$BLOCK"1
    tests/scripts/create-bluestore-partitions.sh --disk "$BLOCK" --bluestore-type block.db --osd-count 1
    tests/scripts/localPathPV.sh "$BLOCK_PART" "$DB_PART"
}

function create_bluestore_partitions_and_pvcs_for_wal(){
    BLOCK_PART="$BLOCK"3
    DB_PART="$BLOCK"1
    WAL_PART="$BLOCK"2
    tests/scripts/create-bluestore-partitions.sh --disk "$BLOCK" --bluestore-type block.wal --osd-count 1
    tests/scripts/localPathPV.sh "$BLOCK_PART" "$DB_PART" "$WAL_PART"
}

function build_rook() {
    GOPATH=$(go env GOPATH) make clean
    # set VERSION to a dummy value since Jenkins normally sets it for us. Do this to make Helm happy and not fail with "Error: Invalid Semantic Version"
    make -j$nproc IMAGES='ceph' VERSION=0 build
    # validate build
    tests/scripts/validate_modified_files.sh build
    docker images
    docker tag $(docker images | awk '/build-/ {print $1}') rook/ceph:master
}

function validate_yaml() {
    cd cluster/examples/kubernetes/ceph
    kubectl create -f crds.yaml -f common.yaml
    # skipping folders and some yamls that are only for openshift.
    kubectl create $(ls -I scc.yaml -I "*-openshift.yaml" -I "*.sh" -I "*.py" -p | grep -v / | awk ' { print " -f " $1 } ') --dry-run
}

function create_cluster_prerequisites() {
    cd cluster/examples/kubernetes/ceph
    kubectl create -f crds.yaml -f common.yaml
}

function deploy_cluster() {
    cd cluster/examples/kubernetes/ceph
    kubectl create -f operator.yaml
    sed -i "s|#deviceFilter:|deviceFilter: $(lsblk | awk '/14G/ {print $1}' | head -1)|g" cluster-test.yaml
    kubectl create -f cluster-test.yaml
    kubectl create -f object-test.yaml
    kubectl create -f pool-test.yaml
    kubectl create -f filesystem-test.yaml
    kubectl create -f rbdmirror.yaml
    kubectl create -f nfs-test.yaml
    kubectl create -f toolbox.yaml
}

function wait_for_prepare_pod() {
    timeout 180 sh -c 'until kubectl -n rook-ceph logs -f $(kubectl -n rook-ceph get pod -l app=rook-ceph-osd-prepare -o jsonpath='{.items[*].metadata.name}'); do sleep 5; done' || true
    timeout 60 sh -c 'until kubectl -n rook-ceph logs $(kubectl -n rook-ceph get pod -l app=rook-ceph-osd,ceph_daemon_id=0 -o jsonpath='{.items[*].metadata.name}') --all-containers; do echo "waiting for osd container" && sleep 1; done' || true
    kubectl -n rook-ceph describe job/$(kubectl -n rook-ceph get pod -l app=rook-ceph-osd-prepare -o jsonpath='{.items[*].metadata.name}') || true
    kubectl -n rook-ceph describe deploy/rook-ceph-osd-0 || true
}

function wait_for_ceph_to_be_ready() {
    DAEMONS=$1
    OSD_COUNT=$2
    mkdir test
    tests/scripts/validate_cluster.sh $DAEMONS $OSD_COUNT
    kubectl -n rook-ceph get pods
}

function check_ownerreferences() {
    curl -L https://github.com/kubernetes-sigs/kubectl-check-ownerreferences/releases/download/v0.2.0/kubectl-check-ownerreferences-linux-amd64.tar.gz -o kubectl-check-ownerreferences-linux-amd64.tar.gz
    tar xzvf kubectl-check-ownerreferences-linux-amd64.tar.gz
    chmod +x kubectl-check-ownerreferences
    ./kubectl-check-ownerreferences -n rook-ceph
}

function create_LV_on_disk() {
    sudo sgdisk --zap-all "${BLOCK}"
    VG=test-rook-vg
    LV=test-rook-lv
    sudo pvcreate "$BLOCK"
    sudo vgcreate "$VG" "$BLOCK"
    sudo lvcreate -l 100%FREE -n "${LV}" "${VG}"
    tests/scripts/localPathPV.sh /dev/"${VG}"/${LV}
    kubectl create -f cluster/examples/kubernetes/ceph/crds.yaml
    kubectl create -f cluster/examples/kubernetes/ceph/common.yaml
}

selected_function="$1"
if [ "$selected_function" = "wait_for_ceph_to_be_ready" ]; then
    $selected_function $2 $3
else
    $selected_function
fi

if [ $? -ne 0 ]; then
    echo "Function call to '$selected_function' was not successful" >&2
    exit 1
fi
