# The wan segment: a dedicated libvirt NAT network holding L1 and nothing
# else. No DHCP — L1's address is static, so behaviour is identical on any
# network the laptop happens to be on.
{ site }:

''
  <network>
    <name>${site.networkName}</name>
    <forward mode='nat'/>
    <bridge name='${site.bridgeName}' stp='on' delay='0'/>
    <ip address='${site.wan.gateway}' netmask='${site.wan.netmask}'>
    </ip>
  </network>
''
