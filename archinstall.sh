#!/bin/bash
# Script para instalação e configuração do Arch Linux com partição swap de 4GB
# Execute este script como root em um ambiente live do Arch Linux

# Verifica se está sendo executado como root
if [ "$EUID" -ne 0 ]; then
    echo "Este script deve ser executado como root!"
    exit 1
fi

# Define variáveis de configuração
HOSTNAME="archlinux"
TIMEZONE="America/Sao_Paulo"
KEYBOARD="us"
LANGUAGE="en_US.UTF-8"
DISK="/dev/nvme0n1"
BOOT_PART="${DISK}p1"
BTRFS_PART="${DISK}p2"
SWAP_PART="${DISK}p3"
USER="kjunda01"
USER_PASS="112148"
ROOT_PASS="112148"

# Atualiza o relógio do sistema
timedatectl set-ntp true

# Particionamento do disco
echo "Particionando o disco $DISK..."
parted -s $DISK mklabel gpt
parted -s $DISK mkpart primary fat32 1MiB 1GiB # Partição EFI (1 GiB)
parted -s $DISK set 1 esp on
parted -s $DISK set 1 boot on
parted -s $DISK mkpart primary linux-swap 1GiB 5GiB # Partição swap (4 GiB)
parted -s $DISK mkpart primary btrfs 5GiB 100% # Partição Btrfs (restante)

# Formatação das partições
mkfs.fat -F32 $BOOT_PART
mkswap $SWAP_PART
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
mkdir -p /mnt/boot /mnt/home /mnt/var/log /mnt/var/cache/pacman/pkg /mnt/.snapshots
mount -o compress=zstd,subvol=@home $BTRFS_PART /mnt/home
mount -o compress=zstd,subvol=@log $BTRFS_PART /mnt/var/log
mount -o compress=zstd,subvol=@pkg $BTRFS_PART /mnt/var/cache/pacman/pkg
mount -o compress=zstd,subvol=@.snapshots $BTRFS_PART /mnt/.snapshots
mount $BOOT_PART /mnt/boot

# Ativa o swap temporariamente para a instalação
swapon $SWAP_PART

# Configuração dos mirrors (usando apenas mirrors do Brasil)
echo "Configurando mirrors brasileiros..."
cat > /etc/pacman.d/mirrorlist << EOF
Server = http://archlinux.c3sl.ufpr.br/\$repo/os/\$arch
Server = https://archlinux.c3sl.ufpr.br/\$repo/os/\$arch
Server = http://br.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://br.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = http://mirror.ufam.edu.br/archlinux/\$repo/os/\$arch
Server = http://mirror.ufscar.br/archlinux/\$repo/os/\$arch
Server = https://mirror.ufscar.br/archlinux/\$repo/os/\$arch
Server = http://mirrors.ic.unicamp.br/archlinux/\$repo/os/\$arch
Server = https://mirrors.ic.unicamp.br/archlinux/\$repo/os/\$arch
EOF

# Instalação do sistema base
pacstrap /mnt base linux linux-firmware

# Geração do fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Configuração do sistema instalado via chroot
arch-chroot /mnt /bin/bash << EOF
# Configuração de fuso horário
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Configuração de locale
echo "$LANGUAGE" > /etc/locale.gen
locale-gen
echo "LANG=$LANGUAGE" > /etc/locale.conf
echo "KEYMAP=$KEYBOARD" > /etc/vconsole.conf

# Configuração do hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Instalação do bootloader (Grub)
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Instalação de pacotes adicionais
pacman -S --noconfirm nano vim openssh samba wget curl pipewire pipewire-pulse hyprland sddm polkit

# Configuração de áudio (PipeWire)
systemctl enable pipewire pipewire-pulse

# Configuração de rede (DHCP automático)
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager

# Configuração do SDDM (greeter)
systemctl enable sddm

# Configuração de usuário e root
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash $USER
echo "$USER:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Saída do chroot
exit
EOF

# Finalização
echo "Instalação concluída! Desmonte as partições e reinicie."
# Para desmontar manualmente: umount -R /mnt
# Para reiniciar: reboot
