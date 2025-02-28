#!/bin/bash

set -e

# Definições gerais
HOSTNAME="archlinux"
TIMEZONE="America/Sao_Paulo"
LOCALE="en_US.UTF-8"
KEYMAP="us"
DISK="/dev/nvme0n1"
INTERFACE="enp6s0"
ROOT_PASSWORD="112148"
USERNAME="kjunda01"
USER_PASSWORD="112148"

# Particionamento manual
wipefs -af $DISK
parted -s $DISK mklabel gpt
parted -s $DISK mkpart ESP fat32 1MiB 1GiB
parted -s $DISK set 1 boot on
parted -s $DISK set 1 esp on
parted -s $DISK mkpart primary btrfs 1GiB 100%

# Formatação
echo "Formatando partições..."
mkfs.fat -F32 ${DISK}p1
mkfs.btrfs -f ${DISK}p2

# Criando subvolumes Btrfs
mount ${DISK}p2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@.snapshots
umount /mnt

# Montagem
mount -o compress=zstd,subvol=@ ${DISK}p2 /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
mount -o compress=zstd,subvol=@home ${DISK}p2 /mnt/home
mount -o compress=zstd,subvol=@log ${DISK}p2 /mnt/var/log
mount -o compress=zstd,subvol=@pkg ${DISK}p2 /mnt/var/cache/pacman/pkg
mount -o compress=zstd,subvol=@.snapshots ${DISK}p2 /mnt/.snapshots
mount ${DISK}p1 /mnt/boot

# Instalação base
echo "Instalando sistema base..."
pacstrap /mnt base linux linux-firmware nano vim openssh samba wget curl efibootmgr

# Gerando fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Configuração do sistema
echo "Configurando sistema..."
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
arch-chroot /mnt hwclock --systohc
echo "$LOCALE UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf
echo "$HOSTNAME" > /mnt/etc/hostname
echo "127.0.0.1   localhost" >> /mnt/etc/hosts
echo "::1         localhost" >> /mnt/etc/hosts
echo "127.0.1.1   $HOSTNAME.localdomain $HOSTNAME" >> /mnt/etc/hosts

# Configuração da rede
echo "Configurando rede..."
arch-chroot /mnt systemctl enable systemd-networkd
arch-chroot /mnt systemctl enable systemd-resolved
cat <<EOF > /mnt/etc/systemd/network/20-wired.network
[Match]
Name=$INTERFACE

[Network]
DHCP=yes
EOF

# Configuração do usuário root e novo usuário
echo "Configurando usuários..."
echo -e "$ROOT_PASSWORD\n$ROOT_PASSWORD" | arch-chroot /mnt passwd root
echo "Criando usuário $USERNAME..."
arch-chroot /mnt useradd -m -G wheel -s /bin/bash $USERNAME
echo -e "$USER_PASSWORD\n$USER_PASSWORD" | arch-chroot /mnt passwd $USERNAME
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers

# Instalando bootloader
echo "Instalando GRUB..."
arch-chroot /mnt pacman -Sy --noconfirm grub
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Finalização
echo "Instalação concluída! Rebootando..."
umount -R /mnt
reboot
