#!/bin/bash
# Безопасное извлечение секретов из JSON с автоматической очисткой
# Соответствует требованиям ИБ: обертка + unset после использования

set -euo pipefail

MODE="${1:-}"
JSON_FILE="${2:-}"
FIELD="${3:-}"

log() {
  echo "[SECRETS_WRAPPER] $*"
}

fail() {
  echo "[SECRETS_WRAPPER][ERROR] $*" >&2
  exit 1
}

# Белый список разрешенных JSON файлов
validate_json_file() {
    local file="$1"
    [[ -f "$file" && -r "$file" ]] || fail "JSON файл недоступен: $file"
    
    # Разрешенные директории (для Secure Edition - user-space)
    local allowed_dirs=(
        "/opt/vault/conf"
        "/tmp"
        "/dev/shm"
        "$HOME"  # Для Secure Edition: файлы в домашней директории пользователя
    )
    
    # Разрешенные имена файлов
    local allowed_names=(
        "data_sec.json"
        "temp_data_cred.json"
    )
    
    local file_dir=$(dirname "$file")
    local file_name=$(basename "$file")
    
    # Проверяем, что файл находится в разрешенной директории (или её поддиректориях)
    local dir_allowed=false
    for allowed_dir in "${allowed_dirs[@]}"; do
        # Проверка: файл в разрешенной директории или её поддиректориях
        if [[ "$file_dir" == "$allowed_dir"* ]]; then
            dir_allowed=true
            break
        fi
    done
    
    # Проверяем, что имя файла разрешено
    local name_allowed=false
    for allowed_name in "${allowed_names[@]}"; do
        if [[ "$file_name" == "$allowed_name" ]]; then
            name_allowed=true
            break
        fi
    done
    
    if [[ "$dir_allowed" == false ]]; then
        fail "JSON файл не в разрешенной директории: $file_dir (разрешены: ${allowed_dirs[*]})"
    fi
    
    if [[ "$name_allowed" == false ]]; then
        fail "Имя JSON файла не в whitelist: $file_name (разрешены: ${allowed_names[*]})"
    fi
}

# Белый список разрешенных полей
validate_field() {
    local field="$1"
    
    local allowed_fields=(
        "grafana_web.user"
        "grafana_web.pass"
        "netapp_ssh.user"
        "netapp_ssh.pass"
        "vault-agent.role_id"
        "vault-agent.secret_id"
    )
    
    local allowed=false
    for af in "${allowed_fields[@]}"; do
        [[ "$field" == "$af" ]] && allowed=true && break
    done
    
    [[ "$allowed" == true ]] || fail "Поле не в whitelist: $field"
}

main() {
    case "$MODE" in
        extract_secret)
            validate_json_file "$JSON_FILE"
            validate_field "$FIELD"
            
            local value
            value=$(jq -r ".${FIELD} // empty" "$JSON_FILE" 2>/dev/null || echo "")
            
            # Выводим значение
            printf '%s' "$value"
            
            # КРИТИЧНО: Очистка переменной после вывода
            unset value
            ;;
            
        validate_json)
            validate_json_file "$JSON_FILE"
            if jq empty "$JSON_FILE" 2>/dev/null; then
                echo "valid"
            else
                echo "invalid"
            fi
            ;;
            
        *)
            fail "Неизвестный режим: $MODE"
            ;;
    esac
}

main "$@"
