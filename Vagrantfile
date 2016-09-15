
# Debian URL to DTB
# "ftp://ftp.us.debian.org/debian/dists/stretch/main/installer-armhf/current/images/device-tree/sun5i-r8-chip.dtb"


Vagrant.configure("2") do |config|

  # Create a forwarded port mapping which allows access to a specific port
  # within the machine from a port on the host machine. In the example below,
  # accessing "localhost:8080" will access port 80 on the guest machine.
  # config.vm.network "forwarded_port", guest: 80, host: 8080

  # Create a private network, which allows host-only access to the machine
  # using a specific IP.
  # config.vm.network "private_network", ip: "192.168.33.10"

  # Create a public network, which generally matched to bridged network.
  # Bridged networks make the machine appear as another physical device on
  # your network.
  # config.vm.network "public_network"

  # Share an additional folder to the guest VM. The first argument is
  # the path on the host to the actual folder. The second argument is
  # the path on the guest to mount the folder. And the optional third
  # argument is a set of non-required options.
  # config.vm.synced_folder "../data", "/vagrant_data"

  # Provider-specific configuration so you can fine-tune various
  # backing providers for Vagrant. These expose provider-specific options.
  config.vm.provider :libvirt do |domain|
    domain.uri = 'qemu+unix:///system'
    domain.driver = "qemu"
    domain.host = "virtualized"
    domain.memory = 256
    domain.boot "network"
    domain.machine_type = "realview-pb-a8"  # sun5i-r8; cortex-a8; allwinner
    domain.machine_arch = "armv7l" # arm7l, armhf
    # @NOTE I don't think this is related to domain virtualization.
    domain.cpu_mode = "custom"
    domain.cpu_model = "cortex-a8"
    domain.cpu_fallback = "allow"
    domain.dtb = File.join(Dir.pwd, "sun5i-r8-chip.dtb")
    domain.emulator_path = "/usr/bin/qemu-system-arm"
  end

  # Enable provisioning with a shell script. Additional provisioners such as
  # Puppet, Chef, Ansible, Salt, and Docker are also available. Please see the
  # documentation for more information about their specific syntax and use.
  # config.vm.provision "shell", inline: <<-SHELL
  #   apt-get update
  #   apt-get install -y apache2
  # SHELL
end
