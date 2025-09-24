#!/bin/bash

# Função para listar VMs existentes
list_existing_vms() {
    echo "=== VMs existentes ==="
    qm list | grep -v VMID
    echo
}

# Função para listar distribuições disponíveis
list_distributions() {
    echo "=== Distribuicoes disponiveis ==="
    echo "1. Ubuntu 22.04 LTS"
    echo "2. Debian 12"
    echo "3. CentOS Stream 9"
    echo "4. Oracle Linux 9"
    echo
}

# Função para baixar template baseado na escolha
download_template() {
    local choice=$1
    local template_path=""
    local url=""
    
    case $choice in
        1)
            template_path="/var/lib/vz/template/iso/ubuntu-22.04-server-cloudimg-amd64.img"
            url="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
            ;;
        2)
            template_path="/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2"
            url="https://cloud.debian.org/images/cloud/bookworm/20241004-1890/debian-12-generic-amd64-20241004-1890.qcow2"
            ;;
        3)
            template_path="/var/lib/vz/template/iso/centos-stream-9.qcow2"
            url="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-20241202.0.x86_64.qcow2"
            ;;
        4)
            template_path="/var/lib/vz/template/iso/oracle-linux-9.qcow2"
            url="https://yum.oracle.com/templates/OracleLinux/OL9/u5/x86_64/OL9U5_x86_64-kvm-b237.qcow2"
            ;;
    esac
    
    if [ ! -f "$template_path" ]; then
        echo "Baixando template..." >&2
        wget -O "$template_path" "$url" >&2
    else
        echo "Template ja existe." >&2
    fi
    echo "$template_path"
}

# Função para obter usuário padrão por distribuição
get_default_user() {
    local choice=$1
    case $choice in
        1) echo "ubuntu" ;;
        2) echo "debian" ;;
        3) echo "cloud-user" ;;
        4) echo "opc" ;;
    esac
}

# Função para converter GB para MB
convert_gb_to_mb() {
    local gb=$1
    echo $((gb * 1024))
}

# Função para criar cloud-init personalizado
create_cloud_init() {
    local vmid=$1
    local user=$2
    local password=$3
    local hostname=$4
    local distro=$5
    
    mkdir -p /var/lib/vz/snippets
    
    # Configuração base para todas as distribuições
    cat > /var/lib/vz/snippets/user-$vmid.yml << EOF
#cloud-config
hostname: $hostname
manage_etc_hosts: true
users:
  - name: $user
    plain_text_passwd: $password
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

ssh_pwauth: true
disable_root: false

write_files:
  - path: /etc/ssh/sshd_config.d/99-enable-password.conf
    content: |
      PasswordAuthentication yes
      PubkeyAuthentication yes
    permissions: '0644'

runcmd:
EOF

    # Comandos específicos por distribuição
    case $distro in
        1|2) # Ubuntu/Debian
            cat >> /var/lib/vz/snippets/user-$vmid.yml << EOF
  - systemctl restart ssh
  - systemctl enable ssh
  - hostnamectl set-hostname $hostname
EOF
            ;;
        3|4) # CentOS/Oracle Linux
            cat >> /var/lib/vz/snippets/user-$vmid.yml << EOF
  - systemctl restart sshd
  - systemctl enable sshd
  - hostnamectl set-hostname $hostname
EOF
            ;;
    esac
}

clear
echo "=== Criador Automatico VM ProxMox ==="
echo

# Listar VMs existentes
list_existing_vms

# Solicitar dados da VM
while true; do
    read -p "Digite o ID para a nova VM: " VMID
    if qm status $VMID &>/dev/null; then
        echo "ID $VMID ja existe! Escolha outro."
    else
        break
    fi
done

read -p "Digite o nome da VM: " VMNAME
read -p "Digite a quantidade de RAM em GB: " MEMORY_GB
MEMORY=$(convert_gb_to_mb $MEMORY_GB)
read -p "Digite o numero de cores da CPU: " CORES
read -p "Digite o tamanho do disco em GB: " DISK_SIZE

# Escolher distribuição
list_distributions
read -p "Selecione a distribuicao (1-4): " DISTRO_CHOICE

# Obter usuário padrão baseado na distribuição
DEFAULT_USER=$(get_default_user $DISTRO_CHOICE)
read -p "Digite o usuario para a VM (padrao: $DEFAULT_USER): " VM_USER
VM_USER=${VM_USER:-$DEFAULT_USER}
read -s -p "Digite a senha para a VM: " VM_PASSWORD
echo

# Baixar template
TEMPLATE_PATH=$(download_template $DISTRO_CHOICE)

# Configurações fixas
BRIDGE="vmbr0"
STORAGE="local-lvm"

echo
echo "=== Resumo ==="
echo "ID: $VMID | Nome: $VMNAME | RAM: ${MEMORY_GB}GB | CPU: $CORES cores | Disco: ${DISK_SIZE}GB"
echo "Usuario: $VM_USER"
echo

read -p "Confirma criacao? (s/n): " CONFIRM
[[ $CONFIRM != "s" ]] && { echo "Cancelado."; exit 1; }

echo "Criando VM..."

# Verificar se template existe
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "ERRO: Template nao encontrado"
    exit 1
fi

# Criar cloud-init personalizado
create_cloud_init $VMID "$VM_USER" "$VM_PASSWORD" "$VMNAME" $DISTRO_CHOICE

# Criar VM - todas com BIOS tradicional
qm create $VMID \
    --name "$VMNAME" \
    --memory $MEMORY \
    --cores $CORES \
    --net0 virtio,bridge=$BRIDGE \
    --scsihw virtio-scsi-pci \
    --ostype l26

# Importar disco do template
echo "Importando template..."
qm importdisk $VMID "$TEMPLATE_PATH" $STORAGE --format qcow2 >/dev/null

# Configurar disco principal
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0

# Redimensionar disco se necessário
if [ $DISK_SIZE -gt 2 ]; then
    qm resize $VMID scsi0 ${DISK_SIZE}G
fi

# Configurar cloud-init
qm set $VMID --ide2 $STORAGE:cloudinit
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --agent enabled=1

# Aplicar cloud-init personalizado
qm set $VMID --cicustom "user=local:snippets/user-$VMID.yml"
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --nameserver 8.8.8.8

# Iniciar VM
echo "Iniciando VM..."
qm start $VMID

echo "VM '$VMNAME' criada com sucesso!"
echo "SSH com senha sera ativado automaticamente"
echo "Aguarde 2-3 minutos e teste: ssh $VM_USER@[IP_DA_VM]"
echo "Verifique o IP na console: ip addr show"

# Limpar arquivo temporário após 30 segundos
(sleep 30 && rm -f /var/lib/vz/snippets/user-$VMID.yml) &
