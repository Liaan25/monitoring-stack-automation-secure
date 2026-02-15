#!/bin/bash
# Безопасное копирование role_id/secret_id в /opt/vault/conf/
# Соответствует требованиям ИБ Сбербанка:
# - Whitelist источников и целей
# - Валидация содержимого
# - Установка правильных прав доступа
# - SHA256 checksum для sudoers

set -euo pipefail

SOURCE_ROLE_ID="${1:-}"
SOURCE_SECRET_ID="${2:-}"
TARGET_DIR="/opt/vault/conf"

log() {
    echo "[VAULT_CREDS_INSTALLER] $*"
}

fail() {
    echo "[VAULT_CREDS_INSTALLER][ERROR] $*" >&2
    exit 1
}

# Валидация источника role_id
validate_source_role_id() {
    local file="$1"
    
    [[ -f "$file" && -r "$file" ]] || fail "role_id файл недоступен: $file"
    
    # Разрешенные директории для источника
    local allowed_source_dirs=(
        "/home"
        "/tmp"
        "/dev/shm"
    )
    
    local file_dir=$(dirname "$file")
    local dir_allowed=false
    
    for allowed_dir in "${allowed_source_dirs[@]}"; do
        if [[ "$file_dir" == "$allowed_dir"* ]]; then
            dir_allowed=true
            break
        fi
    done
    
    [[ "$dir_allowed" == true ]] || fail "Источник role_id не в разрешенной директории: $file_dir"
    
    # Проверка размера файла (UUID должен быть ~36 символов)
    local file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
    if [[ "$file_size" -lt 30 || "$file_size" -gt 100 ]]; then
        fail "Некорректный размер role_id файла: $file_size байт (ожидается 30-100)"
    fi
    
    # Проверка что содержимое похоже на UUID/токен (только буквы, цифры, дефисы)
    if ! grep -qE '^[a-zA-Z0-9-]+$' "$file"; then
        fail "Некорректный формат role_id (разрешены только [a-zA-Z0-9-])"
    fi
    
    log "✅ Источник role_id валиден: $file"
}

# Валидация источника secret_id
validate_source_secret_id() {
    local file="$1"
    
    [[ -f "$file" && -r "$file" ]] || fail "secret_id файл недоступен: $file"
    
    # Разрешенные директории для источника
    local allowed_source_dirs=(
        "/home"
        "/tmp"
        "/dev/shm"
    )
    
    local file_dir=$(dirname "$file")
    local dir_allowed=false
    
    for allowed_dir in "${allowed_source_dirs[@]}"; do
        if [[ "$file_dir" == "$allowed_dir"* ]]; then
            dir_allowed=true
            break
        fi
    done
    
    [[ "$dir_allowed" == true ]] || fail "Источник secret_id не в разрешенной директории: $file_dir"
    
    # Проверка размера файла (UUID должен быть ~36 символов)
    local file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
    if [[ "$file_size" -lt 30 || "$file_size" -gt 100 ]]; then
        fail "Некорректный размер secret_id файла: $file_size байт (ожидается 30-100)"
    fi
    
    # Проверка что содержимое похоже на UUID/токен
    if ! grep -qE '^[a-zA-Z0-9-]+$' "$file"; then
        fail "Некорректный формат secret_id (разрешены только [a-zA-Z0-9-])"
    fi
    
    log "✅ Источник secret_id валиден: $file"
}

# Валидация целевой директории
validate_target_dir() {
    local dir="$1"
    
    # КРИТИЧНО: Только /opt/vault/conf разрешен
    if [[ "$dir" != "/opt/vault/conf" ]]; then
        fail "Целевая директория не разрешена: $dir (разрешена только /opt/vault/conf)"
    fi
    
    [[ -d "$dir" ]] || fail "Целевая директория не существует: $dir"
    [[ -w "$dir" ]] || fail "Целевая директория недоступна для записи: $dir"
    
    log "✅ Целевая директория валидна: $dir"
}

# Получение KAE из NAMESPACE_CI или определение через существующих пользователей
get_kae() {
    # Попытка 1: из переменной окружения NAMESPACE_CI
    if [[ -n "${NAMESPACE_CI:-}" ]]; then
        echo "$NAMESPACE_CI" | cut -d'_' -f2
        return 0
    fi
    
    # Попытка 2: из имени текущего пользователя (если он CI*-lnx-mon_ci)
    local current_user=$(whoami)
    if [[ "$current_user" =~ ^(CI[0-9]+)-lnx-mon_ci$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    
    # Попытка 3: поиск пользователя va-start в системе
    local va_start_user=$(getent passwd | grep -o 'CI[0-9]*-lnx-va-start' | head -1 || echo "")
    if [[ -n "$va_start_user" ]]; then
        echo "$va_start_user" | grep -o 'CI[0-9]*'
        return 0
    fi
    
    fail "Не удалось определить KAE (проверьте NAMESPACE_CI или имена пользователей)"
}

# Установка прав доступа
set_permissions() {
    local file="$1"
    local kae="$2"
    
    local va_start_user="${kae}-lnx-va-start"
    local va_read_group="${kae}-lnx-va-read"
    
    # Проверка существования пользователя и группы
    if ! id "$va_start_user" >/dev/null 2>&1; then
        fail "Пользователь $va_start_user не найден в системе"
    fi
    
    if ! getent group "$va_read_group" >/dev/null 2>&1; then
        fail "Группа $va_read_group не найдена в системе"
    fi
    
    # Установка владельца и группы
    chown "${va_start_user}:${va_read_group}" "$file" || fail "Не удалось установить владельца для $file"
    
    # Установка прав 640 (владелец: rw, группа: r, остальные: нет)
    chmod 640 "$file" || fail "Не удалось установить права для $file"
    
    log "✅ Права установлены для $file: ${va_start_user}:${va_read_group} 640"
}

main() {
    log "=========================================="
    log "Начало установки Vault credentials"
    log "=========================================="
    
    # Проверка аргументов
    [[ -n "$SOURCE_ROLE_ID" ]] || fail "Не указан SOURCE_ROLE_ID (аргумент 1)"
    [[ -n "$SOURCE_SECRET_ID" ]] || fail "Не указан SOURCE_SECRET_ID (аргумент 2)"
    
    log "Источник role_id: $SOURCE_ROLE_ID"
    log "Источник secret_id: $SOURCE_SECRET_ID"
    log "Целевая директория: $TARGET_DIR"
    
    # Валидация
    validate_source_role_id "$SOURCE_ROLE_ID"
    validate_source_secret_id "$SOURCE_SECRET_ID"
    validate_target_dir "$TARGET_DIR"
    
    # Определение KAE
    local kae
    kae=$(get_kae)
    log "Определен KAE: $kae"
    
    # Копирование файлов
    local target_role_id="${TARGET_DIR}/role_id.txt"
    local target_secret_id="${TARGET_DIR}/secret_id.txt"
    
    log "Копирование role_id..."
    cp "$SOURCE_ROLE_ID" "$target_role_id" || fail "Ошибка копирования role_id"
    set_permissions "$target_role_id" "$kae"
    
    log "Копирование secret_id..."
    cp "$SOURCE_SECRET_ID" "$target_secret_id" || fail "Ошибка копирования secret_id"
    set_permissions "$target_secret_id" "$kae"
    
    log "=========================================="
    log "✅ Vault credentials успешно установлены"
    log "   ${target_role_id}"
    log "   ${target_secret_id}"
    log "=========================================="
}

main "$@"
