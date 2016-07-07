#!/bin/bash

echo $$ >> ~/run_tests.pid

DEVSTACK_GATE_REPO="https://github.com/citrix-openstack/devstack-gate"
DEVSTACK_GATE_BRANCH="master"

export WORKSPACE=${WORKSPACE:-/home/jenkins/workspace/testing}

# Trap the exit code + log a final message
function trapexit {
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
	echo "Passed" | tee ~/result.txt
    else
	echo "Failed" | tee ~/result.txt
    fi

    LOGS_DIR=$WORKSPACE/logs
    [ -e ${LOGS_DIR} ] || mkdir -p ${LOGS_DIR}
    mv ~/run_tests.log ${LOGS_DIR}
    # Do not use 'exit' - bash will preserve the status
}

trap trapexit EXIT

set -ex

#REPLACE_ENV

export ZUUL_PROJECT=${ZUUL_PROJECT:-openstack/nova}
export ZUUL_BRANCH=${ZUUL_BRANCH:-master}
export ZUUL_REF=${ZUUL_REF:-HEAD}
# Values from the job template
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-1}
export DEVSTACK_GATE_TEMPEST_FULL=${DEVSTACK_GATE_TEMPEST_FULL:-0}
export DEVSTACK_GATE_NEUTRON=${DEVSTACK_GATE_NEUTRON:-0}

export PYTHONUNBUFFERED=true
export DEVSTACK_GATE_VIRT_DRIVER=xenapi
# Set this to the time in milliseconds that the entire job should be
# allowed to run before being aborted (default 120 minutes=7200000ms).
# This may be supplied by Jenkins based on the configured job timeout
# which is why it's in this convenient unit.
export BUILD_TIMEOUT=${BUILD_TIMEOUT:-10800000}
export DEVSTACK_GATE_XENAPI_DOM0_IP=192.168.33.2
export DEVSTACK_GATE_XENAPI_DOMU_IP=192.168.33.1
export DEVSTACK_GATE_XENAPI_PASSWORD=password
export DEVSTACK_GATE_CLEAN_LOGS=0

# set regular expression
source /home/jenkins/xenapi-os-testing/tempest_exclusion_list
if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
    export DEVSTACK_GATE_TEMPEST_REGEX="$NEUTRON_NETWORK_TEMPEST_REGEX"
else
    export DEVSTACK_GATE_TEMPEST_REGEX="$NOVA_NETWORK_TEMPEST_REGEX"
fi

set -u

# Need to let jenkins sudo as domzero
# TODO: Merge this somewhere better?
TEMPFILE=`mktemp`
echo "jenkins ALL=(ALL) NOPASSWD:ALL" >$TEMPFILE
chmod 0440 $TEMPFILE
sudo chown root:root $TEMPFILE
sudo mv $TEMPFILE /etc/sudoers.d/40_jenkins

function run_in_domzero() {
    sudo -u domzero ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.33.2 "$@"
}

# Get some parameters
APP=$(run_in_domzero xe vm-list name-label=$APPLIANCE_NAME --minimal </dev/null)

# Create a vm network
VMNET=$(run_in_domzero xe network-create name-label=vmnet </dev/null)
VMVIF=$(run_in_domzero xe vif-create vm-uuid=$APP network-uuid=$VMNET device=3 </dev/null)
run_in_domzero xe vif-plug uuid=$VMVIF </dev/null
export VMBRIDGE=$(run_in_domzero xe network-param-get param-name=bridge uuid=$VMNET </dev/null)

# Create pub network
PUBNET=$(run_in_domzero xe network-create name-label=pubnet </dev/null)
PUBVIF=$(run_in_domzero xe vif-create vm-uuid=$APP network-uuid=$PUBNET device=4 </dev/null)
run_in_domzero xe vif-plug uuid=$PUBVIF </dev/null

if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
    # Set to keep localrc file as we will config localrc during pre_test_hook
    export KEEP_LOCALRC=1

    # Create integration network for compute node
    INTNET=$(run_in_domzero xe network-create name-label=intnet </dev/null)
    export INTBRIDGE=$(run_in_domzero xe network-param-get param-name=bridge uuid=$INTNET </dev/null)

    # Remove restriction of linux bridge usage in Dom0, linux bridge is used for security group
    run_in_domzero rm -f /etc/modprobe.d/blacklist-bridge*
fi

# Hack iSCSI SR
run_in_domzero << SRHACK
set -eux
sed -ie "s/'phy'/'aio'/g" /opt/xensource/sm/ISCSISR.py
SRHACK

# This is important, otherwise dhcp client will fail
for dev in eth0 eth1 eth2 eth3 eth4; do
    sudo ethtool -K $dev tx off
done

# Add a separate disk
# Not used as VOLUME_BACKING_DEVICE is ignored by devstack
#SR=$(run_in_domzero xe sr-list type=ext  --minimal </dev/null)
#VDI=$(run_in_domzero xe vdi-create name-label=disk-for-volumes virtual-size=20GiB sr-uuid=$SR type=user </dev/null)
#VBD=$(run_in_domzero xe vbd-create vm-uuid=$APP vdi-uuid=$VDI device=1 </dev/null)
#run_in_domzero xe vbd-plug uuid=$VBD </dev/null

# For development:
export SKIP_DEVSTACK_GATE_PROJECT=1

