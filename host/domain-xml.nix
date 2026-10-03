# The libvirt domain for L1, generated from the flake so it stays text and
# versioned. The system disk is referenced through a symlink, so an image swap
# needs no XML edit.
{
  site,
  virtiofsdWrapper,
  virtiofsdReadonlyWrapper,
}:

''
  <domain type='kvm'>
    <name>${site.domainName}</name>
    <uuid>${site.domainUuid}</uuid>
    <description>L1 carrier for the sandboxed LLM agent stack</description>

    <memory unit='MiB'>${toString site.l1.memoryMiB}</memory>
    <currentMemory unit='MiB'>${toString site.l1.memoryMiB}</currentMemory>
    <!-- Mandatory for virtiofs: without shared memfd backing the filesystem
         will not attach. Also why there is no balloon device below. -->
    <memoryBacking>
      <source type='memfd'/>
      <access mode='shared'/>
    </memoryBacking>

    <vcpu placement='static'>${toString site.l1.vcpu}</vcpu>
    <!-- <period>/<quota> are per vCPU; the domain-wide cap is the global pair.
         This one knob bounds the whole nested tree, sandboxes included. -->
    <cputune>
      <global_period>${toString site.l1.cpuPeriod}</global_period>
      <global_quota>${toString site.l1.cpuQuota}</global_quota>
    </cputune>

    <os>
      <type arch='x86_64' machine='q35'>hvm</type>
      <boot dev='hd'/>
    </os>

    <features>
      <acpi/>
      <apic/>
    </features>

    <!-- Exposes vmx/svm to L1. Required: the sandboxes are nested guests. -->
    <cpu mode='host-passthrough' check='none'/>

    <clock offset='utc'>
      <timer name='rtc' tickpolicy='catchup'/>
      <timer name='pit' tickpolicy='delay'/>
      <timer name='hpet' present='no'/>
    </clock>

    <on_poweroff>destroy</on_poweroff>
    <on_reboot>restart</on_reboot>
    <on_crash>destroy</on_crash>

    <pm>
      <suspend-to-mem enabled='no'/>
      <suspend-to-disk enabled='no'/>
    </pm>

    <!-- Run this domain, and the virtiofsd it spawns, as root without
         touching /etc/libvirt/qemu.conf, which keeps every other VM on the
         host at the distribution default. Root is required because creating
         a file owned by uid 1000 needs CAP_CHOWN. relabel='no': the disks are
         already root-owned, so libvirt must not chown anything. -->
    <seclabel type='static' model='dac' relabel='no'>
      <label>+0:+0</label>
    </seclabel>

    <devices>
      <disk type='file' device='disk'>
        <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
        <source file='${site.imageDir}/l1-system-current.qcow2'/>
        <target dev='vda' bus='virtio'/>
      </disk>
      <disk type='file' device='disk'>
        <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
        <source file='${site.imageDir}/l1-data.raw'/>
        <target dev='vdb' bus='virtio'/>
      </disk>

      <!-- The export root. virtiofsd runs as root under libvirt, confined by
           its own namespace sandbox and seccomp filter, which is what makes
           uid 1000 end to end literally true. The binary is virtiofsd set
           to never use inode file handles; see pin_virtiofsd_wrapper in
           flake.nix for why nesting needs it. -->
      <filesystem type='mount' accessmode='passthrough'>
        <driver type='virtiofs'/>
        <binary path='${virtiofsdWrapper}'/>
        <source dir='${site.exportRoot}'/>
        <target dir='projects'/>
      </filesystem>

      <!-- Configuration files for every sandbox's home. A separate export
           from the workspace because the two have different lifetimes and
           different scopes: this one is shared by every project. Read-only,
           enforced by this virtiofsd rather than by L1's mount option. -->
      <filesystem type='mount' accessmode='passthrough'>
        <driver type='virtiofs'/>
        <binary path='${virtiofsdReadonlyWrapper}'/>
        <source dir='${site.dotfilesRoot}'/>
        <target dir='dotfiles'/>
      </filesystem>

      <interface type='network'>
        <source network='${site.networkName}'/>
        <model type='virtio'/>
      </interface>

      <serial type='pty'>
        <target type='isa-serial' port='0'>
          <model name='isa-serial'/>
        </target>
      </serial>
      <console type='pty'>
        <target type='serial' port='0'/>
      </console>

      <channel type='unix'>
        <target type='virtio' name='org.qemu.guest_agent.0'/>
      </channel>

      <rng model='virtio'>
        <backend model='random'>/dev/urandom</backend>
      </rng>

      <!-- Headless: the console is the serial port. -->
      <video>
        <model type='none'/>
      </video>
      <!-- Fixed memory. Shared backing plus nested guests make ballooning
           unreliable. -->
      <memballoon model='none'/>
    </devices>
  </domain>
''
