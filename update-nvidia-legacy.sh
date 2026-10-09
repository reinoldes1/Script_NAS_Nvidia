#!/bin/bash
# update-nvidia-legacy.sh
# Restaura o driver NVIDIA legado (GTX 970) no TrueNAS depois de atualizações do sistema.
# Pensado para rodar pelos init/shutdown scripts do TrueNAS.
#
# Drivers mantidos pela comunidade: https://truenas-drivers.zhouyou.info/index.html
#
# Mudanças em relação à versão anterior:
#   1. trap: o dataset /usr volta ao estado original (readonly) mesmo se algo falhar
#   2. backup do nvidia.raw atual e rollback se o driver novo não funcionar
#   3. log em arquivo (scripts de init falham em silêncio)
#   4. validação básica do arquivo baixado e verificação opcional de sha256
#   5. flock para impedir duas execuções simultâneas
#   6. mktemp em vez de caminho fixo em /tmp

set -euo pipefail

export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Configuração (pode ser sobrescrita por variáveis de ambiente)
: "${LOG_FILE:=/var/log/update-nvidia.log}"
: "${LOCK_FILE:=/run/update-nvidia.lock}"
: "${BACKUP_DIR:=/root}"                      # idealmente um caminho que sobreviva a updates
: "${SYSEXT_DST:=/usr/share/truenas/sysext-extensions/nvidia.raw}"
: "${VERSION_FILE:=/etc/version}"
: "${OS_RELEASE_FILE:=/etc/os-release}"
: "${DRIVER_BASE_URL:=https://truenas-drivers.zhouyou.info}"
: "${EXPECTED_SHA256:=}"                      # opcional: hash conferido manualmente para esta versão
: "${MIN_SIZE_BYTES:=1048576}"                # abaixo de 1 MB o arquivo é suspeito

TEMP_FILE=""
ZFS_USR_DATASET=""
ORIGINAL_READONLY=""
RO_CHANGED=0
BACKUP_FILE="${BACKUP_DIR}/nvidia.raw.bak"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Tudo que o script imprimir vai para a tela e para o arquivo de log
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

