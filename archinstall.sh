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
            return $((choice - 1))
        else
            echo "Opção inválida. Tente novamente."
        fi
    done
}

# Lista de fusos horários disponíveis no Brasil
TIMEZONES=("America/Sao_Paulo" "America/Fortaleza" "America/Recife" "America/Manaus" "America/Porto_Velho" "America/Cuiaba")
select_option "Escolha seu fuso horário:" "${TIMEZONES[@]}"
TIMEZONE=${TIMEZONES[$?]}

# Lista de layouts de teclado comuns
KEYBOARDS=("us" "br-abnt2" "uk" "de" "fr")
select_option "Escolha o layout do teclado:" "${KEYBOARDS[@]}"
KEYBOARD=${KEYBOARDS[$?]}

# Lista de idiomas disponíveis
LANGUAGES=("en_US.UTF-8" "pt_BR.UTF-8" "es_ES.UTF-8" "fr_FR.UTF-8")
select_option "Escolha o idioma do sistema:" "${LANGUAGES[@]}"
LANGUAGE=${LANGUAGES[$?]}

# Descobrir discos disponíveis
echo "Detectando discos disponíveis..."
DISKS=($(lsblk -d -n -o NAME,SIZE | awk '{print "/dev/" $1}'))

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "Nenhum disco detectado. Abortando."
    exit 1
fi

select_option "Escolha o disco para instalar o sistema:" "${DISKS[@]}"
DISK=${DISKS[$?]}

# Pergunta sobre o usuário
read -rp "Digite o nome do usuário [padrão: kjunda01]: " USER
USER=${USER:-kjunda01}

# Pergunta sobre o hostname
read -rp "Digite o nome do host [padrão: archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}

# Pergunta sobre as senhas
echo "Digite a senha do usuário:"
read -s USER_PASS
echo "Confirme a senha do usuário:"
read -s USER_PASS_CONFIRM
while [ "$USER_PASS" != "$USER_PASS_CONFIRM" ]; do
    echo "As senhas não coincidem. Tente novamente."
    echo "Digite a senha do usuário:"
    read -s USER_PASS
    echo "Confirme a senha do usuário:"
    read -s USER_PASS_CONFIRM
done

echo "Digite a senha do root:"
read -s ROOT_PASS
echo "Confirme a senha do root:"
read -s ROOT_PASS_CONFIRM
while [ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ]; do
    echo "As senhas não coincidem. Tente novamente."
    echo "Digite a senha do root:"
    read -s ROOT_PASS
    echo "Confirme a senha do root:"
    read -s ROOT_PASS_CONFIRM
done

# Detecta se o sistema está em modo EFI
if [ -d /sys/firmware/efi ]; then
    echo "Sistema detectado em modo UEFI."
    EFI_MODE=true
else
    echo "Sistema detectado em modo Legacy BIOS."
    EFI_MODE=false
fi

# Define partições baseadas no disco escolhido
if $EFI_MODE; then
    BOOT_PART="${DISK}1"  # EFI System Partition
    BTRFS_PART="${DISK}2" # Btrfs
else
    BIOS_BOOT_PART="${DISK}1" # BIOS Boot Partition
    BOOT_PART="${DISK}2"      # Boot partition
    BTRFS_PART="${DISK}3"     # Btrfs
fi

# Resumo das configurações
echo -e "\nConfiguração escolhida:"
echo "Hostname: $HOSTNAME"
echo "Fuso Horário: $TIMEZONE"
echo "Teclado: $KEYBOARD"
echo "Idioma: $LANGUAGE"
echo "Disco: $DISK"
echo "Usuário: $USER"
if $EFI_MODE; then
    echo "Partição EFI: $BOOT_PART"
    echo "Partição Btrfs: $BTRFS_PART"
else
    echo "Partição BIOS Boot: $BIOS_BOOT_PART"
    echo "Partição Boot: $BOOT_PART"
    echo "Partição Btrfs: $BTRFS_PART"
fi
echo "Modo de boot: $(if $EFI_MODE; then echo UEFI; else echo Legacy BIOS; fi)"