sudo pip install -i https://pypi.python.org/simple/ XenAPI
sudo pip install pyyaml

LOCATION_OF_LOCAL_GIT_REPOSITORIES=/opt/git

# These came from the Readme
export ZUUL_URL=https://review.openstack.org/p
export REPO_URL=$LOCATION_OF_LOCAL_GIT_REPOSITORIES

# Check out a custom branch
(
    cd $LOCATION_OF_LOCAL_GIT_REPOSITORIES/openstack-infra/devstack-gate/
    sudo git remote add DEVSTACK_GATE_REPO "$DEVSTACK_GATE_REPO"
    sudo git fetch DEVSTACK_GATE_REPO
    sudo git checkout "DEVSTACK_GATE_REPO/$DEVSTACK_GATE_BRANCH" -B DEVSTACK_GATE_BRANCH
)
mkdir -p $WORKSPACE

# Need to let stack sudo as domzero too
# TODO: Merge this somewhere better?
TEMPFILE=`mktemp`
echo "stack ALL=(ALL) NOPASSWD:ALL" >$TEMPFILE
chmod 0440 $TEMPFILE
sudo chown root:root $TEMPFILE
sudo mv $TEMPFILE /etc/sudoers.d/40_stack_sh

function pre_test_hook() {
# Plugins
tar -czf - -C /opt/stack/new/nova/plugins/xenserver/xenapi/etc/xapi.d/plugins/ ./ |
    run_in_domzero \
    'tar -xzf - -C /etc/xapi.d/plugins/ && chmod a+x /etc/xapi.d/plugins/*'

# Console log
tar -czf - -C /opt/stack/new/nova/tools/xenserver/ rotate_xen_guest_logs.sh |
    run_in_domzero \
    'tar -xzf - -C /root/ && chmod +x /root/rotate_xen_guest_logs.sh && mkdir -p /var/log/xen/guest'
run_in_domzero crontab - << CRONTAB
* * * * * /root/rotate_xen_guest_logs.sh
CRONTAB

(
    cd /opt/stack/new/devstack
    {
        echo "set -eux"
        cat tools/xen/functions
        echo "create_directory_for_images"
        echo "create_directory_for_kernels"
    } | run_in_domzero
)

## config interface and localrc for neutron network
(
    if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
        # Set IP address for eth3(vmnet) and eth4(pubnet)
        sudo ip addr add 10.1.0.254/24 broadcast 10.1.0.255 dev eth3
        sudo ip link set eth3 up
        sudo ip addr add 172.24.5.1/24 broadcast 172.24.5.255 dev eth4
        sudo ip link set eth4 up

        # Set localrc for neutron network
        localrc="/opt/stack/new/devstack/localrc"
        cat <<EOF >>"$localrc"
ENABLED_SERVICES+=",neutron,q-agt,q-domua,q-meta,q-svc,q-dhcp,q-l3,q-metering,-n-net"
Q_PLUGIN=ml2
Q_USE_SECGROUP=False
ENABLE_TENANT_VLANS="True"
ENABLE_TENANT_TUNNELS="False"
Q_ML2_TENANT_NETWORK_TYPE="vlan"
ML2_VLAN_RANGES="physnet1:1000:1024"
MULTI_HOST=0
XEN_INTEGRATION_BRIDGE=$INTBRIDGE
FLAT_NETWORK_BRIDGE=$VMBRIDGE
Q_AGENT=openvswitch
Q_ML2_PLUGIN_MECHANISM_DRIVERS=openvswitch
Q_ML2_PLUGIN_TYPE_DRIVERS=vlan
OVS_PHYSICAL_BRIDGE=br-ex
PUBLIC_BRIDGE=br-ex
# Set instance build timeout to 300s in tempest.conf
BUILD_TIMEOUT=390
EOF

        # Set local.conf for neutron ovs-agent in compute node
        localconf="/opt/stack/new/devstack/local.conf"
        cat <<EOF >>"$localconf"
[[local|localrc]]

[[post-config|/etc/neutron/plugins/ml2/ml2_conf.ini]]
[ovs]
ovsdb_interface = vsctl
of_interface = ovs-ofctl
EOF

    fi
)

}

# export this function to be used by devstack-gate
export -f pre_test_hook
# export the functions invoked by pre_test_hook
export -f run_in_domzero

# Insert a rule as the first position - allow all traffic on the mgmt interface
# Other rules are inserted by config/modules/iptables/templates/rules.erb
sudo iptables -I INPUT 1 -i eth2 -s 192.168.33.0/24 -j ACCEPT

cd $WORKSPACE
git clone $DEVSTACK_GATE_REPO -b $DEVSTACK_GATE_BRANCH

# devstack-gate referneces $BASE/new for where it expects devstack-gate... Create copy there too
# When we can disable SKIP_DEVSTACK_GATE_PROJECT (i.e. everything upstreamed) then this can be removed.
( sudo mkdir -p /opt/stack/new && sudo chown -R jenkins:jenkins /opt/stack/new && cd /opt/stack/new && git clone "$DEVSTACK_GATE_REPO" -b "$DEVSTACK_GATE_BRANCH" )

cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh

# OpenStack doesn't care much about unset variables...
set +ue
source ./safe-devstack-vm-gate-wrap.sh