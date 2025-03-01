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
DISKS=($(lsblk -d -n -o NAME | awk '{print "/dev/" $1}'))
if [ ${#DISKS[@]} -eq 0 ]; then
    echo "Nenhum disco detectado. Abortando."
    exit 1
fi
DISK=$(select_option "Escolha o disco para instalar o sistema:" "${DISKS[@]}")

# Pergunta sobre o usuário
read -rp "Digite o nome do usuário [padrão: kjunda01]: " USER
USER=${USER:-kjunda01}

# Pergunta sobre as senhas (com confirmação)
while true; do
    read -rsp "Digite a senha do usuário: " USER_PASS
    echo
    read -rsp "Confirme a senha do usuário: " USER_PASS_CONFIRM
    echo
    [ "$USER_PASS" == "$USER_PASS_CONFIRM" ] && break
    echo "As senhas não coincidem. Tente novamente."
done

while true; do
    read -rsp "Digite a senha do root: " ROOT_PASS
    echo
    read -rsp "Confirme a senha do root: " ROOT_PASS_CONFIRM
    echo
    [ "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" ] && break
    echo "As senhas não coincidem. Tente novamente."
done

# Criando partições corretamente
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 1GiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary btrfs 1GiB 100%

# Definir partições corretamente
BOOT_PART="${DISK}1"
BTRFS_PART="${DISK}2"

# Formatar partições
mkfs.fat -F32 "$BOOT_PART"
mkfs.btrfs -f "$BTRFS_PART"

# Criar subvolumes e montar corretamente
mount "$BTRFS_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@.snapshots
umount /mnt

mount -o compress=zstd,subvol=@ "$BTRFS_PART" /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
mount -o compress=zstd,subvol=@home "$BTRFS_PART" /mnt/home
mount -o compress=zstd,subvol=@log "$BTRFS_PART" /mnt/var/log
mount -o compress=zstd,subvol=@pkg "$BTRFS_PART" /mnt/var/cache/pacman/pkg
mount -o compress=zstd,subvol=@.snapshots "$BTRFS_PART" /mnt/.snapshots
mount "$BOOT_PART" /mnt/boot

# Instalar sistema base
pacstrap /mnt base linux linux-firmware

# Gerar fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Criar script para chroot
cat << EOF > /mnt/root/chroot-script.sh
#!/bin/bash
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/#$LANGUAGE/$LANGUAGE/' /etc/locale.gen
locale-gen
echo "LANG=$LANGUAGE" > /etc/locale.conf
echo "KEYMAP=$KEYBOARD" > /etc/vconsole.conf
echo "archlinux" > /etc/hostname
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash $USER
echo "$USER:$USER_PASS" | chpasswd
echo "$USER ALL=(ALL) ALL" >> /etc/sudoers.d/$USER
chmod 440 /etc/sudoers.d/$USER

# Instalar pacotes essenciais
pacman -Syu --noconfirm
pacman -S --noconfirm grub efibootmgr networkmanager pipewire pipewire-pulse hyprland sddm

# Configurar bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Habilitar serviços
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable pipewire pipewire-pulse

rm -- "\$0"
EOF

chmod +x /mnt/root/chroot-script.sh
arch-chroot /mnt /root/chroot-script.sh

# Finalização
echo "Instalação concluída! Reinicie o sistema."
echo "Para desmontar: umount -R /mnt"
echo "Para reiniciar: reboot"