read -rp "Confirmar? (s/n) " confirm
if [[ "$confirm" != "s" ]]; then
    echo "Instalação cancelada."
    exit 1
fi

# Inicia a instalação
echo "Iniciando instalação..."

# Atualiza o relógio do sistema
timedatectl set-ntp true || echo "Aviso: Falha ao sincronizar NTP"

# Particionamento do disco
echo "Particionando o disco $DISK..."
parted -s "$DISK" mklabel gpt || { echo "Erro ao criar tabela GPT"; exit 1; }
if $EFI_MODE; then
    parted -s "$DISK" mkpart primary fat32 1MiB 1GiB || { echo "Erro ao criar partição EFI"; exit 1; }
    parted -s "$DISK" set 1 esp on || { echo "Erro ao definir flag ESP"; exit 1; }
    parted -s "$DISK" set 1 boot on || { echo "Erro ao definir flag boot"; exit 1; }
    parted -s "$DISK" mkpart primary btrfs 1GiB 100% || { echo "Erro ao criar partição Btrfs"; exit 1; }
else
    parted -s "$DISK" mkpart primary 1MiB 3MiB || { echo "Erro ao criar partição BIOS Boot"; exit 1; }
    parted -s "$DISK" set 1 bios_grub on || { echo "Erro ao definir flag bios_grub"; exit 1; }
    parted -s "$DISK" mkpart primary fat32 3MiB 1GiB || { echo "Erro ao criar partição Boot"; exit 1; }
    parted -s "$DISK" set 2 boot on || { echo "Erro ao definir flag boot"; exit 1; }
    parted -s "$DISK" mkpart primary btrfs 1GiB 100% || { echo "Erro ao criar partição Btrfs"; exit 1; }
fi

# Formatação das partições
echo "Formatando partições..."
if $EFI_MODE; then
    mkfs.fat -F32 "$BOOT_PART" || { echo "Erro ao formatar EFI"; exit 1; }
else
    # Não formata a BIOS Boot Partition (deve ficar sem sistema de arquivos)
    mkfs.fat -F32 "$BOOT_PART" || { echo "Erro ao formatar Boot"; exit 1; }
fi
mkfs.btrfs -f "$BTRFS_PART" || { echo "Erro ao formatar Btrfs"; exit 1; }

# Configuração do Btrfs com subvolumes
echo "Montando partição Btrfs temporariamente..."
mount "$BTRFS_PART" /mnt || { echo "Erro ao montar $BTRFS_PART"; exit 1; }
for subvol in @ @home @log @pkg @.snapshots; do
    btrfs subvolume create "/mnt/$subvol" || { echo "Erro ao criar subvolume $subvol"; umount /mnt; exit 1; }
done
umount /mnt || { echo "Erro ao desmontar /mnt"; exit 1; }

# Montagem das partições
echo "Montando partições com subvolumes..."
mount -o compress=zstd,subvol=@ "$BTRFS_PART" /mnt || { echo "Erro ao montar subvolume @"; exit 1; }
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots} || { echo "Erro ao criar diretórios"; umount /mnt; exit 1; }
mount -o compress=zstd,subvol=@home "$BTRFS_PART" /mnt/home || { echo "Erro ao montar @home"; umount -R /mnt; exit 1; }
mount -o compress=zstd,subvol=@log "$BTRFS_PART" /mnt/var/log || { echo "Erro ao montar @log"; umount -R /mnt; exit 1; }
mount -o compress=zstd,subvol=@pkg "$BTRFS_PART" /mnt/var/cache/pacman/pkg || { echo "Erro ao montar @pkg"; umount -R /mnt; exit 1; }
mount -o compress=zstd,subvol=@.snapshots "$BTRFS_PART" /mnt/.snapshots || { echo "Erro ao montar @.snapshots"; umount -R /mnt; exit 1; }
mount "$BOOT_PART" /mnt/boot || { echo "Erro ao montar EFI/Boot"; umount -R /mnt; exit 1; }

