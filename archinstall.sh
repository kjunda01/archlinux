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

# Partições baseadas no disco escolhido
BOOT_PART="${DISK}1"
BTRFS_PART="${DISK}2"

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

# Continua com o restante do script...
echo "Iniciando instalação..."

# Atualiza o relógio do sistema
timedatectl set-ntp true || echo "Aviso: Falha ao sincronizar NTP"

# Particionamento do disco com verificação
echo "Particionando o disco $DISK..."
if ! parted -s "$DISK" mklabel gpt; then
    echo "Erro ao criar tabela de partição GPT"
    exit 1
fi
if ! parted -s "$DISK" mkpart primary fat32 1MiB 1GiB; then
    echo "Erro ao criar partição EFI"
    exit 1
fi
if ! parted -s "$DISK" set 1 esp on; then
    echo "Erro ao definir flag ESP"
    exit 1
fi
if ! parted -s "$DISK" set 1 boot on; then
    echo "Erro ao definir flag boot"
    exit 1
fi
if ! parted -s "$DISK" mkpart primary btrfs 1GiB 100%; then
    echo "Erro ao criar partição Btrfs"
    exit 1
fi

# Formatação das partições com verificação
echo "Formatando partições..."
if ! mkfs.fat -F32 "$BOOT_PART"; then
    echo "Erro ao formatar partição EFI"
    exit 1
fi
if ! mkfs.btrfs -f "$BTRFS_PART"; then
    echo "Erro ao formatar partição Btrfs"
    exit 1
fi

# Configuração do Btrfs com subvolumes
echo "Montando partição Btrfs temporariamente em /mnt..."
if ! mount "$BTRFS_PART" /mnt; then
    echo "Erro ao montar $BTRFS_PART em /mnt"
    lsblk
    exit 1
fi

echo "Criando subvolumes Btrfs..."
for subvol in @ @home @log @pkg @.snapshots; do
    if ! btrfs subvolume create "/mnt/$subvol"; then
        echo "Erro ao criar subvolume $subvol"
        umount /mnt
        exit 1
    fi
done

echo "Desmontando /mnt..."
if ! umount /mnt; then
    echo "Erro ao desmontar /mnt"
    exit 1
fi

# Montagem das partições com verificação
echo "Montando partições com subvolumes..."
if ! mount -o compress=zstd,subvol=@ "$BTRFS_PART" /mnt; then
    echo "Erro ao montar subvolume @ em /mnt"
    lsblk
    exit 1
fi

echo "Criando diretórios de montagem..."
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots} || {
    echo "Erro ao criar diretórios em /mnt"
    umount /mnt
    exit 1
}

echo "Montando subvolume @home..."
if ! mount -o compress=zstd,subvol=@home "$BTRFS_PART" /mnt/home; then
    echo "Erro ao montar subvolume @home"
    umount -R /mnt
    exit 1
fi

echo "Montando subvolume @log..."
if ! mount -o compress=zstd,subvol=@log "$BTRFS_PART" /mnt/var/log; then
    echo "Erro ao montar subvolume @log"
    umount -R /mnt
    exit 1
fi

echo "Montando subvolume @pkg..."
if ! mount -o compress=zstd,subvol=@pkg "$BTRFS_PART" /mnt/var/cache/pacman/pkg; then
    echo "Erro ao montar subvolume @pkg"
    umount -R /mnt
    exit 1
fi

echo "Montando subvolume @.snapshots..."
if ! mount -o compress=zstd,subvol=@.snapshots "$BTRFS_PART" /mnt/.snapshots; then
    echo "Erro ao montar subvolume @.snapshots"
    umount -R /mnt
    exit 1
fi

echo "Montando partição EFI..."
if ! mount "$BOOT_PART" /mnt/boot; then
    echo "Erro ao montar partição EFI em /mnt/boot"
    umount -R /mnt
    exit 1
fi

# Finalização
echo "Instalação concluída com sucesso!"
echo "Partições montadas em /mnt. Verifique com 'lsblk' se necessário."
echo "Para desmontar: umount -R /mnt"
echo "Para reiniciar: reboot"
