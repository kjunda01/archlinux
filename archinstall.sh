#!/bin/bash

# Script para instalação e configuração do Arch Linux
# Execute como root em um ambiente live do Arch Linux

# Verifica se está sendo executado como root
if [ "$EUID" -ne 0 ]; then
    echo "Este script deve ser executado como root!"
    exit 1
fi

# Define variáveis iniciais
HOSTNAME="archlinux"

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

# Configurações interativas
TIMEZONES=("America/Sao_Paulo" "America/Fortaleza" "America/Recife" "America/Manaus" "America/Porto_Velho" "America/Cuiaba")
TIMEZONE=$(select_option "Escolha seu fuso horário:" "${TIMEZONES[@]}")

KEYBOARDS=("us" "br-abnt2" "uk" "de" "fr")
KEYBOARD=$(select_option "Escolha o layout do teclado:" "${KEYBOARDS[@]}")

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

# Entrada de usuário e senhas
read -rp "Digite o nome do usuário [padrão: kjunda01]: " USER
USER=${USER:-kjunda01}
read -sp "Digite a senha do usuário: " USER_PASS
echo
read -sp "Digite a senha do root: " ROOT_PASS
echo

# Define partições
BOOT_PART="${DISK}p1"
BTRFS_PART="${DISK}p2"

# Resumo das configurações
echo -e "\nConfiguração escolhida:"
echo "Hostname: $HOSTNAME"
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

# Início da instalação
echo "Iniciando instalação..."

# Atualiza o relógio do sistema
timedatectl set-ntp true || { echo "Erro ao atualizar o relógio"; exit 1; }

# Particionamento do disco
echo "Particionando o disco $DISK..."
echo -e "g\nn\n1\n\n+512M\nef00\nt\n1\nef\nn\n2\n\n\n8300\nw" | gdisk "$DISK" || { echo "Erro ao particionar"; exit 1; }

# Formatação das partições
mkfs.fat -F32 "$BOOT_PART" || { echo "Erro ao formatar partição EFI"; exit 1; }
mkfs.btrfs -f "$BTRFS_PART" || { echo "Erro ao formatar partição Btrfs"; exit 1; }

# Montagem das partições
mount "$BTRFS_PART" /mnt || { echo "Erro ao montar partição Btrfs"; exit 1; }
mkdir /mnt/boot
mount "$BOOT_PART" /mnt/boot || { echo "Erro ao montar partição EFI"; exit 1; }

# Configuração de mirrors brasileiros com reflector
echo "Configurando mirrors brasileiros..."
pacman -Sy --noconfirm reflector || { echo "Erro ao instalar reflector"; exit 1; }
reflector --country Brazil --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || { echo "Erro ao configurar mirrors"; exit 1; }

# Instalação do sistema base
pacstrap /mnt base linux linux-firmware || { echo "Erro no pacstrap"; exit 1; }

# Geração do fstab
genfstab -U /mnt >> /mnt/etc/fstab || { echo "Erro no genfstab"; exit 1; }

# Configuração do sistema instalado via chroot
cat << EOF > /mnt/root/chroot-script.sh
#!/bin/bash

# Configuração de fuso horário
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Configuração de locale
echo "$LANGUAGE UTF-8" > /etc/locale.gen
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

# Configuração de rede (NetworkManager)
systemctl enable NetworkManager

# Configuração do SDDM (greeter)
systemctl enable sddm

# Configuração do bootloader (Grub)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Configuração de usuário e root
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USER"
echo "$USER:$USER_PASS" | chpasswd
echo "$USER ALL=(ALL) ALL" > /etc/sudoers.d/$USER
chmod 440 /etc/sudoers.d/$USER

# Remove o script após execução
rm -- "\$0"
EOF

# Torna o script executável e executa no chroot
chmod +x /mnt/root/chroot-script.sh
arch-chroot /mnt /root/chroot-script.sh || { echo "Erro no chroot"; exit 1; }

# Finalização
echo "Instalação concluída!"
echo "Para desmontar: umount -R /mnt"
echo "Para reiniciar: reboot"
