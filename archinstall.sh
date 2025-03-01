#!/bin/bash

# Verifica se está sendo executado como root
if [ "$EUID" -ne 0 ]; then
    echo "Este script deve ser executado como root!"
    exit 1
fi

# Função para exibir menu de seleção
select_option() {
    local prompt="$1"
    shift
    local options=("$@")
    local i=1

    echo "$prompt"
    for opt in "${options[@]}"; do
        echo "$i) $opt"
        ((i++))
    done

    while true; do
        read -rp "Escolha uma opção [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
            echo "${options[choice-1]}"
            return
        else
            echo "Opção inválida. Tente novamente."
        fi
    done
}

# Lista de fusos horários disponíveis no Brasil
TIMEZONES=("America/Sao_Paulo" "America/Fortaleza" "America/Recife" "America/Manaus" "America/Porto_Velho" "America/Cuiaba")
TIMEZONE=$(select_option "Escolha seu fuso horário:" "${TIMEZONES[@]}")

# Lista de layouts de teclado comuns
KEYBOARDS=("us" "br-abnt2" "uk" "de" "fr")
KEYBOARD=$(select_option "Escolha o layout do teclado:" "${KEYBOARDS[@]}")

# Lista de idiomas disponíveis
LANGUAGES=("en_US.UTF-8" "pt_BR.UTF-8" "es_ES.UTF-8" "fr_FR.UTF-8")
LANGUAGE=$(select_option "Escolha o idioma do sistema:" "${LANGUAGES[@]}")

# Descobrir discos disponíveis
echo "Detectando discos disponíveis..."
DISKS=($(lsblk -d -n -o NAME,SIZE | awk '{print "/dev/" $1 " (" $2 ")"}'))

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "Nenhum disco detectado. Abortando."
    exit 1
fi

DISK=$(select_option "Escolha o disco para instalar o sistema:" "${DISKS[@]}")
DISK=$(echo "$DISK" | awk '{print $1}')  # Pega apenas o nome do dispositivo

# Pergunta sobre o usuário
read -rp "Digite o nome do usuário [padrão: kjunda01]: " USER
USER=${USER:-kjunda01}

# Pergunta sobre as senhas
read -rp "Digite a senha do usuário: " USER_PASS
read -rp "Digite a senha do root: " ROOT_PASS

# Partições baseadas no disco escolhido
BOOT_PART="${DISK}p1"
BTRFS_PART="${DISK}p2"

# Resumo das configurações
echo -e "\nConfiguração escolhida:"
echo "Hostname: archlinux"
echo "Fuso Horário: $TIMEZONE"
echo "Teclado: $KEYBOARD"
echo "Idioma: $LANGUAGE"
echo "Disco: $DISK"
echo "Usuário: $USER"
echo "Partição EFI: $BOOT_PART"
echo "Partição Btrfs: $BTRFS_PART"

read -rp "Confirmar? (s/n) " confirm
if [[ "$confirm" != "s" ]]; then
    echo "Instalação cancelada."
    exit 1
fi

# Continua com o restante do script...
echo "Iniciando instalação..."

# Atualiza o relógio do sistema
timedatectl set-ntp true

# Particionamento do disco
echo "Particionando o disco $DISK..."
parted -s $DISK mklabel gpt
parted -s $DISK mkpart primary fat32 1MiB 1GiB
parted -s $DISK set 1 esp on
parted -s $DISK set 1 boot on
parted -s $DISK mkpart primary btrfs 1GiB 100%

# Formatação das partições
mkfs.fat -F32 $BOOT_PART
mkfs.btrfs -f $BTRFS_PART

# Configuração do Btrfs com subvolumes
mount $BTRFS_PART /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@.snapshots
umount /mnt

# Montagem das partições
mount -o compress=zstd,subvol=@ $BTRFS_PART /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
mount -o compress=zstd,subvol=@home $BTRFS_PART /mnt/home
mount -o compress=zstd,subvol=@log $BTRFS_PART /mnt/var/log
mount -o compress=zstd,subvol=@pkg $BTRFS_PART /mnt/var/cache/pacman/pkg
mount -o compress=zstd,subvol=@.snapshots $BTRFS_PART /mnt/.snapshots
mount $BOOT_PART /mnt/boot

# Configuração dos mirrors (usando apenas mirrors do Brasil)
echo "Configurando mirrors brasileiros..."
cat << EOF > /etc/pacman.d/mirrorlist
Server = http://archlinux.c3sl.ufpr.br/\$repo/os/\$arch
Server = https://archlinux.c3sl.ufpr.br/\$repo/os/\$arch
Server = http://mirror.ufscar.br/archlinux/\$repo/os/\$arch
Server = https://mirror.ufscar.br/archlinux/\$repo/os/\$arch
Server = http://mirrors.ic.unicamp.br/archlinux/\$repo/os/\$arch
Server = https://mirrors.ic.unicamp.br/archlinux/\$repo/os/\$arch
EOF

# Instalação do sistema base
pacstrap /mnt base linux linux-firmware

# Geração do fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Criação de script temporário para execução dentro do chroot
cat << EOF > /mnt/root/chroot-script.sh
#!/bin/bash

# Configuração de fuso horário
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Configuração de locale
sed -i 's/#$LANGUAGE/$LANGUAGE/' /etc/locale.gen
locale-gen
echo "LANG=$LANGUAGE" > /etc/locale.conf
echo "KEYMAP=$KEYBOARD" > /etc/vconsole.conf

# Configuração do hostname
echo "$HOSTNAME" > /etc/hostname
cat << HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Atualização e instalação de pacotes adicionais
pacman -Syu --noconfirm
pacman -S --noconfirm grub efibootmgr nano vim openssh samba wget curl \
pipewire pipewire-pulse networkmanager hyprland sddm polkit kitty wayland

# Configuração de áudio (PipeWire)
systemctl enable pipewire pipewire-pulse

# Configuração de rede (DHCP automático)
systemctl enable NetworkManager

# Configuração do SDDM (greeter)
systemctl enable sddm

# Configuração do bootloader (Grub)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Configuração de usuário e root
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash $USER
echo "$USER:$USER_PASS" | chpasswd

# Configuração do sudoers corretamente
echo "$USER ALL=(ALL) ALL" >> /etc/sudoers.d/$USER
chmod 440 /etc/sudoers.d/$USER

# Remove o script após execução
rm -- "\$0"

EOF

# Torna o script executável
chmod +x /mnt/root/chroot-script.sh

# Executa o script dentro do chroot
arch-chroot /mnt /root/chroot-script.sh

# Finalização
echo "Instalação concluída! Desmonte as partições e reinicie."
echo "Para desmontar: umount -R /mnt"
echo "Para reiniciar: reboot"
