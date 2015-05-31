#!/bin/bash

source config-compute

#install ntp
yum -y install ntp
systemctl enable ntpd.service
systemctl start ntpd.service

#openstack repos
yum -y install yum-plugin-priorities
yum -y install http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
yum -y install http://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm
yum -y upgrade
yum -y install openstack-selinux

#loosen things up
systemctl stop firewalld.service
systemctl disable firewalld.service
sed -i 's/enforcing/disabled/g' /etc/selinux/config
echo 0 > /sys/fs/selinux/enforce

echo 'net.ipv4.conf.all.rp_filter=0' >> /etc/sysctl.conf
echo 'net.ipv4.conf.default.rp_filter=0' >> /etc/sysctl.conf
sysctl -p

##get primary NIC info
#for i in $(ls /sys/class/net); do
#    if [ "$(cat /sys/class/net/$i/ifindex)" == '3' ]; then
#        NIC=$i
#        MY_MAC=$(cat /sys/class/net/$i/address)
#        echo "$i ($MY_MAC)"
#    fi
#done

#nova compute
yum -y install openstack-nova-compute sysfsutils libvirt-daemon-config-nwfilter

sed -i.bak "/\[DEFAULT\]/a \
rpc_backend = rabbit\n\
rabbit_host = $CONTROLLER_NAME\n\
rabbit_password = $SERVICE_PWD\n\
auth_strategy = keystone\n\
my_ip = $THISHOST_IP\n\
vnc_enabled = True\n\
vncserver_listen = 0.0.0.0\n\
vncserver_proxyclient_address = $THISHOST_IP\n\
novncproxy_base_url = http://$CONTROLLER_NAME:6080/vnc_auto.html\n\
network_api_class = nova.network.neutronv2.api.API\n\
security_group_api = neutron\n\
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver\n\
firewall_driver = nova.virt.firewall.NoopFirewallDriver\n\
instance_usage_audit = True\n\
instance_usage_audit_period = hour\n\
notify_on_state_change = vm_and_task_state\n\
notification_driver = nova.openstack.common.notifier.rpc_notifier\n\
notification_driver = ceilometer.compute.nova_notifier" /etc/nova/nova.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$CONTROLLER_NAME:5000/v2.0\n\
identity_uri = http://$CONTROLLER_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = nova\n\
admin_password = $SERVICE_PWD" /etc/nova/nova.conf

sed -i "/\[glance\]/a host = $CONTROLLER_NAME" /etc/nova/nova.conf

#if compute node is virtual - change virt_type to qemu
if [ $(egrep -c '(vmx|svm)' /proc/cpuinfo) == "0" ]; then
    sed -i '/\[libvirt\]/a virt_type = qemu' /etc/nova/nova.conf
fi

#install neutron
yum -y install openstack-neutron-ml2 openstack-neutron-openvswitch

sed -i '0,/\[DEFAULT\]/s//\[DEFAULT\]\
rpc_backend = rabbit\n\
rabbit_host = '"$CONTROLLER_NAME"'\
rabbit_password = '"$SERVICE_PWD"'\
auth_strategy = keystone\
core_plugin = ml2\
service_plugins = router\
allow_overlapping_ips = True/' /etc/neutron/neutron.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$CONTROLLER_NAME:5000/v2.0\n\
identity_uri = http://$CONTROLLER_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = neutron\n\
admin_password = $SERVICE_PWD" /etc/neutron/neutron.conf

#edit /etc/neutron/plugins/ml2/ml2_conf.ini
sed -i "/\[ml2\]/a \
type_drivers = flat,gre\n\
tenant_network_types = gre\n\
mechanism_drivers = openvswitch" /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[ml2_type_gre\]/a \
tunnel_id_ranges = 1:1000" /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[securitygroup\]/a \
enable_security_group = True\n\
enable_ipset = True\n\
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver\n\
[ovs]\n\
local_ip = $THISHOST_TUNNEL_IP\n\
enable_tunneling = True\n\
[agent]\n\
tunnel_types = gre" /etc/neutron/plugins/ml2/ml2_conf.ini

systemctl enable openvswitch.service
systemctl start openvswitch.service

sed -i "/\[neutron\]/a \
url = http://$CONTROLLER_NAME:9696\n\
auth_strategy = keystone\n\
admin_auth_url = http://$CONTROLLER_NAME:35357/v2.0\n\
admin_tenant_name = service\n\
admin_username = neutron\n\
admin_password = $SERVICE_PWD" /etc/nova/nova.conf

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

cp /usr/lib/systemd/system/neutron-openvswitch-agent.service \
  /usr/lib/systemd/system/neutron-openvswitch-agent.service.orig
sed -i 's,plugins/openvswitch/ovs_neutron_plugin.ini,plugin.ini,g' \
  /usr/lib/systemd/system/neutron-openvswitch-agent.service

systemctl enable libvirtd.service openstack-nova-compute.service
systemctl start libvirtd.service
systemctl start openstack-nova-compute.service
systemctl enable neutron-openvswitch-agent.service
systemctl start neutron-openvswitch-agent.service

#cinder storage node
#pvcreate /dev/sdb
pvcreate /dev/xvdb
#vgcreate cinder-volumes /dev/sdb
vgcreate cinder-volumes /dev/xvdb

yum -y install openstack-cinder targetcli python-oslo-db MySQL-python

sed -i.bak "/\[database\]/a connection = mysql://cinder:$SERVICE_PWD@$CONTROLLER_IP/cinder" /etc/cinder/cinder.conf

sed -i '0,/\[DEFAULT\]/s//\[DEFAULT\]\
rpc_backend = rabbit\
rabbit_host = '"$CONTROLLER_NAME"'\
rabbit_password = '"$SERVICE_PWD"'\
auth_strategy = keystone\
my_ip = '"$THISHOST_IP"'\
glance_host= '"$CONTROLLER_NAME"'\
iscsi_helper = lioadm/' /etc/cinder/cinder.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$CONTROLLER_NAME:5000/v2.0\n\
identity_uri = http://$CONTROLLER_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = cinder\n\
admin_password = $SERVICE_PWD" /etc/cinder/cinder.conf

systemctl enable openstack-cinder-volume.service target.service
systemctl start openstack-cinder-volume.service target.service

#install Telemetry Compute agent

yum -y install openstack-ceilometer-compute python-ceilometerclient python-pecan

sed -i "/\[DEFAULT\]/a \
rabbit_host = $THISHOST_NAME\n\
rabbit_password = $SERVICE_PWD" /etc/ceilometer/ceilometer.conf

sed -i "/\[publisher\]/a \
metering_secret = $SERVICE_PWD" /etc/ceilometer/ceilometer.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$CONTROLLER_NAME:5000/v2.0\n\
identity_uri = http://$CONTROLLER_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = ceilometer\n\
admin_password = $SERVICE_PWD" /etc/ceilometer/ceilometer.conf

sed -i "/\[service_credentials\]/a \
os_auth_url = http://$THISHOST_NAME:5000/v2.0\n\
os_username = ceilometer\n\
os_tenant_name = service\n\
os_password = $SERVICE_PWD\n\
os_endpoint_type = internalURL" /etc/ceilometer/ceilometer.conf

systemctl enable openstack-ceilometer-compute.service
systemctl start openstack-ceilometer-compute.service

echo 'export OS_TENANT_NAME=admin' > creds
echo 'export OS_USERNAME=admin' >> creds
echo 'export OS_PASSWORD='"$ADMIN_PWD" >> creds
echo 'export OS_AUTH_URL=http://'"$CONTROLLER_NAME"':35357/v2.0' >> creds
source creds

