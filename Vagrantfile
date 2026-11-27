
Vagrant.configure("2") do |config|

  # Debian 13
  config.vm.box = "bento/debian-13"

  # Název virtuálního serveru
  config.vm.hostname = "zabbix-server"

  # Přesměrování webového rozhraní
  config.vm.network "forwarded_port",
    guest: 80,
    host: 8080,
    host_ip: "127.0.0.1"

  # Nastavení VirtualBoxu
  config.vm.provider "virtualbox" do |vb|
    vb.name = "Zabbix-Debian13"
    vb.memory = 2048
    vb.cpus = 2
  end

  # Automatická instalace
  config.vm.provision "shell",
    path: "scripts/install.sh",
    privileged: true

end
