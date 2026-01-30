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
    
    local allowed_paths=(
        "/opt/vault/conf/data_sec.json"
        "/tmp/temp_data_cred.json"
        "/tmp/data_sec.json"
    )
    
    local allowed=false
    for path in "${allowed_paths[@]}"; do
        [[ "$file" == "$path" ]] && allowed=true && break
    done
    
    [[ "$allowed" == true ]] || fail "JSON файл не в whitelist: $file"
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