cleanup() {
    local rc=$?
    [ -n "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
    if [ "$RO_CHANGED" -eq 1 ] && [ -n "$ZFS_USR_DATASET" ]; then
        if zfs set readonly="${ORIGINAL_READONLY:-on}" "$ZFS_USR_DATASET"; then
            log "[+] Dataset ${ZFS_USR_DATASET} restaurado para readonly=${ORIGINAL_READONLY:-on}."
        else
            log "[-] ATENCAO: não foi possível restaurar readonly em ${ZFS_USR_DATASET}. Verifique manualmente."
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        log "[-] Script terminou com erro (código ${rc}). Veja ${LOG_FILE}."
    fi
    exit "$rc"
}
trap cleanup EXIT

# Evita duas execuções ao mesmo tempo (init e shutdown, por exemplo)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "[!] Outra execução já está em andamento. Saindo."
    exit 0
fi

log "=== Verificando Status do Driver NVIDIA Legado ==="

# 1. Garante que o nó /dev/nvidia-modeset existe no boot
if [ ! -e /dev/nvidia-modeset ]; then
    mknod -m 666 /dev/nvidia-modeset c 195 254 2>/dev/null || true
fi

# 2. Testa se o nvidia-smi já está funcionando
if nvidia-smi >/dev/null 2>&1; then
    log "[OK] O driver NVIDIA já está carregado e funcionando. Nenhuma ação necessária."
    exit 0
fi

log "[!] nvidia-smi falhou ou o sistema foi atualizado. Aplicando correção..."

# 3. Detecta a versão exata do TrueNAS em execução
TRUENAS_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    # Ex.: 25.10.7
    TRUENAS_VERSION=$(cut -d'-' -f1 "$VERSION_FILE" | tr -d ' \n\r' || true)
else
    TRUENAS_VERSION=$(grep -oP '(?<=VERSION=")[^"]+' "$OS_RELEASE_FILE" | awk '{print $1}' || true)
fi

if [ -z "$TRUENAS_VERSION" ]; then
    log "[-] ERRO: Não foi possível detectar a versão do TrueNAS SCALE."
    exit 1
fi
log "[+] Versão do TrueNAS detectada: ${TRUENAS_VERSION}"

DRIVER_URL="${DRIVER_BASE_URL}/${TRUENAS_VERSION}/nvidia.raw"
TEMP_FILE=$(mktemp --suffix=.raw /tmp/nvidia.XXXXXX)

log "[+] Baixando extensão do driver em: ${DRIVER_URL}"
if ! wget -nv --timeout=30 --tries=3 -O "$TEMP_FILE" "$DRIVER_URL"; then
    log "[-] ERRO: Não foi possível baixar o driver para a versão ${TRUENAS_VERSION}."
    log "    Verifique se o repositório zzzhouuu já compilou o .raw para esta versão."
    exit 1
fi

# 4. Validação básica do arquivo baixado
FILE_SIZE=$(stat -c %s "$TEMP_FILE")
if [ "$FILE_SIZE" -lt "$MIN_SIZE_BYTES" ]; then
    log "[-] ERRO: arquivo baixado muito pequeno (${FILE_SIZE} bytes). Abortando."
    exit 1
fi
if head -c 64 "$TEMP_FILE" | grep -qiE '<!doctype|<html'; then
    log "[-] ERRO: o download parece ser uma página HTML, não uma extensão. Abortando."
    exit 1
fi

DOWNLOAD_SHA256=$(sha256sum "$TEMP_FILE" | cut -d' ' -f1)
log "[+] sha256 do arquivo baixado: ${DOWNLOAD_SHA256}"
if [ -n "$EXPECTED_SHA256" ] && [ "$DOWNLOAD_SHA256" != "$EXPECTED_SHA256" ]; then
    log "[-] ERRO: sha256 diferente do esperado (${EXPECTED_SHA256}). Abortando."
    exit 1
fi

# 5. Backup da extensão atual, para rollback
mkdir -p "$BACKUP_DIR"
HAD_BACKUP=0
if [ -f "$SYSEXT_DST" ]; then
    cp -f "$SYSEXT_DST" "$BACKUP_FILE"
    HAD_BACKUP=1
    log "[+] Backup da extensão atual em ${BACKUP_FILE}"
fi

rollback() {
    log "[!] Tentando restaurar a extensão anterior..."
    systemd-sysext unmerge || true
    if [ "$HAD_BACKUP" -eq 1 ]; then
        cp -f "$BACKUP_FILE" "$SYSEXT_DST" || log "[-] Falha ao restaurar o backup."
    else
        rm -f "$SYSEXT_DST"
    fi
    systemd-sysext merge || log "[-] Falha ao refazer o merge após o rollback."
}

# 6. Aplica a extensão
log "[+] Aplicando extensão via systemd-sysext..."
systemd-sysext unmerge || true

# Desbloqueia o dataset /usr temporariamente; o trap devolve ao estado original
ZFS_USR_DATASET=$(zfs list -H -o name /usr)
ORIGINAL_READONLY=$(zfs get -H -o value readonly "$ZFS_USR_DATASET")
zfs set readonly=off "$ZFS_USR_DATASET"
RO_CHANGED=1

cp -f "$TEMP_FILE" "$SYSEXT_DST"

if ! systemd-sysext merge; then
    log "[-] ERRO: systemd-sysext merge falhou."
    rollback
    exit 1
fi

# 7. Verifica o resultado (antes de religar o readonly, para permitir rollback)
if nvidia-smi >/dev/null 2>&1; then
    log "[+] Extensão aplicada! Driver funcionando:"
    log "--------------------------------------------------------"
    nvidia-smi
else
    log "[-] ERRO: o driver novo não funcionou (nvidia-smi falhou)."
    rollback
    exit 1
fi