# Instalação do sistema base
echo "Instalando pacotes base..."
pacstrap /mnt base linux linux-firmware networkmanager git || { echo "Erro ao instalar pacotes base"; umount -R /mnt; exit 1; }

# Geração do fstab
echo "Gerando fstab..."
genfstab -U /mnt >> /mnt/etc/fstab || { echo "Erro ao gerar fstab"; umount -R /mnt; exit 1; }

# Configuração do sistema via arch-chroot
echo "Configurando o sistema..."
arch-chroot /mnt /bin/bash <<EOF
# Configura o fuso horário
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime || { echo "Erro ao configurar fuso horário"; exit 1; }
hwclock --systohc || { echo "Erro ao sincronizar relógio"; exit 1; }

# Configura o idioma
echo "$LANGUAGE UTF-8" > /etc/locale.gen || { echo "Erro ao configurar locale.gen"; exit 1; }
locale-gen || { echo "Erro ao gerar locales"; exit 1; }
echo "LANG=$LANGUAGE" > /etc/locale.conf || { echo "Erro ao configurar locale.conf"; exit 1; }

# Configura o teclado
echo "KEYMAP=$KEYBOARD" > /etc/vconsole.conf || { echo "Erro ao configurar teclado"; exit 1; }

# Configura o hostname
echo "$HOSTNAME" > /etc/hostname || { echo "Erro ao configurar hostname"; exit 1; }
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS
[ \$? -ne 0 ] && { echo "Erro ao configurar /etc/hosts"; exit 1; }

# Configura a senha do root
echo "root:$ROOT_PASS" | chpasswd || { echo "Erro ao configurar senha do root"; exit 1; }

# Cria o usuário
useradd -m -G wheel -s /bin/bash "$USER" || { echo "Erro ao criar usuário"; exit 1; }
echo "$USER:$USER_PASS" | chpasswd || { echo "Erro ao configurar senha do usuário"; exit 1; }

# Instala o GRUB e utilitários
pacman -S --noconfirm grub
if [ "$EFI_MODE" = true ]; then
    pacman -S --noconfirm efibootmgr || { echo "Erro ao instalar efibootmgr"; exit 1; }
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || { echo "Erro ao instalar GRUB (UEFI)"; exit 1; }
else
    grub-install --target=i386-pc "$DISK" || { echo "Erro ao instalar GRUB (Legacy)"; exit 1; }
fi
grub-mkconfig -o /boot/grub/grub.cfg || { echo "Erro ao gerar configuração do GRUB"; exit 1; }

# Habilita o usuário wheel para sudo (opcional)
mkdir -p /etc/sudoers.d || { echo "Erro ao criar diretório /etc/sudoers.d"; exit 1; }
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel || { echo "Erro ao configurar sudoers.d/wheel"; exit 1; }
chmod 440 /etc/sudoers.d/wheel || { echo "Erro ao definir permissões do sudoers.d/wheel"; exit 1; }

# Habilita o NetworkManager para iniciar no boot
systemctl enable NetworkManager || { echo "Erro ao habilitar NetworkManager"; exit 1; }

exit
EOF

# Verifica se o chroot foi bem-sucedido
if [ $? -ne 0 ]; then
    echo "Erro durante a configuração no chroot"
    umount -R /mnt
    exit 1
fi

# Instala o Hyprland e seus pacotes
pacman -S dolphin dunst grim hyprland kitty polkit-kde-agent qt5-wayland qt6-wayland slurp wofi xdg-desktop-portal-hyprland swaync polkit

# Instala os drivers de video
pacman -S intel-media-driver libva-intel-driver libva-mesa-driver mesa vulkan-intel vulkan-radeon xf86-video-amdgpu xf86-video-ati xf86-video-nouveau xf86-video-vmware xorg-server xorg-xinit

# Instala o SDDM
pacman -S sddm
systemctl enable sddm

# Finalização
echo "Instalação concluída com sucesso!"
echo "Partições montadas em /mnt. Para desmontar: umount -R /mnt"
echo "Para reiniciar: reboot"
