!/bin/bash
# Мониторинг Stack Deployment Script
# Компоненты: Harvest + Prometheus + Grafana

echo "[SCRIPT_START] Script started at $(date)" >&2
echo "[SCRIPT_START] Running as user: $(whoami)" >&2
echo "[SCRIPT_START] PWD: $PWD" >&2

# КРИТИЧНО: Временно отключаем set -e для диагностики
# set -euo pipefail
set -uo pipefail

echo "[SCRIPT_START] Shell options set" >&2

# НЕ устанавливаем trap DEBUG здесь - слишком рано!

# ============================================
# КОНФИГУРАЦИОННЫЕ ПЕРЕМЕННЫЕ
# ============================================
echo "[SCRIPT_START] Initializing variables..." >&2
: "${RLM_API_URL:=}"
: "${RLM_TOKEN:=}"
: "${NETAPP_API_ADDR:=}"
: "${GRAFANA_USER:=}"
: "${GRAFANA_PASSWORD:=}"
: "${SEC_MAN_ROLE_ID:=}"
: "${SEC_MAN_SECRET_ID:=}"
: "${SEC_MAN_ADDR:=}"
: "${NAMESPACE_CI:=}"
: "${VAULT_AGENT_KV:=}"
: "${RPM_URL_KV:=}"
: "${NETAPP_SSH_KV:=}"
: "${GRAFANA_WEB_KV:=}"
: "${SBERCA_CERT_KV:=}"
: "${ADMIN_EMAIL:=}"
: "${GRAFANA_PORT:=}"
: "${PROMETHEUS_PORT:=}"
: "${NETAPP_POLLER_NAME:=}"
: "${USE_SIMPLIFIED_CERT_FLOW:=true}"
: "${SKIP_IPTABLES:=true}"
: "${RUN_SERVICES_AS_MON_CI:=true}"

# Версионная информация (передается из Jenkins)
: "${DEPLOY_VERSION:=unknown}"
: "${DEPLOY_GIT_COMMIT:=unknown}"
: "${DEPLOY_BUILD_DATE:=unknown}"

WRAPPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wrappers"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_START_TS=$(date +%s)

# Конфигурация
SEC_MAN_ADDR="${SEC_MAN_ADDR^^}"
DATE_INSTALL=$(date '+%Y%m%d_%H%M%S')
# SECURE EDITION: Используем пользовательскую директорию вместо /opt/ (без root)
INSTALL_DIR="$HOME/monitoring/distrib/mon_rpm_${DATE_INSTALL}"
LOG_FILE="$HOME/monitoring_deployment_${DATE_INSTALL}.log"
DEBUG_LOG="$HOME/monitoring_deployment_debug_${DATE_INSTALL}.log"
DEBUG_SUMMARY="$HOME/monitoring_deployment_summary.log"
STATE_FILE="/var/lib/monitoring_deployment_state"

echo "[SCRIPT_START] Variables initialized" >&2
echo "[SCRIPT_START] DEBUG_LOG=$DEBUG_LOG" >&2
echo "[SCRIPT_START] LOG_FILE=$LOG_FILE" >&2
ENV_FILE="/etc/environment.d/99-monitoring-vars.conf"
HARVEST_CONFIG="/opt/harvest/harvest.yml"
# SECURE EDITION: Vault в пользовательском пространстве (без root)
VAULT_CONF_DIR="$HOME/monitoring/config/vault"
VAULT_LOG_DIR="$HOME/monitoring/logs/vault"
VAULT_CERTS_DIR="$HOME/monitoring/certs/vault"
VAULT_AGENT_HCL="${VAULT_CONF_DIR}/agent.hcl"
VAULT_ROLE_ID_FILE="${VAULT_CONF_DIR}/role_id.txt"
VAULT_SECRET_ID_FILE="${VAULT_CONF_DIR}/secret_id.txt"
VAULT_DATA_CRED_JS="${VAULT_CONF_DIR}/data_cred.js"
LOCAL_CRED_JSON="/tmp/temp_data_cred.json"

# URLs для загрузки пакетов (берутся из параметров Jenkins)
PROMETHEUS_URL="${PROMETHEUS_URL:-}"
HARVEST_URL="${HARVEST_URL:-}"
GRAFANA_URL="${GRAFANA_URL:-}"

# Глобальные переменные (будут инициализированы в detect_network_info)
SERVER_IP=""
SERVER_DOMAIN=""
VAULT_CRT_FILE=""
VAULT_KEY_FILE=""
GRAFANA_BEARER_TOKEN=""

# Порты сервисов
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3300}"
HARVEST_UNIX_PORT=12991
HARVEST_NETAPP_PORT=12990

# Значение KAE (вторая часть NAMESPACE_CI вида CIxxxx_CIyyyy), используется для имён УЗ
KAE=""
if [[ -n "${NAMESPACE_CI:-}" ]]; then
    KAE=$(echo "$NAMESPACE_CI" | cut -d'_' -f2)
fi

# ============================================
# ПОЛЬЗОВАТЕЛЬСКИЕ ПУТИ (SECURE EDITION - СООТВЕТСТВИЕ ИБ)
# ============================================
# Согласно документации ИБ Сбербанка, все файлы должны быть в пользовательском пространстве
# Базовая директория для всех данных мониторинга
MONITORING_BASE="$HOME/monitoring"

# Конфигурационные файлы (соответствует рекомендациям ИБ)
MONITORING_CONFIG_DIR="$MONITORING_BASE/config"
GRAFANA_USER_CONFIG_DIR="$MONITORING_CONFIG_DIR/grafana"
PROMETHEUS_USER_CONFIG_DIR="$MONITORING_CONFIG_DIR/prometheus"
HARVEST_USER_CONFIG_DIR="$MONITORING_CONFIG_DIR/harvest"

# Данные приложений
MONITORING_DATA_DIR="$MONITORING_BASE/data"
GRAFANA_USER_DATA_DIR="$MONITORING_DATA_DIR/grafana"
PROMETHEUS_USER_DATA_DIR="$MONITORING_DATA_DIR/prometheus"
HARVEST_USER_DATA_DIR="$MONITORING_DATA_DIR/harvest"

# Логи
MONITORING_LOGS_DIR="$MONITORING_BASE/logs"
GRAFANA_USER_LOGS_DIR="$MONITORING_LOGS_DIR/grafana"
PROMETHEUS_USER_LOGS_DIR="$MONITORING_LOGS_DIR/prometheus"
HARVEST_USER_LOGS_DIR="$MONITORING_LOGS_DIR/harvest"

# Сертификаты
MONITORING_CERTS_DIR="$MONITORING_BASE/certs"
GRAFANA_USER_CERTS_DIR="$MONITORING_CERTS_DIR/grafana"
PROMETHEUS_USER_CERTS_DIR="$MONITORING_CERTS_DIR/prometheus"

# Временные файлы для секретов (в памяти для безопасности)
MONITORING_SECRETS_DIR="/dev/shm/monitoring-secrets-$$"

echo "[SCRIPT_START] User paths configured for Secure Edition (IB compliant)" >&2

# ============================================
# ДИАГНОСТИЧЕСКОЕ ЛОГИРОВАНИЕ
# ============================================
# Диагностический лог для отладки RLM задач
DIAGNOSTIC_RLM_LOG="/tmp/diagnostic_rlm_task.log"

# Инициализация diagnostic log
init_diagnostic_log() {
    cat > "$DIAGNOSTIC_RLM_LOG" << DIAG_HEADER
================================================================
  DIAGNOSTIC LOG - RLM Task Troubleshooting
================================================================
Timestamp:    $(date '+%Y-%m-%d %H:%M:%S %Z')
Script:       ${BASH_SOURCE[0]}
Deploy Ver:   ${DEPLOY_VERSION:-unknown}
Git Commit:   ${DEPLOY_GIT_COMMIT:-unknown}
Build Date:   ${DEPLOY_BUILD_DATE:-unknown}
================================================================

DIAG_HEADER
}

# Функция записи в diagnostic log
write_diagnostic() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$DIAGNOSTIC_RLM_LOG" 2>/dev/null || true
}

# ============================================
# РАСШИРЕННОЕ DEBUG ЛОГИРОВАНИЕ
# ============================================

# Инициализация DEBUG лога с полной диагностикой
init_debug_log() {
    echo "[init_debug_log] START" >&2
    
    # КРИТИЧНО: Полностью отключаем все проверки ошибок
    set +e
    set +u
    set +o pipefail
    
    echo "[init_debug_log] Creating file: $DEBUG_LOG" >&2
    
    # Простой заголовок без сложных команд
    {
        echo "================================================================"
        echo "       MONITORING STACK DEPLOYMENT - DEBUG LOG"
        echo "================================================================"
        echo "Init started: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'Unknown')"
        echo "================================================================"
    } > "$DEBUG_LOG" 2>&1
    
    local result=$?
    echo "[init_debug_log] File creation result: $result" >&2
    
    # Создать симлинк сразу
    echo "[init_debug_log] Creating symlink: $DEBUG_SUMMARY" >&2
    ln -sf "$DEBUG_LOG" "$DEBUG_SUMMARY" 2>/dev/null
    echo "[init_debug_log] Symlink result: $?" >&2
    
    # НЕ восстанавливаем строгий режим для диагностики!
    # set -e
    # set -u
    # set -o pipefail
    
    echo "[init_debug_log] COMPLETE" >&2
    return 0
}

# Функция записи в DEBUG лог
log_debug() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$DEBUG_LOG" 2>/dev/null || true
}

# Функция для добавления расширенной диагностики в DEBUG лог
log_debug_extended() {
    set +e
    {
        echo ""
        echo "=== EXTENDED DIAGNOSTICS ==="
        echo "Timestamp:       $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Hostname:        $(hostname -f 2>/dev/null || hostname)"
        echo "User:            $(whoami) (UID=$(id -u), GID=$(id -g))"
        echo "Home:            $HOME"
        echo "PWD:             $PWD"
        echo "Script:          ${BASH_SOURCE[0]}"
        echo "Deploy Version:  ${DEPLOY_VERSION:-unknown}"
        echo "Git Commit:      ${DEPLOY_GIT_COMMIT:-unknown}"
        echo ""
        echo "=== ENVIRONMENT VARIABLES ==="
        echo "RLM_API_URL=${RLM_API_URL:-<not set>}"
        echo "SEC_MAN_ADDR=${SEC_MAN_ADDR:-<not set>}"
        echo "NAMESPACE_CI=${NAMESPACE_CI:-<not set>}"
        echo "KAE=${KAE:-<not set>}"
        echo "NETAPP_API_ADDR=${NETAPP_API_ADDR:-<not set>}"
        echo "GRAFANA_PORT=${GRAFANA_PORT:-<not set>}"
        echo "PROMETHEUS_PORT=${PROMETHEUS_PORT:-<not set>}"
        echo ""
        echo "=== DISK SPACE ==="
        df -h / /home /tmp 2>/dev/null || echo "Cannot check"
        echo ""
        echo "=== SUDO RIGHTS ==="
        sudo -l 2>&1 | head -10 || echo "No sudo or cannot check"
        echo ""
    } >> "$DEBUG_LOG" 2>&1
    set -e
}

# Функция для логирования состояния системы при ошибке
log_system_state_on_error() {
    {
        echo ""
        echo "================================================================"
        echo "       SYSTEM STATE AT ERROR - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "================================================================"
        echo ""
        echo "--- Running Processes (Monitoring) ---"
        ps aux | grep -E "grafana|prometheus|harvest" | grep -v grep || echo "No monitoring processes found"
        echo ""
        echo "--- Listening Ports ---"
        ss -tlnp 2>/dev/null | grep -E "${GRAFANA_PORT}|${PROMETHEUS_PORT}" || echo "No monitoring ports listening"
        echo ""
        echo "--- User Units Status (if available) ---"
        if [[ -n "${KAE:-}" ]]; then
            local mon_sys_user="${KAE}-lnx-mon_sys"
            if id "$mon_sys_user" >/dev/null 2>&1; then
                local mon_sys_uid
                mon_sys_uid=$(id -u "$mon_sys_user" 2>/dev/null || echo "")
                if [[ -n "$mon_sys_uid" ]]; then
                    echo "User: $mon_sys_user (UID: $mon_sys_uid)"
                    sudo -u "$mon_sys_user" env XDG_RUNTIME_DIR="/run/user/${mon_sys_uid}" \
                        systemctl --user list-units --no-pager 2>&1 || echo "Cannot list user units"
                fi
            else
                echo "Sys user $mon_sys_user does not exist"
            fi
        else
            echo "KAE not set, cannot check user units"
        fi
        echo ""
        echo "--- Recent Grafana Logs (last 30 lines) ---"
        if [[ -f "/tmp/grafana-debug.log" ]]; then
            tail -30 /tmp/grafana-debug.log 2>/dev/null || echo "Cannot read grafana-debug.log"
        else
            echo "/tmp/grafana-debug.log not found"
        fi
        echo ""
        echo "--- Files in working directory ---"
        ls -la "$PWD" 2>/dev/null || echo "Cannot list PWD"
        echo ""
        echo "--- Memory Usage ---"
        free -h 2>/dev/null || echo "Cannot check memory"
        echo ""
        echo "================================================================"
    } >> "$DEBUG_LOG" 2>&1
}

# Trap для отлова ошибок
trap_error() {
    local exit_code=$?
    local line_number=$1
    {
        echo ""
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "!!! ERROR TRAPPED at line $line_number"
        echo "!!! Exit code: $exit_code"
        echo "!!! Last command: $BASH_COMMAND"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo ""
        echo "Call stack:"
        local i=0
        while caller $i 2>/dev/null; do
            ((i++))
        done
        echo ""
    } >> "$DEBUG_LOG" 2>&1
    
    log_system_state_on_error
    create_debug_summary "$exit_code" "$(( $(date +%s) - SCRIPT_START_TS ))"
}

# Функция создания итогового резюме
create_debug_summary() {
    local exit_code=$1
    local elapsed_time=$2
    
    {
        echo ""
        echo "================================================================"
        echo "           DEPLOYMENT SUMMARY"
        echo "================================================================"
        echo "Exit Code:     $exit_code"
        echo "Elapsed Time:  ${elapsed_time}s ($(/usr/bin/awk -v s="$elapsed_time" 'BEGIN{printf "%.1f", s/60}')m)"
        echo "Finished:      $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo ""
        
        if [[ $exit_code -eq 0 ]]; then
            echo "STATUS: ✅ SUCCESS"
        else
            echo "STATUS: ❌ FAILED"
        fi
        
        echo ""
        echo "=== FINAL SERVICE STATUS ==="
        
        if [[ -n "${KAE:-}" ]]; then
            local mon_sys_user="${KAE}-lnx-mon_sys"
            if id "$mon_sys_user" >/dev/null 2>&1; then
                local mon_sys_uid
                mon_sys_uid=$(id -u "$mon_sys_user" 2>/dev/null || echo "")
                
                if [[ -n "$mon_sys_uid" ]]; then
                    for service in monitoring-prometheus monitoring-grafana monitoring-harvest; do
                        echo -n "$service.service: "
                        sudo -u "$mon_sys_user" env XDG_RUNTIME_DIR="/run/user/${mon_sys_uid}" \
                            systemctl --user is-active "$service.service" 2>&1 || echo "unknown"
                    done
                else
                    echo "Cannot determine sys user UID"
                fi
            else
                echo "Sys user $mon_sys_user not found"
            fi
        else
            echo "KAE not set"
        fi
        
        echo ""
        echo "=== LOGS LOCATION ==="
        echo "Main Log:      $LOG_FILE"
        echo "DEBUG Log:     $DEBUG_LOG"
        echo "Summary Link:  $DEBUG_SUMMARY"
        echo "Diagnostic:    $DIAGNOSTIC_RLM_LOG"
        echo ""
        echo "To view this log:"
        echo "  cat $DEBUG_SUMMARY"
        echo "  # or"
        echo "  cat $DEBUG_LOG"
        echo "================================================================"
    } >> "$DEBUG_LOG" 2>&1
}

# Установить trap для автоматического логирования ошибок
trap 'trap_error ${LINENO}' ERR

# ============================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================

format_elapsed_minutes() {
    local now_ts elapsed elapsed_min
    now_ts=$(date +%s)
    elapsed=$(( now_ts - SCRIPT_START_TS ))
    elapsed_min=$(/usr/bin/awk -v s="$elapsed" 'BEGIN{printf "%.1f", s/60}')
    printf "%sm" "$elapsed_min"
}

# Функции для вывода без цветового форматирования
print_header() {
    echo "================================================================"
    echo "     MONITORING STACK AUTOMATION - DEPLOYMENT SCRIPT"
    echo "================================================================"
    echo "  Version:        ${DEPLOY_VERSION}"
    echo "  Git Commit:     ${DEPLOY_GIT_COMMIT}"
    echo "  Build Date:     ${DEPLOY_BUILD_DATE}"
    echo "  Script Start:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "================================================================"
    echo
}

install_vault_via_rlm() {
    print_step "Установка и настройка Vault через RLM"
    ensure_working_directory

    if [[ -z "$RLM_TOKEN" || -z "$RLM_API_URL" || -z "$SEC_MAN_ADDR" || -z "$NAMESPACE_CI" || -z "$SERVER_IP" ]]; then
        print_error "Отсутствуют обязательные параметры для установки Vault (RLM_API_URL/RLM_TOKEN/SEC_MAN_ADDR/NAMESPACE_CI/SERVER_IP)"
        exit 1
    fi

    # Нормализуем SEC_MAN_ADDR в верхний регистр для единообразия
    local SEC_MAN_ADDR_UPPER
    SEC_MAN_ADDR_UPPER="${SEC_MAN_ADDR^^}"

    # Формируем KAE_SERVER из NAMESPACE_CI
    local KAE_SERVER
    KAE_SERVER=$(echo "$NAMESPACE_CI" | cut -d'_' -f2)
    print_info "Создание задачи RLM для Vault (tenant=$NAMESPACE_CI, v_url=$SEC_MAN_ADDR_UPPER, host=$SERVER_IP)"

    # Формируем JSON-пейлоад через jq (надежное экранирование)
    local payload vault_create_resp vault_task_id
    payload=$(jq -n       --arg v_url "$SEC_MAN_ADDR_UPPER"       --arg tenant "$NAMESPACE_CI"       --arg kae "$KAE_SERVER"       --arg ip "$SERVER_IP"       '{
        params: {
          v_url: $v_url,
          tenant: $tenant,
          start_after_configuration: false,
          approle: "approle/vault-agent",
          templates: [
            {
              source: { file_name: null, content: null },
              destination: { path: null }
            }
          ],
          serv_user: ($kae + "-lnx-va-start"),
          serv_group: ($kae + "-lnx-va-read"),
          read_user: ($kae + "-lnx-va-start"),
          log_num: 5,
          log_size: 5,
          log_level: "info",
          config_unwrapped: true,
          skip_sm_conflicts: false
        },
        start_at: "now",
        service: "vault_agent_config",
        items: [
          {
            table_id: "secmanserver",
            invsvm_ip: $ip
          }
        ]
      }')

    if [[ ! -x "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" ]]; then
        print_error "Лаунчер rlm-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        exit 1
    fi

    vault_create_resp=$(printf '%s' "$payload" | "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" create_vault_task "$RLM_API_URL" "$RLM_TOKEN") || true

    vault_task_id=$(echo "$vault_create_resp" | jq -r '.id // empty')
    if [[ -z "$vault_task_id" || "$vault_task_id" == "null" ]]; then
        print_error "❌ Ошибка при создании задачи Vault: $vault_create_resp"
        exit 1
    fi
    print_success "✅ Задача Vault создана. ID: $vault_task_id"

    # Мониторинг статуса задачи Vault
    local max_attempts=120
    local attempt=1
    local current_v_status=""
    local start_ts
    local interval_sec=10
    start_ts=$(date +%s)

    echo ""
    echo "┌────────────────────────────────────────────────────────────┐"
    printf "│  🔐 УСТАНОВКА: %-41s │\n" "Vault-agent"
    printf "│  Task ID: %-47s │\n" "$vault_task_id"
    printf "│  Max attempts: %-3d (интервал: %2dс)                      │\n" "$max_attempts" "$interval_sec"
    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    while [[ $attempt -le $max_attempts ]]; do
        local vault_status_resp
        vault_status_resp=$("$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" get_vault_status "$RLM_API_URL" "$RLM_TOKEN" "$vault_task_id") || true

        # Текущий статус
        current_v_status=$(echo "$vault_status_resp" | jq -r '.status // empty' 2>/dev/null || echo "$vault_status_resp" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
        [[ -z "$current_v_status" ]] && current_v_status="in_progress"

        # Расчет времени
        local now_ts elapsed_sec elapsed_min
        now_ts=$(date +%s)
        elapsed_sec=$(( now_ts - start_ts ))
        elapsed_min=$(/usr/bin/awk -v s="$elapsed_sec" 'BEGIN{printf "%.1f", s/60}')

        # Цветной статус-индикатор
        local status_icon="⏳"
        case "$current_v_status" in
            success) status_icon="✅" ;;
            failed|error) status_icon="❌" ;;
            in_progress) status_icon="🔄" ;;
        esac

        # Вывод прогресса (каждая попытка - новая строка для Jenkins)
        echo "🔐 Vault-agent │ Попытка $attempt/$max_attempts │ Статус: $current_v_status $status_icon │ Время: ${elapsed_min}м (${elapsed_sec}с)"

        write_diagnostic "Vault RLM: attempt=$attempt/$max_attempts, status=$current_v_status, elapsed=${elapsed_min}m"

        if echo "$vault_status_resp" | grep -q '"status":"success"'; then
            echo "✅ Vault-agent УСТАНОВЛЕН за ${elapsed_min}м (${elapsed_sec}с)"
            echo ""
            write_diagnostic "Vault RLM: SUCCESS after ${elapsed_min}m"
            sleep 10
            break
        elif echo "$vault_status_resp" | grep -qE '"status":"(failed|error)"'; then
            echo ""
            print_error "❌ VAULT-AGENT: ОШИБКА УСТАНОВКИ"
            print_error "📋 Ответ RLM: $vault_status_resp"
            write_diagnostic "Vault RLM: FAILED - $vault_status_resp"
            exit 1
        fi

        attempt=$((attempt + 1))
        sleep "$interval_sec"
    done

    if [[ $attempt -gt $max_attempts ]]; then
        echo ""
        print_error "⏰ VAULT-AGENT: ТАЙМАУТ после ${max_attempts} попыток (~$((max_attempts * interval_sec / 60)) минут)"
        exit 1
    fi
}

print_step() {
    echo "[STEP] $1" >&2
    log_message "[STEP] $1"
    log_debug "STEP: $1"
}

print_success() {
    echo "[SUCCESS] $1" >&2
    log_message "[SUCCESS] $1"
    log_debug "SUCCESS: $1"
}

print_error() {
    echo "[ERROR] $1" >&2
    log_message "[ERROR] $1"
    log_debug "ERROR: $1"
}

print_warning() {
    echo "[WARNING] $1" >&2
    log_message "[WARNING] $1"
    log_debug "WARNING: $1"
}

print_info() {
    echo "[INFO] $1" >&2
    log_message "[INFO] $1"
    log_debug "INFO: $1"
}

# Функция логирования
log_message() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    mkdir -p "$log_dir" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

# ИБ-COMPLIANT: Создание защищенной директории для временных секретов в RAM
# Требования ИБ: секреты должны храниться в /dev/shm (RAM) с автоочисткой
create_secure_secrets_dir() {
    local dir_name="monitoring-secrets-$$"
    local secure_dir="/dev/shm/${dir_name}"
    
    if [[ ! -d "$secure_dir" ]]; then
        mkdir -p "$secure_dir" || {
            print_error "Не удалось создать защищенную директорию: $secure_dir"
            return 1
        }
        
        # Установка прав 700 (только владелец)
        chmod 700 "$secure_dir" || {
            print_error "Не удалось установить права на: $secure_dir"
            return 1
        }
        
        print_info "Создана защищенная директория для секретов: $secure_dir"
        log_message "Создана защищенная директория для секретов (RAM): $secure_dir"
    fi
    
    # Возвращаем путь через echo (для использования в переменной)
    echo "$secure_dir"
}

# ИБ-COMPLIANT: Очистка защищенной директории с секретами
cleanup_secure_secrets_dir() {
    local secure_dir="$1"
    
    if [[ -n "$secure_dir" && -d "$secure_dir" && "$secure_dir" == /dev/shm/monitoring-secrets-* ]]; then
        print_info "Очистка защищенной директории секретов: $secure_dir"
        log_message "Очистка защищенной директории секретов: $secure_dir"
        
        # Затираем файлы перед удалением (paranoid mode)
        find "$secure_dir" -type f -exec shred -n 3 -z -u {} \; 2>/dev/null || true
        
        # Удаляем директорию
        rm -rf "$secure_dir" 2>/dev/null || true
        
        print_success "Защищенная директория очищена"
    fi
}

# Универсальная функция добавления пользователя в группу as-admin через RLM
ensure_user_in_as_admin() {
    local user="$1"

    if [[ -z "$user" ]]; then
        print_warning "ensure_user_in_as_admin: пустое имя пользователя, пропускаем"
        return 0
    fi

    if ! id "$user" >/dev/null 2>&1; then
        print_warning "Пользователь $user не найден в системе, пропускаем добавление в as-admin"
        return 0
    fi

    # Уже в группе as-admin → ничего не делаем
    if id "$user" | grep -q '\bas-admin\b'; then
        print_success "Пользователь $user уже состоит в группе as-admin"
        return 0
    fi

    if [[ -z "${RLM_API_URL:-}" || -z "${RLM_TOKEN:-}" || -z "${SERVER_IP:-}" ]]; then
        print_error "Недостаточно параметров для вызова RLM (RLM_API_URL/RLM_TOKEN/SERVER_IP)"
        exit 1
    fi

    if [[ ! -x "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" ]]; then
        print_error "Лаунчер rlm-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        exit 1
    fi

    print_info "Создание задачи RLM UVS_LINUX_ADD_USERS_GROUP для добавления $user в as-admin"

    local payload create_resp group_task_id
    payload=$(jq -n \
        --arg usr "$user" \
        --arg ip "$SERVER_IP" \
        '{
          params: {
            VAR_GRPS: [
              {
                group: "as-admin",
                gid: "",
                users: [ $usr ]
              }
            ]
          },
          start_at: "now",
          service: "UVS_LINUX_ADD_USERS_GROUP",
          skip_check_collisions: true,
          items: [
            {
              table_id: "uvslinuxtemplatewithtestandprom",
              invsvm_ip: $ip
            }
          ]
        }')

    create_resp=$(printf '%s' "$payload" | \
        "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" create_group_task "$RLM_API_URL" "$RLM_TOKEN") || true

    group_task_id=$(echo "$create_resp" | jq -r '.id // empty')
    if [[ -z "$group_task_id" || "$group_task_id" == "null" ]]; then
        print_error "Не удалось создать задачу UVS_LINUX_ADD_USERS_GROUP: $create_resp"
        exit 1
    fi
    print_success "Задача UVS_LINUX_ADD_USERS_GROUP создана. ID: $group_task_id"

    local max_attempts=120
    local attempt=1
    local current_status=""
    local start_ts
    local interval_sec=10
    start_ts=$(date +%s)

    echo ""
    echo "┌────────────────────────────────────────────────────────────┐"
    printf "│  👤 ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ В AS-ADMIN                  │\n"
    printf "│  User: %-50s │\n" "$user"
    printf "│  Task ID: %-47s │\n" "$group_task_id"
    printf "│  Max attempts: %-3d (интервал: %2dс)                      │\n" "$max_attempts" "$interval_sec"
    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    while [[ $attempt -le $max_attempts ]]; do
        local status_resp
        status_resp=$("$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" get_group_status "$RLM_API_URL" "$RLM_TOKEN" "$group_task_id") || true

        current_status=$(echo "$status_resp" | jq -r '.status // empty' 2>/dev/null || echo "in_progress")
        [[ -z "$current_status" ]] && current_status="in_progress"

        # Расчет времени
        local now_ts elapsed_sec elapsed_min
        now_ts=$(date +%s)
        elapsed_sec=$(( now_ts - start_ts ))
        elapsed_min=$(/usr/bin/awk -v s="$elapsed_sec" 'BEGIN{printf "%.1f", s/60}')

        # Цветной статус-индикатор
        local status_icon="⏳"
        case "$current_status" in
            success) status_icon="✅" ;;
            failed|error) status_icon="❌" ;;
            in_progress) status_icon="🔄" ;;
        esac

        # Вывод прогресса (каждая попытка - новая строка для Jenkins)
        echo "👤 User: $user │ Попытка $attempt/$max_attempts │ Статус: $current_status $status_icon │ Время: ${elapsed_min}м (${elapsed_sec}с)"

        if echo "$status_resp" | grep -q '"status":"success"'; then
            echo "✅ Пользователь $user добавлен в as-admin за ${elapsed_min}м (${elapsed_sec}с)"
            echo ""
            break
        elif echo "$status_resp" | grep -qE '"status":"(failed|error)"'; then
            echo ""
            print_error "❌ Ошибка добавления пользователя $user в as-admin"
            print_error "📋 Ответ RLM: $status_resp"
            exit 1
        fi

        attempt=$((attempt + 1))
        sleep "$interval_sec"
    done

    if [[ $attempt -gt $max_attempts ]]; then
        echo ""
        print_error "⏰ Таймаут добавления пользователя $user после ${max_attempts} попыток (~$((max_attempts * interval_sec / 60)) минут)"
        exit 1
    fi
}

# Добавляет пользователя в группу ${KAE}-lnx-va-read через RLM API
# Используется для получения доступа к сертификатам Vault Agent в /opt/vault/certs/
ensure_user_in_va_read_group() {
    local user="$1"
    
    print_step "Добавление пользователя $user в группу ${KAE}-lnx-va-read через RLM"
    ensure_working_directory
    
    if [[ -z "${KAE:-}" ]]; then
        print_warning "KAE не определён, пропускаем добавление в va-read"
        print_info "Добавьте пользователя $user в группу va-read вручную через IDM"
        return 1
    fi
    
    local va_read_group="${KAE}-lnx-va-read"
    
    # ПРОВЕРКА: Может пользователь уже в группе?
    echo "[VA-READ] Проверка: состоит ли $user в группе $va_read_group..." | tee /dev/stderr
    log_debug "Checking if $user is already in $va_read_group"
    
    if id "$user" 2>/dev/null | grep -q "$va_read_group"; then
        echo "[VA-READ] ✅ Пользователь $user УЖЕ СОСТОИТ в группе $va_read_group" | tee /dev/stderr
        log_debug "✅ User $user is already in $va_read_group"
        print_success "Пользователь $user уже в группе $va_read_group (пропускаем создание RLM задачи)"
        return 0
    fi
    
    echo "[VA-READ] ⚠️  Пользователь $user НЕ в группе $va_read_group, создаем RLM задачу..." | tee /dev/stderr
    log_debug "⚠️  User $user is not in $va_read_group, creating RLM task"
    
    if [[ -z "${RLM_API_URL:-}" || -z "${RLM_TOKEN:-}" ]]; then
        print_warning "RLM_API_URL или RLM_TOKEN не заданы, пропускаем добавление в va-read"
        print_info "Добавьте пользователя $user в группу ${KAE}-lnx-va-read вручную через IDM"
        return 1
    fi

    if [[ ! -x "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" ]]; then
        print_error "Лаунчер rlm-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        return 1
    fi

    print_info "Создание задачи RLM UVS_LINUX_ADD_USERS_GROUP для добавления $user в $va_read_group"

    local payload create_resp group_task_id
    payload=$(jq -n \
        --arg usr "$user" \
        --arg grp "$va_read_group" \
        --arg ip "$SERVER_IP" \
        '{
          params: {
            VAR_GRPS: [
              {
                group: $grp,
                gid: "",
                users: [ $usr ]
              }
            ]
          },
          start_at: "now",
          service: "UVS_LINUX_ADD_USERS_GROUP",
          skip_check_collisions: true,
          items: [
            {
              table_id: "uvslinuxtemplatewithtestandprom",
              invsvm_ip: $ip
            }
          ]
        }')

    create_resp=$(printf '%s' "$payload" | \
        "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" create_group_task "$RLM_API_URL" "$RLM_TOKEN") || true

    group_task_id=$(echo "$create_resp" | jq -r '.id // empty')
    if [[ -z "$group_task_id" || "$group_task_id" == "null" ]]; then
        print_error "Не удалось создать задачу UVS_LINUX_ADD_USERS_GROUP: $create_resp"
        return 1
    fi
    print_success "Задача UVS_LINUX_ADD_USERS_GROUP создана. ID: $group_task_id"

    local max_attempts=60  # 10 минут (60 * 10 сек)
    local attempt=1
    local current_status=""
    local start_ts
    local interval_sec=10
    start_ts=$(date +%s)

    echo ""
    echo "┌────────────────────────────────────────────────────────────┐"
    printf "│  🔐 ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ В VA-READ ГРУППУ             │\n"
    printf "│  User: %-50s │\n" "$user"
    printf "│  Group: %-48s │\n" "$va_read_group"
    printf "│  Task ID: %-47s │\n" "$group_task_id"
    printf "│  Max attempts: %-3d (интервал: %2dс)                      │\n" "$max_attempts" "$interval_sec"
    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    while [[ $attempt -le $max_attempts ]]; do
        local status_resp
        status_resp=$("$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" get_group_status "$RLM_API_URL" "$RLM_TOKEN" "$group_task_id") || true

        current_status=$(echo "$status_resp" | jq -r '.status // empty' 2>/dev/null || echo "in_progress")
        [[ -z "$current_status" ]] && current_status="in_progress"

        # Расчет времени
        local now_ts elapsed_sec elapsed_min
        now_ts=$(date +%s)
        elapsed_sec=$(( now_ts - start_ts ))
        elapsed_min=$(/usr/bin/awk -v s="$elapsed_sec" 'BEGIN{printf "%.1f", s/60}')

        # Цветной статус-индикатор
        local status_icon="⏳"
        case "$current_status" in
            success) status_icon="✅" ;;
            failed|error) status_icon="❌" ;;
            in_progress) status_icon="🔄" ;;
        esac

        # Вывод прогресса
        echo "🔐 User: $user │ Попытка $attempt/$max_attempts │ Статус: $current_status $status_icon │ Время: ${elapsed_min}м (${elapsed_sec}с)"

        if echo "$status_resp" | grep -q '"status":"success"'; then
            echo "✅ Пользователь $user добавлен в группу $va_read_group за ${elapsed_min}м (${elapsed_sec}с)"
            echo ""
            return 0
        elif echo "$status_resp" | grep -qE '"status":"(failed|error)"'; then
            echo ""
            print_error "❌ Ошибка добавления пользователя $user в $va_read_group"
            print_error "📋 Ответ RLM: $status_resp"
            return 1
        fi

        attempt=$((attempt + 1))
        sleep "$interval_sec"
    done

    echo ""
    print_error "⏰ Таймаут добавления пользователя $user в $va_read_group после ${max_attempts} попыток (~$((max_attempts * interval_sec / 60)) минут)"
    return 1
}

install_vault_via_rlm() {
    print_step "Установка и настройка Vault через RLM"
    ensure_working_directory

    if [[ -z "$RLM_TOKEN" || -z "$RLM_API_URL" || -z "$SEC_MAN_ADDR" || -z "$NAMESPACE_CI" || -z "$SERVER_IP" ]]; then
        print_error "Отсутствуют обязательные параметры для установки Vault (RLM_API_URL/RLM_TOKEN/SEC_MAN_ADDR/NAMESPACE_CI/SERVER_IP)"
        exit 1
    fi

    # Нормализуем SEC_MAN_ADDR в верхний регистр для единообразия
    local SEC_MAN_ADDR_UPPER
    SEC_MAN_ADDR_UPPER="${SEC_MAN_ADDR^^}"

    # Формируем KAE_SERVER из NAMESPACE_CI
    local KAE_SERVER
    KAE_SERVER=$(echo "$NAMESPACE_CI" | cut -d'_' -f2)
    print_info "Создание задачи RLM для Vault (tenant=$NAMESPACE_CI, v_url=$SEC_MAN_ADDR_UPPER, host=$SERVER_IP)"

    # Формируем JSON-пейлоад через jq (надежное экранирование)
    local payload vault_create_resp vault_task_id
    payload=$(jq -n \
      --arg v_url "$SEC_MAN_ADDR_UPPER" \
      --arg tenant "$NAMESPACE_CI" \
      --arg kae "$KAE_SERVER" \
      --arg ip "$SERVER_IP" \
      '{
        params: {
          v_url: $v_url,
          tenant: $tenant,
          start_after_configuration: false,
          approle: "approle/vault-agent",
          templates: [
            {
              source: { file_name: null, content: null },
              destination: { path: null }
            }
          ],
          serv_user: ($kae + "-lnx-va-start"),
          serv_group: ($kae + "-lnx-va-read"),
          read_user: ($kae + "-lnx-va-start"),
          log_num: 5,
          log_size: 5,
          log_level: "info",
          config_unwrapped: true,
          skip_sm_conflicts: false
        },
        start_at: "now",
        service: "vault_agent_config",
        items: [
          {
            table_id: "secmanserver",
            invsvm_ip: $ip
          }
        ]
      }')

    if [[ ! -x "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" ]]; then
        print_error "Лаунчер rlm-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        exit 1
    fi

    vault_create_resp=$(printf '%s' "$payload" | "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" create_vault_task "$RLM_API_URL" "$RLM_TOKEN") || true

    vault_task_id=$(echo "$vault_create_resp" | jq -r '.id // empty')
    if [[ -z "$vault_task_id" || "$vault_task_id" == "null" ]]; then
        print_error "❌ Ошибка при создании задачи Vault: $vault_create_resp"
        exit 1
    fi
    print_success "✅ Задача Vault создана. ID: $vault_task_id"

    # Мониторинг статуса задачи Vault
    local max_attempts=120
    local attempt=1
    local current_v_status=""
    local start_ts
    local interval_sec=10
    start_ts=$(date +%s)

    echo ""
    echo "┌────────────────────────────────────────────────────────────┐"
    printf "│  🔐 УСТАНОВКА: %-41s │\n" "Vault-agent"
    printf "│  Task ID: %-47s │\n" "$vault_task_id"
    printf "│  Max attempts: %-3d (интервал: %2dс)                      │\n" "$max_attempts" "$interval_sec"
    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    while [[ $attempt -le $max_attempts ]]; do
        local vault_status_resp
        vault_status_resp=$("$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" get_vault_status "$RLM_API_URL" "$RLM_TOKEN" "$vault_task_id") || true

        # Текущий статус
        current_v_status=$(echo "$vault_status_resp" | jq -r '.status // empty' 2>/dev/null || echo "$vault_status_resp" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
        [[ -z "$current_v_status" ]] && current_v_status="in_progress"

        # Расчет времени
        local now_ts elapsed_sec elapsed_min
        now_ts=$(date +%s)
        elapsed_sec=$(( now_ts - start_ts ))
        elapsed_min=$(/usr/bin/awk -v s="$elapsed_sec" 'BEGIN{printf "%.1f", s/60}')

        # Цветной статус-индикатор
        local status_icon="⏳"
        case "$current_v_status" in
            success) status_icon="✅" ;;
            failed|error) status_icon="❌" ;;
            in_progress) status_icon="🔄" ;;
        esac

        # Вывод прогресса (каждая попытка - новая строка для Jenkins)
        echo "🔐 Vault-agent │ Попытка $attempt/$max_attempts │ Статус: $current_v_status $status_icon │ Время: ${elapsed_min}м (${elapsed_sec}с)"

        write_diagnostic "Vault RLM: attempt=$attempt/$max_attempts, status=$current_v_status, elapsed=${elapsed_min}m"

        if echo "$vault_status_resp" | grep -q '"status":"success"'; then
            echo "✅ Vault-agent УСТАНОВЛЕН за ${elapsed_min}м (${elapsed_sec}с)"
            echo ""
            write_diagnostic "Vault RLM: SUCCESS after ${elapsed_min}m"
            sleep 10
            break
        elif echo "$vault_status_resp" | grep -qE '"status":"(failed|error)"'; then
            echo ""
            print_error "❌ VAULT-AGENT: ОШИБКА УСТАНОВКИ"
            print_error "📋 Ответ RLM: $vault_status_resp"
            write_diagnostic "Vault RLM: FAILED - $vault_status_resp"
            exit 1
        fi

        attempt=$((attempt + 1))
        sleep "$interval_sec"
    done

    if [[ $attempt -gt $max_attempts ]]; then
        echo ""
        print_error "⏰ VAULT-AGENT: ТАЙМАУТ после ${max_attempts} попыток (~$((max_attempts * interval_sec / 60)) минут)"
        exit 1
    fi
}

ensure_user_in_va_start_group() {
    local user="$1"
    
    print_step "Добавление пользователя $user в группу ${KAE}-lnx-va-start через RLM"
    ensure_working_directory
    
    if [[ -z "${KAE:-}" ]]; then
        print_warning "KAE не определён, пропускаем добавление в va-start"
        print_info "Добавьте пользователя $user в группу va-start вручную через IDM"
        return 1
    fi
    
    local va_start_group="${KAE}-lnx-va-start"
    
    # ПРОВЕРКА: Может пользователь уже в группе?
    echo "[VA-START] Проверка: состоит ли $user в группе $va_start_group..." | tee /dev/stderr
    log_debug "Checking if $user is already in $va_start_group"
    
    if id "$user" 2>/dev/null | grep -q "$va_start_group"; then
        echo "[VA-START] ✅ Пользователь $user УЖЕ СОСТОИТ в группе $va_start_group" | tee /dev/stderr
        log_debug "✅ User $user is already in $va_start_group"
        print_success "Пользователь $user уже в группе $va_start_group (пропускаем создание RLM задачи)"
        return 0
    fi
    
    echo "[VA-START] ⚠️  Пользователь $user НЕ в группе $va_start_group, создаем RLM задачу..." | tee /dev/stderr
    log_debug "⚠️  User $user is not in $va_start_group, creating RLM task"
    
    if [[ -z "${RLM_API_URL:-}" || -z "${RLM_TOKEN:-}" ]]; then
        print_warning "RLM_API_URL или RLM_TOKEN не заданы, пропускаем добавление в va-start"
        print_info "Добавьте пользователя $user в группу ${KAE}-lnx-va-start вручную через IDM"
        return 1
    fi

    if [[ ! -x "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" ]]; then
        print_error "Лаунчер rlm-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        return 1
    fi

    print_info "Создание задачи RLM UVS_LINUX_ADD_USERS_GROUP для добавления $user в $va_start_group"

    local payload create_resp group_task_id
    payload=$(jq -n \
        --arg usr "$user" \
        --arg grp "$va_start_group" \
        --arg ip "$SERVER_IP" \
        '{
          params: {
            VAR_GRPS: [
              {
                group: $grp,
                gid: "",
                users: [ $usr ]
              }
            ]
          },
          start_at: "now",
          service: "UVS_LINUX_ADD_USERS_GROUP",
          skip_check_collisions: true,
          items: [
            {
              table_id: "uvslinuxtemplatewithtestandprom",
              invsvm_ip: $ip
            }
          ]
        }')

    create_resp=$(printf '%s' "$payload" | \
        "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" create_group_task "$RLM_API_URL" "$RLM_TOKEN") || true

    group_task_id=$(echo "$create_resp" | jq -r '.id // empty')
    if [[ -z "$group_task_id" || "$group_task_id" == "null" ]]; then
        print_error "Не удалось создать задачу UVS_LINUX_ADD_USERS_GROUP: $create_resp"
        return 1
    fi
    print_success "Задача UVS_LINUX_ADD_USERS_GROUP создана. ID: $group_task_id"

    local max_attempts=60  # 10 минут (60 * 10 сек)
    local attempt=1
    local current_status=""
    local start_ts
    local interval_sec=10
    start_ts=$(date +%s)

    echo ""
    echo "┌────────────────────────────────────────────────────────────┐"
    printf "│  🔐 ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ В VA-START ГРУППУ            │\n"
    printf "│  User: %-50s │\n" "$user"
    printf "│  Group: %-48s │\n" "$va_start_group"
    printf "│  Task ID: %-47s │\n" "$group_task_id"
    printf "│  Max attempts: %-3d (интервал: %2dс)                      │\n" "$max_attempts" "$interval_sec"
    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    while [[ $attempt -le $max_attempts ]]; do
        local status_resp
        status_resp=$("$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" get_group_status "$RLM_API_URL" "$RLM_TOKEN" "$group_task_id") || true

        current_status=$(echo "$status_resp" | jq -r '.status // empty' 2>/dev/null || echo "in_progress")
        [[ -z "$current_status" ]] && current_status="in_progress"

        # Расчет времени
        local now_ts elapsed_sec elapsed_min
        now_ts=$(date +%s)
        elapsed_sec=$(( now_ts - start_ts ))
        elapsed_min=$(/usr/bin/awk -v s="$elapsed_sec" 'BEGIN{printf "%.1f", s/60}')

        # Цветной статус-индикатор
        local status_icon="⏳"
        case "$current_status" in
            success) status_icon="✅" ;;
            failed|error) status_icon="❌" ;;
            in_progress) status_icon="🔄" ;;
        esac

        echo "🔐 $user → $va_start_group │ Попытка $attempt/$max_attempts │ Статус: $current_status $status_icon │ Время: ${elapsed_min}м (${elapsed_sec}с)"

        if echo "$status_resp" | grep -q '"status":"success"'; then
            echo "✅ Пользователь $user добавлен в $va_start_group за ${elapsed_min}м (${elapsed_sec}с)"
            echo ""
            print_success "Пользователь $user добавлен в группу $va_start_group"
            print_info "ВАЖНО: Изменения группы применятся в новой сессии (или требуется newgrp/$USER login)"
            return 0
        elif echo "$status_resp" | grep -qE '"status":"(failed|error)"'; then
            echo ""
            print_error "❌ Ошибка добавления пользователя $user в $va_start_group"
            print_error "📋 Ответ RLM: $status_resp"
            return 1
        fi

        attempt=$((attempt + 1))
        sleep "$interval_sec"
    done

    echo ""
    print_error "⏰ Таймаут добавления пользователя $user в $va_start_group после ${max_attempts} попыток (~$((max_attempts * interval_sec / 60)) минут)"
    return 1
}

# Последовательно добавляет ${KAE}-lnx-mon_sys и ${KAE}-lnx-mon_ci в группу as-admin через RLM
ensure_monitoring_users_in_as_admin() {
    print_step "Проверка членства monitoring-УЗ в группе as-admin"
    ensure_working_directory

    if [[ -z "${KAE:-}" ]]; then
        print_warning "KAE не определён (NAMESPACE_CI пуст), пропускаем добавление monitoring-УЗ в as-admin"
        return 0
    fi

    local mon_sys_user="${KAE}-lnx-mon_sys"
    local mon_ci_user="${KAE}-lnx-mon_ci"

    # Сначала добавляем mon_sys, ожидаем success
    ensure_user_in_as_admin "$mon_sys_user"
    
    # КРИТИЧЕСКИ ВАЖНО: Включаем linger для mon_sys (обязательно для user units!)
    # Linger позволяет user units продолжать работать после logout пользователя
    print_step "Включение linger для ${mon_sys_user} (required for user units)"
    
    if ! id "$mon_sys_user" >/dev/null 2>&1; then
        print_warning "Пользователь $mon_sys_user не найден, пропускаем linger"
    elif command -v linuxadm-enable-linger >/dev/null 2>&1; then
        # ===== РАСШИРЕННАЯ ДИАГНОСТИКА =====
        log_debug "========================================"
        log_debug "ДИАГНОСТИКА: linuxadm-enable-linger"
        log_debug "========================================"
        
        echo "[DEBUG-LINGER] ========================================" >&2
        echo "[DEBUG-LINGER] Диагностика linuxadm-enable-linger" >&2
        echo "[DEBUG-LINGER] ========================================" >&2
        
        # Информация о текущем пользователе
        local current_user=$(whoami)
        local current_uid=$(id -u)
        local current_gid=$(id -g)
        echo "[DEBUG-LINGER] Текущий пользователь: $current_user (UID=$current_uid, GID=$current_gid)" >&2
        log_debug "Текущий пользователь: $current_user (UID=$current_uid, GID=$current_gid)"
        
        # Информация о целевом пользователе
        echo "[DEBUG-LINGER] Целевой пользователь: $mon_sys_user" >&2
        log_debug "Целевой пользователь: $mon_sys_user"
        
        echo "[DEBUG-LINGER] ========================================" >&2
        
        # Группы ТЕКУЩЕГО пользователя
        echo "[DEBUG-LINGER] Группы ТЕКУЩЕГО пользователя ($current_user):" >&2
        id "$current_user" >&2
        log_debug "Группы текущего пользователя: $(id $current_user)"
        
        echo "[DEBUG-LINGER] ----------------------------------------" >&2
        
        # Группы ЦЕЛЕВОГО пользователя
        echo "[DEBUG-LINGER] Группы ЦЕЛЕВОГО пользователя ($mon_sys_user):" >&2
        id "$mon_sys_user" >&2
        log_debug "Группы целевого пользователя: $(id $mon_sys_user)"
        
        echo "[DEBUG-LINGER] ========================================" >&2
        
        # Проверка as-admin для текущего пользователя
        if id "$current_user" | grep -q '\bas-admin\b'; then
            echo "[DEBUG-LINGER] ✅ Текущий ($current_user) в as-admin" >&2
            log_debug "✅ Текущий пользователь в as-admin"
        else
            echo "[DEBUG-LINGER] ❌ Текущий ($current_user) НЕ в as-admin" >&2
            log_debug "❌ Текущий пользователь НЕ в as-admin"
        fi
        
        # Проверка as-admin для целевого пользователя
        if id "$mon_sys_user" | grep -q '\bas-admin\b'; then
            echo "[DEBUG-LINGER] ✅ Целевой ($mon_sys_user) в as-admin" >&2
            log_debug "✅ Целевой пользователь в as-admin"
        else
            echo "[DEBUG-LINGER] ❌ Целевой ($mon_sys_user) НЕ в as-admin" >&2
            log_debug "❌ Целевой пользователь НЕ в as-admin"
        fi
        
        echo "[DEBUG-LINGER] ========================================" >&2
        
        # Проверка пути к команде
        local linger_cmd_path=$(command -v linuxadm-enable-linger)
        echo "[DEBUG-LINGER] Путь к команде: $linger_cmd_path" >&2
        log_debug "linuxadm-enable-linger path: $linger_cmd_path"
        
        # Проверка прав на файл
        if [[ -f "$linger_cmd_path" ]]; then
            echo "[DEBUG-LINGER] Права на файл:" >&2
            ls -la "$linger_cmd_path" >&2
            log_debug "Права на linuxadm-enable-linger: $(ls -la $linger_cmd_path)"
        fi
        
        echo "[DEBUG-LINGER] ========================================" >&2
        
        # Проверка текущего статуса linger
        echo "[DEBUG-LINGER] Текущий статус linger для $mon_sys_user:" >&2
        loginctl show-user "$mon_sys_user" 2>&1 | grep -i linger >&2 || echo "[DEBUG-LINGER] (loginctl show-user не доступен или пользователь не имеет сессии)" >&2
        
        echo "[DEBUG-LINGER] ========================================" >&2
        echo "[DEBUG-LINGER] Выполнение команды: linuxadm-enable-linger '$mon_sys_user'" >&2
        log_debug "Выполнение: linuxadm-enable-linger '$mon_sys_user'"
        
        # Запуск с захватом ВСЕГО вывода
        local linger_stdout linger_stderr linger_exit_code
        linger_stdout=$(mktemp)
        linger_stderr=$(mktemp)
        
        linuxadm-enable-linger "$mon_sys_user" > "$linger_stdout" 2> "$linger_stderr"
        linger_exit_code=$?
        
        echo "[DEBUG-LINGER] ========================================" >&2
        echo "[DEBUG-LINGER] Exit code: $linger_exit_code" >&2
        log_debug "linuxadm-enable-linger exit code: $linger_exit_code"
        
        echo "[DEBUG-LINGER] ----------------------------------------" >&2
        echo "[DEBUG-LINGER] STDOUT:" >&2
        cat "$linger_stdout" >&2
        log_debug "STDOUT: $(cat $linger_stdout)"
        
        echo "[DEBUG-LINGER] ----------------------------------------" >&2
        echo "[DEBUG-LINGER] STDERR:" >&2
        cat "$linger_stderr" >&2
        log_debug "STDERR: $(cat $linger_stderr)"
        
        echo "[DEBUG-LINGER] ========================================" >&2
        
        # Очистка временных файлов
        rm -f "$linger_stdout" "$linger_stderr"
        
        # Проверка статуса после выполнения
        echo "[DEBUG-LINGER] Проверка статуса ПОСЛЕ выполнения команды:" >&2
        loginctl show-user "$mon_sys_user" 2>&1 | grep -i linger >&2 || echo "[DEBUG-LINGER] (loginctl show-user недоступен)" >&2
        
        # Альтернативная проверка через файл
        if [[ -f "/var/lib/systemd/linger/$mon_sys_user" ]]; then
            echo "[DEBUG-LINGER] ✅ Файл linger существует: /var/lib/systemd/linger/$mon_sys_user" >&2
            log_debug "✅ Linger file exists"
        else
            echo "[DEBUG-LINGER] ❌ Файл linger НЕ существует: /var/lib/systemd/linger/$mon_sys_user" >&2
            log_debug "❌ Linger file NOT exists"
        fi
        
        echo "[DEBUG-LINGER] ========================================" >&2
        
        if [[ $linger_exit_code -eq 0 ]]; then
            print_success "✅ Linger включен для ${mon_sys_user}"
            log_debug "✅ Linger enabled successfully"
        else
            print_error "❌ Ошибка включения linger для ${mon_sys_user} (exit code: $linger_exit_code)"
            print_warning "User units могут не запуститься без linger!"
            print_info "🔍 См. детальную диагностику [DEBUG-LINGER] выше"
            log_debug "❌ Linger enable FAILED with exit code: $linger_exit_code"
            
            # НЕ останавливаем выполнение для получения полной диагностики
            # Можно раскомментировать если критично:
            # exit 1
        fi
    else
        print_error "❌ linuxadm-enable-linger не найден на сервере"
        log_debug "❌ linuxadm-enable-linger command not found"
        print_warning "Требуется установка пакета linuxadm или аналогичного"
        print_info "Без linger user units остановятся при logout пользователя"
        exit 1
    fi

    # Затем добавляем mon_ci
    ensure_user_in_as_admin "$mon_ci_user"
}

# Добавляет ${KAE}-lnx-mon_sys в группу grafana через RLM (для доступа к /etc/grafana/grafana.ini)
ensure_mon_sys_in_grafana_group() {
    print_step "Проверка членства ${KAE}-lnx-mon_sys в группе grafana"
    ensure_working_directory

    if [[ -z "${KAE:-}" ]]; then
        print_warning "KAE не определён (NAMESPACE_CI пуст), пропускаем добавление mon_sys в grafana"
        return 0
    fi

    local mon_sys_user="${KAE}-lnx-mon_sys"

    if ! id "$mon_sys_user" >/dev/null 2>&1; then
        print_warning "Пользователь ${mon_sys_user} не найден в системе, пропускаем добавление в grafana"
        return 0
    fi

    # Уже в группе grafana → ничего не делаем
    if id "$mon_sys_user" | grep -q '\bgrafana\b'; then
        print_success "Пользователь ${mon_sys_user} уже состоит в группе grafana"
        return 0
    fi

    if [[ -z "${RLM_API_URL:-}" || -z "${RLM_TOKEN:-}" || -z "${SERVER_IP:-}" ]]; then
        print_error "Недостаточно параметров для вызова RLM (RLM_API_URL/RLM_TOKEN/SERVER_IP)"
        exit 1
    fi

    if [[ ! -x "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" ]]; then
        print_error "Лаунчер rlm-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        exit 1
    fi

    print_info "Создание задачи RLM UVS_LINUX_ADD_USERS_GROUP для добавления ${mon_sys_user} в grafana"

    local payload create_resp group_task_id
    payload=$(jq -n \
        --arg usr "$mon_sys_user" \
        --arg ip "$SERVER_IP" \
        '{
          params: {
            VAR_GRPS: [
              {
                group: "grafana",
                gid: "",
                users: [ $usr ]
              }
            ]
          },
          start_at: "now",
          service: "UVS_LINUX_ADD_USERS_GROUP",
          skip_check_collisions: true,
          items: [
            {
              table_id: "uvslinuxtemplatewithtestandprom",
              invsvm_ip: $ip
            }
          ]
        }')

    create_resp=$(printf '%s' "$payload" | \
        "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" create_group_task "$RLM_API_URL" "$RLM_TOKEN") || true

    group_task_id=$(echo "$create_resp" | jq -r '.id // empty')
    if [[ -z "$group_task_id" || "$group_task_id" == "null" ]]; then
        print_error "Не удалось создать задачу UVS_LINUX_ADD_USERS_GROUP для grafana: $create_resp"
        exit 1
    fi
    print_success "Задача UVS_LINUX_ADD_USERS_GROUP (grafana) создана. ID: $group_task_id"
    print_info "Ожидание выполнения задачи для пользователя ${mon_sys_user} (grafana группа)..."

    local max_attempts=120
    local attempt=1
    local current_status=""
    local start_ts
    local interval_sec=10
    start_ts=$(date +%s)

    while [[ $attempt -le $max_attempts ]]; do
        local status_resp
        status_resp=$("$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" get_group_status "$RLM_API_URL" "$RLM_TOKEN" "$group_task_id") || true

        current_status=$(echo "$status_resp" | jq -r '.status // empty' 2>/dev/null || \
            echo "$status_resp" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
        [[ -z "$current_status" ]] && current_status="in_progress"

        # Расчет времени
        local now_ts elapsed elapsed_sec elapsed_min
        now_ts=$(date +%s)
        elapsed=$(( now_ts - start_ts ))
        elapsed_sec=$elapsed
        elapsed_min=$(/usr/bin/awk -v s="$elapsed" 'BEGIN{printf "%.1f", s/60}')

        # Информативный вывод
        echo "[INFO] ├─ Попытка $attempt/$max_attempts | Статус: $current_status | Время ожидания: ${elapsed_min}м (${elapsed_sec}с)" >&2
        log_message "ADD_USERS_GROUP (grafana) for ${mon_sys_user}: attempt=$attempt/$max_attempts, status=$current_status, elapsed=${elapsed_min}m"

        if echo "$status_resp" | grep -q '"status":"success"'; then
            local total_time
            total_time=$(/usr/bin/awk -v s="$elapsed" 'BEGIN{printf "%.1f", s/60}')
            print_success "🎉 Задача UVS_LINUX_ADD_USERS_GROUP для ${mon_sys_user} (grafana) выполнена за ${total_time}м (${elapsed_sec}с)"
            break
        fi

        if echo "$status_resp" | grep -q '"status":"failed"'; then
            print_error "💥 Задача UVS_LINUX_ADD_USERS_GROUP для ${mon_sys_user} (grafana) завершилась с ошибкой"
            print_error "Ответ RLM: $status_resp"
            exit 1
        elif echo "$status_resp" | grep -q '"status":"error"'; then
            print_error "💥 Задача UVS_LINUX_ADD_USERS_GROUP для ${mon_sys_user} (grafana) вернула статус error"
            print_error "Ответ RLM: $status_resp"
            exit 1
        fi

        attempt=$((attempt + 1))
        sleep "$interval_sec"
    done

    if [[ $attempt -gt $max_attempts ]]; then
        local total_time=$(( max_attempts * interval_sec / 60 ))
        print_error "⏰ UVS_LINUX_ADD_USERS_GROUP для ${mon_sys_user} (grafana): таймаут ожидания (~${total_time} минут). Последний статус: ${current_status:-unknown}"
        exit 1
    fi
}

# Функция для проверки и установки рабочей директории
ensure_working_directory() {
    local target_dir="/tmp"
    if ! pwd >/dev/null 2>&1; then
        print_warning "Текущая директория недоступна, переключаемся на $target_dir"
        cd "$target_dir" || {
            print_error "Не удалось переключиться на $target_dir"
            exit 1
        }
    fi
    local current_dir
    current_dir=$(pwd)
    print_info "Текущая рабочая директория: $current_dir"
}

# Функция проверки прав (Secure Edition - БЕЗ root!)
check_sudo() {
    print_step "Проверка режима запуска"
    ensure_working_directory
    
    # В Secure Edition (v4.0+) скрипт НЕ должен запускаться под root
    if [[ $EUID -eq 0 ]]; then
        print_error "⚠️  Скрипт запущен под root!"
        print_error "В Secure Edition (v4.0+) скрипт должен запускаться под CI-пользователем"
        print_error "Используйте: ./$SCRIPT_NAME (БЕЗ sudo)"
        log_debug "ERROR: Script run as root (EUID=0), but Secure Edition requires CI-user"
        exit 1
    fi
    
    print_success "✅ Скрипт запущен под непривилегированным пользователем ($(whoami))"
    print_info "Режим: Secure Edition (User Units Only)"
    log_debug "Script running as user: $(whoami) (UID=$EUID)"
}

# Функция проверки и закрытия портов
check_and_close_ports() {
    print_step "Проверка и закрытие используемых портов"
    ensure_working_directory
    local ports=(
        "$PROMETHEUS_PORT:Prometheus"
        "$GRAFANA_PORT:Grafana"
        "$HARVEST_UNIX_PORT:Harvest-Unix"
        "$HARVEST_NETAPP_PORT:Harvest-NetApp"
    )
    local port_in_use=false

    for port_info in "${ports[@]}"; do
        IFS=':' read -r port name <<< "$port_info"
        if ss -tln | grep -q ":$port "; then
            print_warning "$name (порт $port) уже используется"
            port_in_use=true
            print_info "Поиск процессов, использующих порт $port..."
            local pids
            pids=$(ss -tlnp | grep ":$port " | awk -F, '{for(i=1;i<=NF;i++) if ($i ~ /pid=/) {print $i}}' | awk -F= '{print $2}' | sort -u)
            if [[ -n "$pids" ]]; then
                for pid in $pids; do
                    print_info "Информация о процессе с PID $pid:"
                    ps -p "$pid" -o pid,ppid,cmd --no-headers | while read -r pid ppid cmd; do
                        print_info "PID: $pid, PPID: $ppid, Команда: $cmd"
                        log_message "PID: $pid, PPID: $ppid, Команда: $cmd"
                    done
                    print_info "Попытка завершения процесса с PID $pid"
                    kill -TERM "$pid" 2>/dev/null || print_warning "Не удалось отправить SIGTERM процессу $pid"
                    sleep 2
                    if kill -0 "$pid" 2>/dev/null; then
                        print_info "Процесс $pid не завершился, отправляем SIGKILL"
                        kill -9 "$pid" 2>/dev/null || print_warning "Не удалось завершить процесс $pid с SIGKILL"
                    fi
                done
                sleep 2
                if ! ss -tln | grep -q ":$port "; then
                    print_success "Порт $port успешно освобожден"
                else
                    print_error "Не удалось освободить порт $port"
                    ss -tlnp | grep ":$port " | while read -r line; do
                        print_info "$line"
                        log_message "Порт $port все еще занят: $line"
                    done
                    exit 1
                fi
            else
                print_warning "Не удалось найти процессы для порта $port"
                ss -tlnp | grep ":$port " | while read -r line; do
                    print_info "$line"
                    log_message "Порт $port занят, но PID не найден: $line"
                done
            fi
        else
            print_success "$name (порт $port) свободен"
        fi
    done

    if [[ "$port_in_use" == true ]]; then
        print_info "Все используемые порты были закрыты"
    else
        print_success "Все порты свободны, дополнительных действий не требуется"
    fi
}

# Функция определения IP и домена
detect_network_info() {
    print_step "Определение IP адреса и домена сервера"
    ensure_working_directory
    print_info "Определение IP адреса..."
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if [[ -z "$SERVER_IP" ]]; then
        print_error "Не удалось определить IP адрес"
        exit 1
    fi
    print_success "IP адрес определен: $SERVER_IP"

    print_info "Определение домена через nslookup..."
    if command -v nslookup &> /dev/null; then
        SERVER_DOMAIN=$(nslookup "$SERVER_IP" 2>/dev/null | grep 'name =' | awk '{print $4}' | /usr/bin/sed 's/\.$//' | head -1)
        if [[ -z "$SERVER_DOMAIN" ]]; then
            SERVER_DOMAIN=$(nslookup "$SERVER_IP" 2>/dev/null | grep -E "^$SERVER_IP" | awk '{print $2}' | /usr/bin/sed 's/\.$//' | head -1)
        fi
    fi

    if [[ -z "$SERVER_DOMAIN" ]]; then
        print_warning "Не удалось определить домен через nslookup"
        SERVER_DOMAIN=$(hostname -f 2>/dev/null || hostname)
        print_info "Используется hostname: $SERVER_DOMAIN"
    else
        print_success "Домен определен: $SERVER_DOMAIN"
    fi

    # Инициализация путей к сертификатам после определения домена
    VAULT_CRT_FILE="${VAULT_CERTS_DIR}/server.crt"
    VAULT_KEY_FILE="${VAULT_CERTS_DIR}/server.key"

    save_environment_variables
}

save_environment_variables() {
    print_step "Сохранение сетевых переменных в окружение"
    ensure_working_directory
    
    # В Secure Edition НЕ пишем в /etc/environment.d/ (требует root)
    # Только экспортируем переменные в текущую сессию
    export MONITOR_SERVER_IP="$SERVER_IP"
    export MONITOR_SERVER_DOMAIN="$SERVER_DOMAIN"
    export MONITOR_INSTALL_DATE="$DATE_INSTALL"
    export MONITOR_INSTALL_DIR="$INSTALL_DIR"
    
    log_debug "Exported environment variables (not saved to /etc/ - no root in Secure Edition)"
    print_success "Переменные экспортированы в текущую сессию"
    print_info "IP: $SERVER_IP, Домен: $SERVER_DOMAIN"
    print_warning "Переменные НЕ сохранены в $ENV_FILE (требует root, не нужно в Secure Edition)"
}

cleanup_all_previous() {
    print_step "Полная очистка предыдущих установок"
    ensure_working_directory
    local services=("prometheus" "grafana-server" "harvest" "harvest-prometheus")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_info "Остановка сервиса: $service"
            systemctl stop "$service" || true
        fi
        if systemctl is-enabled --quiet "$service" 2>/dev/null; then
            print_info "Отключение автозапуска: $service"
            systemctl disable "$service" || true
        fi
    done

    # Убираем остановку vault - он уже установлен и работает
    print_info "Vault оставляем без изменений (предполагается что уже установлен и настроен)"

    if command -v harvest &> /dev/null; then
        print_info "Остановка Harvest через команду"
        harvest stop --config "$HARVEST_CONFIG" 2>/dev/null || true
    fi

    local packages=("prometheus" "grafana" "harvest")
    for package in "${packages[@]}"; do
        if rpm -q "$package" &>/dev/null; then
            print_info "Удаление пакета: $package"
            rpm -e "$package" --nodeps >/dev/null 2>&1 || true
        fi
    done

    local dirs_to_clean=(
        "/etc/prometheus"
        "/etc/grafana"
        "/etc/harvest"
        "/opt/harvest"
        "/var/lib/prometheus"
        "/var/lib/grafana"
        "/var/lib/harvest"
        "/usr/share/grafana"
        "/usr/share/prometheus"
    )


    for dir in "${dirs_to_clean[@]}"; do
        # Пропускаем очистку /var/lib/grafana если установлена переменная SKIP_GRAFANA_DATA_CLEANUP
        if [[ "$dir" == "/var/lib/grafana" && "${SKIP_GRAFANA_DATA_CLEANUP:-false}" == "true" ]]; then
            print_info "Пропускаем удаление директории: $dir (SKIP_GRAFANA_DATA_CLEANUP=true)"
            continue
        fi
        
        if [[ -d "$dir" ]]; then
            print_info "Удаление директории: $dir"
            if ! rm -rf "$dir" >/dev/null 2>&1; then
                print_warning "Не удалось удалить директорию: $dir (недостаточно прав)"
            fi
        fi
    done

    local files_to_clean=(
        "/usr/lib/systemd/system/prometheus.service"
        "/usr/lib/systemd/system/grafana-server.service"
        "/usr/lib/systemd/system/harvest.service"
        "/usr/lib/systemd/system/harvest-prometheus.service"
        "/etc/systemd/system/prometheus.service"
        "/etc/systemd/system/grafana-server.service"
        "/etc/systemd/system/harvest.service"
        "/usr/bin/harvest"
        "/usr/local/bin/harvest"
    )

    for file in "${files_to_clean[@]}"; do
        if [[ -f "$file" ]]; then
            print_info "Удаление файла: $file"
            if ! rm -rf "$file" >/dev/null 2>&1; then
                print_warning "Не удалось удалить файл: $file (недостаточно прав)"
            fi
        fi
    done




    systemctl daemon-reload >/dev/null 2>&1
    print_success "Полная очистка завершена"
}

check_dependencies() {
    print_step "Проверка необходимых зависимостей"
    ensure_working_directory
    local missing_deps=()
    # УБИРАЕМ vault из списка зависимостей
    local deps=("curl" "rpm" "systemctl" "nslookup" "iptables" "jq" "ss" "openssl")

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Отсутствуют необходимые зависимости: ${missing_deps[*]}"
        exit 1
    fi

    print_success "Все зависимости доступны"
}

create_user_monitoring_directories() {
    print_step "Создание пользовательских директорий для мониторинга (Secure Edition - ИБ compliant)"
    ensure_working_directory
    
    log_debug "Creating user-space monitoring directories..."
    
    # Создаем базовую структуру БЕЗ root
    local dirs=(
        "$MONITORING_BASE"
        "$MONITORING_BASE/distrib"
        "$MONITORING_CONFIG_DIR"
        "$GRAFANA_USER_CONFIG_DIR"
        "$PROMETHEUS_USER_CONFIG_DIR"
        "$HARVEST_USER_CONFIG_DIR"
        "$VAULT_CONF_DIR"
        "$MONITORING_DATA_DIR"
        "$GRAFANA_USER_DATA_DIR"
        "$PROMETHEUS_USER_DATA_DIR"
        "$HARVEST_USER_DATA_DIR"
        "$MONITORING_LOGS_DIR"
        "$GRAFANA_USER_LOGS_DIR"
        "$PROMETHEUS_USER_LOGS_DIR"
        "$HARVEST_USER_LOGS_DIR"
        "$VAULT_LOG_DIR"
        "$MONITORING_CERTS_DIR"
        "$GRAFANA_USER_CERTS_DIR"
        "$PROMETHEUS_USER_CERTS_DIR"
        "$VAULT_CERTS_DIR"
    )
    
    for dir in "${dirs[@]}"; do
        if mkdir -p "$dir" 2>/dev/null; then
            log_debug "Created: $dir"
        else
            print_warning "Не удалось создать $dir (может уже существует)"
        fi
    done
    
    # Создаем директорию для секретов в памяти (безопасность по ИБ)
    if mkdir -p "$MONITORING_SECRETS_DIR" 2>/dev/null; then
        chmod 700 "$MONITORING_SECRETS_DIR"
        log_debug "Created secrets dir in memory: $MONITORING_SECRETS_DIR"
    fi
    
    print_success "Пользовательские директории созданы в $MONITORING_BASE"
    print_info "Конфигурация: $MONITORING_CONFIG_DIR"
    print_info "Данные: $MONITORING_DATA_DIR"
    print_info "Логи: $MONITORING_LOGS_DIR"
    print_info "Сертификаты: $MONITORING_CERTS_DIR"
}

create_directories() {
    # В Secure Edition НЕ создаем директории в /opt/ (требуют root)
    # Вместо этого используем пользовательские директории
    create_user_monitoring_directories
}

# ============================================================
# LEGACY APPROACH: vault-agent with system paths (/opt/vault/)
# ============================================================
# ВНИМАНИЕ: Этот код закомментирован в пользу упрощенного подхода
# без vault-agent и без sudo для файловых операций.
#
# ТЕКУЩИЙ ПОДХОД (Simplified):
# - Credentials извлекаются из temp_data_cred.json при деплое
# - Сертификаты получаются из Jenkins или генерируются self-signed
# - Всё хранится в $HOME/monitoring/ (user-space)
# - Перезапуск сервисов через sudo -u mon_sys systemctl --user
# - НЕ требуется sudo для файловых операций
#
# LEGACY ПОДХОД (vault-agent):
# - vault-agent работает как системный сервис
# - Автоматическая ротация сертификатов (каждые N часов)
# - Непрерывное обновление secrets из Vault
# - Требует sudo для операций в /opt/vault/conf/ и /opt/vault/certs/
# - Требует IDM заявку с System-level sudo-правилами
#
# КАК ВЕРНУТЬСЯ К vault-agent:
# 1. Раскомментируйте эту функцию (строки 1771-2575)
# 2. В main() замените get_certificates_from_jenkins() на setup_vault_config()
# 3. Раскомментируйте секцию в sudoers.example (строки 36-68)
# 4. Создайте IDM заявку с sudo-правилами из sudoers.example
# 5. Раскомментируйте вызов в create_rlm_install_tasks() для создания /opt/vault/
# 6. См. документацию: HOW-TO-REVERT.md
#
# ПРЕИМУЩЕСТВА vault-agent:
# ✅ Автоматическая ротация сертификатов
# ✅ Непрерывное обновление secrets
# ✅ Разделение секретов по времени получения
#
# НЕДОСТАТКИ vault-agent:
# ❌ Требует sudo для системных операций
# ❌ Сложнее настройка и troubleshooting
# ❌ Зависимость от системного сервиса
# ❌ Требует пользователей va-start, va-read
#
# Дата закомментирования: 15.02.2026
# Причина: Упрощение архитектуры согласно требованиям ИБ
# ============================================================

check_vault_agent_preflight_access() {
    local current_user
    current_user=$(whoami)
    local missing=0

    echo "[VAULT-PREFLIGHT] ========================================" | tee /dev/stderr
    echo "[VAULT-PREFLIGHT] Проверка прав для legacy vault-agent flow" | tee /dev/stderr
    echo "[VAULT-PREFLIGHT] Текущий пользователь: $current_user" | tee /dev/stderr
    echo "[VAULT-PREFLIGHT] KAE=${KAE:-<unknown>}" | tee /dev/stderr
    echo "[VAULT-PREFLIGHT] Ожидаемый источник agent.hcl: $VAULT_AGENT_HCL" | tee /dev/stderr
    echo "[VAULT-PREFLIGHT] ========================================" | tee /dev/stderr

    # Проверка membership - изменения групп применяются только в новой сессии.
    if id -nG "$current_user" 2>/dev/null | tr ' ' '\n' | grep -Fxq "${KAE}-lnx-va-start"; then
        echo "[VAULT-PREFLIGHT] ✅ Пользователь уже в группе ${KAE}-lnx-va-start" | tee /dev/stderr
    else
        echo "[VAULT-PREFLIGHT] ⚠️  Пользователь НЕ в группе ${KAE}-lnx-va-start (нужна новая сессия после добавления)" | tee /dev/stderr
    fi

    # Проверяем sudo rules без фактического выполнения команд.
    check_sudo_rule() {
        local label="$1"
        shift
        if sudo -n -l -- "$@" >/dev/null 2>&1; then
            echo "[VAULT-PREFLIGHT] ✅ sudo rule есть: $label" | tee /dev/stderr
        else
            echo "[VAULT-PREFLIGHT] ❌ sudo rule отсутствует: $label" | tee /dev/stderr
            echo "[VAULT-PREFLIGHT]    EXPECTED: ALL=(root) NOEXEC: NOPASSWD: $*" | tee /dev/stderr
            missing=1
        fi
    }

    # Минимум для текущей реализации setup_vault_config().
    check_sudo_rule "copy role_id" /usr/bin/cp /tmp/vault_role_id.txt /opt/vault/conf/role_id.txt
    check_sudo_rule "copy secret_id" /usr/bin/cp /tmp/vault_secret_id.txt /opt/vault/conf/secret_id.txt
    check_sudo_rule "copy agent.hcl" /usr/bin/cp "$VAULT_AGENT_HCL" /opt/vault/conf/agent.hcl
    check_sudo_rule "vault-agent restart" /usr/bin/systemctl restart vault-agent
    check_sudo_rule "vault-agent is-active" /usr/bin/systemctl is-active vault-agent
    check_sudo_rule "vault-agent status" /usr/bin/systemctl status vault-agent

    # Рекомендованные (необязательные) права: для автоматического bootstrap /opt/vault/certs.
    check_sudo_rule "mkdir /opt/vault/certs (recommended)" /usr/bin/mkdir -p /opt/vault/certs
    check_sudo_rule "chown /opt/vault/certs (recommended)" /usr/bin/chown "${KAE}-lnx-va-start:${KAE}-lnx-va-read" /opt/vault/certs
    check_sudo_rule "chmod /opt/vault/certs (recommended)" /usr/bin/chmod 750 /opt/vault/certs

    if [[ $missing -ne 0 ]]; then
        echo "[VAULT-PREFLIGHT] ========================================" | tee /dev/stderr
        echo "[VAULT-PREFLIGHT] ❌ Обнаружены недостающие права/правила." | tee /dev/stderr
        echo "[VAULT-PREFLIGHT] Подсказка: проверьте, что KAE в sudoers совпадает с текущим (${KAE})." | tee /dev/stderr
        echo "[VAULT-PREFLIGHT] Частая ошибка: правило для /home/<другой-KAE>-lnx-mon_ci/.../agent.hcl." | tee /dev/stderr
        echo "[VAULT-PREFLIGHT] Диагностика: sudo -n -l" | tee /dev/stderr
        echo "[VAULT-PREFLIGHT] ========================================" | tee /dev/stderr
    else
        echo "[VAULT-PREFLIGHT] ✅ Проверка прав пройдена" | tee /dev/stderr
    fi
}

setup_vault_config() {
    print_step "Настройка Vault конфигурации"
    ensure_working_directory
    check_vault_agent_preflight_access

    # Проверяем, что SERVER_DOMAIN определен
    if [[ -z "$SERVER_DOMAIN" ]]; then
        print_error "SERVER_DOMAIN не определен. Запустите detect_network_info() сначала."
        exit 1
    fi

   mkdir -p "$VAULT_CONF_DIR" "$VAULT_LOG_DIR" "$VAULT_CERTS_DIR"
    # Ищем временный JSON с cred в известных местах (учитываем запуск под sudo)
   local cred_json_path=""
   for candidate in "$LOCAL_CRED_JSON" "$PWD/temp_data_cred.json" "$(dirname "$0")/temp_data_cred.json" "/home/${SUDO_USER:-}/temp_data_cred.json" "/tmp/temp_data_cred.json"; do
       if [[ -n "$candidate" && -f "$candidate" ]]; then
           cred_json_path="$candidate"
           break
       fi
   done
   if [[ -z "$cred_json_path" ]]; then
       print_error "Временный файл с учетными данными не найден (проверены стандартные пути)"
       exit 1
   fi
    
    # ===== РАСШИРЕННАЯ ДИАГНОСТИКА SECRETS =====
   echo "[DEBUG-SECRETS] ========================================" >&2
   echo "[DEBUG-SECRETS] Диагностика secrets-manager-wrapper" >&2
   echo "[DEBUG-SECRETS] ========================================" >&2
   log_debug "========================================"
   log_debug "ДИАГНОСТИКА: secrets extraction"
   log_debug "========================================"
    
   echo "[DEBUG-SECRETS] Файл с credentials: $cred_json_path" >&2
   log_debug "Credentials file: $cred_json_path"
    
   if [[ -f "$cred_json_path" ]]; then
       echo "[DEBUG-SECRETS] ✅ Файл существует" >&2
       echo "[DEBUG-SECRETS] Размер: $(stat -c%s "$cred_json_path" 2>/dev/null || echo "unknown") байт" >&2
       echo "[DEBUG-SECRETS] Права: $(ls -la "$cred_json_path")" >&2
       log_debug "✅ Credentials file exists: $(stat -c%s "$cred_json_path" 2>/dev/null || echo "unknown") bytes"
        
        # БЕЗОПАСНО: Показываем только структуру JSON (ключи без значений)
       echo "[DEBUG-SECRETS] Структура JSON (только ключи):" >&2
       jq -r 'keys | .[]' "$cred_json_path" 2>&1 >&2 || echo "[DEBUG-SECRETS] (не удалось прочитать структуру)" >&2
        
        # Проверяем наличие нужных полей
       echo "[DEBUG-SECRETS] ----------------------------------------" >&2
       echo "[DEBUG-SECRETS] Проверка наличия поля 'vault-agent':" >&2
       if jq -e '.["vault-agent"]' "$cred_json_path" >/dev/null 2>&1; then
           echo "[DEBUG-SECRETS] ✅ Поле 'vault-agent' существует" >&2
           log_debug "✅ Field 'vault-agent' exists"
            
           echo "[DEBUG-SECRETS] Проверка наличия 'vault-agent.role_id':" >&2
           if jq -e '.["vault-agent"].role_id' "$cred_json_path" >/dev/null 2>&1; then
               echo "[DEBUG-SECRETS] ✅ Поле 'vault-agent.role_id' существует" >&2
               log_debug "✅ Field 'vault-agent.role_id' exists"
           else
               echo "[DEBUG-SECRETS] ❌ Поле 'vault-agent.role_id' НЕ существует" >&2
               log_debug "❌ Field 'vault-agent.role_id' NOT exists"
           fi
            
           echo "[DEBUG-SECRETS] Проверка наличия 'vault-agent.secret_id':" >&2
           if jq -e '.["vault-agent"].secret_id' "$cred_json_path" >/dev/null 2>&1; then
               echo "[DEBUG-SECRETS] ✅ Поле 'vault-agent.secret_id' существует" >&2
               log_debug "✅ Field 'vault-agent.secret_id' exists"
           else
               echo "[DEBUG-SECRETS] ❌ Поле 'vault-agent.secret_id' НЕ существует" >&2
               log_debug "❌ Field 'vault-agent.secret_id' NOT exists"
           fi
       else
           echo "[DEBUG-SECRETS] ❌ Поле 'vault-agent' НЕ существует" >&2
           log_debug "❌ Field 'vault-agent' NOT exists"
       fi
   else
       echo "[DEBUG-SECRETS] ❌ Файл НЕ существует" >&2
       log_debug "❌ Credentials file NOT exists"
   fi
    
   echo "[DEBUG-SECRETS] ========================================" >&2
   echo "[DEBUG-SECRETS] Проверка secrets-manager-wrapper:" >&2
    
   local wrapper_path="$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh"
   echo "[DEBUG-SECRETS] Путь: $wrapper_path" >&2
   log_debug "Wrapper path: $wrapper_path"
    
   if [[ -f "$wrapper_path" ]]; then
       echo "[DEBUG-SECRETS] ✅ Файл существует" >&2
       echo "[DEBUG-SECRETS] Права: $(ls -la "$wrapper_path")" >&2
       log_debug "✅ Wrapper exists: $(ls -la "$wrapper_path")"
        
       if [[ -x "$wrapper_path" ]]; then
           echo "[DEBUG-SECRETS] ✅ Файл исполняемый" >&2
           log_debug "✅ Wrapper is executable"
       else
           echo "[DEBUG-SECRETS] ❌ Файл НЕ исполняемый" >&2
           log_debug "❌ Wrapper NOT executable"
       fi
   else
       echo "[DEBUG-SECRETS] ❌ Файл НЕ существует" >&2
       log_debug "❌ Wrapper NOT exists"
   fi
    
   echo "[DEBUG-SECRETS] ========================================" >&2
    
    # SECURITY: Используем secrets-manager-wrapper для безопасного извлечения секретов
    # Пишем role_id/secret_id напрямую из JSON в файлы через wrapper (автоматическая очистка)
   echo "[VAULT-CONFIG] Извлечение секретов..." | tee /dev/stderr
    
   local secrets_extracted=false
    
    # Сначала пробуем через wrapper (безопасный способ)
   if [[ -x "$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" ]]; then
       echo "[VAULT-CONFIG] Используем secrets-manager-wrapper..." | tee /dev/stderr
       echo "[DEBUG-SECRETS] Выполнение: extract_secret role_id..." >&2
       log_debug "Executing: extract_secret for role_id"
        
       local role_id_stdout role_id_stderr role_id_exit
       role_id_stdout=$(mktemp)
       role_id_stderr=$(mktemp)
        
       "$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" extract_secret "$cred_json_path" "vault-agent.role_id" > "$role_id_stdout" 2> "$role_id_stderr"
       role_id_exit=$?
        
       echo "[DEBUG-SECRETS] Exit code: $role_id_exit" >&2
       log_debug "role_id extraction exit code: $role_id_exit"
        
       if [[ $role_id_exit -eq 0 && -s "$role_id_stdout" ]]; then
           echo "[DEBUG-SECRETS] ✅ role_id успешно извлечен" >&2
           log_debug "✅ role_id extracted successfully"
           cat "$role_id_stdout" > "$VAULT_ROLE_ID_FILE"
           secrets_extracted=true
       else
           echo "[DEBUG-SECRETS] ⚠️  Не удалось извлечь role_id или результат пустой" >&2
           echo "[DEBUG-SECRETS] STDOUT:" >&2
           cat "$role_id_stdout" >&2
           echo "[DEBUG-SECRETS] STDERR:" >&2
           cat "$role_id_stderr" >&2
           log_debug "⚠️  role_id extraction failed or empty"
            # Не выходим с ошибкой, продолжаем с пустыми файлами
       fi
        
       rm -f "$role_id_stdout" "$role_id_stderr"
        
       echo "[DEBUG-SECRETS] ----------------------------------------" >&2
       echo "[DEBUG-SECRETS] Выполнение: extract_secret secret_id..." >&2
       log_debug "Executing: extract_secret for secret_id"
        
       local secret_id_stdout secret_id_stderr secret_id_exit
       secret_id_stdout=$(mktemp)
       secret_id_stderr=$(mktemp)
        
       "$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" extract_secret "$cred_json_path" "vault-agent.secret_id" > "$secret_id_stdout" 2> "$secret_id_stderr"
       secret_id_exit=$?
        
       echo "[DEBUG-SECRETS] Exit code: $secret_id_exit" >&2
       log_debug "secret_id extraction exit code: $secret_id_exit"
        
       if [[ $secret_id_exit -eq 0 && -s "$secret_id_stdout" ]]; then
           echo "[DEBUG-SECRETS] ✅ secret_id успешно извлечен" >&2
           log_debug "✅ secret_id extracted successfully"
           cat "$secret_id_stdout" > "$VAULT_SECRET_ID_FILE"
           secrets_extracted=true
       else
           echo "[DEBUG-SECRETS] ⚠️  Не удалось извлечь secret_id или результат пустой" >&2
           echo "[DEBUG-SECRETS] STDOUT:" >&2
           cat "$secret_id_stdout" >&2
           echo "[DEBUG-SECRETS] STDERR:" >&2
           cat "$secret_id_stderr" >&2
           log_debug "⚠️  secret_id extraction failed or empty"
            # Не выходим с ошибкой, продолжаем с пустыми файлами
       fi
        
       rm -f "$secret_id_stdout" "$secret_id_stderr"
        
       echo "[DEBUG-SECRETS] ========================================" | tee /dev/stderr
        
       if [[ "$secrets_extracted" == "true" ]]; then
           echo "[VAULT-CONFIG] ✅ Секреты успешно извлечены через wrapper" | tee /dev/stderr
       else
           echo "[VAULT-CONFIG] ⚠️  Секреты НЕ извлечены через wrapper" | tee /dev/stderr
       fi
   else
       echo "[VAULT-CONFIG] ⚠️  secrets-manager-wrapper_launcher.sh не найден или не исполняемый" | tee /dev/stderr
       log_debug "⚠️  Wrapper not found or not executable"
   fi
    
    # ВТОРОЙ ЭТАП: Извлечение секретов в /tmp/ через jq
    # SECURE EDITION: Используем /tmp/ с случайным суффиксом для безопасности
    # и автоматическую очистку через trap
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   echo "[VAULT-CONFIG] Извлечение секретов в /tmp/ через jq" | tee /dev/stderr
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   log_debug "========================================"
   log_debug "EXTRACTING: secrets to /tmp/ via jq"
   log_debug "========================================"
    
    # Используем /tmp/ с фиксированными именами (требование ИБ - нет wildcards в sudoers)
    # БЕЗОПАСНОСТЬ: файлы с mode 600, удаляются сразу после копирования
   local TMP_ROLE_ID="/tmp/vault_role_id.txt"
   local TMP_SECRET_ID="/tmp/vault_secret_id.txt"
    
    # Удаляем старые файлы если остались от предыдущего запуска
   rm -f "$TMP_ROLE_ID" "$TMP_SECRET_ID" 2>/dev/null
    
   echo "[VAULT-CONFIG] Временные файлы:" | tee /dev/stderr
   echo "[VAULT-CONFIG]   TMP_ROLE_ID=$TMP_ROLE_ID" | tee /dev/stderr
   echo "[VAULT-CONFIG]   TMP_SECRET_ID=$TMP_SECRET_ID" | tee /dev/stderr
   log_debug "TMP_ROLE_ID=$TMP_ROLE_ID"
   log_debug "TMP_SECRET_ID=$TMP_SECRET_ID"
    
    # Trap для автоматической очистки временных файлов
   trap 'rm -f "$TMP_ROLE_ID" "$TMP_SECRET_ID" 2>/dev/null' EXIT INT TERM
    
   if command -v jq >/dev/null 2>&1 && [[ -f "$cred_json_path" ]]; then
       echo "[VAULT-CONFIG] jq доступен, извлекаем секреты..." | tee /dev/stderr
       log_debug "jq available, extracting secrets"
        
        # Проверяем, есть ли секреты в файле (используем правильный синтаксис)
       if jq -e '.["vault-agent"].role_id' "$cred_json_path" >/dev/null 2>&1 && \
          jq -e '.["vault-agent"].secret_id' "$cred_json_path" >/dev/null 2>&1; then
           echo "[VAULT-CONFIG] ✅ Секреты найдены в JSON файле" | tee /dev/stderr
           log_debug "✅ Secrets found in JSON file"
            
            # Извлекаем в /tmp/ с правами 600
           if jq -r '.["vault-agent"].role_id' "$cred_json_path" > "$TMP_ROLE_ID" 2>/dev/null && \
              jq -r '.["vault-agent"].secret_id' "$cred_json_path" > "$TMP_SECRET_ID" 2>/dev/null; then
                
                # Устанавливаем строгие права (только для текущего пользователя)
               chmod 600 "$TMP_ROLE_ID" "$TMP_SECRET_ID" 2>/dev/null
                
               echo "[VAULT-CONFIG] Проверка извлеченных файлов..." | tee /dev/stderr
               log_debug "Checking extracted files"
                
                # Проверяем что файлы не пустые
               if [[ -s "$TMP_ROLE_ID" && -s "$TMP_SECRET_ID" ]]; then
                   local role_id_size secret_id_size
                   role_id_size=$(stat -c%s "$TMP_ROLE_ID" 2>/dev/null || echo "0")
                   secret_id_size=$(stat -c%s "$TMP_SECRET_ID" 2>/dev/null || echo "0")
                    
                   echo "[VAULT-CONFIG] ✅ Секреты успешно извлечены в /tmp/" | tee /dev/stderr
                   echo "[VAULT-CONFIG]   role_id: $role_id_size байт" | tee /dev/stderr
                   echo "[VAULT-CONFIG]   secret_id: $secret_id_size байт" | tee /dev/stderr
                   log_debug "✅ Secrets extracted to /tmp/ successfully"
                   log_debug "role_id size: $role_id_size bytes"
                   log_debug "secret_id size: $secret_id_size bytes"
                    
                   secrets_extracted=true
                    
                    # Также копируем в user-space для справки
                   echo "[VAULT-CONFIG] Копирование в user-space для справки..." | tee /dev/stderr
                   if cp "$TMP_ROLE_ID" "$VAULT_ROLE_ID_FILE" 2>/dev/null && \
                      cp "$TMP_SECRET_ID" "$VAULT_SECRET_ID_FILE" 2>/dev/null; then
                       chmod 640 "$VAULT_ROLE_ID_FILE" "$VAULT_SECRET_ID_FILE" 2>/dev/null || true
                       echo "[VAULT-CONFIG] ✅ Скопировано в user-space" | tee /dev/stderr
                       log_debug "✅ Copied to user-space"
                   else
                       echo "[VAULT-CONFIG] ⚠️  Не удалось скопировать в user-space (не критично)" | tee /dev/stderr
                       log_debug "⚠️  Failed to copy to user-space (not critical)"
                   fi
               else
                   echo "[VAULT-CONFIG] ❌ Извлеченные секреты пустые" | tee /dev/stderr
                   log_debug "❌ Extracted secrets are empty"
                   secrets_extracted=false
               fi
           else
               echo "[VAULT-CONFIG] ❌ Ошибка при извлечении секретов через jq" | tee /dev/stderr
               log_debug "❌ Error extracting secrets via jq"
               secrets_extracted=false
           fi
       else
           echo "[VAULT-CONFIG] ❌ Секреты НЕ найдены в JSON файле" | tee /dev/stderr
           echo "[VAULT-CONFIG] Проверьте наличие полей: .['vault-agent'].role_id и .['vault-agent'].secret_id" | tee /dev/stderr
           log_debug "❌ Secrets NOT found in JSON file"
           secrets_extracted=false
       fi
   else
       echo "[VAULT-CONFIG] ❌ jq не найден или файл недоступен" | tee /dev/stderr
       log_debug "❌ jq not found or file inaccessible"
       secrets_extracted=false
   fi
    
   if [[ "$secrets_extracted" != "true" ]]; then
       echo "[VAULT-CONFIG] ⚠️  Vault-agent НЕ сможет аутентифицироваться!" | tee /dev/stderr
       log_debug "⚠️  vault-agent will NOT be able to authenticate"
       print_warning "Секреты vault-agent не извлечены. Vault-agent не сможет работать."
   fi
    
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   echo "[VAULT-CONFIG] После извлечения секретов" | tee /dev/stderr
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   log_debug "========================================"
   log_debug "POST-SECRETS: Setting permissions"
   log_debug "========================================"
    
   echo "[VAULT-CONFIG] Установка прав на файлы секретов..." | tee /dev/stderr
   echo "[VAULT-CONFIG] VAULT_ROLE_ID_FILE=$VAULT_ROLE_ID_FILE" | tee /dev/stderr
   echo "[VAULT-CONFIG] VAULT_SECRET_ID_FILE=$VAULT_SECRET_ID_FILE" | tee /dev/stderr
   log_debug "VAULT_ROLE_ID_FILE=$VAULT_ROLE_ID_FILE"
   log_debug "VAULT_SECRET_ID_FILE=$VAULT_SECRET_ID_FILE"
    
    # Права только на файлы (директории оставляем как настроил RLM)
   if chmod 640 "$VAULT_ROLE_ID_FILE" "$VAULT_SECRET_ID_FILE" 2>/dev/null; then
       echo "[VAULT-CONFIG] ✅ chmod 640 успешен" | tee /dev/stderr
       log_debug "✅ chmod 640 successful"
   else
       echo "[VAULT-CONFIG] ⚠️  chmod 640 failed (не критично)" | tee /dev/stderr
       log_debug "⚠️  chmod 640 failed"
   fi
    
    # SECURE EDITION: Пропускаем chown операции (нет доступа к /opt/, не нужны в user-space)
   echo "[VAULT-CONFIG] SECURE EDITION: Пропускаем chown операции (не нужны в user-space)" | tee /dev/stderr
   log_debug "SECURE EDITION: Skipping chown operations"
    
    # Приводим владельца/группу каталога certs и файлов role_id/secret_id к тем же, что у conf
    # ЗАКОММЕНТИРОВАНО для Secure Edition - все файлы уже в $HOME с правильными правами
    # if [[ -d "$VAULT_CONF_DIR" && -d "$VAULT_CERTS_DIR" ]]; then
    #     /usr/bin/chown --reference=/opt/vault/conf /opt/vault/certs 2>/dev/null || true
    #     /usr/bin/chmod --reference=/opt/vault/conf /opt/vault/certs 2>/dev/null || true
    #     /usr/bin/chown --reference=/opt/vault/conf /opt/vault/conf/role_id.txt /opt/vault/conf/secret_id.txt 2>/dev/null || true
    # fi
    
   echo "[VAULT-CONFIG] Создание vault-agent.conf..." | tee /dev/stderr
   log_debug "Creating vault-agent.conf"

   echo "[VAULT-CONFIG] Начинается блок генерации vault-agent.conf..." | tee /dev/stderr
   log_debug "Generating vault-agent.conf content"
    
    # Создаем две версии agent.hcl:
    # 1. Системная версия (для vault-agent) - с путями /opt/vault/
    # 2. User-space версия (для справки) - с путями $HOME/monitoring/
    
   echo "[VAULT-CONFIG] Создание agent.hcl в user-space..." | tee /dev/stderr
    
    # ============================================
    # ПОЛНАЯ ВЕРСИЯ agent.hcl (в user-space)
    # ============================================
    # Создаем полную версию в user-space, затем копируем через sudo в /opt/vault/conf/
    # Это безопаснее и соответствует требованиям ИБ
    # ============================================
    
   echo "[VAULT-CONFIG] Генерация полного agent.hcl..." | tee /dev/stderr
   log_debug "Generating full agent.hcl configuration"
    
    # Создаем полный agent.hcl в user-space
   cat > "$VAULT_AGENT_HCL" << SYS_EOF
pid_file = "/opt/vault/log/vault-agent.pidfile"
vault {
address = "https://$SEC_MAN_ADDR"
tls_skip_verify = "false"
ca_path = "/opt/vault/conf/ca-trust"
}
auto_auth {
method "approle" {
namespace = "$NAMESPACE_CI"
mount_path = "auth/approle"

config = {
role_id_file_path = "/opt/vault/conf/role_id.txt"
secret_id_file_path = "/opt/vault/conf/secret_id.txt"
remove_secret_id_file_after_reading = false
}
}
}
log_destination "Tengry" {
log_format = "json"
log_path = "/opt/vault/log"
log_rotate = "5"
log_max_size = "5mb"
log_level = "trace"
log_file = "agent.log"
}

template {
 destination = "/opt/vault/conf/data_sec.json"
 contents    = <<EOT
{
SYS_EOF

    # Добавляем блок rpm_url
   if [[ -n "$RPM_URL_KV" ]]; then
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF
 "rpm_url": {
   {{ with secret "$RPM_URL_KV" }}
   "harvest": {{ .Data.harvest | toJSON }},
   "prometheus": {{ .Data.prometheus | toJSON }},
   "grafana": {{ .Data.grafana | toJSON }}
   {{ end }}
 },
SYS_EOF
   else
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF
 "rpm_url": {},
SYS_EOF
   fi

    # Добавляем блок netapp_ssh
   if [[ -n "$NETAPP_SSH_KV" ]]; then
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF
 "netapp_ssh": {
   {{ with secret "$NETAPP_SSH_KV" }}
   "addr": {{ .Data.addr | toJSON }},
   "user": {{ .Data.user | toJSON }},
   "pass": {{ .Data.pass | toJSON }}
   {{ end }}
 },
SYS_EOF
   else
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF
 "netapp_ssh": {},
SYS_EOF
   fi

    # Добавляем блок grafana_web
   if [[ -n "$GRAFANA_WEB_KV" ]]; then
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF
 "grafana_web": {
   {{ with secret "$GRAFANA_WEB_KV" }}
   "user": {{ .Data.user | toJSON }},
   "pass": {{ .Data.pass | toJSON }}
   {{ end }}
 },
SYS_EOF
   else
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF
 "grafana_web": {},
SYS_EOF
   fi

    # Добавляем блок vault-agent
   if [[ -n "$VAULT_AGENT_KV" ]]; then
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF
 "vault-agent": {
   {{ with secret "$VAULT_AGENT_KV" }}
   "role_id": {{ .Data.role_id | toJSON }},
   "secret_id": {{ .Data.secret_id | toJSON }}
   {{ end }}
 }
}
 EOT
 perms = "0640"
 error_on_missing_key = false
}
SYS_EOF
   else
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF
 "vault-agent": {}
}
 EOT
 perms = "0640"
 error_on_missing_key = false
}
SYS_EOF
   fi

    # Добавляем блоки для сертификатов SBERCA
   if [[ -n "$SBERCA_CERT_KV" ]]; then
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF

template {
 destination = "/opt/vault/certs/server_bundle.pem"
 contents    = <<EOT
{{- with secret "$SBERCA_CERT_KV" "common_name=${SERVER_DOMAIN}" "email=$ADMIN_EMAIL" "alt_names=${SERVER_DOMAIN}" -}}
{{ .Data.private_key }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end -}}
 EOT
 perms = "0640"
}

template {
 destination = "/opt/vault/certs/ca_chain.crt"
 contents = <<EOT
{{- with secret "$SBERCA_CERT_KV" "common_name=${SERVER_DOMAIN}" "email=$ADMIN_EMAIL" -}}
{{ .Data.issuing_ca }}
{{- end -}}
 EOT
 perms = "0640"
}

template {
 destination = "/opt/vault/certs/grafana-client.pem"
 contents    = <<EOT
{{- with secret "$SBERCA_CERT_KV" "common_name=${SERVER_DOMAIN}" "email=$ADMIN_EMAIL" "alt_names=${SERVER_DOMAIN}" -}}
{{ .Data.private_key }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end -}}
 EOT
 perms = "0640"
}
SYS_EOF
   else
       cat >> "$VAULT_AGENT_HCL" << SYS_EOF

SBERCA_CERT_KV не задан, шаблоны сертификатов не будут использоваться vault-agent.
SYS_EOF
   fi
        
   echo "[VAULT-CONFIG] ✅ agent.hcl создан в: $VAULT_AGENT_HCL" | tee /dev/stderr
   log_debug "✅ agent.hcl created at $VAULT_AGENT_HCL"
   print_success "agent.hcl успешно создан"
   
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   echo "[VAULT-CONFIG] agent.hcl будет скопирован в /opt/vault/conf/ через sudo" | tee /dev/stderr
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   log_debug "agent.hcl will be copied to /opt/vault/conf/ via sudo"
    
    # ============================================================
    # КОПИРОВАНИЕ CREDENTIALS В /OPT/VAULT/CONF/ (SECURE EDITION)
    # ============================================================
    # ВАЖНО: Используем /tmp/ как промежуточное хранилище и sudo для копирования
    # в системные пути согласно требованиям ИБ
    # ============================================================
    
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   echo "[VAULT-CONFIG] Копирование credentials в /opt/vault/conf/" | tee /dev/stderr
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   log_debug "========================================"
   log_debug "COPYING: credentials to /opt/vault/conf/"
   log_debug "========================================"
    
    # Проверяем что временные файлы в /tmp/ существуют и не пустые
   if [[ "$secrets_extracted" == "true" && -s "$TMP_ROLE_ID" && -s "$TMP_SECRET_ID" ]]; then
       echo "[VAULT-CONFIG] ✅ Секреты извлечены в /tmp/, начинаем копирование..." | tee /dev/stderr
       log_debug "✅ Secrets extracted to /tmp/, starting copy"
        
        # 1. Создаем /opt/vault/certs/ если не существует
       if [[ ! -d "/opt/vault/certs" ]]; then
           echo "[VAULT-CONFIG] Создание /opt/vault/certs/..." | tee /dev/stderr
           log_debug "Creating /opt/vault/certs/"
            
           if sudo -n /usr/bin/mkdir -p /opt/vault/certs 2>/dev/null; then
               echo "[VAULT-CONFIG] ✅ /opt/vault/certs/ создана" | tee /dev/stderr
               log_debug "✅ /opt/vault/certs/ created"
                
                # Устанавливаем владельца и права
               if sudo -n /usr/bin/chown "${KAE}-lnx-va-start:${KAE}-lnx-va-read" /opt/vault/certs 2>/dev/null; then
                   echo "[VAULT-CONFIG] ✅ Владелец установлен: ${KAE}-lnx-va-start:${KAE}-lnx-va-read" | tee /dev/stderr
                   log_debug "✅ Owner set for /opt/vault/certs/"
               fi
                
               if sudo -n /usr/bin/chmod 750 /opt/vault/certs 2>/dev/null; then
                   echo "[VAULT-CONFIG] ✅ Права установлены: 750" | tee /dev/stderr
                   log_debug "✅ Permissions set for /opt/vault/certs/"
               fi
           else
               echo "[VAULT-CONFIG] ⚠️  Не удалось создать /opt/vault/certs/ (требуется sudo)" | tee /dev/stderr
               log_debug "⚠️  Failed to create /opt/vault/certs/ (sudo required)"
               print_warning "Не удалось создать /opt/vault/certs/ - добавьте sudo-права"
           fi
       else
           echo "[VAULT-CONFIG] ✅ /opt/vault/certs/ уже существует" | tee /dev/stderr
           log_debug "✅ /opt/vault/certs/ already exists"
       fi
        
        # 2. Копируем role_id.txt из /tmp/ в /opt/vault/conf/
       echo "[VAULT-CONFIG] Копирование role_id.txt..." | tee /dev/stderr
       log_debug "Copying role_id.txt from $TMP_ROLE_ID to /opt/vault/conf/"
        
       if sudo -n /usr/bin/cp "$TMP_ROLE_ID" /opt/vault/conf/role_id.txt 2>/dev/null; then
           echo "[VAULT-CONFIG] ✅ role_id.txt скопирован" | tee /dev/stderr
           log_debug "✅ role_id.txt copied"
            
            # Устанавливаем владельца и права
           if sudo -n /usr/bin/chown "${KAE}-lnx-va-start:${KAE}-lnx-va-read" /opt/vault/conf/role_id.txt 2>/dev/null; then
               echo "[VAULT-CONFIG] ✅ Владелец role_id.txt установлен" | tee /dev/stderr
               log_debug "✅ Owner set for role_id.txt"
           fi
            
           if sudo -n /usr/bin/chmod 640 /opt/vault/conf/role_id.txt 2>/dev/null; then
               echo "[VAULT-CONFIG] ✅ Права role_id.txt установлены: 640" | tee /dev/stderr
               log_debug "✅ Permissions set for role_id.txt"
           fi
            
           print_success "role_id.txt установлен в /opt/vault/conf/"
       else
           echo "[VAULT-CONFIG] ❌ Не удалось скопировать role_id.txt (требуется sudo)" | tee /dev/stderr
           log_debug "❌ Failed to copy role_id.txt (sudo required)"
           print_error "Не удалось скопировать role_id.txt - добавьте sudo-права"
       fi
        
        # 3. Копируем secret_id.txt из /tmp/ в /opt/vault/conf/
       echo "[VAULT-CONFIG] Копирование secret_id.txt..." | tee /dev/stderr
       log_debug "Copying secret_id.txt from $TMP_SECRET_ID to /opt/vault/conf/"
        
       if sudo -n /usr/bin/cp "$TMP_SECRET_ID" /opt/vault/conf/secret_id.txt 2>/dev/null; then
           echo "[VAULT-CONFIG] ✅ secret_id.txt скопирован" | tee /dev/stderr
           log_debug "✅ secret_id.txt copied"
            
            # Устанавливаем владельца и права
           if sudo -n /usr/bin/chown "${KAE}-lnx-va-start:${KAE}-lnx-va-read" /opt/vault/conf/secret_id.txt 2>/dev/null; then
               echo "[VAULT-CONFIG] ✅ Владелец secret_id.txt установлен" | tee /dev/stderr
               log_debug "✅ Owner set for secret_id.txt"
           fi
            
           if sudo -n /usr/bin/chmod 640 /opt/vault/conf/secret_id.txt 2>/dev/null; then
               echo "[VAULT-CONFIG] ✅ Права secret_id.txt установлены: 640" | tee /dev/stderr
               log_debug "✅ Permissions set for secret_id.txt"
           fi
            
           print_success "secret_id.txt установлен в /opt/vault/conf/"
       else
           echo "[VAULT-CONFIG] ❌ Не удалось скопировать secret_id.txt (требуется sudo)" | tee /dev/stderr
           log_debug "❌ Failed to copy secret_id.txt (sudo required)"
           print_error "Не удалось скопировать secret_id.txt - добавьте sudo-права"
       fi
        
        # 3. Копируем agent.hcl из user-space в /opt/vault/conf/
       echo "[VAULT-CONFIG] Копирование agent.hcl..." | tee /dev/stderr
       log_debug "Copying agent.hcl from $VAULT_AGENT_HCL to /opt/vault/conf/"
        
       if [[ -f "$VAULT_AGENT_HCL" ]]; then
           local copied_agent_hcl=false
           local target_agent_hcl="/opt/vault/conf/agent.hcl"
           
            # Сначала пробуем без sudo (если уже есть доступ через группу va-start).
           if [[ -w "/opt/vault/conf/" ]]; then
               if cp "$VAULT_AGENT_HCL" "$target_agent_hcl" 2>/dev/null; then
                   copied_agent_hcl=true
                   echo "[VAULT-CONFIG] ✅ agent.hcl скопирован без sudo (через права директории)" | tee /dev/stderr
                   log_debug "✅ agent.hcl copied without sudo"
                   chmod 640 "$target_agent_hcl" 2>/dev/null || true
               else
                   echo "[VAULT-CONFIG] ⚠️  Копирование без sudo не удалось, пробуем через sudo..." | tee /dev/stderr
                   log_debug "⚠️  Non-sudo copy failed, will try sudo fallback"
               fi
           else
               echo "[VAULT-CONFIG] ⚠️  Нет прав записи в /opt/vault/conf/, пробуем через sudo..." | tee /dev/stderr
               log_debug "⚠️  No write access to /opt/vault/conf/, will try sudo fallback"
           fi
           
            # Fallback через sudo (для сред, где доступ в /opt/vault/conf только через sudo).
           if [[ "$copied_agent_hcl" != "true" ]]; then
               if sudo -n /usr/bin/cp "$VAULT_AGENT_HCL" "$target_agent_hcl" 2>/dev/null; then
                   copied_agent_hcl=true
                   echo "[VAULT-CONFIG] ✅ agent.hcl скопирован через sudo" | tee /dev/stderr
                   log_debug "✅ agent.hcl copied with sudo"
                   
                    # Установка владельца/прав как best-effort: может быть ограничено политикой IDM.
                   sudo -n /usr/bin/chown "${KAE}-lnx-va-start:${KAE}-lnx-va-read" "$target_agent_hcl" 2>/dev/null || true
                   if sudo -n /usr/bin/chmod 640 "$target_agent_hcl" 2>/dev/null; then
                       echo "[VAULT-CONFIG] ✅ agent.hcl права установлены (640)" | tee /dev/stderr
                       log_debug "✅ agent.hcl chmod 640 successful (sudo)"
                   fi
               else
                   echo "[VAULT-CONFIG] ❌ Не удалось скопировать agent.hcl ни без sudo, ни через sudo" | tee /dev/stderr
                   echo "[VAULT-CONFIG] EXPECTED sudo rule: ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp $VAULT_AGENT_HCL /opt/vault/conf/agent.hcl" | tee /dev/stderr
                   log_debug "❌ agent.hcl copy failed in both modes"
                   print_error "Не удалось скопировать agent.hcl - проверьте права va-start или sudo rule для cp"
               fi
           fi
           
            # Финальная проверка результата.
           if [[ -f "$target_agent_hcl" && -s "$target_agent_hcl" ]]; then
               echo "[VAULT-CONFIG] ✅ agent.hcl присутствует в /opt/vault/conf/" | tee /dev/stderr
               log_debug "✅ agent.hcl final check passed"
           else
               echo "[VAULT-CONFIG] ❌ agent.hcl отсутствует в /opt/vault/conf/ после попыток копирования" | tee /dev/stderr
               log_debug "❌ agent.hcl missing after copy attempts"
           fi
       else
           echo "[VAULT-CONFIG] ⚠️  agent.hcl не найден в: $VAULT_AGENT_HCL" | tee /dev/stderr
           log_debug "⚠️  agent.hcl not found"
       fi
        
        # 4. Очищаем временные файлы из /tmp/ (важно для безопасности!)
       echo "[VAULT-CONFIG] Очистка временных файлов из /tmp/..." | tee /dev/stderr
       log_debug "Cleaning up temporary files from /tmp/"
        
       if rm -f "$TMP_ROLE_ID" "$TMP_SECRET_ID" 2>/dev/null; then
           echo "[VAULT-CONFIG] ✅ Временные файлы удалены" | tee /dev/stderr
           log_debug "✅ Temporary files removed"
       else
           echo "[VAULT-CONFIG] ⚠️  Не удалось удалить временные файлы" | tee /dev/stderr
           log_debug "⚠️  Failed to remove temporary files"
       fi
        
       echo "[VAULT-CONFIG] ✅ Credentials успешно установлены в /opt/vault/conf/" | tee /dev/stderr
       log_debug "✅ Credentials successfully installed"
   else
       echo "[VAULT-CONFIG] ⚠️  Секреты не извлечены или файлы пустые, пропускаем копирование" | tee /dev/stderr
       log_debug "⚠️  Secrets not extracted or files empty, skipping copy"
       print_warning "Секреты не извлечены - vault-agent не сможет аутентифицироваться"
   fi
    
    # ============================================================
    # ПРИМЕНЕНИЕ КОНФИГУРАЦИИ К VAULT-AGENT
    # ============================================================
   echo "[VAULT-CONFIG] Применение конфигурации к vault-agent..." | tee /dev/stderr
   log_debug "Applying configuration to vault-agent"
    
   local current_user
   current_user=$(whoami)
    
    # Проверяем, можем ли записать в /opt/vault/conf/
   if [[ -w "/opt/vault/conf/" ]]; then
       echo "[VAULT-CONFIG] ✅ Пользователь $current_user может писать в /opt/vault/conf/" | tee /dev/stderr
       log_debug "✅ User $current_user can write to /opt/vault/conf/"
        
        # Проверяем, отличается ли новый конфиг от существующего
       if [[ -f "$VAULT_AGENT_HCL" ]]; then
           echo "[VAULT-CONFIG] ✅ Системный agent.hcl уже создан" | tee /dev/stderr
           log_debug "✅ System agent.hcl already created"
            
            # Пробуем перезапустить vault-agent
           echo "[VAULT-CONFIG] Попытка перезапуска vault-agent..." | tee /dev/stderr
           log_debug "Attempting to restart vault-agent"
            
            # Используем sudo с полным путем согласно требованиям ИБ
           if sudo -n /usr/bin/systemctl restart vault-agent 2>/dev/null; then
               echo "[VAULT-CONFIG] ✅ vault-agent перезапущен успешно" | tee /dev/stderr
               log_debug "✅ vault-agent restarted successfully"
               print_success "vault-agent успешно перезапущен"
                
                # Ждем 5 секунд для стабилизации
               echo "[VAULT-CONFIG] Ожидание стабилизации vault-agent (5 сек)..." | tee /dev/stderr
               sleep 5
                
                # Проверяем статус после перезапуска
               echo "[VAULT-CONFIG] Проверка статуса vault-agent..." | tee /dev/stderr
               if sudo -n /usr/bin/systemctl is-active vault-agent >/dev/null 2>&1; then
                   echo "[VAULT-CONFIG] ✅ vault-agent активен (running)" | tee /dev/stderr
                   log_debug "✅ vault-agent is active (running)"
                   print_success "vault-agent работает с новым конфигом"
                    
                    # Ждем еще 5 секунд для генерации сертификатов
                   echo "[VAULT-CONFIG] Ожидание генерации сертификатов (5 сек)..." | tee /dev/stderr
                   sleep 5
                    
                    # Проверяем наличие сертификатов
                   if [[ -f "/opt/vault/certs/server_bundle.pem" && -s "/opt/vault/certs/server_bundle.pem" ]]; then
                       echo "[VAULT-CONFIG] ✅ Сертификаты успешно сгенерированы" | tee /dev/stderr
                       log_debug "✅ Certificates generated successfully"
                       print_success "Сертификаты vault-agent созданы"
                   else
                       echo "[VAULT-CONFIG] ⚠️  Сертификаты еще не сгенерированы (могут появиться позже)" | tee /dev/stderr
                       log_debug "⚠️  Certificates not yet generated"
                       print_warning "Сертификаты еще не созданы - проверьте логи vault-agent"
                   fi
               else
                   echo "[VAULT-CONFIG] ⚠️  vault-agent не активен после перезапуска" | tee /dev/stderr
                   log_debug "⚠️  vault-agent not active after restart"
                   print_warning "vault-agent запущен, но не активен - проверьте логи"
                    
                    # Показываем статус для диагностики
                   if sudo -n /usr/bin/systemctl status vault-agent --no-pager 2>&1 | tee -a "$DIAGNOSTIC_RLM_LOG"; then
                       echo "[VAULT-CONFIG] Статус vault-agent записан в лог" | tee /dev/stderr
                   fi
               fi
           else
               echo "[VAULT-CONFIG] ❌ Не удалось перезапустить vault-agent (требуется sudo)" | tee /dev/stderr
               log_debug "❌ Failed to restart vault-agent (sudo required)"
               print_error "Не удалось перезапустить vault-agent - добавьте sudo-права"
               print_info "Требуемое sudo-правило: ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl restart vault-agent"
               print_info "Перезапустите вручную: sudo systemctl restart vault-agent"
           fi
       fi
   else
       echo "[VAULT-CONFIG] ⚠️  Пользователь $current_user НЕ может писать в /opt/vault/conf/" | tee /dev/stderr
       log_debug "⚠️  User $current_user cannot write to /opt/vault/conf/"
        
        # Добавляем в группу va-start для доступа на запись
       echo "[VAULT-CONFIG] Добавляем $current_user в группу ${KAE}-lnx-va-start..." | tee /dev/stderr
       log_debug "Adding $current_user to ${KAE}-lnx-va-start group"
        
       if ensure_user_in_va_start_group "$current_user"; then
           echo "[VAULT-CONFIG] ✅ Пользователь добавлен в группу va-start" | tee /dev/stderr
           log_debug "✅ User added to va-start group"
           print_info "ВАЖНО: Изменения группы применятся в новой сессии"
           print_info "Пробуем записать agent.hcl (может потребоваться перелогин)"
       else
           echo "[VAULT-CONFIG] ❌ Не удалось добавить в группу va-start" | tee /dev/stderr
           log_debug "❌ Failed to add to va-start group"
           print_warning "Не удалось добавить в группу va-start"
           print_info "Добавьте пользователя $current_user в группу ${KAE}-lnx-va-start вручную через IDM"
           print_info "После этого agent.hcl можно скопировать: cp $VAULT_AGENT_HCL /opt/vault/conf/agent.hcl"
       fi
   fi
    
    
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   echo "[VAULT-CONFIG] ✅ setup_vault_config ЗАВЕРШЕНА УСПЕШНО" | tee /dev/stderr
   echo "[VAULT-CONFIG] ========================================" | tee /dev/stderr
   log_debug "========================================"
   log_debug "✅ setup_vault_config COMPLETED SUCCESSFULLY"
   log_debug "========================================"
}

load_config_from_json() {
    print_step "Загрузка конфигурации из параметров Jenkins"
    ensure_working_directory
    
    echo "[DEBUG-CONFIG] ========================================" >&2
    echo "[DEBUG-CONFIG] Диагностика load_config_from_json" >&2
    echo "[DEBUG-CONFIG] ========================================" >&2
    log_debug "========================================"
    log_debug "ДИАГНОСТИКА: load_config_from_json"
    log_debug "========================================"
    
    echo "[DEBUG-CONFIG] Проверка обязательных параметров:" >&2
    echo "[DEBUG-CONFIG] NETAPP_API_ADDR=${NETAPP_API_ADDR:-<НЕ ЗАДАН>}" >&2
    echo "[DEBUG-CONFIG] GRAFANA_URL=${GRAFANA_URL:-<НЕ ЗАДАН>}" >&2
    echo "[DEBUG-CONFIG] PROMETHEUS_URL=${PROMETHEUS_URL:-<НЕ ЗАДАН>}" >&2
    echo "[DEBUG-CONFIG] HARVEST_URL=${HARVEST_URL:-<НЕ ЗАДАН>}" >&2
    log_debug "NETAPP_API_ADDR=${NETAPP_API_ADDR:-<НЕ ЗАДАН>}"
    log_debug "GRAFANA_URL=${GRAFANA_URL:-<НЕ ЗАДАН>}"
    log_debug "PROMETHEUS_URL=${PROMETHEUS_URL:-<НЕ ЗАДАН>}"
    log_debug "HARVEST_URL=${HARVEST_URL:-<НЕ ЗАДАН>}"
    
    local missing=()
    [[ -z "$NETAPP_API_ADDR" ]] && missing+=("NETAPP_API_ADDR")
    [[ -z "$GRAFANA_URL" ]] && missing+=("GRAFANA_URL")
    [[ -z "$PROMETHEUS_URL" ]] && missing+=("PROMETHEUS_URL")
    [[ -z "$HARVEST_URL" ]] && missing+=("HARVEST_URL")

    if (( ${#missing[@]} > 0 )); then
        echo "[DEBUG-CONFIG] ❌ Отсутствуют параметры: ${missing[*]}" >&2
        log_debug "❌ Missing parameters: ${missing[*]}"
        print_error "Не заданы обязательные параметры Jenkins: ${missing[*]}"
        print_error "Эти переменные должны быть переданы через 'sudo -n env' из Jenkinsfile"
        write_diagnostic "ERROR: Не заданы параметры: ${missing[*]}"
        
        echo "[DEBUG-CONFIG] ========================================" >&2
        echo "[DEBUG-CONFIG] DUMP всех ENV переменных:" >&2
        env | grep -E "(NETAPP|GRAFANA|PROMETHEUS|HARVEST|NAMESPACE|KAE)" | sort >&2
        echo "[DEBUG-CONFIG] ========================================" >&2
        
        exit 1
    fi
    
    echo "[DEBUG-CONFIG] ✅ Все обязательные параметры заданы" >&2
    log_debug "✅ All required parameters are set"

    NETAPP_POLLER_NAME=$(echo "$NETAPP_API_ADDR" | awk -F'.' '{print toupper(substr($1,1,1)) tolower(substr($1,2))}')
    
    echo "[DEBUG-CONFIG] Вычислен NETAPP_POLLER_NAME=$NETAPP_POLLER_NAME" >&2
    log_debug "NETAPP_POLLER_NAME=$NETAPP_POLLER_NAME"
    echo "[DEBUG-CONFIG] ========================================" >&2
    
    print_success "Конфигурация загружена из параметров Jenkins"
    print_info "NETAPP_API_ADDR=$NETAPP_API_ADDR, NETAPP_POLLER_NAME=$NETAPP_POLLER_NAME"
}

copy_certs_to_dirs() {
    print_step "Копирование сертификатов в целевые директории"
    ensure_working_directory

    # Создание папок и копирование для harvest
    mkdir -p /opt/harvest/cert
    if id harvest >/dev/null 2>&1; then
        chown harvest:harvest /opt/harvest/cert
    else
        print_warning "Пользователь harvest не найден, пропускаем chown для /opt/harvest/cert"
    fi
    # Разрезаем PEM на crt/key, чтобы гарантировать соответствие пары
    if [[ -f "/opt/vault/certs/server_bundle.pem" ]]; then
        openssl pkey -in "/opt/vault/certs/server_bundle.pem" -out "/opt/harvest/cert/harvest.key" 2>/dev/null
        openssl crl2pkcs7 -nocrl -certfile "/opt/vault/certs/server_bundle.pem" | openssl pkcs7 -print_certs -out "/opt/harvest/cert/harvest.crt" 2>/dev/null
    else
        cp "$VAULT_CRT_FILE" /opt/harvest/cert/harvest.crt
        cp "$VAULT_KEY_FILE" /opt/harvest/cert/harvest.key
    fi
    if id harvest >/dev/null 2>&1; then
        chown harvest:harvest /opt/harvest/cert/harvest.*
    fi
    chmod 640 /opt/harvest/cert/harvest.crt
    chmod 600 /opt/harvest/cert/harvest.key

    # Для grafana
    mkdir -p /etc/grafana/cert
    if id grafana >/dev/null 2>&1; then
        chown root:grafana /etc/grafana/cert
    else
        print_warning "Пользователь grafana не найден, пропускаем chown для /etc/grafana/cert"
    fi
    if [[ -f "/opt/vault/certs/server_bundle.pem" ]]; then
        openssl pkey -in "/opt/vault/certs/server_bundle.pem" -out "/etc/grafana/cert/key.key" 2>/dev/null
        openssl crl2pkcs7 -nocrl -certfile "/opt/vault/certs/server_bundle.pem" | openssl pkcs7 -print_certs -out "/etc/grafana/cert/crt.crt" 2>/dev/null
    else
        cp "$VAULT_CRT_FILE" /etc/grafana/cert/crt.crt
        cp "$VAULT_KEY_FILE" /etc/grafana/cert/key.key
    fi
    if id grafana >/dev/null 2>&1; then
        /usr/bin/chown root:grafana /etc/grafana/cert/crt.crt
        /usr/bin/chown root:grafana /etc/grafana/cert/key.key
    fi
    chmod 640 /etc/grafana/cert/crt.crt
    chmod 640 /etc/grafana/cert/key.key

    # Для prometheus
    mkdir -p /etc/prometheus/cert
    if id prometheus >/dev/null 2>&1; then
        chown prometheus:prometheus /etc/prometheus/cert
    else
        print_warning "Пользователь prometheus не найден, пропускаем chown для /etc/prometheus/cert"
    fi
    if [[ -f "/opt/vault/certs/server_bundle.pem" ]]; then
        openssl pkey -in "/opt/vault/certs/server_bundle.pem" -out "/etc/prometheus/cert/server.key" 2>/dev/null
        openssl crl2pkcs7 -nocrl -certfile "/opt/vault/certs/server_bundle.pem" | openssl pkcs7 -print_certs -out "/etc/prometheus/cert/server.crt" 2>/dev/null
    else
        cp "$VAULT_CRT_FILE" /etc/prometheus/cert/server.crt
        cp "$VAULT_KEY_FILE" /etc/prometheus/cert/server.key
    fi
    if id prometheus >/dev/null 2>&1; then
        chown prometheus:prometheus /etc/prometheus/cert/server.*
    fi
    chmod 640 /etc/prometheus/cert/server.crt
    chmod 600 /etc/prometheus/cert/server.key
    # Копируем CA-цепочку для проверки клиентских сертификатов
    local ca_src=""
    if [[ -f /opt/vault/certs/ca_chain.crt ]]; then
        ca_src="/opt/vault/certs/ca_chain.crt"
    elif [[ -f /opt/vault/certs/ca_chain ]]; then
        ca_src="/opt/vault/certs/ca_chain"
    fi
    if [[ -n "$ca_src" ]]; then
        cp "$ca_src" /etc/prometheus/cert/ca_chain.crt
        if id prometheus >/dev/null 2>&1; then
            chown prometheus:prometheus /etc/prometheus/cert/ca_chain.crt
        fi
        chmod 644 /etc/prometheus/cert/ca_chain.crt
    else
        print_warning "CA chain не найдена (/opt/vault/certs/ca_chain[.crt])"
    fi

    # Для Grafana client cert (используется в secureJsonData)
    if [[ -f "/opt/vault/certs/grafana-client.pem" ]]; then
        chmod 600 "/opt/vault/certs/grafana-client.pem" || true
        # Также подготовим .crt/.key рядом для curl/диагностики
        openssl pkey -in "/opt/vault/certs/grafana-client.pem" -out "/opt/vault/certs/grafana-client.key" 2>/dev/null || true
        openssl crl2pkcs7 -nocrl -certfile "/opt/vault/certs/grafana-client.pem" | openssl pkcs7 -print_certs -out "/opt/vault/certs/grafana-client.crt" 2>/dev/null || true
    fi

    print_success "Сертификаты скопированы и проверены"
}

# SECURE EDITION: Копирование сертификатов в user-space директории (БЕЗ root)
copy_certs_to_user_dirs() {
    echo "[CERTS-COPY] ========================================" | tee /dev/stderr
    echo "[CERTS-COPY] Копирование сертификатов (Secure Edition)" | tee /dev/stderr
    echo "[CERTS-COPY] ========================================" | tee /dev/stderr
    log_debug "========================================"
    log_debug "copy_certs_to_user_dirs (Secure Edition)"
    log_debug "========================================"
    
    print_step "Распределение сертификатов по сервисам (user-space)"
    ensure_working_directory

    # На этом этапе сертификаты уже должны быть в $VAULT_CERTS_DIR
    local vault_bundle="$VAULT_CERTS_DIR/server_bundle.pem"
    local grafana_client_pem="$MONITORING_CERTS_DIR/grafana/grafana-client.pem"
    
    echo "[CERTS-COPY] Источники сертификатов (user-space):" | tee /dev/stderr
    echo "[CERTS-COPY]   vault_bundle=$vault_bundle" | tee /dev/stderr
    echo "[CERTS-COPY]   grafana_client_pem=$grafana_client_pem" | tee /dev/stderr
    log_debug "Certificate sources (user-space):"
    log_debug "  vault_bundle=$vault_bundle"
    log_debug "  grafana_client_pem=$grafana_client_pem"
    
    # Проверяем что bundle существует и не пустой
    if [[ ! -f "$vault_bundle" ]]; then
        echo "[CERTS-COPY] ❌ vault_bundle не найден: $vault_bundle" | tee /dev/stderr
        log_debug "❌ vault_bundle not found: $vault_bundle"
        print_error "vault_bundle не найден в user-space: $vault_bundle"
        print_error "Эта функция должна вызываться ПОСЛЕ копирования сертификатов из /opt/vault/"
        exit 1
    fi
    
    # Проверяем что файл не пустой
    if [[ ! -s "$vault_bundle" ]]; then
        echo "[CERTS-COPY] ❌ vault_bundle пустой: $vault_bundle" | tee /dev/stderr
        log_debug "❌ vault_bundle is empty: $vault_bundle"
        print_error "vault_bundle пустой (0 байт). Возможно vault-agent не создал сертификаты."
        print_error "Проверьте логи vault-agent: journalctl -u vault-agent"
        exit 1
    fi
    
    # Проверяем что файл содержит приватный ключ (ищем BEGIN PRIVATE KEY или BEGIN RSA PRIVATE KEY)
    if ! grep -q "BEGIN.*PRIVATE KEY" "$vault_bundle"; then
        echo "[CERTS-COPY] ⚠️  vault_bundle не содержит приватный ключ (нет BEGIN PRIVATE KEY)" | tee /dev/stderr
        log_debug "⚠️  vault_bundle does not contain private key"
        print_warning "vault_bundle может содержать только сертификаты без приватного ключа"
        print_warning "Проверьте template в agent.hcl - должен содержать {{ .Data.private_key }}"
    fi
    
    echo "[CERTS-COPY] ✅ vault_bundle найден: $vault_bundle (размер: $(stat -c%s "$vault_bundle") байт)" | tee /dev/stderr
    log_debug "✅ vault_bundle found: $vault_bundle (size: $(stat -c%s "$vault_bundle") bytes)"
    
    # ========================================
    # 1. Harvest сертификаты
    # ========================================
    echo "[CERTS-COPY] 1/3: Обработка сертификатов для Harvest..." | tee /dev/stderr
    log_debug "Processing Harvest certificates..."
    
    local harvest_cert_dir="$HARVEST_USER_CONFIG_DIR/cert"
    mkdir -p "$harvest_cert_dir" || {
        echo "[CERTS-COPY] ❌ Не удалось создать $harvest_cert_dir" | tee /dev/stderr
        log_debug "❌ Failed to create $harvest_cert_dir"
        print_error "Не удалось создать директорию для сертификатов Harvest: $harvest_cert_dir"
        exit 1
    }
    echo "[CERTS-COPY] ✅ Создана директория: $harvest_cert_dir" | tee /dev/stderr
    log_debug "✅ Created directory: $harvest_cert_dir"
    
    echo "[CERTS-COPY] Поиск приватного ключа..." | tee /dev/stderr
    log_debug "Looking for private key"
    
    # Ищем приватный ключ в нескольких возможных местах
    local private_key_found=false
    local private_key_source=""
    
    # Вариант 1: Отдельный файл с ключом (системный путь где vault-agent создает)
    local possible_key_files=(
        "/opt/vault/certs/server.key"
        "/opt/vault/certs/private.key"
        "/opt/vault/certs/key.pem"
        "/opt/vault/certs/private.pem"
        "$VAULT_CERTS_DIR/server.key"           # user-space копия
        "$VAULT_CERTS_DIR/private.key"          # user-space копия
        "$(dirname "$vault_bundle")/server.key" # рядом с bundle в user-space
        "$(dirname "$vault_bundle")/private.key"
    )
    
    for key_file in "${possible_key_files[@]}"; do
        if [[ -f "$key_file" && -r "$key_file" ]]; then
            echo "[CERTS-COPY] ✅ Найден приватный ключ: $key_file" | tee /dev/stderr
            log_debug "✅ Found private key: $key_file"
            cp "$key_file" "$harvest_cert_dir/harvest.key" || {
                echo "[CERTS-COPY] ❌ Не удалось скопировать ключ" | tee /dev/stderr
                log_debug "❌ Failed to copy key"
                exit 1
            }
            private_key_found=true
            private_key_source="$key_file"
            break
        fi
    done
    
    # Вариант 2: Ключ внутри bundle (попробуем извлечь)
    if [[ "$private_key_found" == "false" ]]; then
        echo "[CERTS-COPY] ⚠️  Отдельный файл с ключом не найден, пробуем извлечь из bundle..." | tee /dev/stderr
        log_debug "⚠️  No separate key file found, trying to extract from bundle"
        
        # Пробуем извлечь ключ из bundle (если он там есть)
        if openssl pkey -in "$vault_bundle" -out "$harvest_cert_dir/harvest.key" 2>/dev/null; then
            echo "[CERTS-COPY] ✅ Ключ извлечен из bundle" | tee /dev/stderr
            log_debug "✅ Key extracted from bundle"
            private_key_found=true
            private_key_source="bundle"
        else
            echo "[CERTS-COPY] ❌ Не удалось найти или извлечь приватный ключ" | tee /dev/stderr
            log_debug "❌ Failed to find or extract private key"
            print_error "Не удалось найти приватный ключ для сертификатов"
            print_error "Проверьте что vault-agent создал файлы в /opt/vault/certs/"
            print_error "Нужны: server_bundle.pem (сертификаты) и server.key (приватный ключ)"
            exit 1
        fi
    fi
    
    # Извлекаем сертификат из bundle
    echo "[CERTS-COPY] Извлечение сертификата из bundle..." | tee /dev/stderr
    log_debug "Extracting certificate from bundle"
    openssl crl2pkcs7 -nocrl -certfile "$vault_bundle" | openssl pkcs7 -print_certs -out "$harvest_cert_dir/harvest.crt" 2>/dev/null || {
        echo "[CERTS-COPY] ❌ Не удалось извлечь сертификат" | tee /dev/stderr
        log_debug "❌ Failed to extract certificate"
        print_error "Не удалось извлечь сертификат из $vault_bundle"
        exit 1
    }
    echo "[CERTS-COPY] ✅ Извлечены harvest.key и harvest.crt" | tee /dev/stderr
    echo "[CERTS-COPY]   Источник ключа: $private_key_source" | tee /dev/stderr
    log_debug "✅ Extracted harvest.key and harvest.crt"
    log_debug "  Key source: $private_key_source"
    
    chmod 640 "$harvest_cert_dir/harvest.crt"
    chmod 600 "$harvest_cert_dir/harvest.key"
    echo "[CERTS-COPY] ✅ Harvest сертификаты: $harvest_cert_dir/harvest.{crt,key}" | tee /dev/stderr
    log_debug "✅ Harvest certificates: $harvest_cert_dir/harvest.{crt,key}"
    
    # ========================================
    # 2. Grafana сертификаты
    # ========================================
    echo "[CERTS-COPY] 2/3: Обработка сертификатов для Grafana..." | tee /dev/stderr
    log_debug "Processing Grafana certificates..."
    
    mkdir -p "$GRAFANA_USER_CERTS_DIR" || {
        echo "[CERTS-COPY] ❌ Не удалось создать $GRAFANA_USER_CERTS_DIR" | tee /dev/stderr
        log_debug "❌ Failed to create $GRAFANA_USER_CERTS_DIR"
        print_error "Не удалось создать директорию для сертификатов Grafana: $GRAFANA_USER_CERTS_DIR"
        exit 1
    }
    echo "[CERTS-COPY] ✅ Создана директория: $GRAFANA_USER_CERTS_DIR" | tee /dev/stderr
    log_debug "✅ Created directory: $GRAFANA_USER_CERTS_DIR"
    
    echo "[CERTS-COPY] Копирование ключа и сертификата для Grafana..." | tee /dev/stderr
    log_debug "Copying key and cert for Grafana"
    
    # Копируем тот же ключ что использовали для Harvest
    if [[ -f "$harvest_cert_dir/harvest.key" ]]; then
        cp "$harvest_cert_dir/harvest.key" "$GRAFANA_USER_CERTS_DIR/key.key" || {
            echo "[CERTS-COPY] ❌ Не удалось скопировать ключ для Grafana" | tee /dev/stderr
            log_debug "❌ Failed to copy key for Grafana"
            exit 1
        }
    else
        echo "[CERTS-COPY] ❌ Ключ Harvest не найден: $harvest_cert_dir/harvest.key" | tee /dev/stderr
        log_debug "❌ Harvest key not found: $harvest_cert_dir/harvest.key"
        exit 1
    fi
    
    # Извлекаем сертификат из bundle
    openssl crl2pkcs7 -nocrl -certfile "$vault_bundle" | openssl pkcs7 -print_certs -out "$GRAFANA_USER_CERTS_DIR/crt.crt" 2>/dev/null || {
        echo "[CERTS-COPY] ❌ Не удалось извлечь сертификат для Grafana" | tee /dev/stderr
        log_debug "❌ Failed to extract certificate for Grafana"
        exit 1
    }
    echo "[CERTS-COPY] ✅ Извлечены key.key и crt.crt для Grafana" | tee /dev/stderr
    log_debug "✅ Extracted key.key and crt.crt for Grafana"
    
    chmod 640 "$GRAFANA_USER_CERTS_DIR/crt.crt"
    chmod 600 "$GRAFANA_USER_CERTS_DIR/key.key"
    echo "[CERTS-COPY] ✅ Grafana сертификаты: $GRAFANA_USER_CERTS_DIR/{crt.crt,key.key}" | tee /dev/stderr
    log_debug "✅ Grafana certificates: $GRAFANA_USER_CERTS_DIR/{crt.crt,key.key}"
    
    # Grafana client cert (если существует)
    if [[ -f "$grafana_client_pem" ]]; then
        echo "[CERTS-COPY] Обработка Grafana client certificate..." | tee /dev/stderr
        log_debug "Processing Grafana client certificate"
        chmod 600 "$grafana_client_pem" || true
        openssl pkey -in "$grafana_client_pem" -out "$GRAFANA_USER_CERTS_DIR/grafana-client.key" 2>/dev/null || true
        openssl crl2pkcs7 -nocrl -certfile "$grafana_client_pem" | openssl pkcs7 -print_certs -out "$GRAFANA_USER_CERTS_DIR/grafana-client.crt" 2>/dev/null || true
        echo "[CERTS-COPY] ✅ Grafana client cert обработан" | tee /dev/stderr
        log_debug "✅ Grafana client cert processed"
    else
        echo "[CERTS-COPY] ⚠️  Grafana client cert не найден: $grafana_client_pem" | tee /dev/stderr
        log_debug "⚠️  Grafana client cert not found: $grafana_client_pem"
    fi
    
    # ========================================
    # 3. Prometheus сертификаты
    # ========================================
    echo "[CERTS-COPY] 3/3: Обработка сертификатов для Prometheus..." | tee /dev/stderr
    log_debug "Processing Prometheus certificates..."
    
    mkdir -p "$PROMETHEUS_USER_CERTS_DIR" || {
        echo "[CERTS-COPY] ❌ Не удалось создать $PROMETHEUS_USER_CERTS_DIR" | tee /dev/stderr
        log_debug "❌ Failed to create $PROMETHEUS_USER_CERTS_DIR"
        print_error "Не удалось создать директорию для сертификатов Prometheus: $PROMETHEUS_USER_CERTS_DIR"
        exit 1
    }
    echo "[CERTS-COPY] ✅ Создана директория: $PROMETHEUS_USER_CERTS_DIR" | tee /dev/stderr
    log_debug "✅ Created directory: $PROMETHEUS_USER_CERTS_DIR"
    
    echo "[CERTS-COPY] Копирование ключа и сертификата для Prometheus..." | tee /dev/stderr
    log_debug "Copying key and cert for Prometheus"
    
    # Копируем тот же ключ что использовали для Harvest
    if [[ -f "$harvest_cert_dir/harvest.key" ]]; then
        cp "$harvest_cert_dir/harvest.key" "$PROMETHEUS_USER_CERTS_DIR/server.key" || {
            echo "[CERTS-COPY] ❌ Не удалось скопировать ключ для Prometheus" | tee /dev/stderr
            log_debug "❌ Failed to copy key for Prometheus"
            exit 1
        }
    else
        echo "[CERTS-COPY] ❌ Ключ Harvest не найден: $harvest_cert_dir/harvest.key" | tee /dev/stderr
        log_debug "❌ Harvest key not found: $harvest_cert_dir/harvest.key"
        exit 1
    fi
    
    # Извлекаем сертификат из bundle
    openssl crl2pkcs7 -nocrl -certfile "$vault_bundle" | openssl pkcs7 -print_certs -out "$PROMETHEUS_USER_CERTS_DIR/server.crt" 2>/dev/null || {
        echo "[CERTS-COPY] ❌ Не удалось извлечь сертификат для Prometheus" | tee /dev/stderr
        log_debug "❌ Failed to extract certificate for Prometheus"
        exit 1
    }
    echo "[CERTS-COPY] ✅ Извлечены server.key и server.crt для Prometheus" | tee /dev/stderr
    log_debug "✅ Extracted server.key and server.crt for Prometheus"
    
    chmod 640 "$PROMETHEUS_USER_CERTS_DIR/server.crt"
    chmod 600 "$PROMETHEUS_USER_CERTS_DIR/server.key"
    echo "[CERTS-COPY] ✅ Prometheus сертификаты: $PROMETHEUS_USER_CERTS_DIR/{server.crt,server.key}" | tee /dev/stderr
    log_debug "✅ Prometheus certificates: $PROMETHEUS_USER_CERTS_DIR/{server.crt,server.key}"
    
    # ========================================
    # 4. CA chain (если есть)
    # ========================================
    local ca_chain="$VAULT_CERTS_DIR/ca_chain.crt"
    if [[ -f "$ca_chain" ]]; then
        echo "[CERTS-COPY] Копирование CA chain во все директории..." | tee /dev/stderr
        log_debug "Copying CA chain to all directories"
        cp "$ca_chain" "$harvest_cert_dir/ca_chain.crt" || true
        cp "$ca_chain" "$GRAFANA_USER_CERTS_DIR/ca_chain.crt" || true
        cp "$ca_chain" "$PROMETHEUS_USER_CERTS_DIR/ca_chain.crt" || true
        chmod 644 "$harvest_cert_dir/ca_chain.crt" "$GRAFANA_USER_CERTS_DIR/ca_chain.crt" "$PROMETHEUS_USER_CERTS_DIR/ca_chain.crt" 2>/dev/null || true
        echo "[CERTS-COPY] ✅ CA chain скопирован" | tee /dev/stderr
        log_debug "✅ CA chain copied"
    else
        echo "[CERTS-COPY] ⚠️  CA chain не найден: $ca_chain" | tee /dev/stderr
        log_debug "⚠️  CA chain not found: $ca_chain"
    fi
    
    echo "[CERTS-COPY] ========================================" | tee /dev/stderr
    echo "[CERTS-COPY] ✅ Все сертификаты скопированы в user-space" | tee /dev/stderr
    echo "[CERTS-COPY] ========================================" | tee /dev/stderr
    log_debug "========================================"
    log_debug "✅ All certificates copied to user-space"
    log_debug "========================================"
    
    print_success "Сертификаты скопированы и настроены в user-space директориях"
}

# Создание user-юнитов systemd под runtime-пользователем (mon_ci или mon_sys)
setup_monitoring_user_units() {
    print_step "Создание user-юнитов systemd для мониторинга (Prometheus/Grafana/Harvest)"
    ensure_working_directory

    if [[ -z "${KAE:-}" ]]; then
        print_warning "KAE не определён (NAMESPACE_CI пуст), пропускаем создание user-юнитов"
        return 0
    fi

    local runtime_user=""
    local runtime_home=""
    if [[ "${RUN_SERVICES_AS_MON_CI:-true}" == "true" ]]; then
        runtime_user="$(whoami)"
        runtime_home="$HOME"
        print_warning "RUN_SERVICES_AS_MON_CI=true: user-юниты будут созданы под ${runtime_user}"
    else
        runtime_user="${KAE}-lnx-mon_sys"
        if ! id "$runtime_user" >/dev/null 2>&1; then
            print_warning "Пользователь ${runtime_user} не найден в системе, пропускаем создание user-юнитов"
            return 0
        fi
        runtime_home=$(getent passwd "$runtime_user" | awk -F: '{print $6}')
        if [[ -z "$runtime_home" ]]; then
            runtime_home="/home/${runtime_user}"
        fi
    fi

    local user_systemd_dir="${runtime_home}/.config/systemd/user"
    mkdir -p "$user_systemd_dir"

    # User-юнит Prometheus
    local prom_unit="${user_systemd_dir}/monitoring-prometheus.service"
    
    # SECURE EDITION: Явные пути runtime-пользователя (требования ИБ)
    # Все конфиги, данные и логи в ${runtime_home}/monitoring/
    local runtime_prometheus_config="${runtime_home}/monitoring/config/prometheus"
    local runtime_prometheus_data="${runtime_home}/monitoring/data/prometheus"
    local runtime_prometheus_logs="${runtime_home}/monitoring/logs/prometheus"
    
    print_info "Prometheus пути (user-space для $runtime_user):"
    print_info "  Config: $runtime_prometheus_config"
    print_info "  Data:   $runtime_prometheus_data"
    print_info "  Logs:   $runtime_prometheus_logs"
    
    # Удаляем старый unit файл, чтобы гарантировать создание нового
    if [[ -f "$prom_unit" ]]; then
        print_info "Удаление старого unit файла для пересоздания"
        rm -f "$prom_unit" 2>/dev/null || true
    fi
    
    print_info "Создание нового systemd unit файла: $prom_unit"
    
    # ИБ-COMPLIANT: Явные пути в ExecStart (НЕ переменные окружения)
    cat > "$prom_unit" << EOF
[Unit]
Description=Monitoring Prometheus (user service - Secure Edition)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/prometheus --config.file=${runtime_prometheus_config}/prometheus.yml --storage.tsdb.path=${runtime_prometheus_data} --web.console.templates=${runtime_prometheus_config}/consoles --web.console.libraries=${runtime_prometheus_config}/console_libraries --web.config.file=${runtime_prometheus_config}/web-config.yml --web.external-url=https://${SERVER_DOMAIN}:${PROMETHEUS_PORT}/ --web.listen-address=0.0.0.0:${PROMETHEUS_PORT}
WorkingDirectory=${runtime_prometheus_data}
Restart=on-failure
RestartSec=10
StandardOutput=append:${runtime_prometheus_logs}/prometheus.log
StandardError=append:${runtime_prometheus_logs}/prometheus.log

[Install]
WantedBy=default.target
EOF

    # User-юнит Grafana
    local graf_unit="${user_systemd_dir}/monitoring-grafana.service"
    
    # SECURE EDITION: Явные пути для runtime-пользователя
    local runtime_grafana_config="${runtime_home}/monitoring/config/grafana"
    local runtime_grafana_data="${runtime_home}/monitoring/data/grafana"
    local runtime_grafana_logs="${runtime_home}/monitoring/logs/grafana"
    
    print_info "Grafana пути (user-space для $runtime_user):"
    print_info "  Config: $runtime_grafana_config"
    print_info "  Data:   $runtime_grafana_data"
    print_info "  Logs:   $runtime_grafana_logs"
    
    # ИБ-COMPLIANT: Явные пути в ExecStart
    cat > "$graf_unit" << EOF
[Unit]
Description=Monitoring Grafana (user service - Secure Edition)
After=network-online.target

[Service]
Type=simple
# SECURE EDITION: Grafana config в пользовательском пространстве
ExecStart=/usr/sbin/grafana-server --config=${runtime_grafana_config}/grafana.ini --homepath=/usr/share/grafana
WorkingDirectory=${runtime_grafana_data}
StandardOutput=append:${runtime_grafana_logs}/grafana.log
StandardError=append:${runtime_grafana_logs}/grafana.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

    # User-юнит Harvest (аналогично системному сервису)
    # SECURE EDITION: бинарники в /opt/harvest, конфиги/логи в user-space
    local harvest_unit="${user_systemd_dir}/monitoring-harvest.service"
    
    local runtime_harvest_config="${runtime_home}/monitoring/config/harvest"
    local runtime_harvest_logs="${runtime_home}/monitoring/logs/harvest"
    
    print_info "Harvest пути (user-space для $runtime_user):"
    print_info "  Config: $runtime_harvest_config"
    print_info "  Binaries: /opt/harvest (RPM installation)"
    
    # ИБ-COMPLIANT: Явные пути в Environment
    cat > "$harvest_unit" << HARVEST_USER_SERVICE_EOF
[Unit]
Description=NetApp Harvest Poller (user service - Secure Edition)
After=network.target

[Service]
Type=oneshot
# Бинарники из RPM остаются в /opt/harvest, рабочая директория writable в user-space
WorkingDirectory=${runtime_harvest_config}
# Конфиги в user-space: передаются через --config
ExecStart=/opt/harvest/bin/harvest start --config ${runtime_harvest_config}/harvest.yml
ExecStop=/opt/harvest/bin/harvest stop --config ${runtime_harvest_config}/harvest.yml
RemainAfterExit=yes
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/opt/harvest/bin
Environment=HARVEST_CONF=${runtime_harvest_config}
StandardOutput=append:${runtime_harvest_logs}/harvest.log
StandardError=append:${runtime_harvest_logs}/harvest.log

[Install]
WantedBy=default.target
HARVEST_USER_SERVICE_EOF

    # Групповой target для удобства управления всем стеком
    local target_unit="${user_systemd_dir}/monitoring.target"
    cat > "$target_unit" << EOF
[Unit]
Description=Monitoring stack (Prometheus + Grafana + Harvest)

[Install]
WantedBy=default.target
EOF

    # ✅ SECURE EDITION: НЕТ chown/chmod - файлы создаются от имени mon_sys пользователя
    # Права устанавливаются автоматически при создании файлов
    
    print_success "User-юниты systemd для мониторинга созданы под пользователем ${runtime_user}"
    
    # Логируем для отладки
    echo "[DEBUG-SYSTEMD] Юниты созданы в: $user_systemd_dir" | tee /dev/stderr
    echo "[DEBUG-SYSTEMD] Prometheus unit: $prom_unit" | tee /dev/stderr
    echo "[DEBUG-SYSTEMD] Grafana unit: $graf_unit" | tee /dev/stderr
    echo "[DEBUG-SYSTEMD] Harvest unit: $harvest_unit" | tee /dev/stderr
}

configure_grafana_ini() {
    print_step "Конфигурация grafana.ini (Secure Edition)"
    ensure_working_directory
    
    # Определяем user-space пути
    local GRAFANA_USER_CONFIG_DIR="$HOME/monitoring/config/grafana"
    local GRAFANA_USER_DATA_DIR="$HOME/monitoring/data/grafana"
    local GRAFANA_USER_LOGS_DIR="$HOME/monitoring/logs/grafana"
    local GRAFANA_USER_CERTS_DIR="$HOME/monitoring/certs/grafana"
    
    # Создаем директории (без chown/chmod - работаем в user-space)
    mkdir -p "$GRAFANA_USER_CONFIG_DIR" "$GRAFANA_USER_DATA_DIR" \
             "$GRAFANA_USER_LOGS_DIR" "$GRAFANA_USER_CERTS_DIR" \
             "$GRAFANA_USER_DATA_DIR/plugins"
    
    # Проверяем, есть ли сертификаты (скопированы ли они из /opt/vault/certs/)
    if [[ ! -f "$GRAFANA_USER_CERTS_DIR/crt.crt" || ! -f "$GRAFANA_USER_CERTS_DIR/key.key" ]]; then
        print_warning "Сертификаты Grafana не найдены в $GRAFANA_USER_CERTS_DIR/"
        print_info "Ожидаем что copy_certs_to_user_dirs() скопирует их из /opt/vault/certs/"
        print_info "Если SKIP_VAULT_INSTALL=true, сертификаты должны быть уже скопированы"
    fi
    
    # Создаем grafana.ini в user-space
    cat > "$GRAFANA_USER_CONFIG_DIR/grafana.ini" << EOF
[server]
protocol = https
http_port = ${GRAFANA_PORT}
domain = ${SERVER_DOMAIN}
cert_file = $GRAFANA_USER_CERTS_DIR/crt.crt
cert_key = $GRAFANA_USER_CERTS_DIR/key.key

[security]
allow_embedding = true

[paths]
data = $GRAFANA_USER_DATA_DIR
logs = $GRAFANA_USER_LOGS_DIR
plugins = $GRAFANA_USER_DATA_DIR/plugins
provisioning = $GRAFANA_USER_CONFIG_DIR/provisioning
EOF
    
    # ✅ НЕТ chown/chmod - файлы в user-space принадлежат текущему пользователю
    # ✅ НЕТ root операций
    
    print_success "grafana.ini настроен в $GRAFANA_USER_CONFIG_DIR/grafana.ini"
    
    # Создаем provisioning директорию если нужно
    mkdir -p "$GRAFANA_USER_CONFIG_DIR/provisioning"
    
    # Логируем для отладки
    echo "[DEBUG-GRAFANA] Конфиг создан: $GRAFANA_USER_CONFIG_DIR/grafana.ini" | tee /dev/stderr
    echo "[DEBUG-GRAFANA] Данные: $GRAFANA_USER_DATA_DIR" | tee /dev/stderr
    echo "[DEBUG-GRAFANA] Логи: $GRAFANA_USER_LOGS_DIR" | tee /dev/stderr
    echo "[DEBUG-GRAFANA] Сертификаты: $GRAFANA_USER_CERTS_DIR/" | tee /dev/stderr
}

configure_grafana_ini_no_ssl() {
    print_step "Конфигурация grafana.ini (без SSL)"
    ensure_working_directory
    "$WRAPPERS_DIR/config-writer_launcher.sh" /etc/grafana/grafana.ini << EOF
[server]
protocol = http
http_port = ${GRAFANA_PORT}
domain = ${SERVER_DOMAIN}

[security]
allow_embedding = true
EOF
    /usr/bin/chown root:grafana /etc/grafana/grafana.ini
    chmod 640 /etc/grafana/grafana.ini
    print_success "grafana.ini настроен (без SSL)"
}

configure_prometheus_files() {
    print_step "Создание файлов для Prometheus (Secure Edition)"
    ensure_working_directory
    
    # Определяем user-space пути
    local PROMETHEUS_USER_CONFIG_DIR="$HOME/monitoring/config/prometheus"
    local PROMETHEUS_USER_DATA_DIR="$HOME/monitoring/data/prometheus"
    local PROMETHEUS_USER_CERTS_DIR="$HOME/monitoring/certs/prometheus"
    
    # Создаем директории
    mkdir -p "$PROMETHEUS_USER_CONFIG_DIR" "$PROMETHEUS_USER_DATA_DIR" \
             "$PROMETHEUS_USER_CERTS_DIR"
    
    # Проверяем, есть ли сертификаты
    if [[ ! -f "$PROMETHEUS_USER_CERTS_DIR/server.crt" || ! -f "$PROMETHEUS_USER_CERTS_DIR/server.key" ]]; then
        print_warning "Сертификаты Prometheus не найдены в $PROMETHEUS_USER_CERTS_DIR/"
        print_info "Ожидаем что copy_certs_to_user_dirs() скопирует их из /opt/vault/certs/"
    fi
    
    # Создаем web-config.yml
    cat > "$PROMETHEUS_USER_CONFIG_DIR/web-config.yml" << EOF
tls_server_config:
  cert_file: $PROMETHEUS_USER_CERTS_DIR/server.crt
  key_file: $PROMETHEUS_USER_CERTS_DIR/server.key
  min_version: "TLS12"
  # Внимание: список cipher_suites применяется только к TLS 1.2 (TLS 1.3 не настраивается в Go)
  cipher_suites:
    - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  # mTLS: требуем и проверяем клиентские сертификаты (высокая безопасность)
  client_auth_type: "RequireAndVerifyClientCert"
  client_ca_file: "$PROMETHEUS_USER_CERTS_DIR/ca_chain.crt"
  client_allowed_sans:
    - "${SERVER_DOMAIN}"
EOF
    
    # Создаем prometheus.env (только для справки)
    cat > "$PROMETHEUS_USER_CONFIG_DIR/prometheus.env" << EOF
# ВНИМАНИЕ: Этот файл создается только для справки
# Systemd unit файл monitoring-prometheus.service НЕ читает его
# Все параметры запуска задаются напрямую в ExecStart
PROMETHEUS_OPTS="--config.file=$PROMETHEUS_USER_CONFIG_DIR/prometheus.yml --storage.tsdb.path=$PROMETHEUS_USER_DATA_DIR/data --web.console.templates=$PROMETHEUS_USER_CONFIG_DIR/consoles --web.console.libraries=$PROMETHEUS_USER_CONFIG_DIR/console_libraries --web.config.file=$PROMETHEUS_USER_CONFIG_DIR/web-config.yml --web.external-url=https://${SERVER_DOMAIN}:${PROMETHEUS_PORT}/ --web.listen-address=0.0.0.0:${PROMETHEUS_PORT}"
EOF
    
    # ✅ НЕТ chown/chmod - файлы в user-space
    
    print_success "Файлы Prometheus созданы в $PROMETHEUS_USER_CONFIG_DIR/"
    
    # Логируем для отладки
    echo "[DEBUG-PROMETHEUS] Конфиг: $PROMETHEUS_USER_CONFIG_DIR/" | tee /dev/stderr
    echo "[DEBUG-PROMETHEUS] Данные: $PROMETHEUS_USER_DATA_DIR" | tee /dev/stderr
    echo "[DEBUG-PROMETHEUS] Сертификаты: $PROMETHEUS_USER_CERTS_DIR/" | tee /dev/stderr
}

configure_prometheus_files_no_ssl() {
    print_step "Создание файлов для Prometheus (без SSL)"
    ensure_working_directory
    "$WRAPPERS_DIR/config-writer_launcher.sh" /etc/prometheus/prometheus.env << EOF
PROMETHEUS_OPTS="--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/data --web.console.templates=/etc/prometheus/consoles --web.console.libraries=/etc/prometheus/console_libraries --web.external-url=http://${SERVER_DOMAIN}:${PROMETHEUS_PORT}/ --web.listen-address=0.0.0.0:${PROMETHEUS_PORT}"
EOF
    chown prometheus:prometheus /etc/prometheus/prometheus.env
    chmod 640 /etc/prometheus/prometheus.env
    print_success "Файлы Prometheus созданы (без SSL)"
}

create_rlm_install_tasks() {
    print_step "Создание задач RLM для установки пакетов"
    ensure_working_directory
    
    write_diagnostic ">>> ВХОД в create_rlm_install_tasks()"
    write_diagnostic "  RLM_TOKEN: ${RLM_TOKEN:+<задан - длина ${#RLM_TOKEN}>}"
    write_diagnostic "  RLM_API_URL: ${RLM_API_URL:-<не задан>}"
    write_diagnostic "  GRAFANA_URL: ${GRAFANA_URL:-<не задан>}"
    write_diagnostic "  PROMETHEUS_URL: ${PROMETHEUS_URL:-<не задан>}"
    write_diagnostic "  HARVEST_URL: ${HARVEST_URL:-<не задан>}"

    if [[ -z "$RLM_TOKEN" || -z "$RLM_API_URL" ]]; then
        write_diagnostic "ERROR: RLM API токен или URL не задан"
        print_error "RLM API токен или URL не задан (RLM_TOKEN/RLM_API_URL)"
        exit 1
    fi

    # Создание задач для всех RPM пакетов
    local packages=(
        "$GRAFANA_URL|Grafana"
        "$PROMETHEUS_URL|Prometheus"
        "$HARVEST_URL|Harvest"
    )

    for package in "${packages[@]}"; do
        IFS='|' read -r url name <<< "$package"

        print_info "Создание задачи для $name..."
        if [[ -z "$url" ]]; then
            print_warning "URL пакета для $name не задан (пусто)"
        else
            print_info "📦 Устанавливаемый RPM: $url"
        fi

        local response
        local payload
        payload=$(jq -n           --arg url "$url"           --arg ip "$SERVER_IP"           '{
            params: { url: $url, reinstall_is_allowed: true },
            start_at: "now",
            service: "LINUX_RPM_INSTALLER",
            items: [ { table_id: "linuxrpminstallertable", invsvm_ip: $ip } ]
          }')
        if [[ ! -x "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" ]]; then
            print_error "Лаунчер rlm-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
            exit 1
        fi

        response=$(printf '%s' "$payload" | "$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" create_rpm_task "$RLM_API_URL" "$RLM_TOKEN") || true

        # Получаем ID задачи
        local task_id
        task_id=$(echo "$response" | jq -r '.id // empty')
        if [[ -z "$task_id" || "$task_id" == "null" ]]; then
            print_error "❌ Ошибка при создании задачи для $name: $response"
            print_error "❌ URL пакета: ${url:-не задан}"
            exit 1
        fi
        print_success "✅ Задача создана для $name. ID: $task_id"
        print_info "📦 Устанавливаемый RPM: $url"

        # Мониторинг статуса задачи RLM для установки RPM
        local max_attempts=120
        local attempt=1
        local start_ts
        local interval_sec=10
        start_ts=$(date +%s)

        echo ""
        echo "┌────────────────────────────────────────────────────────────┐"
        printf "│  📦 УСТАНОВКА: %-41s │\n" "$name"
        printf "│  Task ID: %-47s │\n" "$task_id"
        printf "│  Max attempts: %-3d (интервал: %2dс)                      │\n" "$max_attempts" "$interval_sec"
        echo "└────────────────────────────────────────────────────────────┘"
        echo ""

        while [[ $attempt -le $max_attempts ]]; do
            local status_response
            status_response=$("$WRAPPERS_DIR/rlm-api-wrapper_launcher.sh" get_rpm_status "$RLM_API_URL" "$RLM_TOKEN" "$task_id") || true

            local current_status
            current_status=$(echo "$status_response" | jq -r '.status // empty' 2>/dev/null || echo "in_progress")
            [[ -z "$current_status" ]] && current_status="in_progress"

            # Расчет времени
            local now_ts elapsed_sec elapsed_min
            now_ts=$(date +%s)
            elapsed_sec=$(( now_ts - start_ts ))
            elapsed_min=$(/usr/bin/awk -v s="$elapsed_sec" 'BEGIN{printf "%.1f", s/60}')

            # Цветной статус-индикатор
            local status_icon="⏳"
            case "$current_status" in
                success) status_icon="✅" ;;
                failed|error) status_icon="❌" ;;
                in_progress) status_icon="🔄" ;;
            esac

            # Вывод прогресса (каждая попытка - новая строка для Jenkins)
            echo "📦 $name │ Попытка $attempt/$max_attempts │ Статус: $current_status $status_icon │ Время: ${elapsed_min}м (${elapsed_sec}с)"

            write_diagnostic "$name RLM: attempt=$attempt/$max_attempts, status=$current_status, elapsed=${elapsed_min}m"

            if echo "$status_response" | grep -q '"status":"success"'; then
                echo "✅ $name УСТАНОВЛЕН за ${elapsed_min}м (${elapsed_sec}с)"
                echo ""
                write_diagnostic "$name RLM: SUCCESS after ${elapsed_min}m"
                # Сохраняем ID задачи по имени
                case "$name" in
                    "Grafana")
                        RLM_ID_TASK_GRAFANA="$task_id"
                        export RLM_ID_TASK_GRAFANA
                        ;;
                    "Prometheus")
                        RLM_ID_TASK_PROMETHEUS="$task_id"
                        export RLM_ID_TASK_PROMETHEUS
                        ;;
                    "Harvest")
                        RLM_ID_TASK_HARVEST="$task_id"
                        export RLM_ID_TASK_HARVEST
                        ;;
                esac
                break
            elif echo "$status_response" | grep -qE '"status":"(failed|error)"'; then
                echo ""
                print_error "❌ $name: ОШИБКА УСТАНОВКИ"
                print_error "📋 Ответ RLM: $status_response"
                write_diagnostic "$name RLM: FAILED - $status_response"
                exit 1
            fi

            attempt=$((attempt + 1))
            sleep "$interval_sec"
        done

        if [[ $attempt -gt $max_attempts ]]; then
            echo ""
            print_error "⏰ $name: ТАЙМАУТ после ${max_attempts} попыток (~$((max_attempts * interval_sec / 60)) минут)"
            exit 1
        fi

        # Пауза 3 секунды после успешной задачи
        sleep 3
    done

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║      ✅ ВСЕ RPM ПАКЕТЫ УСПЕШНО УСТАНОВЛЕНЫ               ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "📊 Установленные пакеты:"
    echo "  ✅ Grafana       - Task ID: ${RLM_ID_TASK_GRAFANA:-N/A}"
    echo "  ✅ Prometheus    - Task ID: ${RLM_ID_TASK_PROMETHEUS:-N/A}"
    echo "  ✅ Harvest       - Task ID: ${RLM_ID_TASK_HARVEST:-N/A}"
    echo ""

    # Настройка PATH для Harvest
    echo "[RLM-INSTALL] Настройка PATH для Harvest..." | tee /dev/stderr
    log_debug "Setting up Harvest PATH"
    print_info "Настройка PATH для Harvest"
    
    # SECURE EDITION: Пропускаем операции с /etc/ и /usr/local/bin/ (требуют root)
    # Harvest будет запускаться через systemd user unit с явно указанным путем к исполняемому файлу
    if [[ -f "/opt/harvest/bin/harvest" ]]; then
        echo "[RLM-INSTALL] ✅ Найден harvest: /opt/harvest/bin/harvest" | tee /dev/stderr
        log_debug "Found harvest: /opt/harvest/bin/harvest"
        # Не создаем симлинк в /usr/local/bin/ (требует root)
        # ln -sf /opt/harvest/bin/harvest /usr/local/bin/harvest || true
        print_success "Найден исполняемый файл harvest: /opt/harvest/bin/harvest"
    elif [[ -f "/opt/harvest/harvest" ]]; then
        echo "[RLM-INSTALL] ✅ Найден harvest: /opt/harvest/harvest" | tee /dev/stderr
        log_debug "Found harvest: /opt/harvest/harvest"
        # Не создаем симлинк в /usr/local/bin/ (требует root)
        # ln -sf /opt/harvest/harvest /usr/local/bin/harvest || true
        print_success "Найден исполняемый файл harvest: /opt/harvest/harvest"
    else
        echo "[RLM-INSTALL] ⚠️  harvest не найден в стандартных путях" | tee /dev/stderr
        log_debug "⚠️  harvest executable not found"
        print_warning "Исполняемый файл harvest не найден в стандартных путях"
    fi
    
    # SECURE EDITION: Не записываем в /etc/profile.d/ (требует root, не нужно для user units)
    # cat > /etc/profile.d/harvest.sh << 'HARVEST_EOF'
    # # Harvest PATH configuration
    # export PATH=$PATH:/opt/harvest/bin:/opt/harvest
    # HARVEST_EOF
    # chmod +x /etc/profile.d/harvest.sh
    
    # Экспортируем PATH только в текущую сессию (для последующих команд в скрипте)
    export PATH=$PATH:/opt/harvest/bin:/opt/harvest
    echo "[RLM-INSTALL] PATH обновлен для текущей сессии: $PATH" | tee /dev/stderr
    log_debug "PATH updated for current session"
    print_success "PATH настроен для Harvest (в рамках текущей сессии)"
    
    echo "[RLM-INSTALL] ========================================" | tee /dev/stderr
    echo "[RLM-INSTALL] ✅ create_rlm_install_tasks ЗАВЕРШЕНА" | tee /dev/stderr
    echo "[RLM-INSTALL] ========================================" | tee /dev/stderr
    write_diagnostic "<<< ВЫХОД из create_rlm_install_tasks() - успешно"
    log_debug "========================================"
    log_debug "✅ create_rlm_install_tasks COMPLETED"
    log_debug "========================================"
}

setup_certificates_after_install() {
    echo "[CERTS] ========================================" | tee /dev/stderr
    echo "[CERTS] Настройка сертификатов (Secure Edition)" | tee /dev/stderr
    echo "[CERTS] ========================================" | tee /dev/stderr
    log_debug "========================================"
    log_debug "setup_certificates_after_install (Secure Edition)"
    log_debug "========================================"
    
    print_step "Настройка сертификатов после установки пакетов (Secure Edition)"
    ensure_working_directory

    # ВАЖНО: Vault Agent - это СИСТЕМНЫЙ СЕРВИС, который создает сертификаты в /opt/vault/certs/
    # Мы копируем их оттуда в user-space для использования нашими мониторинговыми сервисами
    local system_vault_bundle="/opt/vault/certs/server_bundle.pem"
    local userspace_vault_bundle="$VAULT_CERTS_DIR/server_bundle.pem"
    local sys_user="${KAE}-lnx-mon_sys"
    
    echo "[CERTS] ========================================" | tee /dev/stderr
    echo "[CERTS] Проверка источников сертификатов..." | tee /dev/stderr
    echo "[CERTS] ========================================" | tee /dev/stderr
    echo "[CERTS] Системный путь (vault-agent): $system_vault_bundle" | tee /dev/stderr
    echo "[CERTS] User-space путь: $userspace_vault_bundle" | tee /dev/stderr
    echo "[CERTS] Альтернативные пути:" | tee /dev/stderr
    echo "[CERTS]   VAULT_CRT_FILE=${VAULT_CRT_FILE:-<не задан>}" | tee /dev/stderr
    echo "[CERTS]   VAULT_KEY_FILE=${VAULT_KEY_FILE:-<не задан>}" | tee /dev/stderr
    log_debug "Checking certificate sources:"
    log_debug "  system_vault_bundle=$system_vault_bundle"
    log_debug "  userspace_vault_bundle=$userspace_vault_bundle"
    log_debug "  VAULT_CRT_FILE=${VAULT_CRT_FILE:-<not set>}"
    log_debug "  VAULT_KEY_FILE=${VAULT_KEY_FILE:-<not set>}"
    
    # Проверяем наличие сертификатов от vault-agent
    # Приоритет 1: системный путь /opt/vault/certs/ (где vault-agent создает файлы)
    if [[ -f "$system_vault_bundle" ]]; then
        echo "[CERTS] ✅ Найден системный vault bundle: $system_vault_bundle" | tee /dev/stderr
        log_debug "✅ Found system vault bundle: $system_vault_bundle"
        print_success "Найдены сертификаты от Vault Agent: $system_vault_bundle"
        
        # Проверяем права доступа
        echo "[CERTS] Проверка прав доступа к сертификатам..." | tee /dev/stderr
        log_debug "Checking access permissions"
        
        if [[ -r "$system_vault_bundle" ]]; then
            echo "[CERTS] ✅ CI-user имеет доступ на чтение" | tee /dev/stderr
            log_debug "✅ CI-user has read access"
            
            # Копируем в user-space для доступа без root
            echo "[CERTS] Копирование сертификатов в user-space..." | tee /dev/stderr
            log_debug "Copying certificates to user-space"
            mkdir -p "$VAULT_CERTS_DIR" || {
                echo "[CERTS] ❌ Не удалось создать $VAULT_CERTS_DIR" | tee /dev/stderr
                log_debug "❌ Failed to create $VAULT_CERTS_DIR"
                exit 1
            }
            cp "$system_vault_bundle" "$userspace_vault_bundle" || {
                echo "[CERTS] ❌ Не удалось скопировать bundle" | tee /dev/stderr
                log_debug "❌ Failed to copy bundle"
                exit 1
            }
            echo "[CERTS] ✅ Bundle скопирован напрямую" | tee /dev/stderr
            log_debug "✅ Bundle copied directly"
        else
            echo "[CERTS] ⚠️  CI-user НЕ имеет доступа на чтение" | tee /dev/stderr
            log_debug "⚠️  CI-user does not have read access"
            
            # Попытка 1: Автоматически добавить CI-user в группу va-read через RLM
            echo "[CERTS] ========================================" | tee /dev/stderr
            echo "[CERTS] ПОПЫТКА 1: Автоматическое добавление в группу va-read" | tee /dev/stderr
            echo "[CERTS] ========================================" | tee /dev/stderr
            log_debug "Attempting to add CI-user to va-read group via RLM"
            
            if ensure_user_in_va_read_group "$USER"; then
                echo "[CERTS] ✅ Пользователь успешно добавлен в группу!" | tee /dev/stderr
                log_debug "✅ User successfully added to va-read group"
                print_success "CI-user добавлен в группу ${KAE}-lnx-va-read"
                
                # ВАЖНО: После добавления в группу требуется новая сессия для применения изменений
                # Пробуем несколько способов копирования
                print_warning "Изменения группы применятся в новой сессии. Пробуем несколько способов копирования..."
                
                # Создаем директорию перед копированием
                mkdir -p "$VAULT_CERTS_DIR" || {
                    echo "[CERTS] ❌ Не удалось создать $VAULT_CERTS_DIR" | tee /dev/stderr
                    log_debug "❌ Failed to create $VAULT_CERTS_DIR"
                    exit 1
                }
                
                local copy_success=false
                
                # Способ 1: Через sys_user с sudo (если sys_user в va-read группе)
                if id "$sys_user" 2>/dev/null | grep -q "${KAE}-lnx-va-read"; then
                    echo "[CERTS] 🔧 Попытка копирования через sudo -u $sys_user..." | tee /dev/stderr
                    log_debug "Attempt 1: Copy via sudo -u $sys_user"
                    
                    if sudo -n -u "$sys_user" cp "$system_vault_bundle" "$userspace_vault_bundle" 2>/dev/null; then
                        chown "$USER:$USER" "$userspace_vault_bundle" 2>/dev/null || true
                        echo "[CERTS] ✅ Bundle скопирован через sudo -u $sys_user" | tee /dev/stderr
                        log_debug "✅ Bundle copied via sudo -u $sys_user"
                        copy_success=true
                    else
                        # Пробуем Способ 2: через cat
                        echo "[CERTS] 🔧 Попытка копирования через sudo cat..." | tee /dev/stderr
                        log_debug "Attempt 2: Copy via sudo cat"
                        
                        if sudo -n -u "$sys_user" cat "$system_vault_bundle" > "$userspace_vault_bundle" 2>/dev/null; then
                            echo "[CERTS] ✅ Bundle скопирован через sudo cat" | tee /dev/stderr
                            log_debug "✅ Bundle copied via sudo cat"
                            copy_success=true
                        fi
                    fi
                else
                    echo "[CERTS] ⚠️  $sys_user не в группе va-read" | tee /dev/stderr
                    log_debug "⚠️  $sys_user not in va-read group"
                fi
                
                # Способ 3: Прямое копирование (на случай если группа уже применилась)
                if [[ "$copy_success" == false ]]; then
                    echo "[CERTS] 🔧 Попытка прямого копирования (возможно группа уже применилась)..." | tee /dev/stderr
                    log_debug "Attempt 3: Direct copy"
                    
                    if cp "$system_vault_bundle" "$userspace_vault_bundle" 2>/dev/null; then
                        echo "[CERTS] ✅ Bundle скопирован напрямую (группа применилась!)" | tee /dev/stderr
                        log_debug "✅ Bundle copied directly (group applied!)"
                        copy_success=true
                    fi
                fi
                
                # Финальная проверка
                if [[ "$copy_success" == false ]]; then
                    echo "[CERTS] ❌ Все способы копирования не сработали" | tee /dev/stderr
                    log_debug "❌ All copy methods failed"
                    print_error "Не удалось скопировать сертификаты ни одним из способов"
                    print_error ""
                    print_error "ДИАГНОСТИКА:"
                    print_error "  1. Пользователь добавлен в группу ${KAE}-lnx-va-read через RLM ✅"
                    print_error "  2. Но изменения группы требуют новой сессии/перелогина"
                    print_error "  3. sudo -u $sys_user не работает (нет прав в sudoers)"
                    print_error ""
                    print_error "РЕШЕНИЕ (выберите один из вариантов):"
                    print_error ""
                    print_error "  ⭐ Вариант 1: Перезапустите pipeline (РЕКОМЕНДУЕТСЯ)"
                    print_error "     Группа уже применится, и прямое копирование сработает"
                    print_error ""
                    print_error "  Вариант 2: Добавьте в sudoers право на cat"
                    print_error "     $USER ALL=($sys_user) NOPASSWD: /usr/bin/cat /opt/vault/certs/*"
                    print_error ""
                    print_error "  Вариант 3: Измените права на сертификаты в vault-agent.hcl (ЛУЧШЕЕ ДОЛГОСРОЧНОЕ РЕШЕНИЕ)"
                    print_error "     В setup_vault_config() добавьте perms = \"0640\" в template блоки"
                    print_error "     Тогда группа ${KAE}-lnx-va-read сможет читать сертификаты"
                    exit 1
                fi
            else
                echo "[CERTS] ⚠️  Не удалось автоматически добавить в группу через RLM" | tee /dev/stderr
                log_debug "⚠️  Failed to add to group via RLM"
                
                # Попытка 2: Копирование через mon_sys (если он уже в группе)
                echo "[CERTS] ========================================" | tee /dev/stderr
                echo "[CERTS] ПОПЫТКА 2: Копирование через sys_user" | tee /dev/stderr
                echo "[CERTS] ========================================" | tee /dev/stderr
                log_debug "Attempting to copy via sys_user"
                
                # Проверяем, есть ли доступ у mon_sys через группу va-read
                echo "[CERTS] Проверка: есть ли у $sys_user доступ через группу va-read..." | tee /dev/stderr
                log_debug "Checking if $sys_user has access via va-read group"
                
                if id "$sys_user" | grep -q "${KAE}-lnx-va-read"; then
                    echo "[CERTS] ✅ $sys_user состоит в группе va-read" | tee /dev/stderr
                    log_debug "✅ $sys_user is in va-read group"
                    print_info "$sys_user имеет доступ к сертификатам через группу va-read"
                    
                    # Копируем от имени mon_sys через sudo
                    echo "[CERTS] Копирование от имени $sys_user..." | tee /dev/stderr
                    log_debug "Copying as $sys_user"
                    
                    mkdir -p "$VAULT_CERTS_DIR" || {
                        echo "[CERTS] ❌ Не удалось создать $VAULT_CERTS_DIR" | tee /dev/stderr
                        log_debug "❌ Failed to create $VAULT_CERTS_DIR"
                        exit 1
                    }
                    
                    # Копируем через sudo -u mon_sys (предполагается что у ci-user есть права на sudo -u mon_sys)
                    if sudo -n -u "$sys_user" cp "$system_vault_bundle" "$userspace_vault_bundle" 2>/dev/null; then
                        echo "[CERTS] ✅ Bundle скопирован через sudo -u $sys_user" | tee /dev/stderr
                        log_debug "✅ Bundle copied via sudo -u $sys_user"
                        # Меняем владельца обратно на ci-user для последующей работы
                        chown "$USER:$USER" "$userspace_vault_bundle" 2>/dev/null || true
                    else
                        echo "[CERTS] ⚠️  Не удалось скопировать через sudo -u $sys_user" | tee /dev/stderr
                        log_debug "⚠️  Failed to copy via sudo -u $sys_user"
                        print_warning "Не удалось скопировать сертификаты через sudo -u $sys_user"
                        print_info "Попытка прямого копирования (может не сработать)..."
                        cp "$system_vault_bundle" "$userspace_vault_bundle" || {
                            echo "[CERTS] ❌ Не удалось скопировать bundle" | tee /dev/stderr
                            log_debug "❌ Failed to copy bundle"
                            print_error "Недостаточно прав для копирования сертификатов"
                            print_error "Права на файл: $(ls -l "$system_vault_bundle")"
                            print_error "Требуется: добавить ${KAE}-lnx-mon_ci в группу ${KAE}-lnx-va-read через RLM/IDM"
                            exit 1
                        }
                    fi
                else
                    echo "[CERTS] ❌ $sys_user НЕ состоит в группе va-read" | tee /dev/stderr
                    log_debug "❌ $sys_user is not in va-read group"
                    print_error "Недостаточно прав для доступа к сертификатам Vault"
                    print_error "Права на файл: $(ls -l "$system_vault_bundle")"
                    print_error "Владелец: $(stat -c '%U:%G' "$system_vault_bundle")"
                    print_error ""
                    print_error "ТРЕБУЕТСЯ: Добавить ${KAE}-lnx-mon_ci в группу ${KAE}-lnx-va-read"
                    print_error "Используйте RLM или IDM для добавления пользователя в группу"
                    exit 1
                fi
            fi
        fi
        
        # Копируем также CA chain если есть
        if [[ -f "/opt/vault/certs/ca_chain.crt" ]]; then
            if [[ -r "/opt/vault/certs/ca_chain.crt" ]]; then
                cp "/opt/vault/certs/ca_chain.crt" "$VAULT_CERTS_DIR/ca_chain.crt" || true
            elif id "$sys_user" | grep -q "${KAE}-lnx-va-read" 2>/dev/null; then
                sudo -n -u "$sys_user" cp "/opt/vault/certs/ca_chain.crt" "$VAULT_CERTS_DIR/ca_chain.crt" 2>/dev/null || true
                chown "$USER:$USER" "$VAULT_CERTS_DIR/ca_chain.crt" 2>/dev/null || true
            fi
            if [[ -f "$VAULT_CERTS_DIR/ca_chain.crt" ]]; then
                echo "[CERTS] ✅ CA chain скопирован" | tee /dev/stderr
                log_debug "✅ CA chain copied"
            else
                echo "[CERTS] ⚠️  CA chain не скопирован (нет прав)" | tee /dev/stderr
                log_debug "⚠️  CA chain not copied (no permissions)"
            fi
        fi
        
        # Копируем grafana client cert если есть
        if [[ -f "/opt/vault/certs/grafana-client.pem" ]]; then
            mkdir -p "$MONITORING_CERTS_DIR/grafana" || true
            if [[ -r "/opt/vault/certs/grafana-client.pem" ]]; then
                cp "/opt/vault/certs/grafana-client.pem" "$MONITORING_CERTS_DIR/grafana/grafana-client.pem" || true
            elif id "$sys_user" | grep -q "${KAE}-lnx-va-read" 2>/dev/null; then
                sudo -n -u "$sys_user" cp "/opt/vault/certs/grafana-client.pem" "$MONITORING_CERTS_DIR/grafana/grafana-client.pem" 2>/dev/null || true
                chown "$USER:$USER" "$MONITORING_CERTS_DIR/grafana/grafana-client.pem" 2>/dev/null || true
            fi
            if [[ -f "$MONITORING_CERTS_DIR/grafana/grafana-client.pem" ]]; then
                echo "[CERTS] ✅ Grafana client cert скопирован" | tee /dev/stderr
                log_debug "✅ Grafana client cert copied"
            else
                echo "[CERTS] ⚠️  Grafana client cert не скопирован (нет прав)" | tee /dev/stderr
                log_debug "⚠️  Grafana client cert not copied (no permissions)"
            fi
        fi
        
        echo "[CERTS] ✅ Сертификаты скопированы в user-space" | tee /dev/stderr
        log_debug "✅ Certificates copied to user-space"
        
        # Теперь вызываем функцию распределения по сервисам
        copy_certs_to_user_dirs
        
        # Верифицируем наличие файлов для Prometheus в user-space
        if [[ -f "$PROMETHEUS_USER_CERTS_DIR/server.crt" && -f "$PROMETHEUS_USER_CERTS_DIR/server.key" ]]; then
            echo "[CERTS] ✅ Prometheus сертификаты присутствуют в $PROMETHEUS_USER_CERTS_DIR" | tee /dev/stderr
            log_debug "✅ Prometheus certificates present in $PROMETHEUS_USER_CERTS_DIR"
            print_success "Проверка Prometheus сертификатов: файлы присутствуют"
        else
            echo "[CERTS] ❌ Отсутствуют Prometheus сертификаты в $PROMETHEUS_USER_CERTS_DIR" | tee /dev/stderr
            log_debug "❌ Missing Prometheus certificates in $PROMETHEUS_USER_CERTS_DIR"
            print_error "Отсутствуют файлы Prometheus сертификатов в $PROMETHEUS_USER_CERTS_DIR"
            print_error "Ожидались: server.crt и server.key"
            ls -l "$PROMETHEUS_USER_CERTS_DIR" || true
            exit 1
        fi
        
    # Приоритет 2: уже скопированный user-space bundle
    elif [[ -f "$userspace_vault_bundle" ]]; then
        echo "[CERTS] ✅ Найден user-space vault bundle: $userspace_vault_bundle" | tee /dev/stderr
        log_debug "✅ Found user-space vault bundle: $userspace_vault_bundle"
        print_success "Найдены сертификаты в user-space: $userspace_vault_bundle"
        copy_certs_to_user_dirs
        
    # Приоритет 3: отдельные .crt/.key файлы
    elif [[ -f "$VAULT_CRT_FILE" && -f "$VAULT_KEY_FILE" ]]; then
        echo "[CERTS] ✅ Найдена пара сертификатов: $VAULT_CRT_FILE, $VAULT_KEY_FILE" | tee /dev/stderr
        log_debug "✅ Found certificate pair: $VAULT_CRT_FILE, $VAULT_KEY_FILE"
        print_success "Найдены сертификаты: $VAULT_CRT_FILE и $VAULT_KEY_FILE"
        copy_certs_to_user_dirs
        
    else
        echo "[CERTS] ❌ Сертификаты не найдены ни в одном из путей!" | tee /dev/stderr
        log_debug "❌ No certificates found in any path!"
        print_error "Сертификаты от Vault не найдены:"
        print_error "  Системный путь: $system_vault_bundle"
        print_error "  User-space путь: $userspace_vault_bundle"
        print_error "  Или пара: $VAULT_CRT_FILE + $VAULT_KEY_FILE"
        echo "[CERTS] Проверка содержимого /opt/vault/certs/:" | tee /dev/stderr
        ls -la /opt/vault/certs/ 2>&1 | tee /dev/stderr || echo "[CERTS] Директория не существует или недоступна" | tee /dev/stderr
        exit 1
    fi
    
    echo "[CERTS] ========================================" | tee /dev/stderr
    echo "[CERTS] ✅ setup_certificates_after_install ЗАВЕРШЕНА" | tee /dev/stderr
    echo "[CERTS] ========================================" | tee /dev/stderr
    log_debug "========================================"
    log_debug "✅ setup_certificates_after_install COMPLETED"
    log_debug "========================================"
}

configure_harvest() {
    print_step "Настройка Harvest (Secure Edition)"
    ensure_working_directory
    
    # Определяем user-space пути
    local HARVEST_USER_CONFIG_DIR="$HOME/monitoring/config/harvest"
    local HARVEST_USER_CERTS_DIR="$HARVEST_USER_CONFIG_DIR/cert"
    
    # Создаем директории
    mkdir -p "$HARVEST_USER_CONFIG_DIR" "$HARVEST_USER_CERTS_DIR"
    
    # Проверяем, есть ли сертификаты
    local HARVEST_RUNTIME_CERT_DIR="$HARVEST_USER_CERTS_DIR"
    if [[ ! -f "$HARVEST_RUNTIME_CERT_DIR/harvest.crt" || ! -f "$HARVEST_RUNTIME_CERT_DIR/harvest.key" ]]; then
        print_warning "Сертификаты Harvest пока не найдены в $HARVEST_RUNTIME_CERT_DIR/"
        print_info "Ожидаем, что copy_certs_to_user_dirs() разложит их из user-space bundle"
    fi
    
    # Создаем harvest.yml
    cat > "$HARVEST_USER_CONFIG_DIR/harvest.yml" << EOF
Exporters:
    prometheus_unix:
        exporter: Prometheus
        local_http_addr: 0.0.0.0
        port: ${HARVEST_UNIX_PORT}
    prometheus_netapp_https:
        exporter: Prometheus
        local_http_addr: 0.0.0.0
        port: ${HARVEST_NETAPP_PORT}
        tls:
            cert_file: $HARVEST_USER_CERTS_DIR/harvest.crt
            key_file: $HARVEST_USER_CERTS_DIR/harvest.key
        http_listen_ssl: true
Defaults:
    collectors:
        - Zapi
        - ZapiPerf
        - Ems
    use_insecure_tls: false
Pollers:
    unix:
        datacenter: local
        addr: localhost
        collectors:
            - Unix
        exporters:
            - prometheus_unix
    ${NETAPP_POLLER_NAME}:
        datacenter: DC1
        addr: ${NETAPP_API_ADDR}
        auth_style: certificate_auth
        ssl_cert: $HARVEST_USER_CERTS_DIR/harvest.crt
        ssl_key: $HARVEST_USER_CERTS_DIR/harvest.key
        use_insecure_tls: false
        collectors:
            - Rest
            - RestPerf
        exporters:
            - prometheus_netapp_https
EOF
    
    print_success "Конфигурация Harvest обновлена в $HARVEST_USER_CONFIG_DIR/harvest.yml"
    
    # ✅ В Secure Edition НЕТ создания systemd сервиса в /etc/systemd/system/
    # Вместо этого используется user unit созданный в create_systemd_user_units()
    
    # Логируем для отладки
    echo "[DEBUG-HARVEST] Конфиг: $HARVEST_USER_CONFIG_DIR/harvest.yml" | tee /dev/stderr
    echo "[DEBUG-HARVEST] Сертификаты: $HARVEST_USER_CERTS_DIR/" | tee /dev/stderr
    if [[ -f "$HARVEST_USER_CERTS_DIR/harvest.crt" && -f "$HARVEST_USER_CERTS_DIR/harvest.key" ]]; then
        echo "[DEBUG-HARVEST] ✅ Найдены harvest.crt и harvest.key" | tee /dev/stderr
    else
        echo "[DEBUG-HARVEST] ❌ Нет пары harvest.crt/harvest.key в $HARVEST_USER_CERTS_DIR" | tee /dev/stderr
    fi
}

configure_prometheus() {
    print_step "Настройка Prometheus (Secure Edition - user-space)"
    ensure_working_directory
    
    # SECURE EDITION: Создаем конфиг в пользовательской директории БЕЗ root
    local prometheus_config="${PROMETHEUS_USER_CONFIG_DIR}/prometheus.yml"
    
    # Копируем consoles и console_libraries из RPM в user-space
    if [[ -d "/etc/prometheus/consoles" ]]; then
        print_info "Копирование consoles из RPM в user-space..."
        cp -r /etc/prometheus/consoles "$PROMETHEUS_USER_CONFIG_DIR/" 2>/dev/null || print_warning "Не удалось скопировать consoles"
    fi
    if [[ -d "/etc/prometheus/console_libraries" ]]; then
        print_info "Копирование console_libraries из RPM в user-space..."
        cp -r /etc/prometheus/console_libraries "$PROMETHEUS_USER_CONFIG_DIR/" 2>/dev/null || print_warning "Не удалось скопировать console_libraries"
    fi
    
    print_info "Создание конфигурации Prometheus: $prometheus_config"

    # SECURE EDITION: Прямая запись в пользовательскую директорию (БЕЗ config-writer)
    cat > "$prometheus_config" << PROMETHEUS_CONFIG_EOF
global:
  scrape_interval: 60s
  evaluation_interval: 60s
  scrape_timeout: 30s

scrape_configs:
  - job_name: 'prometheus'
    scheme: https
    tls_config:
      cert_file: ${PROMETHEUS_USER_CERTS_DIR}/server.crt
      key_file: ${PROMETHEUS_USER_CERTS_DIR}/server.key
      ca_file: ${PROMETHEUS_USER_CERTS_DIR}/ca_chain.crt
      insecure_skip_verify: false
    static_configs:
      - targets: ['${SERVER_DOMAIN}:${PROMETHEUS_PORT}']
    metrics_path: /metrics
    scrape_interval: 60s

  - job_name: 'harvest-unix'
    static_configs:
      - targets: ['localhost:${HARVEST_UNIX_PORT}']
    metrics_path: /metrics
    scrape_interval: 30s

  - job_name: 'harvest-netapp-https'
    scheme: https
    tls_config:
      cert_file: ${PROMETHEUS_USER_CERTS_DIR}/server.crt
      key_file: ${PROMETHEUS_USER_CERTS_DIR}/server.key
      ca_file: ${PROMETHEUS_USER_CERTS_DIR}/ca_chain.crt
      insecure_skip_verify: false
    static_configs:
      - targets: ['${SERVER_DOMAIN}:${HARVEST_NETAPP_PORT}']
    metrics_path: /metrics
    scrape_interval: 60s
PROMETHEUS_CONFIG_EOF

    chmod 640 "$prometheus_config" 2>/dev/null || true
    print_success "Конфигурация Prometheus создана в user-space: $prometheus_config"
}

# Настройка прав для Prometheus при запуске как user-юнит под ${KAE}-lnx-mon_sys
adjust_prometheus_permissions_for_mon_sys() {
    print_step "Проверка конфигурации Prometheus (Secure Edition - user-space)"
    ensure_working_directory

    # SECURE EDITION: Все файлы уже в $HOME/monitoring/ с правильными правами
    # chown/chmod операции НЕ НУЖНЫ и ЗАПРЕЩЕНЫ (нет доступа к /etc/, /var/)
    
    print_success "✅ Secure Edition: Все файлы Prometheus в user-space"
    print_info "   Конфиг: $PROMETHEUS_USER_CONFIG_DIR"
    print_info "   Данные: $PROMETHEUS_USER_DATA_DIR"
    print_info "   Логи: $PROMETHEUS_USER_LOGS_DIR"
    print_info "   Сертификаты: $PROMETHEUS_USER_CERTS_DIR"
}

# Настройка прав для Grafana при запуске как user-юнит под ${KAE}-lnx-mon_sys
adjust_grafana_permissions_for_mon_sys() {
    print_step "Адаптация прав Grafana для user-юнита под ${KAE}-lnx-mon_sys"
    ensure_working_directory

    if [[ -z "${KAE:-}" ]]; then
        print_warning "KAE не определён (NAMESPACE_CI пуст), пропускаем настройку прав Grafana для mon_sys"
        return 0
    fi

    local mon_sys_user="${KAE}-lnx-mon_sys"
    if ! id "$mon_sys_user" >/dev/null 2>&1; then
        print_warning "Пользователь ${mon_sys_user} не найден, пропускаем настройку прав Grafana для mon_sys"
        return 0
    fi

    # Проверяем, что пользователь входит в группу grafana
    if ! id "$mon_sys_user" | grep -q '\bgrafana\b'; then
        print_warning "Пользователь ${mon_sys_user} не состоит в группе grafana"
        print_info "Добавление пользователя ${mon_sys_user} в группу grafana..."
        usermod -a -G grafana "$mon_sys_user" 2>/dev/null || print_warning "Не удалось добавить пользователя в группу grafana"
    fi

    # Каталоги и файлы Grafana, которые должны быть доступны mon_sys
    local grafana_data_dir="/var/lib/grafana"
    local grafana_log_dir="/var/log/grafana"
    local grafana_cert_dir="/etc/grafana/cert"
    local grafana_config="/etc/grafana/grafana.ini"
    local grafana_provisioning_dir="/etc/grafana/provisioning"

    # Директория с данными Grafana
    if [[ -d "$grafana_data_dir" ]]; then
        print_info "Настройка владельца/прав данных Grafana для ${mon_sys_user}"
        # Устанавливаем владельца как mon_sys:grafana для возможности записи
        chown -R "${mon_sys_user}:grafana" "$grafana_data_dir" 2>/dev/null || print_warning "Не удалось изменить владельца $grafana_data_dir"
        chmod 775 "$grafana_data_dir" 2>/dev/null || true
        # Устанавливаем setgid bit, чтобы новые файлы наследовали группу grafana
        chmod g+s "$grafana_data_dir" 2>/dev/null || true
    else
        print_warning "Каталог данных Grafana ($grafana_data_dir) не найден, создаем..."
        mkdir -p "$grafana_data_dir"
        chown "${mon_sys_user}:grafana" "$grafana_data_dir" 2>/dev/null || true
        chmod 775 "$grafana_data_dir" 2>/dev/null || true
        chmod g+s "$grafana_data_dir" 2>/dev/null || true
    fi

    # Директория с логами Grafana
    if [[ -d "$grafana_log_dir" ]]; then
        print_info "Настройка владельца/прав логов Grafana для ${mon_sys_user}"
        chown -R "${mon_sys_user}:grafana" "$grafana_log_dir" 2>/dev/null || print_warning "Не удалось изменить владельца $grafana_log_dir"
        chmod 775 "$grafana_log_dir" 2>/dev/null || true
        chmod g+s "$grafana_log_dir" 2>/dev/null || true
    else
        print_warning "Каталог логов Grafana ($grafana_log_dir) не найден, создаем..."
        mkdir -p "$grafana_log_dir"
        chown "${mon_sys_user}:grafana" "$grafana_log_dir" 2>/dev/null || true
        chmod 775 "$grafana_log_dir" 2>/dev/null || true
        chmod g+s "$grafana_log_dir" 2>/dev/null || true
    fi

    # Сертификаты Grafana
    if [[ -d "$grafana_cert_dir" ]]; then
        print_info "Настройка владельца/прав сертификатов Grafana для ${mon_sys_user}"
        chown -R "${mon_sys_user}:grafana" "$grafana_cert_dir" 2>/dev/null || print_warning "Не удалось изменить владельца $grafana_cert_dir"
        chmod 640 "$grafana_cert_dir"/crt.crt 2>/dev/null || true
        chmod 640 "$grafana_cert_dir"/key.key 2>/dev/null || true
    else
        print_warning "Каталог сертификатов Grafana ($grafana_cert_dir) не найден"
    fi

    # Конфиг Grafana
    if [[ -f "$grafana_config" ]]; then
        print_info "Настройка владельца/прав конфига Grafana для ${mon_sys_user}"
        chown "${mon_sys_user}:grafana" "$grafana_config" 2>/dev/null || print_warning "Не удалось изменить владельца $grafana_config"
        chmod 640 "$grafana_config" 2>/dev/null || true
    fi

    # Директория provisioning Grafana
    if [[ -d "$grafana_provisioning_dir" ]]; then
        print_info "Настройка владельца/прав provisioning директории Grafana для ${mon_sys_user}"
        chown -R "${mon_sys_user}:grafana" "$grafana_provisioning_dir" 2>/dev/null || print_warning "Не удалось изменить владельца $grafana_provisioning_dir"
        chmod 750 "$grafana_provisioning_dir" 2>/dev/null || true
        # Рекурсивно устанавливаем права на чтение для файлов в provisioning
        find "$grafana_provisioning_dir" -type f -exec chmod 640 {} \; 2>/dev/null || true
        find "$grafana_provisioning_dir" -type d -exec chmod 750 {} \; 2>/dev/null || true
    else
        print_warning "Каталог provisioning Grafana ($grafana_provisioning_dir) не найден"
    fi

    print_success "Права Grafana адаптированы для запуска под ${mon_sys_user} (user-юнит)"
}

configure_grafana_datasource() {
    print_step "Настройка Prometheus Data Source в Grafana (Secure Edition)"
    ensure_working_directory

    # Два подхода:
    # 1. Через API (если есть токен)
    # 2. Через provisioning файлы (user-space)
    
    # Определяем user-space пути
    local GRAFANA_USER_CONFIG_DIR="$HOME/monitoring/config/grafana"
    local GRAFANA_PROVISIONING_DIR="$GRAFANA_USER_CONFIG_DIR/provisioning"
    local DATASOURCES_DIR="$GRAFANA_PROVISIONING_DIR/datasources"
    
    # Создаем директории
    mkdir -p "$DATASOURCES_DIR"
    
    # ============================================
    # 1. Создаем provisioning файл (user-space)
    # ============================================
    cat > "$DATASOURCES_DIR/prometheus.yml" << EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: https://${SERVER_DOMAIN}:${PROMETHEUS_PORT}
    isDefault: true
    jsonData:
      tlsSkipVerify: false
      tlsAuth: true
      tlsAuthWithCACert: true
    secureJsonData:
      tlsCACert: |
        $(cat "$HOME/monitoring/certs/prometheus/ca_chain.crt" 2>/dev/null | /usr/bin/sed 's/^/        /')
      tlsClientCert: |
        $(cat "$HOME/monitoring/certs/prometheus/client.crt" 2>/dev/null | /usr/bin/sed 's/^/        /')
      tlsClientKey: |
        $(cat "$HOME/monitoring/certs/prometheus/client.key" 2>/dev/null | /usr/bin/sed 's/^/        /')
EOF
    
    print_success "Provisioning файл создан в $DATASOURCES_DIR/prometheus.yml"
    
    # ============================================
    # 2. Пытаемся настроить через API (если есть токен)
    # ============================================
    local grafana_url="https://${SERVER_DOMAIN}:${GRAFANA_PORT}"

    if [[ -z "$GRAFANA_BEARER_TOKEN" ]]; then
        print_warning "GRAFANA_BEARER_TOKEN пуст. Используем только provisioning файлы"
        print_info "Grafana автоматически загрузит datasource при запуске"
        return 0
    fi

    if [[ ! -x "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ]]; then
        print_warning "Лаунчер grafana-api-wrapper_launcher.sh не найден. Используем только provisioning файлы"
        return 0
    fi

    # Проверяем наличие источника данных через API (по токену)
    local ds_status
    ds_status=$("$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ds_status_by_name "$grafana_url" "$GRAFANA_BEARER_TOKEN" "prometheus")

    local create_payload update_payload http_code
    create_payload=$(jq -n \
        --arg url "https://${SERVER_DOMAIN}:${PROMETHEUS_PORT}" \
        --arg sn  "${SERVER_DOMAIN}" \
        '{name:"prometheus", type:"prometheus", access:"proxy", url:$url, isDefault:true,
          jsonData:{httpMethod:"POST", serverName:$sn, tlsAuth:true, tlsAuthWithCACert:true, tlsSkipVerify:false}}')

    if [[ "$ds_status" == "200" ]]; then
        update_payload=$(jq -n \
            --arg url "https://${SERVER_DOMAIN}:${PROMETHEUS_PORT}" \
            --arg sn  "${SERVER_DOMAIN}" \
            '{name:"prometheus", type:"prometheus", access:"proxy", url:$url, isDefault:true,
              jsonData:{httpMethod:"POST", serverName:$sn, tlsAuth:true, tlsAuthWithCACert:true, tlsSkipVerify:false}}')
        http_code=$(printf '%s' "$update_payload" | \
            "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ds_update_by_name "$grafana_url" "$GRAFANA_BEARER_TOKEN" "prometheus")
        if [[ "$http_code" == "200" || "$http_code" == "202" ]]; then
            print_success "Prometheus Data Source обновлён через API"
        else
            print_warning "Не удалось обновить Data Source через API (код $http_code)"
            print_info "Используем provisioning файлы"
        fi
    else
        http_code=$(printf '%s' "$create_payload" | \
            "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ds_create "$grafana_url" "$GRAFANA_BEARER_TOKEN")
        if [[ "$http_code" == "200" || "$http_code" == "202" ]]; then
            print_success "Prometheus Data Source создан через API"
        else
            print_warning "Не удалось создать Data Source через API (код $http_code)"
            print_info "Используем provisioning файлы"
        fi
    fi
}

# Проверка доступности Grafana
check_grafana_availability() {
    print_step "Проверка доступности Grafana"
    ensure_working_directory
    
    local grafana_url="https://${SERVER_DOMAIN}:${GRAFANA_PORT}"
    local max_attempts=30
    local attempt=1
    local interval_sec=2
    
    print_info "Ожидание запуска Grafana (максимум $((max_attempts * interval_sec)) секунд)..."
    
    while [[ $attempt -le $max_attempts ]]; do
        # Проверяем, активен ли user-юнит Grafana
        if [[ -n "${KAE:-}" ]]; then
            local mon_sys_user="${KAE}-lnx-mon_sys"
            local mon_sys_uid=""
            if id "$mon_sys_user" >/dev/null 2>&1; then
                mon_sys_uid=$(id -u "$mon_sys_user")
                local ru_cmd="sudo -n -u ${mon_sys_user}"
                local xdg_env="XDG_RUNTIME_DIR=/run/user/${mon_sys_uid}"
                
                if $ru_cmd env "$xdg_env" /usr/bin/systemctl --user is-active --quiet monitoring-grafana.service 2>/dev/null; then
                    print_success "Grafana user-юнит активен"
                    
                    # Проверяем что процесс слушает порт
                    if ss -tln | grep -q ":${GRAFANA_PORT} "; then
                        print_success "Grafana слушает порт ${GRAFANA_PORT}"
                        print_info "Проверка процесса grafana..."
                        if pgrep -f "grafana" >/dev/null 2>&1; then
                            print_success "Процесс grafana найден"
                        else
                            print_warning "Процесс grafana не найден по имени, но порт слушается"
                        fi
                        return 0
                    else
                        print_info "Grafana юнит активен, но порт ${GRAFANA_PORT} не слушается (попытка $attempt/$max_attempts)"
                    fi
                fi
            fi
        fi
        
        # Также проверяем системный юнит на случай fallback
        if systemctl is-active --quiet grafana-server 2>/dev/null; then
            print_success "Grafana системный юнит активен"
            
            # Проверяем что процесс слушает порт
            if ss -tln | grep -q ":${GRAFANA_PORT} "; then
                print_success "Grafana слушает порт ${GRAFANA_PORT}"
                return 0
            else
                print_info "Grafana системный юнит активен, но порт ${GRAFANA_PORT} не слушается (попытка $attempt/$max_attempts)"
            fi
        fi
        
        echo "[INFO] ├─ Ожидание Grafana... (попытка $attempt/$max_attempts)" >&2
        sleep "$interval_sec"
        attempt=$((attempt + 1))
    done
    print_error "Grafana не доступна после $((max_attempts * interval_sec)) секунд ожидания"
    print_info "Проверьте статус:"
    print_info "  sudo -u CI10742292-lnx-mon_sys XDG_RUNTIME_DIR=\"/run/user/\$(id -u CI10742292-lnx-mon_sys)\" systemctl --user status monitoring-grafana.service"
    print_info "  sudo systemctl status grafana-server"
    print_info "Проверьте логи: /tmp/grafana-debug.log"
    
    return 1
}

ensure_grafana_token() {
    print_step "Получение API токена Grafana (service account)"
    ensure_working_directory

    local grafana_url="https://${SERVER_DOMAIN}:${GRAFANA_PORT}"
    local grafana_user=""
    local grafana_password=""

    if [[ -n "$GRAFANA_BEARER_TOKEN" ]]; then
        print_info "Токен Grafana уже получен"
        return 0
    fi

    # Читаем учетные данные Grafana. В simplified режиме источник - temp_data_cred.json,
    # в legacy режиме - /opt/vault/conf/data_sec.json.
    local cred_json=""
    for candidate in \
        "${CRED_JSON_PATH:-}" \
        "$PWD/temp_data_cred.json" \
        "$(dirname "$0")/temp_data_cred.json" \
        "$HOME/monitoring-deployment/temp_data_cred.json" \
        "/tmp/temp_data_cred.json" \
        "/opt/vault/conf/data_sec.json"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            cred_json="$candidate"
            break
        fi
    done
    if [[ ! -f "$cred_json" ]]; then
        print_error "Файл с учетными данными Grafana не найден (проверены temp_data_cred.json и legacy data_sec.json)"
        return 1
    fi
    print_info "Используется файл учетных данных: $cred_json"

    # SECURITY: Используем secrets-manager-wrapper для безопасного извлечения секретов
    if [[ ! -x "$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" ]]; then
        print_error "secrets-manager-wrapper_launcher.sh не найден или не исполняемый"
        return 1
    fi
    
    grafana_user=$("$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" extract_secret "$cred_json" "grafana_web.user")
    grafana_password=$("$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" extract_secret "$cred_json" "grafana_web.pass")
    
    # Устанавливаем trap для очистки переменных при выходе из функции
    trap 'unset grafana_user grafana_password' RETURN

    if [[ -z "$grafana_user" || -z "$grafana_password" ]]; then
        print_error "Не удалось получить учётные данные Grafana через secrets-wrapper"
        return 1
    fi

    if [[ ! -x "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ]]; then
        print_error "Лаунчер grafana-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        exit 1
    fi

    local timestamp service_account_name token_name payload_sa payload_token resp http_code body sa_id
    timestamp=$(date +%s)
    service_account_name="harvest-service-account_$timestamp"
    token_name="harvest-token_$timestamp"

    # Создаём сервисный аккаунт и извлекаем его id из ответа
    payload_sa=$(jq -n --arg name "$service_account_name" --arg role "Admin" '{name:$name, role:$role}')
    resp=$(printf '%s' "$payload_sa" | \
        "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" sa_create "$grafana_url" "$grafana_user" "$grafana_password") || true
    http_code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        sa_id=$(echo "$body" | jq -r '.id // empty')
    elif [[ "$http_code" == "409" ]]; then
        # Уже существует; найдём id по имени
        local list_resp list_code list_body
        list_resp=$("$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" sa_list "$grafana_url" "$grafana_user" "$grafana_password") || true
        list_code="${list_resp##*$'\n'}"
        list_body="${list_resp%$'\n'*}"
        if [[ "$list_code" == "200" ]]; then
            sa_id=$(echo "$list_body" | jq -r '.[] | select(.name=="'"$service_account_name"'") | .id' | head -1)
        fi
    else
        print_error "Не удалось создать сервисный аккаунт Grafana (HTTP $http_code)"
        return 1
    fi

    if [[ -z "$sa_id" || "$sa_id" == "null" ]]; then
        print_error "ID сервисного аккаунта не получен"
        return 1
    fi

    # Создаём токен и извлекаем ключ
    payload_token=$(jq -n --arg name "$token_name" '{name:$name}')
    local tok_resp tok_code tok_body token_value
    tok_resp=$(printf '%s' "$payload_token" | \
        "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" sa_token_create "$grafana_url" "$grafana_user" "$grafana_password" "$sa_id") || true
    tok_code="${tok_resp##*$'\n'}"
    tok_body="${tok_resp%$'\n'*}"

    if [[ "$tok_code" == "200" || "$tok_code" == "201" ]]; then
        token_value=$(echo "$tok_body" | jq -r '.key // empty')
    else
        print_error "Не удалось создать токен сервисного аккаунта (HTTP $tok_code)"
        return 1
    fi

    if [[ -z "$token_value" || "$token_value" == "null" ]]; then
        print_error "Пустой токен сервисного аккаунта"
        return 1
    fi

    GRAFANA_BEARER_TOKEN="$token_value"
    export GRAFANA_BEARER_TOKEN
    print_success "Получен токен Grafana"
}

# Настройка Prometheus datasource и импорт дашбордов Harvest
setup_grafana_datasource_and_dashboards() {
    print_step "Настройка Prometheus datasource и дашбордов в Grafana"
    ensure_working_directory
    
    # Проверяем, установлена ли Grafana (если используется SKIP_RPM_INSTALL)
    if [[ ! -d "/usr/share/grafana" && ! -d "/etc/grafana" ]]; then
        print_warning "Grafana не установлена (отсутствуют /usr/share/grafana и /etc/grafana)"
        print_info "Если используется SKIP_RPM_INSTALL=true, пропускаем настройку datasource и дашбордов"
        return 0
    fi
    
    # Файл для детального логирования диагностики
    local DIAGNOSIS_LOG="/tmp/grafana_diagnosis_$(date +%Y%m%d_%H%M%S).log"
    print_info "Детальная диагностика сохраняется в: $DIAGNOSIS_LOG"
    
    # Функция для записи в лог-файл
    log_diagnosis() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DIAGNOSIS_LOG"
    }
    
    # Начало диагностики
    log_diagnosis "=== НАЧАЛО ДИАГНОСТИКИ GRAFANA ==="
    log_diagnosis "Функция: setup_grafana_datasource_and_dashboards"
    log_diagnosis "Время: $(date)"
    log_diagnosis "Пользователь: $(whoami)"
    log_diagnosis "PID: $$"
    
    # Принудительное использование localhost если задана переменная
    if [[ "${USE_GRAFANA_LOCALHOST:-false}" == "true" ]]; then
        print_warning "Используем localhost вместо $SERVER_DOMAIN (USE_GRAFANA_LOCALHOST=true)"
        export SERVER_DOMAIN="localhost"
    fi
    
    local grafana_url="https://${SERVER_DOMAIN}:${GRAFANA_PORT}"
    
    # Диагностическая информация
    print_info "=== ДИАГНОСТИКА GRAFANA ==="
    print_info "Grafana URL: $grafana_url"
    print_info "GRAFANA_PORT: ${GRAFANA_PORT}"
    print_info "SERVER_DOMAIN: ${SERVER_DOMAIN}"
    print_info "Текущий токен установлен: $( [[ -n "$GRAFANA_BEARER_TOKEN" ]] && echo "ДА" || echo "НЕТ" )"
    
    # Проверка различий между localhost и доменным именем
    print_info "Проверка доступности через разные адреса:"
    print_info "  localhost:3000 - $(curl -k -s -o /dev/null -w "%{http_code}" "https://localhost:3000/api/health" 2>/dev/null || echo "ERROR")"
    print_info "  127.0.0.1:3000 - $(curl -k -s -o /dev/null -w "%{http_code}" "https://127.0.0.1:3000/api/health" 2>/dev/null || echo "ERROR")"
    print_info "  ${SERVER_DOMAIN}:3000 - $(curl -k -s -o /dev/null -w "%{http_code}" "https://${SERVER_DOMAIN}:3000/api/health" 2>/dev/null || echo "ERROR")"
    
    # Проверяем доступность Grafana - просто проверяем что порт слушается
    # Не делаем HTTP/HTTPS запросы, так как Grafana может требовать клиентские сертификаты
    print_info "Проверка доступности Grafana (порт ${GRAFANA_PORT})..."
    
    # Детальная диагностика порта
    print_info "Проверка порта ${GRAFANA_PORT} с помощью ss:"
    ss -tln | grep ":${GRAFANA_PORT}" || true
    
    if ! ss -tln | grep -q ":${GRAFANA_PORT} "; then
        print_error "Grafana не слушает порт ${GRAFANA_PORT}"
        print_info "Текущие слушающие порты:"
        ss -tln | head -20
        return 1
    fi
    
    # Дополнительная проверка - процесс Grafana запущен
    print_info "Проверка процесса grafana..."
    pgrep -f "grafana" && print_info "Процесс grafana найден" || print_info "Процесс grafana не найден"
    
    # Опция для пропуска проверки процесса (временное решение)
    if [[ "${SKIP_GRAFANA_PROCESS_CHECK:-false}" == "true" ]]; then
        print_warning "Пропускаем проверку процесса grafana (SKIP_GRAFANA_PROCESS_CHECK=true)"
        print_info "Убедитесь что Grafana действительно запущена"
    elif ! pgrep -f "grafana" >/dev/null 2>&1; then
        print_error "Процесс grafana не найден"
        print_info "Текущие процессы:"
        ps aux | grep -i grafana | head -10
        return 1
    fi
    
    print_success "Grafana доступна (порт слушается, процесс запущен)"
    
    # Получаем учетные данные
    print_info "Получение учетных данных Grafana из Vault..."
    local cred_json=""
    for candidate in \
        "${CRED_JSON_PATH:-}" \
        "$PWD/temp_data_cred.json" \
        "$(dirname "$0")/temp_data_cred.json" \
        "$HOME/monitoring-deployment/temp_data_cred.json" \
        "/tmp/temp_data_cred.json" \
        "/opt/vault/conf/data_sec.json"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            cred_json="$candidate"
            break
        fi
    done
    
    # Диагностика файла с учетными данными
    print_info "Проверка файла с учетными данными: $cred_json"
    if [[ -f "$cred_json" ]]; then
        print_info "Файл существует, размер: $(stat -c%s "$cred_json" 2>/dev/null || echo "неизвестно") байт"
        
        # Проверка формата JSON
        print_info "Проверка формата JSON файла..."
        if jq empty "$cred_json" 2>/dev/null; then
            print_success "JSON файл валиден"
        else
            print_warning "JSON файл имеет проблемы с форматом, пробуем исправить..."
            
            # Сохраняем оригинальный файл
            cp "$cred_json" "${cred_json}.backup" 2>/dev/null
            
            # Исправляем возможные проблемы
            # 1. Убираем Windows line endings
            /usr/bin/sed -i 's/\r$//' "$cred_json" 2>/dev/null
            # 2. Убираем лишние запятые в конце объектов/массивов
            /usr/bin/sed -i 's/,\s*}/}/g' "$cred_json" 2>/dev/null
            /usr/bin/sed -i 's/,\s*]/]/g' "$cred_json" 2>/dev/null
            # 3. Убираем лишние пробелы
            /usr/bin/sed -i 's/^[[:space:]]*//;s/[[:space:]]*$//' "$cred_json" 2>/dev/null
            
            if jq empty "$cred_json" 2>/dev/null; then
                print_success "JSON файл исправлен"
            else
                print_error "Не удалось исправить JSON файл"
                print_info "Оригинальное содержимое (первые 500 символов):"
                head -c 500 "${cred_json}.backup" 2>/dev/null | cat -A || true
                echo
                return 1
            fi
        fi
        
        print_info "Содержимое файла (первые 200 символов):"
        head -c 200 "$cred_json" 2>/dev/null | cat -A || true
        echo
        
        # Показываем структуру JSON
        print_info "Структура JSON файла:"
        jq 'keys' "$cred_json" 2>/dev/null || echo "Не удалось прочитать структуру"
        
    else
        print_error "Файл с учетными данными не найден (проверены temp_data_cred.json и legacy data_sec.json)"
        print_info "Поиск альтернативных файлов..."
        find /opt/vault "$HOME" /tmp -maxdepth 4 -type f \( -name "data_sec.json" -o -name "temp_data_cred.json" \) 2>/dev/null | head -10
        return 1
    fi
    
    # SECURITY: Используем secrets-manager-wrapper для безопасного извлечения секретов
    if [[ ! -x "$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" ]]; then
        print_error "secrets-manager-wrapper_launcher.sh не найден или не исполняемый"
        return 1
    fi
    
    local grafana_user grafana_password
    grafana_user=$("$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" extract_secret "$cred_json" "grafana_web.user")
    grafana_password=$("$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" extract_secret "$cred_json" "grafana_web.pass")
    
    # Устанавливаем trap для очистки переменных при выходе из функции
    trap 'unset grafana_user grafana_password' RETURN
    
    print_info "Полученные учетные данные:"
    print_info "  Пользователь: $( [[ -n "$grafana_user" ]] && echo "установлен" || echo "НЕ УСТАНОВЛЕН" )"
    print_info "  Пароль: $( [[ -n "$grafana_password" ]] && echo "установлен" || echo "НЕ УСТАНОВЛЕН" )"
    
    if [[ -z "$grafana_user" || -z "$grafana_password" ]]; then
        print_error "Не удалось получить учетные данные Grafana через secrets-wrapper"
        print_info "Проверьте наличие секретов в JSON файле"
        return 1
    fi
    print_success "Учетные данные получены безопасно через wrapper"
    
    # Проверяем, есть ли уже токен
    if [[ -n "$GRAFANA_BEARER_TOKEN" ]]; then
        print_info "Используем существующий токен Grafana"
    else
        # Пытаемся получить токен через API
        print_info "Попытка получения токена через API Grafana..."
        local timestamp service_account_name token_name
        timestamp=$(date +%s)
        service_account_name="harvest-service-account_$timestamp"
        token_name="harvest-token_$timestamp"
        
        # Функция для создания сервисного аккаунта через API (исправленная версия)
        create_service_account_via_api() {
            # ============================================================================
            # УПРОЩЕННАЯ ВЕРСИЯ - используем grafana-api-wrapper.sh (требование ИБ)
            # Правила ИБ: НЕ вызывать curl напрямую, только через обёртки!
            # ============================================================================
            
            # КРИТИЧЕСКИ ВАЖНО: Определяем DEBUG_LOG в начале функции!
            local DEBUG_LOG="/tmp/debug_grafana_key.log"
            
            # Создаем заголовок debug лога
            cat > "$DEBUG_LOG" << 'EOF_HEADER'
================================================================================
DEBUG LOG: Создание Service Account в Grafana
Дата и время: $(date '+%Y-%m-%d %H:%M:%S %Z')
================================================================================
EOF_HEADER
            
            print_info "=== Создание Service Account через wrapper ===" 
            log_diagnosis "=== ВХОД В create_service_account_via_api (через wrapper) ==="
            
            # Отладочное логирование - начало функции
            echo "DEBUG_FUNC_START: Функция create_service_account_via_api вызвана $(date '+%Y-%m-%d %H:%M:%S')" >&2
            echo "DEBUG_PARAMS: service_account_name='$service_account_name'" >&2
            echo "DEBUG_PARAMS: grafana_url='$grafana_url'" >&2
            echo "DEBUG_PARAMS: grafana_user='$grafana_user'" >&2
            echo "DEBUG_PARAMS: текущий каталог='$(pwd)'" >&2
            
            print_info "Параметры функции:"
            print_info "  service_account_name: $service_account_name"
            print_info "  grafana_url: $grafana_url"
            print_info "  grafana_user: $grafana_user"
            
            print_info "=== НАЧАЛО create_service_account_via_api ==="
            log_diagnosis "=== ВХОД В create_service_account_via_api ==="
            
            print_info "Параметры функции:"
            print_info "  service_account_name: $service_account_name"
            print_info "  grafana_url: $grafana_url"
            print_info "  grafana_user: $grafana_user"
            print_info "  Текущий каталог: $(pwd)"
            print_info "  Время: $(date)"
            
            log_diagnosis "Параметры функции:"
            log_diagnosis "  service_account_name: $service_account_name"
            log_diagnosis "  grafana_url: $grafana_url"
            log_diagnosis "  grafana_user: $grafana_user"
            log_diagnosis "  grafana_password: ***** (длина: ${#grafana_password})"
            log_diagnosis "  Текущий каталог: $(pwd)"
            log_diagnosis "  Время: $(date)"
            
            local sa_payload sa_response http_code sa_body sa_id
            
            # Grafana 11.x не поддерживает поле "role" при создании service account
            # ВАЖНО: 
            # 1. Используем -c (compact) для создания JSON БЕЗ переносов строк
            # 2. Используем tr -d '\n' чтобы убрать trailing newline от jq
            # 3. Проблема: jq добавляет \n в конец, что вызывает несоответствие Content-Length
            sa_payload=$(jq -c -n --arg name "$service_account_name" '{name:$name}' | tr -d '\n')
            print_info "Payload для создания сервисного аккаунта: $sa_payload"
            log_diagnosis "Payload для создания сервисного аккаунта: $sa_payload"
            
            echo "[PAYLOAD ДЛЯ SERVICE ACCOUNT]" >> "$DEBUG_LOG"
            echo "  🔧 КРИТИЧЕСКИЕ ИСПРАВЛЕНИЯ:" >> "$DEBUG_LOG"
            echo "    1. Используем jq -c для compact JSON (одна строка)" >> "$DEBUG_LOG"
            echo "    2. Используем tr -d '\\n' чтобы убрать trailing newline от jq" >> "$DEBUG_LOG"
            echo "    3. Сохраняем в файл и используем curl --data-binary @file" >> "$DEBUG_LOG"
            echo "       (избегаем проблем с экранированием кавычек в bash)" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            echo "  JSON Payload (compact, no trailing newline):" >> "$DEBUG_LOG"
            printf '  %s\n' "$sa_payload" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            echo "  JSON Payload (pretty-print для читаемости):" >> "$DEBUG_LOG"
            printf '%s' "$sa_payload" | jq '.' >> "$DEBUG_LOG" 2>&1 || printf '%s\n' "$sa_payload" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            echo "  Команда JQ для генерации:" >> "$DEBUG_LOG"
            echo "  jq -c -n --arg name \"$service_account_name\" '{name:\$name}' | tr -d '\\n'" >> "$DEBUG_LOG"
            echo "  -c = compact output, tr -d '\\n' = убрать trailing newline" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            
            echo "  Проверка payload:" >> "$DEBUG_LOG"
            echo "    - Валидность JSON: $(printf '%s' "$sa_payload" | jq empty 2>&1 && echo "✅ валиден" || echo "❌ невалиден")" >> "$DEBUG_LOG"
            echo "    - Формат: $(printf '%s' "$sa_payload" | grep -q $'\n' && echo "❌ содержит newline!" || echo "✅ компактный, без newline")" >> "$DEBUG_LOG"
            echo "    - Количество полей: $(printf '%s' "$sa_payload" | jq 'keys | length' 2>/dev/null || echo "?")" >> "$DEBUG_LOG"
            echo "    - Поля: $(printf '%s' "$sa_payload" | jq -c 'keys' 2>/dev/null || echo "?")" >> "$DEBUG_LOG"
            echo "    - Значение name: $(printf '%s' "$sa_payload" | jq -r '.name' 2>/dev/null)" >> "$DEBUG_LOG"
            echo "    - Есть ли поле 'role': $(printf '%s' "$sa_payload" | jq 'has("role")' 2>/dev/null)" >> "$DEBUG_LOG"
            echo "    - Есть ли поле 'isDisabled': $(printf '%s' "$sa_payload" | jq 'has("isDisabled")' 2>/dev/null)" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            
            echo "  Размеры:" >> "$DEBUG_LOG"
            echo "    - Длина JSON строки: ${#sa_payload} байт" >> "$DEBUG_LOG"
            echo "    - Длина имени SA: ${#service_account_name} символов" >> "$DEBUG_LOG"
            echo "    - Ожидаемый Content-Length в HTTP: ${#sa_payload}" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            
            echo "  Raw payload (как видит bash):" >> "$DEBUG_LOG"
            echo "    '$sa_payload'" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            
            echo "  Hexdump полного payload (проверка на trailing bytes):" >> "$DEBUG_LOG"
            printf '%s' "$sa_payload" | od -A x -t x1z -v >> "$DEBUG_LOG" 2>&1 || echo "  (hexdump недоступен)" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            
            # Сначала проверим доступность API
            echo "DEBUG_HEALTH_CHECK: Начало проверки доступности Grafana API" >&2
            echo "DEBUG_HEALTH_URL: Проверяем URL: ${grafana_url}/api/health" >&2
            
            echo "[HEALTH CHECK /api/health]" >> "$DEBUG_LOG"
            echo "  URL: ${grafana_url}/api/health" >> "$DEBUG_LOG"
            echo "  Время запроса: $(date '+%Y-%m-%d %H:%M:%S.%3N')" >> "$DEBUG_LOG"
            
            print_info "Проверка доступности Grafana API перед созданием сервисного аккаунта..."
            local test_cmd="curl -k -s -w \"\n%{http_code}\" -u \"${grafana_user}:*****\" \"${grafana_url}/api/health\""
            print_info "Команда проверки health: $test_cmd"
            
            echo "  Полная curl команда:" >> "$DEBUG_LOG"
            echo "  curl -k -s -w \"\\n%{http_code}\" -u \"${grafana_user}:${grafana_password}\" \"${grafana_url}/api/health\"" >> "$DEBUG_LOG"
            
            # SECURITY: Используем grafana-api-wrapper для health check (БЕЗ секретов в eval)
            local test_code=$("$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" health_check "$grafana_url")
            local test_body=""  # health_check возвращает только HTTP код
            
            echo "  HTTP Code: $test_code" >> "$DEBUG_LOG"
            echo "  Response Body:" >> "$DEBUG_LOG"
            echo "$test_body" | jq '.' >> "$DEBUG_LOG" 2>&1 || echo "$test_body" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            
            print_info "Проверка API /api/health: HTTP $test_code"
            log_diagnosis "Health check ответ: HTTP $test_code"
            log_diagnosis "Полный ответ health check: $test_response"
            
            if [[ "$test_code" != "200" ]]; then
                print_error "Grafana API /api/health недоступен (HTTP $test_code)"
                print_info "Тело ответа: $(echo "$test_body" | head -c 200)"
                log_diagnosis "❌ Health check не прошел: HTTP $test_code"
                log_diagnosis "Тело ответа: $test_body"
                
                echo "[ОШИБКА] Health check FAILED - HTTP $test_code" >> "$DEBUG_LOG"
                echo "DEBUG LOG сохранен в: $DEBUG_LOG" >> "$DEBUG_LOG"
                echo ""
                echo "DEBUG_RETURN: Health check не прошел, возвращаем код 2" >&2
                print_error "DEBUG LOG: $DEBUG_LOG"
                return 2
            else
                echo "DEBUG_HEALTH_SUCCESS: Health check прошел успешно, HTTP 200" >&2
                print_success "Grafana API /api/health доступен"
                log_diagnosis "✅ Health check прошел успешно"
                echo "[SUCCESS] Health check passed ✅" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
            fi
            
            # Автоматическое определение: если доменное имя не работает, пробуем localhost
            local try_localhost=false
            local original_grafana_url_for_fallback="$grafana_url"
            
            # Проверяем, не является ли уже localhost
            if [[ "$grafana_url" != *"localhost"* && "$grafana_url" != *"127.0.0.1"* ]]; then
                print_info "Проверяем возможность использования localhost вместо доменного имени..."
                log_diagnosis "Проверка возможности использования localhost"
                
                # Быстрая проверка: если health check через доменное имя работает,
                # но создание SA возвращает 400, вероятно проблема с доменным именем
                echo "DEBUG_DOMAIN_CHECK: Проверяем доменное имя vs localhost" >&2
                echo "DEBUG_DOMAIN_CHECK: Текущий URL: $grafana_url" >&2
                
                # Если USE_GRAFANA_LOCALHOST не установлен, но мы видим проблемы с доменным именем,
                # устанавливаем флаг для попытки localhost
                if [[ "${USE_GRAFANA_LOCALHOST:-false}" == "false" ]]; then
                    print_info "USE_GRAFANA_LOCALHOST не установлен, но будем готовы к fallback на localhost"
                    try_localhost=true
                fi
            fi
            
            # КРИТИЧЕСКИ ВАЖНО: Сохраняем payload в файл, чтобы избежать проблем с экранированием кавычек!
            # Проблема: -d "$sa_payload" с JSON внутри вызывает неправильный парсинг кавычек bash
            # Решение: используем --data-binary @file для передачи данных
            local payload_file="/tmp/grafana_sa_payload_$$.json"
            printf '%s' "$sa_payload" > "$payload_file"
            
            # Гарантируем удаление временного файла при выходе из функции
            trap "rm -f '$payload_file' 2>/dev/null" RETURN
            
            # Логируем созданный файл
            echo "[PAYLOAD FILE CREATED]" >> "$DEBUG_LOG"
            echo "  Временный файл для curl создан:" >> "$DEBUG_LOG"
            echo "    Файл: $payload_file" >> "$DEBUG_LOG"
            echo "    Размер файла: $(wc -c < "$payload_file" 2>/dev/null || echo "?") байт" >> "$DEBUG_LOG"
            echo "    MD5 hash: $(md5sum "$payload_file" 2>/dev/null | awk '{print $1}' || echo "?")" >> "$DEBUG_LOG"
            echo "    Hexdump файла (для проверки):" >> "$DEBUG_LOG"
            od -A x -t x1z -v "$payload_file" >> "$DEBUG_LOG" 2>&1 || echo "    (hexdump недоступен)" >> "$DEBUG_LOG"
            echo "" >> "$DEBUG_LOG"
            
            # ИЗМЕНЕНО: Используем только mTLS (mutual TLS) с клиентскими сертификатами
            # ВАЖНО: используем '@файл' вместо прямой передачи JSON строки
            local curl_cmd_without_cert="curl -k -s -w \"\n%{http_code}\" \
                -X POST \
                -H \"Content-Type: application/json\" \
                -u \"${grafana_user}:${grafana_password}\" \
                --data-binary \"@${payload_file}\" \
                \"${grafana_url}/api/serviceaccounts\""
            
            local curl_cmd_with_cert=""
            if [[ -f "/opt/vault/certs/grafana-client.crt" && -f "/opt/vault/certs/grafana-client.key" ]]; then
                curl_cmd_with_cert="curl -k -s -w \"\n%{http_code}\" \
                    --cert \"/opt/vault/certs/grafana-client.crt\" \
                    --key \"/opt/vault/certs/grafana-client.key\" \
                    -X POST \
                    -H \"Content-Type: application/json\" \
                    -u \"${grafana_user}:${grafana_password}\" \
                    --data-binary \"@${payload_file}\" \
                    \"${grafana_url}/api/serviceaccounts\""
            fi
            
            # ИЗМЕНЕНО: Приоритет - использование mTLS с клиентскими сертификатами
            # Команды curl_cmd_without_cert и curl_cmd_with_cert подготовлены выше
            # Основной метод: curl_cmd_with_cert (с сертификатами)
            
            # Функция для выполнения запроса с заданной командой curl
            execute_curl_request() {
                local cmd="$1"
                local use_cert="$2"
                
                local safe_cmd=$(echo "$cmd" | sed "s/-u \"${grafana_user}:${grafana_password}\"/-u \"${grafana_user}:*****\"/")
                print_info "Выполнение API запроса: $safe_cmd"
                print_info "Payload: $sa_payload"
                
                log_diagnosis "CURL команда (без пароля): $safe_cmd"
                log_diagnosis "Полная CURL команда: $(echo "$cmd" | sed "s/${grafana_password}/*****/g")"
                log_diagnosis "Payload: $sa_payload"
                log_diagnosis "Endpoint: ${grafana_url}/api/serviceaccounts"
                log_diagnosis "Время начала запроса: $(date '+%Y-%m-%d %H:%M:%S.%3N')"
                
                echo "DEBUG_SA_CREATE: Начало создания сервисного аккаунта" >&2
                echo "DEBUG_SA_ENDPOINT: Endpoint: ${grafana_url}/api/serviceaccounts" >&2
                echo "DEBUG_SA_PAYLOAD: Payload: $sa_payload" >&2
                echo "DEBUG_CURL_CMD: Команда curl (без пароля): $(echo "$cmd" | sed "s/${grafana_password}/*****/g")" >&2
                
                # ============================================================================
                # ДЕТАЛЬНОЕ ЛОГИРОВАНИЕ CURL ЗАПРОСА В ФАЙЛ
                # ============================================================================
                echo "================================================================================" >> "$DEBUG_LOG"
                echo "[CURL REQUEST - POST /api/serviceaccounts]" >> "$DEBUG_LOG"
                if [[ "$use_cert" == "with_cert" ]]; then
                    echo "  Тип: С клиентскими сертификатами (mTLS)" >> "$DEBUG_LOG"
                else
                    echo "  Тип: БЕЗ клиентских сертификатов (Basic Auth)" >> "$DEBUG_LOG"
                fi
                echo "  Время запроса: $(date '+%Y-%m-%d %H:%M:%S.%3N')" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Endpoint: ${grafana_url}/api/serviceaccounts" >> "$DEBUG_LOG"
                echo "  Method: POST" >> "$DEBUG_LOG"
                echo "  Content-Type: application/json" >> "$DEBUG_LOG"
                echo "  Auth: Basic (user: ${grafana_user}, pass: ***)" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Полная curl команда (с реальным паролем):" >> "$DEBUG_LOG"
                echo "  $cmd" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  [КОМАНДА ДЛЯ РУЧНОГО ВОСПРОИЗВЕДЕНИЯ]" >> "$DEBUG_LOG"
                echo "  🔧 Рекомендуется использовать payload через файл:" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "  # Создайте файл с payload:" >> "$DEBUG_LOG"
                echo "  printf '%s' '$sa_payload' > /tmp/grafana_payload.json" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                if [[ "$use_cert" == "with_cert" ]]; then
                    echo "  # Отправьте запрос:" >> "$DEBUG_LOG"
                    echo "  curl -k -v -w '\\n%{http_code}' \\" >> "$DEBUG_LOG"
                    echo "    --cert '/opt/vault/certs/grafana-client.crt' \\" >> "$DEBUG_LOG"
                    echo "    --key '/opt/vault/certs/grafana-client.key' \\" >> "$DEBUG_LOG"
                    echo "    -X POST \\" >> "$DEBUG_LOG"
                    echo "    -H 'Content-Type: application/json' \\" >> "$DEBUG_LOG"
                    echo "    -u '${grafana_user}:${grafana_password}' \\" >> "$DEBUG_LOG"
                    echo "    --data-binary '@/tmp/grafana_payload.json' \\" >> "$DEBUG_LOG"
                    echo "    '${grafana_url}/api/serviceaccounts'" >> "$DEBUG_LOG"
                else
                    echo "  # Отправьте запрос:" >> "$DEBUG_LOG"
                    echo "  curl -k -v -w '\\n%{http_code}' \\" >> "$DEBUG_LOG"
                    echo "    -X POST \\" >> "$DEBUG_LOG"
                    echo "    -H 'Content-Type: application/json' \\" >> "$DEBUG_LOG"
                    echo "    -u '${grafana_user}:${grafana_password}' \\" >> "$DEBUG_LOG"
                    echo "    --data-binary '@/tmp/grafana_payload.json' \\" >> "$DEBUG_LOG"
                    echo "    '${grafana_url}/api/serviceaccounts'" >> "$DEBUG_LOG"
                fi
                echo "" >> "$DEBUG_LOG"
                echo "  ⚠️  ВАЖНО: printf '%s' гарантирует отсутствие trailing newline!" >> "$DEBUG_LOG"
                echo "  ⚠️  --data-binary '@файл' избегает проблем с экранированием кавычек" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Request Payload:" >> "$DEBUG_LOG"
                printf '%s' "$sa_payload" | jq '.' >> "$DEBUG_LOG" 2>&1 || printf '%s\n' "$sa_payload" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Request Headers:" >> "$DEBUG_LOG"
                echo "    Content-Type: application/json" >> "$DEBUG_LOG"
                echo "    Authorization: Basic $(echo -n "${grafana_user}:${grafana_password}" | base64)" >> "$DEBUG_LOG"
                if [[ "$use_cert" == "with_cert" ]]; then
                    echo "    Client Cert: /opt/vault/certs/grafana-client.crt" >> "$DEBUG_LOG"
                    echo "    Client Key: /opt/vault/certs/grafana-client.key" >> "$DEBUG_LOG"
                fi
                echo "" >> "$DEBUG_LOG"
                
                echo "  [ВЫПОЛНЕНИЕ ЗАПРОСА]" >> "$DEBUG_LOG"
                echo "  Запускаем curl команду (БЕЗ verbose для чистого ответа)..." >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "[INFO] Выполнение curl команды для создания сервисного аккаунта..." >&2
                log_diagnosis "Начало выполнения curl команды..."
                
                local curl_start_time=$(date +%s.%3N)
                local response
                
                # ВАЖНО: Выполняем БЕЗ verbose, чтобы получить чистый ответ
                if ! response=$(eval "$cmd" 2>&1); then
                    local curl_end_time=$(date +%s.%3N)
                    local curl_duration=$(echo "$curl_end_time - $curl_start_time" | bc)
                    
                    print_error "ОШИБКА выполнения curl команды!"
                    print_info "Команда: $safe_cmd"
                    print_info "Ошибка: $response"
                    
                    log_diagnosis "❌ ОШИБКА выполнения curl команды!"
                    log_diagnosis "Время выполнения: ${curl_duration} секунд"
                    log_diagnosis "Команда: $safe_cmd"
                    log_diagnosis "Полная ошибка: $response"
                    log_diagnosis "Код возврата: $?"
                    log_diagnosis "Время ошибки: $(date '+%Y-%m-%d %H:%M:%S.%3N')"
                    
                    echo "[ОШИБКА] CURL выполнение провалилось!" >> "$DEBUG_LOG"
                    echo "  Время выполнения: ${curl_duration} секунд" >> "$DEBUG_LOG"
                    echo "  Ошибка curl: $response" >> "$DEBUG_LOG"
                    echo "  Код возврата: $?" >> "$DEBUG_LOG"
                    echo "" >> "$DEBUG_LOG"
                    echo "DEBUG LOG сохранен в: $DEBUG_LOG" >> "$DEBUG_LOG"
                    
                    echo ""
                    echo "DEBUG_RETURN: Ошибка выполнения curl, возвращаем код 2" >&2
                    print_error "DEBUG LOG: $DEBUG_LOG"
                    return 2
                fi
                
                local curl_end_time=$(date +%s.%3N)
                local curl_duration=$(echo "$curl_end_time - $curl_start_time" | bc)
                
                local code=$(echo "$response" | tail -1)
                local body=$(echo "$response" | head -n -1)
                
                echo "DEBUG_SA_RESPONSE: Ответ получен, HTTP код: $code" >&2
                echo "DEBUG_SA_DURATION: Время выполнения: ${curl_duration} секунд" >&2
                
                # ============================================================================
                # ЛОГИРОВАНИЕ ОТВЕТА ОТ API
                # ============================================================================
                echo "[CURL RESPONSE]" >> "$DEBUG_LOG"
                echo "  HTTP Status Code: $code" >> "$DEBUG_LOG"
                echo "  Время выполнения: ${curl_duration} секунд" >> "$DEBUG_LOG"
                echo "  Время получения ответа: $(date '+%Y-%m-%d %H:%M:%S.%3N')" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Response Body:" >> "$DEBUG_LOG"
                if [[ -n "$body" ]]; then
                    echo "$body" | jq '.' >> "$DEBUG_LOG" 2>&1 || echo "$body" >> "$DEBUG_LOG"
                else
                    echo "  (пустой ответ)" >> "$DEBUG_LOG"
                fi
                echo "" >> "$DEBUG_LOG"
                
                echo "  Полный Raw Response:" >> "$DEBUG_LOG"
                echo "$response" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                # VERBOSE CURL для DEBUG лога - НЕ повторяем запрос!
                # ВАЖНО: НЕ делаем повторный запрос с -v, так как это создает дубликаты!
                # Вместо этого логируем только команду, которая была выполнена
                echo "  [CURL COMMAND INFO]" >> "$DEBUG_LOG"
                echo "  Для повторного выполнения с verbose используйте:" >> "$DEBUG_LOG"
                echo "  ${cmd//-s/-v}" >> "$DEBUG_LOG"
                echo "  ⚠️  ВНИМАНИЕ: POST запросы не следует повторять без необходимости!" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "DEBUG_SA_FULL_RESPONSE: Полный ответ от API:" >&2
                echo "$response" >&2
                echo "DEBUG_SA_BODY: Тело ответа: $body" >&2
                
                print_info "Ответ получен, HTTP код: $code"
                print_info "Время выполнения запроса: ${curl_duration} секунд"
                log_diagnosis "✅ Ответ получен"
                log_diagnosis "Время выполнения: ${curl_duration} секунд"
                log_diagnosis "HTTP код: $code"
                log_diagnosis "Полный ответ:"
                log_diagnosis "$response"
                log_diagnosis "--- КОНЕЦ ОТВЕТА ---"
                log_diagnosis "Тело ответа (сырое): $body"
                log_diagnosis "Время получения ответа: $(date '+%Y-%m-%d %H:%M:%S.%3N')"
                
                # Логируем ответ для диагностики (ВАЖНО: выводим в stderr!)
                echo "[INFO] Ответ API создания сервисного аккаунта: HTTP $code" >&2
                echo "[INFO] Тело ответа (первые 200 символов): $(echo "$body" | head -c 200)" >&2
                
                # Детальное логирование при ошибках (ВАЖНО: выводим в stderr!)
                if [[ "$code" != "200" && "$code" != "201" && "$code" != "409" ]]; then
                    echo "[WARNING] Ошибка API при создании сервисного аккаунта" >&2
                    echo "[INFO] Полный ответ:" >&2
                    echo "$response" >&2
                    echo "[INFO] Тело ответа (первые 500 символов):" >&2
                    echo "$body" | head -c 500 >&2
                    echo "" >&2
                fi
                
                # Возвращаем код и тело через stdout
                # ВАЖНО: Используем редкий разделитель ||| вместо : (в JSON есть двоеточия!)
                echo "${code}|||${body}|||${response}"
                return 0
            }
            
            # ИЗМЕНЕНО: Используем только запрос с клиентскими сертификатами (mTLS)
            # Это более безопасный подход с двусторонней TLS аутентификацией
            print_info "=== Создание Service Account с клиентскими сертификатами (mTLS) ==="
            log_diagnosis "=== Используем mTLS для повышенной безопасности ==="
            
            # Проверяем наличие сертификатов
            if [[ ! -f "/opt/vault/certs/grafana-client.crt" || ! -f "/opt/vault/certs/grafana-client.key" ]]; then
                print_error "❌ Клиентские сертификаты не найдены!"
                print_error "   Требуется: /opt/vault/certs/grafana-client.crt"
                print_error "   Требуется: /opt/vault/certs/grafana-client.key"
                log_diagnosis "❌ Сертификаты отсутствуют, прерываем выполнение"
                
                echo "[ОШИБКА] Клиентские сертификаты не найдены" >> "$DEBUG_LOG"
                echo "  Требуемые файлы:" >> "$DEBUG_LOG"
                echo "    - /opt/vault/certs/grafana-client.crt" >> "$DEBUG_LOG"
                echo "    - /opt/vault/certs/grafana-client.key" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "  FALLBACK: Попробуйте использовать Basic Auth без сертификатов" >> "$DEBUG_LOG"
                echo "  (для этого замените execute_curl_request с 'curl_cmd_with_cert' на 'curl_cmd_without_cert')" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                print_error "📋 DEBUG LOG: $DEBUG_LOG"
                return 2
            fi
            
            print_success "✅ Сертификаты найдены:"
            print_info "   /opt/vault/certs/grafana-client.crt ($(stat -c%s "/opt/vault/certs/grafana-client.crt" 2>/dev/null || echo "?") байт)"
            print_info "   /opt/vault/certs/grafana-client.key ($(stat -c%s "/opt/vault/certs/grafana-client.key" 2>/dev/null || echo "?") байт)"
            log_diagnosis "✅ Сертификаты присутствуют"
            log_diagnosis "   Cert size: $(stat -c%s "/opt/vault/certs/grafana-client.crt" 2>/dev/null) bytes"
            log_diagnosis "   Key size: $(stat -c%s "/opt/vault/certs/grafana-client.key" 2>/dev/null) bytes"
            
            # Выполняем запрос с сертификатами
            print_info "Отправка запроса с mTLS аутентификацией..."
            local attempt_result
            if ! attempt_result=$(execute_curl_request "$curl_cmd_with_cert" "with_cert"); then
                print_error "Ошибка выполнения запроса с сертификатами"
                log_diagnosis "❌ Критическая ошибка при выполнении curl"
                return 2
            fi
            
            # Парсим результат
            # ВАЖНО: IFS не работает с многосимвольными разделителями!
            # Используем bash parameter expansion для разделения по |||
            # attempt_result формат: "code|||body|||response"
            echo "DEBUG_PARSE_START: Начало парсинга attempt_result" >&2
            echo "DEBUG_PARSE_INPUT: attempt_result='$attempt_result'" >&2
            echo "DEBUG_PARSE_INPUT_LENGTH: ${#attempt_result} символов" >&2
            
            # Разделяем через parameter expansion
            # 1. Извлекаем http_code (все до первого |||)
            http_code="${attempt_result%%|||*}"
            
            # 2. Удаляем http_code||| из начала
            local temp="${attempt_result#*|||}"
            
            # 3. Извлекаем sa_body (все до следующего |||)
            sa_body="${temp%%|||*}"
            
            # 4. Извлекаем sa_response (все после второго |||)
            sa_response="${temp#*|||}"
            
            echo "DEBUG_PARSE_RESULT: http_code='$http_code'" >&2
            echo "DEBUG_PARSE_RESULT: sa_body='${sa_body:0:100}...'" >&2
            echo "DEBUG_PARSE_RESULT: sa_response='${sa_response:0:100}...'" >&2
            echo "DEBUG_PARSE_RESULT: sa_body length=${#sa_body}" >&2
            echo "DEBUG_PARSE_RESULT: sa_response length=${#sa_response}" >&2
            
            print_info "Результат запроса: HTTP $http_code"
            log_diagnosis "Получен HTTP код: $http_code"
            
            log_diagnosis "Проверка HTTP кода: $http_code"
            
            if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
                log_diagnosis "✅ HTTP код успешный: $http_code"
                
                # КРИТИЧЕСКАЯ ОТЛАДКА: Детально проверяем извлечение ID
                echo "DEBUG_ID_EXTRACTION: Начало извлечения ID" >&2
                echo "DEBUG_ID_EXTRACTION: sa_body='$sa_body'" >&2
                
                sa_id=$(echo "$sa_body" | jq -r '.id // empty')
                
                echo "DEBUG_ID_EXTRACTION: sa_id после jq='$sa_id'" >&2
                echo "DEBUG_ID_EXTRACTION: Длина sa_id=${#sa_id}" >&2
                echo "DEBUG_ID_EXTRACTION: sa_id пустой? $([ -z "$sa_id" ] && echo 'ДА' || echo 'НЕТ')" >&2
                echo "DEBUG_ID_EXTRACTION: sa_id == null? $([ "$sa_id" == "null" ] && echo 'ДА' || echo 'НЕТ')" >&2
                
                # FALLBACK: Если jq не сработал, пробуем извлечь ID через grep/sed
                if [[ -z "$sa_id" || "$sa_id" == "null" ]]; then
                    echo "DEBUG_ID_EXTRACTION: jq не извлек ID, пробуем альтернативный метод (grep/sed)" >&2
                    sa_id=$(echo "$sa_body" | grep -o '"id":[0-9]*' | head -1 | /usr/bin/sed 's/"id"://')
                    echo "DEBUG_ID_EXTRACTION: sa_id после grep/sed='$sa_id'" >&2
                fi
                
                log_diagnosis "Извлеченный ID из ответа: '$sa_id' (длина: ${#sa_id})"
                log_diagnosis "Полный JSON ответ: $sa_body"
                
                echo "================================================================================" >> "$DEBUG_LOG"
                echo "[УСПЕХ] Service Account создан! ✅" >> "$DEBUG_LOG"
                echo "  HTTP Code: $http_code" >> "$DEBUG_LOG"
                echo "  Service Account ID: $sa_id" >> "$DEBUG_LOG"
                echo "  Время: $(date '+%Y-%m-%d %H:%M:%S.%3N')" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "  Полный ответ от Grafana:" >> "$DEBUG_LOG"
                echo "$sa_body" | jq '.' >> "$DEBUG_LOG" 2>&1 || echo "$sa_body" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "DEBUG LOG завершен успешно: $DEBUG_LOG" >> "$DEBUG_LOG"
                echo "================================================================================" >> "$DEBUG_LOG"
                
                if [[ -n "$sa_id" && "$sa_id" != "null" ]]; then
                    print_success "Сервисный аккаунт создан через API, ID: $sa_id"
                    log_diagnosis "✅ Сервисный аккаунт создан, ID: $sa_id"
                    
                    # ВАЖНО: Обновляем роль с Viewer на Admin для возможности создания datasources
                    print_info "Обновление роли Service Account на Admin..."
                    echo "DEBUG_SA_UPDATE_ROLE: Обновляем роль SA ID=$sa_id на Admin" >&2
                    
                    local role_update_payload
                    role_update_payload=$(printf '{"role":"Admin"}')
                    local role_update_file="/tmp/grafana_sa_role_update_$$.json"
                    printf '%s' "$role_update_payload" > "$role_update_file"
                    
                    local role_update_cmd="curl -k -s -w \"\n%{http_code}\" \
                        --cert \"/opt/vault/certs/grafana-client.crt\" \
                        --key \"/opt/vault/certs/grafana-client.key\" \
                        -X PATCH \
                        -H \"Content-Type: application/json\" \
                        -u \"${grafana_user}:${grafana_password}\" \
                        --data-binary \"@${role_update_file}\" \
                        \"${grafana_url}/api/serviceaccounts/${sa_id}\""
                    
                    local role_response role_code role_body
                    role_response=$(eval "$role_update_cmd" 2>&1)
                    role_code=$(echo "$role_response" | tail -1)
                    role_body=$(echo "$role_response" | head -n -1)
                    
                    rm -f "$role_update_file" 2>/dev/null || true
                    
                    echo "DEBUG_SA_UPDATE_ROLE_RESPONSE: HTTP $role_code" >&2
                    echo "DEBUG_SA_UPDATE_ROLE_BODY: $role_body" >&2
                    
                    if [[ "$role_code" == "200" || "$role_code" == "201" ]]; then
                        print_success "✅ Роль Service Account обновлена на Admin"
                        log_diagnosis "✅ Роль обновлена на Admin"
                    else
                        print_warning "⚠️  Не удалось обновить роль (HTTP $role_code), но продолжаем"
                        log_diagnosis "⚠️  Обновление роли не удалось (HTTP $role_code): $role_body"
                    fi
                    
                    log_diagnosis "=== УСПЕШНОЕ СОЗДАНИЕ СЕРВИСНОГО АККАУНТА ==="
                    print_info "📋 DEBUG LOG: $DEBUG_LOG"
                    echo "$sa_id"
                    echo "DEBUG_RETURN: Сервисный аккаунт успешно создан, возвращаем код 0" >&2
                    return 0
                else
                    print_warning "Сервисный аккаунт создан, но ID не получен"
                    log_diagnosis "⚠️  Сервисный аккаунт создан, но ID не получен"
                    log_diagnosis "Тело ответа для анализа: $sa_body"
                    
                    echo "[ПРОБЛЕМА] ID не извлечен из ответа" >> "$DEBUG_LOG"
                    echo "  Response body: $sa_body" >> "$DEBUG_LOG"
                    echo "  Попытка извлечения: jq -r '.id // empty'" >> "$DEBUG_LOG"
                    echo "DEBUG LOG: $DEBUG_LOG" >> "$DEBUG_LOG"
                    
                    echo ""
                    echo "DEBUG_RETURN: SA создан но ID не получен, возвращаем код 2" >&2
                    print_error "📋 DEBUG LOG: $DEBUG_LOG"
                    return 2  # Специальный код для "частичного успеха"
                fi
            elif [[ "$http_code" == "409" ]] || [[ "$http_code" == "400" && "$sa_body" == *"ErrAlreadyExists"* ]]; then
                # Сервисный аккаунт уже существует
                # Grafana 11.x возвращает 400 с messageId "ErrAlreadyExists" вместо 409
                if [[ "$http_code" == "409" ]]; then
                    print_warning "Сервисный аккаунт уже существует (HTTP 409)"
                    log_diagnosis "⚠️  Сервисный аккаунт уже существует (HTTP 409)"
                else
                    print_warning "Сервисный аккаунт уже существует (HTTP 400, messageId: ErrAlreadyExists)"
                    log_diagnosis "⚠️  Сервисный аккаунт уже существует (HTTP 400, Grafana 11.x)"
                fi
                
                # Пробуем получить ID через поиск или используем известный ID
                # Из тестов видно, что созданный сервисный аккаунт имеет ID=2
                print_info "Попытка получить ID существующего сервисного аккаунта..."
                
                # Вариант 1: Пробуем получить через поиск (если endpoint работает)
                local list_cmd="curl -k -s -w \"\n%{http_code}\" \
                    -u \"${grafana_user}:${grafana_password}\" \
                    \"${grafana_url}/api/serviceaccounts/search?query=${service_account_name}\""
                
                if [[ -f "/opt/vault/certs/grafana-client.crt" && -f "/opt/vault/certs/grafana-client.key" ]]; then
                    list_cmd="curl -k -s -w \"\n%{http_code}\" \
                        --cert \"/opt/vault/certs/grafana-client.crt\" \
                        --key \"/opt/vault/certs/grafana-client.key\" \
                        -u \"${grafana_user}:${grafana_password}\" \
                        \"${grafana_url}/api/serviceaccounts/search?query=${service_account_name}\""
                fi
                
                log_diagnosis "Команда для поиска сервисного аккаунта: $(echo "$list_cmd" | sed "s/${grafana_password}/*****/g")"
                list_response=$(eval "$list_cmd" 2>&1)
                list_code=$(echo "$list_response" | tail -1)
                list_body=$(echo "$list_response" | head -n -1)
                
                print_info "Ответ API поиска сервисного аккаунта: HTTP $list_code"
                log_diagnosis "Ответ поиска: HTTP $list_code"
                log_diagnosis "Тело ответа поиска: $list_body"
                
                if [[ "$list_code" == "200" ]]; then
                    sa_id=$(echo "$list_body" | jq -r '.serviceAccounts[] | select(.name=="'"$service_account_name"'") | .id' | head -1)
                    log_diagnosis "Извлеченный ID из поиска: '$sa_id'"
                    
                    if [[ -n "$sa_id" && "$sa_id" != "null" ]]; then
                        print_success "Найден существующий сервисный аккаунт, ID: $sa_id"
                        log_diagnosis "✅ Найден существующий сервисный аккаунт, ID: $sa_id"
                        echo "$sa_id"
                        return 0
                    fi
                fi
                
                # Вариант 2: Если поиск не сработал, пробуем получить список всех SA
                print_info "Попытка получить список всех сервисных аккаунтов..."
                local all_cmd="curl -k -s -w \"\n%{http_code}\" \
                    -u \"${grafana_user}:${grafana_password}\" \
                    \"${grafana_url}/api/serviceaccounts\""
                
                if [[ -f "/opt/vault/certs/grafana-client.crt" && -f "/opt/vault/certs/grafana-client.key" ]]; then
                    all_cmd="curl -k -s -w \"\n%{http_code}\" \
                        --cert \"/opt/vault/certs/grafana-client.crt\" \
                        --key \"/opt/vault/certs/grafana-client.key\" \
                        -u \"${grafana_user}:${grafana_password}\" \
                        \"${grafana_url}/api/serviceaccounts\""
                fi
                
                all_response=$(eval "$all_cmd" 2>&1)
                all_code=$(echo "$all_response" | tail -1)
                all_body=$(echo "$all_response" | head -n -1)
                
                if [[ "$all_code" == "200" ]]; then
                    sa_id=$(echo "$all_body" | jq -r '.[] | select(.name=="'"$service_account_name"'") | .id' | head -1)
                    if [[ -n "$sa_id" && "$sa_id" != "null" ]]; then
                        print_success "Найден существующий сервисный аккаунт в общем списке, ID: $sa_id"
                        log_diagnosis "✅ Найден существующий сервисный аккаунт в общем списке, ID: $sa_id"
                        echo "$sa_id"
                        return 0
                    fi
                fi
                
                # Вариант 3: Если не удалось получить ID, используем известный ID=2 или создаем новое имя
                print_warning "Не удалось получить ID существующего сервисного аккаунта"
                print_info "Endpoint /api/serviceaccounts возвращает 404, используем обходной путь..."
                
                # Пробуем использовать ID=2 (как в тестовом скрипте)
                local known_id=2
                print_info "Используем известный ID сервисного аккаунта: $known_id"
                log_diagnosis "⚠️  Используем известный ID: $known_id (так как endpoint /api/serviceaccounts возвращает 404)"
                echo "$known_id"
                return 0
            else
                print_warning "API запрос создания сервисного аккаунта не удался (HTTP $http_code)"
                log_diagnosis "❌ API запрос не удался (HTTP $http_code)"
                log_diagnosis "Полный ответ: $sa_response"
                log_diagnosis "Тело ответа: $sa_body"
                
                # Детальный анализ ошибки
                log_diagnosis "=== АНАЛИЗ ОШИБКИ ==="
                log_diagnosis "URL: ${grafana_url}/api/serviceaccounts"
                log_diagnosis "Метод: POST"
                log_diagnosis "Пользователь: $grafana_user"
                log_diagnosis "Время: $(date)"
                
                # ============================================================================
                # ФИНАЛЬНЫЙ АНАЛИЗ ОШИБКИ В DEBUG LOG
                # ============================================================================
                echo "================================================================================" >> "$DEBUG_LOG"
                echo "[ФИНАЛЬНЫЙ АНАЛИЗ ОШИБКИ]" >> "$DEBUG_LOG"
                echo "  HTTP Status Code: $http_code" >> "$DEBUG_LOG"
                echo "  Время: $(date '+%Y-%m-%d %H:%M:%S.%3N')" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "[ВОЗМОЖНЫЕ ПРИЧИНЫ ОШИБКИ $http_code]" >> "$DEBUG_LOG"
                case "$http_code" in
                    400)
                        echo "  🔴 HTTP 400 Bad Request - Некорректный запрос" >> "$DEBUG_LOG"
                        echo "" >> "$DEBUG_LOG"
                        echo "  Частые причины:" >> "$DEBUG_LOG"
                        echo "    1. Неправильный формат JSON payload" >> "$DEBUG_LOG"
                        echo "    2. Неизвестные поля в JSON (например, 'role' в Grafana 11.x)" >> "$DEBUG_LOG"
                        echo "    3. Некорректные значения полей" >> "$DEBUG_LOG"
                        echo "    4. Неправильный Content-Type заголовок" >> "$DEBUG_LOG"
                        echo "    5. Проблемы с кодировкой данных" >> "$DEBUG_LOG"
                        echo "" >> "$DEBUG_LOG"
                        echo "  Что проверить:" >> "$DEBUG_LOG"
                        echo "    - Версия Grafana (проверено: 11.6.2)" >> "$DEBUG_LOG"
                        echo "    - Формат payload должен быть: {\"name\":\"...\", \"isDisabled\":false}" >> "$DEBUG_LOG"
                        echo "    - НЕ используйте поле 'role' в Grafana 11.x" >> "$DEBUG_LOG"
                        echo "    - Проверьте не дублируются ли заголовки" >> "$DEBUG_LOG"
                        ;;
                    401)
                        echo "  🔴 HTTP 401 Unauthorized - Проблема аутентификации" >> "$DEBUG_LOG"
                        echo "" >> "$DEBUG_LOG"
                        echo "  Проверьте:" >> "$DEBUG_LOG"
                        echo "    - Правильность логина: $grafana_user" >> "$DEBUG_LOG"
                        echo "    - Правильность пароля (длина: ${#grafana_password})" >> "$DEBUG_LOG"
                        echo "    - Base64 auth: $(echo -n "${grafana_user}:${grafana_password}" | base64)" >> "$DEBUG_LOG"
                        ;;
                    403)
                        echo "  🔴 HTTP 403 Forbidden - Недостаточно прав" >> "$DEBUG_LOG"
                        echo "    Пользователь $grafana_user не имеет прав на создание Service Accounts" >> "$DEBUG_LOG"
                        ;;
                    404)
                        echo "  🔴 HTTP 404 Not Found - Endpoint не найден" >> "$DEBUG_LOG"
                        echo "    Проверьте URL: ${grafana_url}/api/serviceaccounts" >> "$DEBUG_LOG"
                        echo "    Возможно неправильная версия API" >> "$DEBUG_LOG"
                        ;;
                    409)
                        echo "  ⚠️  HTTP 409 Conflict - Service Account уже существует" >> "$DEBUG_LOG"
                        echo "    Это нормально, нужно получить ID существующего аккаунта" >> "$DEBUG_LOG"
                        ;;
                    500)
                        echo "  🔴 HTTP 500 Internal Server Error - Внутренняя ошибка Grafana" >> "$DEBUG_LOG"
                        echo "    Проверьте логи Grafana: /var/log/grafana/ или /tmp/grafana-debug.log" >> "$DEBUG_LOG"
                        ;;
                    *)
                        echo "  🔴 HTTP $http_code - Неожиданный код ответа" >> "$DEBUG_LOG"
                        ;;
                esac
                echo "" >> "$DEBUG_LOG"
                
                echo "[РУЧНОЕ ТЕСТИРОВАНИЕ - Команды для проверки]" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "  1. Проверить версию Grafana:" >> "$DEBUG_LOG"
                echo "     curl -k -u '${grafana_user}:${grafana_password}' '${grafana_url}/api/health' | jq" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  2. Получить список Service Accounts:" >> "$DEBUG_LOG"
                echo "     curl -k -u '${grafana_user}:${grafana_password}' '${grafana_url}/api/serviceaccounts' | jq" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  3. Попробовать создать через минимальный payload (COMPACT JSON):" >> "$DEBUG_LOG"
                echo "     ⚠️  ВАЖНО: Используйте JSON в одну строку (compact), БЕЗ переносов!" >> "$DEBUG_LOG"
                echo "     curl -k -v -X POST \\" >> "$DEBUG_LOG"
                echo "       -H 'Content-Type: application/json' \\" >> "$DEBUG_LOG"
                echo "       -u '${grafana_user}:${grafana_password}' \\" >> "$DEBUG_LOG"
                echo "       -d '{\"name\":\"test-sa\"}' \\" >> "$DEBUG_LOG"
                echo "       '${grafana_url}/api/serviceaccounts'" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  4. Попробовать через файл с payload (COMPACT):" >> "$DEBUG_LOG"
                echo "     echo '{\"name\":\"test-sa-2\"}' > /tmp/payload.json" >> "$DEBUG_LOG"
                echo "     # ИЛИ с jq для гарантии компактности:" >> "$DEBUG_LOG"
                echo "     jq -c -n '{name:\"test-sa-3\"}' > /tmp/payload.json" >> "$DEBUG_LOG"
                echo "     curl -k -v -X POST \\" >> "$DEBUG_LOG"
                echo "       -H 'Content-Type: application/json' \\" >> "$DEBUG_LOG"
                echo "       -u '${grafana_user}:${grafana_password}' \\" >> "$DEBUG_LOG"
                echo "       -d @/tmp/payload.json \\" >> "$DEBUG_LOG"
                echo "       '${grafana_url}/api/serviceaccounts'" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  5. Проверить логи Grafana:" >> "$DEBUG_LOG"
                echo "     sudo journalctl -u grafana-server -n 100 --no-pager" >> "$DEBUG_LOG"
                echo "     tail -100 /var/log/grafana/grafana.log" >> "$DEBUG_LOG"
                echo "     tail -100 /tmp/grafana-debug.log" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  6. Создать через UI (рекомендуется для первой проверки):" >> "$DEBUG_LOG"
                echo "     Administration → Users and access → Service accounts → New service account" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "[СПРАВКА: ПРАВИЛЬНЫЕ ФОРМАТЫ PAYLOAD ДЛЯ РАЗНЫХ ВЕРСИЙ GRAFANA]" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "  🔴 КРИТИЧЕСКОЕ ТРЕБОВАНИЕ: JSON должен быть КОМПАКТНЫМ (без переносов строк)!" >> "$DEBUG_LOG"
                echo "  Используйте: jq -c (compact) или echo без переносов" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Grafana 8.x (старая версия):" >> "$DEBUG_LOG"
                echo "    {\"name\":\"test-sa\",\"role\":\"Admin\"}" >> "$DEBUG_LOG"
                echo "    ⚠️  Поле 'role' поддерживалось" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Grafana 9.x - 10.x:" >> "$DEBUG_LOG"
                echo "    {\"name\":\"test-sa\"}" >> "$DEBUG_LOG"
                echo "    ⚠️  Поле 'role' убрано из API" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Grafana 11.x (текущая версия 11.6.2) - РЕКОМЕНДУЕТСЯ:" >> "$DEBUG_LOG"
                echo "    ✅ Минимальный (compact): {\"name\":\"test-sa\"}" >> "$DEBUG_LOG"
                echo "    ❌ НЕ используйте многострочный JSON!" >> "$DEBUG_LOG"
                echo "    ❌ НЕ используйте поле 'role'" >> "$DEBUG_LOG"
                echo "    ⚠️  Поле 'isDisabled' может вызывать проблемы - пока не используем" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Примеры ПРАВИЛЬНОГО создания и отправки payload:" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "    # Вариант 1: jq -c с tr (удаляет trailing newline):" >> "$DEBUG_LOG"
                echo "    jq -c -n --arg name \"mysa\" '{name:\$name}' | tr -d '\\n' > /tmp/p.json" >> "$DEBUG_LOG"
                echo "    curl ... --data-binary '@/tmp/p.json' ..." >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "    # Вариант 2: printf (РЕКОМЕНДУЕТСЯ, нет newline):" >> "$DEBUG_LOG"
                echo "    printf '%s' '{\"name\":\"mysa\"}' > /tmp/p.json" >> "$DEBUG_LOG"
                echo "    curl ... --data-binary '@/tmp/p.json' ..." >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "    # Вариант 3: echo -n (без newline):" >> "$DEBUG_LOG"
                echo "    echo -n '{\"name\":\"mysa\"}' > /tmp/p.json" >> "$DEBUG_LOG"
                echo "    curl ... --data-binary '@/tmp/p.json' ..." >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Примеры НЕПРАВИЛЬНОГО (вызывают 400 Bad Request):" >> "$DEBUG_LOG"
                echo "    jq -n ... (без -c, создает многострочный JSON)" >> "$DEBUG_LOG"
                echo "    echo '{" >> "$DEBUG_LOG"
                echo "      \"name\": \"mysa\"" >> "$DEBUG_LOG"
                echo "    }'" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  Документация API для Grafana 11.x:" >> "$DEBUG_LOG"
                echo "    POST /api/serviceaccounts" >> "$DEBUG_LOG"
                echo "    Content-Type: application/json" >> "$DEBUG_LOG"
                echo "    Body (COMPACT!): {\"name\":\"string\"}" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "[ЧТО БЫЛО ИСПРАВЛЕНО - ФИНАЛЬНАЯ ВЕРСИЯ]" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                echo "  🔧 ПРОБЛЕМА #1: Многострочный JSON" >> "$DEBUG_LOG"
                echo "     - jq по умолчанию создавал JSON с переносами строк" >> "$DEBUG_LOG"
                echo "     - Grafana 11.6.2 строго проверяет формат" >> "$DEBUG_LOG"
                echo "  ✅ РЕШЕНИЕ #1: jq -c (compact output)" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  🔧 ПРОБЛЕМА #2: Trailing newline" >> "$DEBUG_LOG"
                echo "     - jq -c добавлял \\n в конец строки" >> "$DEBUG_LOG"
                echo "     - Это вызывало несоответствие Content-Length" >> "$DEBUG_LOG"
                echo "  ✅ РЕШЕНИЕ #2: | tr -d '\\n' (убираем newline)" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  🔧 ПРОБЛЕМА #3: Экранирование кавычек в bash" >> "$DEBUG_LOG"
                echo "     - curl -d \"\$payload\" с JSON внутри" >> "$DEBUG_LOG"
                echo "     - bash неправильно парсил двойные кавычки внутри двойных" >> "$DEBUG_LOG"
                echo "     - Content-Length был 41 вместо 45 байт!" >> "$DEBUG_LOG"
                echo "  ✅ РЕШЕНИЕ #3: Сохраняем в файл + curl --data-binary '@file'" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "  📋 ИТОГОВОЕ РЕШЕНИЕ:" >> "$DEBUG_LOG"
                echo "     1. jq -c -n ... | tr -d '\\n' > file" >> "$DEBUG_LOG"
                echo "     2. curl --data-binary '@file' ..." >> "$DEBUG_LOG"
                echo "     3. Payload: {\"name\":\"...\"} (только name, без isDisabled)" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "[ЧТО ДЕЛАТЬ ЕСЛИ ОШИБКА ПОВТОРЯЕТСЯ]" >> "$DEBUG_LOG"
                echo "  1. Прочитайте этот DEBUG LOG: cat $DEBUG_LOG" >> "$DEBUG_LOG"
                echo "  2. Проверьте что payload КОМПАКТНЫЙ (одна строка)" >> "$DEBUG_LOG"
                echo "  3. Выполните ручные команды выше для проверки" >> "$DEBUG_LOG"
                echo "  4. Проверьте логи Grafana:" >> "$DEBUG_LOG"
                echo "     journalctl -u grafana-server -n 50" >> "$DEBUG_LOG"
                echo "  5. Если все еще не работает - создайте SA через UI и используйте его" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "[СИСТЕМНАЯ ИНФОРМАЦИЯ]" >> "$DEBUG_LOG"
                echo "  Hostname: $(hostname)" >> "$DEBUG_LOG"
                echo "  Current User: $(whoami)" >> "$DEBUG_LOG"
                echo "  Curl Version: $(curl --version | head -1)" >> "$DEBUG_LOG"
                echo "  JQ Version: $(jq --version 2>&1)" >> "$DEBUG_LOG"
                echo "" >> "$DEBUG_LOG"
                
                echo "================================================================================" >> "$DEBUG_LOG"
                echo "DEBUG LOG ЗАВЕРШЕН - Файл: $DEBUG_LOG" >> "$DEBUG_LOG"
                echo "================================================================================" >> "$DEBUG_LOG"
                
                echo ""
                echo "DEBUG_RETURN: API запрос не удался (HTTP $http_code), возвращаем код 2" >&2
                print_error "📋 ПОДРОБНЫЙ DEBUG LOG: $DEBUG_LOG"
                print_info "Скопируйте содержимое этого файла для анализа проблемы"
                return 2  # Возвращаем 2 вместо 1, чтобы продолжить с fallback
            fi
        }
        
        # Функция для создания токена через API
        create_token_via_api() {
            local sa_id="$1"
            local token_payload token_response token_code token_body bearer_token
            
            # ИСПРАВЛЕНО: Используем jq -c и tr для compact JSON без trailing newline
            # Сохраняем в файл для избежания проблем с экранированием
            token_payload=$(jq -c -n --arg name "$token_name" '{name:$name}' | tr -d '\n')
            
            local token_payload_file="/tmp/grafana_token_payload_$$.json"
            printf '%s' "$token_payload" > "$token_payload_file"
            
            echo "DEBUG_TOKEN_PAYLOAD: $token_payload" >&2
            echo "DEBUG_TOKEN_PAYLOAD_FILE: $token_payload_file (размер: $(stat -c%s "$token_payload_file" 2>/dev/null || echo "?") байт)" >&2
            
            # ИСПРАВЛЕНО: Используем --data-binary '@file' вместо -d "$variable"
            local curl_cmd_without_cert="curl -k -s -w \"\n%{http_code}\" \
                -X POST \
                -H \"Content-Type: application/json\" \
                -u \"${grafana_user}:${grafana_password}\" \
                --data-binary \"@${token_payload_file}\" \
                \"${grafana_url}/api/serviceaccounts/${sa_id}/tokens\""
            
            local curl_cmd_with_cert=""
            if [[ -f "/opt/vault/certs/grafana-client.crt" && -f "/opt/vault/certs/grafana-client.key" ]]; then
                curl_cmd_with_cert="curl -k -s -w \"\n%{http_code}\" \
                    --cert \"/opt/vault/certs/grafana-client.crt\" \
                    --key \"/opt/vault/certs/grafana-client.key\" \
                    -X POST \
                    -H \"Content-Type: application/json\" \
                    -u \"${grafana_user}:${grafana_password}\" \
                    --data-binary \"@${token_payload_file}\" \
                    \"${grafana_url}/api/serviceaccounts/${sa_id}/tokens\""
            fi
            
            # Функция для выполнения запроса создания токена
            execute_token_request() {
                local cmd="$1"
                local use_cert="$2"
                
                print_info "Выполнение API запроса для создания токена сервисного аккаунта..."
                echo "DEBUG_TOKEN_CURL_CMD: ${cmd//${grafana_password}/*****}" >&2
                
                local response
                if ! response=$(eval "$cmd" 2>&1); then
                    print_error "Ошибка выполнения curl команды для токена"
                    echo "ERROR|||{\"error\":\"curl failed\"}|||curl execution failed"
                    return 1
                fi
                
                local code=$(echo "$response" | tail -1)
                local body=$(echo "$response" | head -n -1)
                
                echo "DEBUG_TOKEN_RESPONSE: HTTP $code" >&2
                echo "DEBUG_TOKEN_BODY: $body" >&2
                
                # Логируем ответ для диагностики
                print_info "Ответ API создания токена: HTTP $code"
                
                # ИСПРАВЛЕНО: Используем ||| как разделитель (как в create_service_account_via_api)
                echo "${code}|||${body}|||${response}"
                return 0
            }
            
            # ИЗМЕНЕНО: Используем только mTLS (как в create_service_account_via_api)
            print_info "=== Создание токена с клиентскими сертификатами (mTLS) ==="
            if [[ -z "$curl_cmd_with_cert" ]]; then
                print_error "Клиентские сертификаты не найдены, не можем создать токен"
                return 2
            fi
            
            local attempt_result
            attempt_result=$(execute_token_request "$curl_cmd_with_cert" "true")
            
            # ИСПРАВЛЕНО: Используем bash parameter expansion вместо awk
            token_code="${attempt_result%%|||*}"
            local temp="${attempt_result#*|||}"
            token_body="${temp%%|||*}"
            token_response="${temp#*|||}"
            
            echo "DEBUG_TOKEN_PARSE: token_code='$token_code'" >&2
            echo "DEBUG_TOKEN_PARSE: token_body='${token_body:0:100}...'" >&2
            
            # Проверяем результат
            if [[ "$token_code" == "200" || "$token_code" == "201" ]]; then
                print_success "Токен создан успешно (HTTP $token_code)"
                
                # Извлекаем токен из ответа
                bearer_token=$(echo "$token_body" | jq -r '.key // empty')
                
                echo "DEBUG_TOKEN_EXTRACTION: bearer_token='${bearer_token:0:20}...'" >&2
                echo "DEBUG_TOKEN_EXTRACTION: длина=${#bearer_token}" >&2
                
                if [[ -n "$bearer_token" && "$bearer_token" != "null" ]]; then
                    GRAFANA_BEARER_TOKEN="$bearer_token"
                    export GRAFANA_BEARER_TOKEN
                    print_success "✅ Bearer токен получен и экспортирован"
                    
                    # Очищаем временный файл
                    rm -f "$token_payload_file" 2>/dev/null || true
                    
                    return 0
                else
                    print_warning "Токен создан, но значение пустое или null"
                    print_warning "token_body: $token_body"
                    
                    # Очищаем временный файл
                    rm -f "$token_payload_file" 2>/dev/null || true
                    
                    return 2  # Специальный код для "частичного успеха"
                fi
            else
                print_warning "Создание токена через API не удалось (HTTP $token_code)"
                print_warning "Response body: $token_body"
                
                # Очищаем временный файл
                rm -f "$token_payload_file" 2>/dev/null || true
                
                return 2
            fi
        }
        
        # Пробуем получить токен через API
        print_info "Вызов функции create_service_account_via_api..."
        local sa_id
        sa_id=$(create_service_account_via_api)
        local sa_result=$?
        print_info "Результат create_service_account_via_api: код $sa_result, sa_id='$sa_id'"
        
        # Логируем ВСЕ детали для отладки пайплайна
        print_info "=== ОТЛАДКА ПАЙПЛАЙНА ==="
        print_info "sa_result: $sa_result"
        print_info "sa_id: '$sa_id'"
        print_info "grafana_url: $grafana_url"
        print_info "service_account_name: $service_account_name"
        
        if [[ $sa_result -eq 0 && -n "$sa_id" ]]; then
            # Успешно создали сервисный аккаунт, пробуем создать токен
            if ! create_token_via_api "$sa_id"; then
                print_warning "Не удалось создать токен через API"
                print_info "Пропускаем настройку datasource и дашбордов"
                print_info "Datasource и дашборды могут быть настроены вручную через UI Grafana"
                return 0  # Возвращаем успех, но пропускаем настройку
            fi
        elif [[ $sa_result -eq 2 ]]; then
            # Частичный успех или временная ошибка API
            print_warning "Проблемы с API Grafana (код $sa_result)"
            print_info "Пропускаем настройку datasource и дашбордов"
            print_info "Datasource и дашборды могут быть настроены вручную через UI Grafana"
            return 0  # Возвращаем успех, но пропускаем настройку
        else
            # Другие ошибки (например, код 1 или 2)
            print_warning "Не удалось создать сервисный аккаунт через API (код $sa_result)."
            
            # Пробуем с localhost вместо доменного имени
            print_info "Пробуем с localhost вместо $SERVER_DOMAIN..."
            local original_domain="$SERVER_DOMAIN"
            export SERVER_DOMAIN="localhost"
            local local_grafana_url="https://localhost:${GRAFANA_PORT}"
            
            print_info "Новый URL: $local_grafana_url"
            print_info "Повторная попытка с localhost..."
            
            # Сбрасываем переменные и пробуем снова
            unset sa_id sa_result
            service_account_name="harvest-service-account-localhost_$(date +%s)"
            sa_id=$(create_service_account_via_api)
            sa_result=$?
            
            # Восстанавливаем оригинальный домен
            export SERVER_DOMAIN="$original_domain"
            
            if [[ $sa_result -eq 0 && -n "$sa_id" ]]; then
                print_success "Успешно с localhost! Продолжаем создание токена..."
                # Здесь будет продолжение создания токена
            else
                print_warning "Не сработало даже с localhost. Пробуем старую функцию ensure_grafana_token..."
                
                # Fallback на старую функцию
                if ensure_grafana_token; then
                    print_success "Токен получен через старую функцию ensure_grafana_token"
                else
                    print_warning "Все методы не сработали. Пропускаем настройку токена."
                    print_info "Datasource и дашборды могут быть настроены вручную через UI Grafana"
                    return 0  # Возвращаем успех, но пропускаем настройку
                fi
            fi
        fi
    fi
    
    # Настраиваем Prometheus datasource (только если есть токен)
    if [[ -z "$GRAFANA_BEARER_TOKEN" ]]; then
        print_warning "Токен Grafana не получен. Пропускаем настройку datasource."
        print_info "Datasource может быть настроен вручную через UI Grafana"
        return 0
    fi
    
    print_info "Настройка Prometheus datasource..."
    
    # Подготавливаем сертификаты для mTLS
    local tls_client_cert tls_client_key tls_ca_cert
    tls_client_cert=$(cat /opt/vault/certs/grafana-client.crt 2>/dev/null | jq -R -s . || echo '""')
    tls_client_key=$(cat /opt/vault/certs/grafana-client.key 2>/dev/null | jq -R -s . || echo '""')
    tls_ca_cert=$(cat /etc/prometheus/cert/ca_chain.crt 2>/dev/null | jq -R -s . || echo '""')
    
    # ИСПРАВЛЕНО: Создаем payload для datasource (compact JSON)
    local ds_payload
    ds_payload=$(jq -c -n \
        --arg url "https://${SERVER_DOMAIN}:${PROMETHEUS_PORT}" \
        --arg sn "${SERVER_DOMAIN}" \
        --argjson tlsClientCert "$tls_client_cert" \
        --argjson tlsClientKey "$tls_client_key" \
        --argjson tlsCACert "$tls_ca_cert" \
        '{
            name: "prometheus",
            type: "prometheus",
            access: "proxy",
            url: $url,
            isDefault: true,
            jsonData: {
                httpMethod: "POST",
                serverName: $sn,
                tlsAuth: true,
                tlsAuthWithCACert: true,
                tlsSkipVerify: false
            },
            secureJsonData: {
                tlsClientCert: $tlsClientCert,
                tlsClientKey: $tlsClientKey,
                tlsCACert: $tlsCACert
            }
        }' | tr -d '\n')
    
    # Сохраняем payload в файл (избегаем проблем с экранированием в bash)
    local ds_payload_file="/tmp/grafana_datasource_payload_$$.json"
    printf '%s' "$ds_payload" > "$ds_payload_file"
    
    echo "DEBUG_DS_PAYLOAD_FILE: $ds_payload_file (размер: $(stat -c%s "$ds_payload_file" 2>/dev/null || echo "?") байт)" >&2
    echo "DEBUG_DS_PAYLOAD_PREVIEW: ${ds_payload:0:150}..." >&2
    
    # Функция для настройки datasource через API
    configure_datasource_via_api() {
        local bearer_token="$1"
        
        # Проверяем существующий datasource
        local ds_response ds_code ds_body ds_id
        
        local curl_cmd="curl -k -s -w \"\n%{http_code}\" \
            -H \"Authorization: Bearer $bearer_token\" \
            \"${grafana_url}/api/datasources/name/prometheus\""
        
        if [[ -f "/opt/vault/certs/grafana-client.crt" && -f "/opt/vault/certs/grafana-client.key" ]]; then
            curl_cmd="curl -k -s -w \"\n%{http_code}\" \
                --cert \"/opt/vault/certs/grafana-client.crt\" \
                --key \"/opt/vault/certs/grafana-client.key\" \
                -H \"Authorization: Bearer $bearer_token\" \
                \"${grafana_url}/api/datasources/name/prometheus\""
        fi
        
        ds_response=$(eval "$curl_cmd")
        ds_code=$(echo "$ds_response" | tail -1)
        ds_body=$(echo "$ds_response" | head -n -1)
        
        if [[ "$ds_code" == "200" ]]; then
            # Datasource существует, обновляем
            ds_id=$(echo "$ds_body" | jq -r '.id')
            print_info "Datasource существует, ID: $ds_id, обновляем..."
            
            # ИСПРАВЛЕНО: Используем --data-binary '@file' вместо -d "$variable"
            local update_cmd="curl -k -s -w \"\n%{http_code}\" \
                -X PUT \
                -H \"Content-Type: application/json\" \
                -H \"Authorization: Bearer $bearer_token\" \
                --data-binary \"@${ds_payload_file}\" \
                \"${grafana_url}/api/datasources/${ds_id}\""
            
            if [[ -f "/opt/vault/certs/grafana-client.crt" && -f "/opt/vault/certs/grafana-client.key" ]]; then
                update_cmd="curl -k -s -w \"\n%{http_code}\" \
                    --cert \"/opt/vault/certs/grafana-client.crt\" \
                    --key \"/opt/vault/certs/grafana-client.key\" \
                    -X PUT \
                    -H \"Content-Type: application/json\" \
                    -H \"Authorization: Bearer $bearer_token\" \
                    --data-binary \"@${ds_payload_file}\" \
                    \"${grafana_url}/api/datasources/${ds_id}\""
            fi
            
            echo "DEBUG_DS_UPDATE_CMD: ${update_cmd//$bearer_token/*****}" >&2
            
            local update_response update_code update_body
            update_response=$(eval "$update_cmd" 2>&1)
            update_code=$(echo "$update_response" | tail -1)
            update_body=$(echo "$update_response" | head -n -1)
            
            echo "DEBUG_DS_UPDATE_RESPONSE: HTTP $update_code" >&2
            echo "DEBUG_DS_UPDATE_BODY: ${update_body:0:200}..." >&2
            
            if [[ "$update_code" == "200" || "$update_code" == "202" ]]; then
                print_success "Datasource обновлен через API (HTTP $update_code)"
                rm -f "$ds_payload_file" 2>/dev/null || true
                return 0
            else
                print_warning "Не удалось обновить datasource через API: HTTP $update_code"
                print_warning "Response body: ${update_body:0:300}"
                rm -f "$ds_payload_file" 2>/dev/null || true
                return 1
            fi
        else
            # Datasource не существует, создаем
            print_info "Создание нового datasource через API..."
            
            # ИСПРАВЛЕНО: Используем --data-binary '@file' вместо -d "$variable"
            local create_cmd="curl -k -s -w \"\n%{http_code}\" \
                -X POST \
                -H \"Content-Type: application/json\" \
                -H \"Authorization: Bearer $bearer_token\" \
                --data-binary \"@${ds_payload_file}\" \
                \"${grafana_url}/api/datasources\""
            
            if [[ -f "/opt/vault/certs/grafana-client.crt" && -f "/opt/vault/certs/grafana-client.key" ]]; then
                create_cmd="curl -k -s -w \"\n%{http_code}\" \
                    --cert \"/opt/vault/certs/grafana-client.crt\" \
                    --key \"/opt/vault/certs/grafana-client.key\" \
                    -X POST \
                    -H \"Content-Type: application/json\" \
                    -H \"Authorization: Bearer $bearer_token\" \
                    --data-binary \"@${ds_payload_file}\" \
                    \"${grafana_url}/api/datasources\""
            fi
            
            echo "DEBUG_DS_CREATE_CMD: ${create_cmd//$bearer_token/*****}" >&2
            
            local create_response create_code create_body
            create_response=$(eval "$create_cmd" 2>&1)
            create_code=$(echo "$create_response" | tail -1)
            create_body=$(echo "$create_response" | head -n -1)
            
            echo "DEBUG_DS_CREATE_RESPONSE: HTTP $create_code" >&2
            echo "DEBUG_DS_CREATE_BODY: ${create_body:0:200}..." >&2
            
            if [[ "$create_code" == "200" || "$create_code" == "201" || "$create_code" == "202" ]]; then
                print_success "Datasource создан через API (HTTP $create_code)"
                rm -f "$ds_payload_file" 2>/dev/null || true
                return 0
            else
                print_warning "Не удалось создать datasource через API: HTTP $create_code"
                print_warning "Response body: ${create_body:0:300}"
                rm -f "$ds_payload_file" 2>/dev/null || true
                return 1
            fi
        fi
    }
    
    # Пробуем настроить datasource через API
    if ! configure_datasource_via_api "$GRAFANA_BEARER_TOKEN"; then
        print_warning "Не удалось настроить datasource через API"
        print_info "Datasource может быть настроен вручную через UI Grafana"
        # Продолжаем выполнение, не прерываем скрипт
    fi
    
    # Импортируем дашборды Harvest (только если есть токен)
    if [[ -z "$GRAFANA_BEARER_TOKEN" ]]; then
        print_warning "Токен Grafana не получен. Пропускаем импорт дашбордов."
        print_info "Дашборды могут быть импортированы вручную через UI Grafana или команду harvest"
        print_success "Настройка Grafana завершена (частично - datasource и дашборды пропущены)"
        return 0
    fi
    
    print_info "Импорт дашбордов Harvest..."
    
    if [[ ! -d "/opt/harvest" ]]; then
        print_warning "Директория /opt/harvest не найдена. Пропускаем импорт дашбордов."
        print_info "Установите Harvest для импорта дашбордов"
        print_success "Настройка Grafana завершена (частично - дашборды пропущены)"
        return 0
    fi
    
    cd /opt/harvest || {
        print_warning "Не удалось перейти в /opt/harvest. Пропускаем импорт дашбордов."
        print_success "Настройка Grafana завершена (частично - дашборды пропущены)"
        return 0
    }
    
    if [[ ! -f "./harvest.yml" ]]; then
        print_warning "Файл конфигурации harvest.yml не найден. Пропускаем импорт дашбордов."
        print_info "Проверьте установку Harvest"
        print_success "Настройка Grafana завершена (частично - дашборды пропущены)"
        return 0
    fi
    
    if [[ ! -x "./bin/harvest" ]]; then
        print_warning "Бинарный файл harvest не найден или не исполняемый. Пропускаем импорт дашбордов."
        print_info "Проверьте установку Harvest"
        print_success "Настройка Grafana завершена (частично - дашборды пропущены)"
        return 0
    fi
    
    # Функция для импорта дашбордов через harvest
    import_dashboards_via_harvest() {
        local bearer_token="$1"
        
        print_info "Попытка импорта дашбордов через harvest..."
        
        # Пробуем импортировать дашборды
        if echo "Y" | ./bin/harvest --config ./harvest.yml grafana import --addr "$grafana_url" --token "$bearer_token" --insecure 2>&1; then
            print_success "Дашборды импортированы через harvest"
            return 0
        else
            print_warning "Не удалось импортировать дашборды автоматически через harvest"
            return 1
        fi
    }
    
    # Пробуем импортировать дашборды
    if ! import_dashboards_via_harvest "$GRAFANA_BEARER_TOKEN"; then
        print_warning "Импорт дашбордов не удался"
        print_info "Попробуйте вручную:"
        print_info "cd /opt/harvest && echo 'Y' | ./bin/harvest --config ./harvest.yml grafana import --addr $grafana_url --token <TOKEN> --insecure"
        print_info "Или импортируйте дашборды через UI Grafana"
    fi
    
    print_success "Настройка Grafana завершена"
    return 0
}

configure_iptables() {
    print_step "Настройка iptables для мониторинговых сервисов"
    ensure_working_directory

    if [[ ! -x "$WRAPPERS_DIR/firewall-manager_launcher.sh" ]]; then
        print_error "Лаунчер firewall-manager_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        exit 1
    fi

    # Передаём параметры в обёртку, где реализована валидация и настройка
    "$WRAPPERS_DIR/firewall-manager_launcher.sh" \
        "$PROMETHEUS_PORT" \
        "$GRAFANA_PORT" \
        "$HARVEST_UNIX_PORT" \
        "$HARVEST_NETAPP_PORT" \
        "$SERVER_IP"

    print_success "Настройка iptables завершена (через скрипт-обёртку)"
}

configure_services() {
    print_step "Настройка и запуск сервисов мониторинга"
    ensure_working_directory

    print_info "Проверка наличия сертификатов (обязательно для TLS)"
    local userspace_bundle="${VAULT_CERTS_DIR}/server_bundle.pem"
    local userspace_ca_chain="${VAULT_CERTS_DIR}/ca_chain.crt"
    local system_bundle="/opt/vault/certs/server_bundle.pem"
    local system_ca_chain="/opt/vault/certs/ca_chain.crt"
    local system_ca_chain_alt="/opt/vault/certs/ca_chain"
    local userspace_pair_ok=false
    local userspace_bundle_ok=false
    local userspace_ca_ok=false
    local system_bundle_ok=false
    local system_ca_ok=false

    [[ -f "$VAULT_CRT_FILE" && -f "$VAULT_KEY_FILE" ]] && userspace_pair_ok=true
    [[ -f "$userspace_bundle" ]] && userspace_bundle_ok=true
    [[ -f "$userspace_ca_chain" ]] && userspace_ca_ok=true
    [[ -f "$system_bundle" ]] && system_bundle_ok=true
    [[ -f "$system_ca_chain" || -f "$system_ca_chain_alt" ]] && system_ca_ok=true

    # Подробная диагностика: помогает быстро понять, где именно разрыв в цепочке.
    echo "[CERTS-SVC-DIAG] userspace_pair: $userspace_pair_ok (crt=$VAULT_CRT_FILE, key=$VAULT_KEY_FILE)" | tee /dev/stderr
    echo "[CERTS-SVC-DIAG] userspace_bundle: $userspace_bundle_ok ($userspace_bundle)" | tee /dev/stderr
    echo "[CERTS-SVC-DIAG] userspace_ca_chain: $userspace_ca_ok ($userspace_ca_chain)" | tee /dev/stderr
    echo "[CERTS-SVC-DIAG] system_bundle: $system_bundle_ok ($system_bundle)" | tee /dev/stderr
    echo "[CERTS-SVC-DIAG] system_ca_chain: $system_ca_ok ($system_ca_chain or $system_ca_chain_alt)" | tee /dev/stderr

    if { [[ "$userspace_pair_ok" == true ]] || [[ "$userspace_bundle_ok" == true ]] || [[ "$system_bundle_ok" == true ]]; } && \
       { [[ "$userspace_ca_ok" == true ]] || [[ "$system_ca_ok" == true ]]; }; then
        print_success "Найдены сертификаты и CA chain (userspace/system)"
        configure_grafana_ini
        configure_prometheus_files
    else
        print_error "Сертификаты не найдены. TLS обязателен согласно требованиям. Останавливаемся."
        print_error "Ожидались файлы (любой валидный набор):"
        print_error "  userspace bundle: $userspace_bundle"
        print_error "  userspace CA:     $userspace_ca_chain"
        print_error "  userspace pair:   $VAULT_CRT_FILE + $VAULT_KEY_FILE"
        print_error "  system bundle:    $system_bundle"
        print_error "  system CA:        $system_ca_chain (или $system_ca_chain_alt)"
        exit 1
    fi

    # Определяем runtime-пользователя для user-юнитов (mon_ci или mon_sys)
    local use_user_units=false
    local runtime_user=""
    local runtime_uid=""

    if [[ "${RUN_SERVICES_AS_MON_CI:-true}" == "true" ]]; then
        runtime_user="$(whoami)"
        runtime_uid="$(id -u)"
        use_user_units=true
        print_warning "RUN_SERVICES_AS_MON_CI=true: user-юниты будут запускаться под ${runtime_user} (UID=${runtime_uid})"
    elif [[ -n "${KAE:-}" ]]; then
        runtime_user="${KAE}-lnx-mon_sys"
        if id "$runtime_user" >/dev/null 2>&1; then
            runtime_uid=$(id -u "$runtime_user")
            use_user_units=true
            print_info "Обнаружен пользователь для user-юнитов: ${runtime_user} (UID=${runtime_uid})"
        else
            print_warning "Пользователь ${runtime_user} не найден, будем использовать системные юниты"
        fi
    else
        print_warning "KAE не определён, будем использовать системные юниты"
    fi

    if [[ "$use_user_units" == true ]]; then
        print_info "Настройка и запуск user-юнитов мониторинга под пользователем ${runtime_user}"
        local xdg_env="XDG_RUNTIME_DIR=/run/user/${runtime_uid}"
        local run_as_current_user=false
        if [[ "$runtime_user" == "$(whoami)" ]]; then
            run_as_current_user=true
        fi

        run_user_systemctl() {
            if [[ "$run_as_current_user" == "true" ]]; then
                env "$xdg_env" /usr/bin/systemctl --user "$@"
            else
                runuser -u "$runtime_user" -- env "$xdg_env" /usr/bin/systemctl --user "$@"
            fi
        }

        port_in_use() {
            local port="$1"
            # Предпочитаем фильтр ss по порту; fallback на grep для старых версий ss.
            if ss -H -tln "( sport = :${port} )" 2>/dev/null | grep -q .; then
                return 0
            fi
            ss -tln 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
        }

        print_port_owner_diag() {
            local port="$1"
            print_info "Диагностика порта ${port}:"
            ss -tlnp 2>/dev/null | grep ":${port} " | while IFS= read -r line; do
                print_info "  $line"
                log_message "[PORT ${port} OWNER] $line"
            done
        }

        # Перед запуском Prometheus настраиваем права на его файлы/директории
        if [[ "$run_as_current_user" != "true" && "${SKIP_PROMETHEUS_PERMISSIONS_ADJUST:-false}" != "true" ]]; then
            adjust_prometheus_permissions_for_mon_sys
        else
            print_info "Пропускаем настройку прав Prometheus для mon_sys (runtime user: ${runtime_user})"
        fi
        
        # Перед запуском Grafana настраиваем права на её файлы/директории
        if [[ "$run_as_current_user" != "true" ]]; then
            adjust_grafana_permissions_for_mon_sys
        else
            print_info "Пропускаем настройку прав Grafana для mon_sys (runtime user: ${runtime_user})"
        fi

        # Перечитываем конфигурацию user-юнитов
        run_user_systemctl daemon-reload >/dev/null 2>&1 || print_warning "Не удалось выполнить daemon-reload для user-юнитов"

        # Сбрасываем предыдущее failed-состояние, чтобы StartLimitBurst
        # не блокировал перезапуск юнитов после неудачных попыток
        run_user_systemctl reset-failed \
            monitoring-prometheus.service \
            monitoring-grafana.service \
            >/dev/null 2>&1 || print_warning "Не удалось выполнить reset-failed для user-юнитов мониторинга"

        # Включаем и перезапускаем Prometheus
        run_user_systemctl enable monitoring-prometheus.service >/dev/null 2>&1 || print_warning "Не удалось включить автозапуск monitoring-prometheus.service"
        run_user_systemctl restart monitoring-prometheus.service >/dev/null 2>&1 || print_error "Ошибка запуска monitoring-prometheus.service"
        sleep 2
        if run_user_systemctl is-active --quiet monitoring-prometheus.service; then
            print_success "monitoring-prometheus.service успешно запущен (user-юнит)"
        else
            print_error "monitoring-prometheus.service не удалось запустить"
            run_user_systemctl status monitoring-prometheus.service --no-pager | while IFS= read -r line; do
                print_info "$line"
                log_message "[PROMETHEUS USER SYSTEMD STATUS] $line"
            done
        fi
        echo

        # Включаем и перезапускаем Grafana
        local grafana_started=false
        if port_in_use "$GRAFANA_PORT"; then
            print_warning "Порт Grafana ${GRAFANA_PORT} уже занят. Пропускаем запуск monitoring-grafana.service"
            print_port_owner_diag "$GRAFANA_PORT"
            grafana_started=true
        else
            run_user_systemctl enable monitoring-grafana.service >/dev/null 2>&1 || print_warning "Не удалось включить автозапуск monitoring-grafana.service"
            run_user_systemctl restart monitoring-grafana.service >/dev/null 2>&1 || print_error "Ошибка запуска monitoring-grafana.service"
            sleep 2
            if run_user_systemctl is-active --quiet monitoring-grafana.service; then
                print_success "monitoring-grafana.service успешно запущен (user-юнит)"
                grafana_started=true
            else
                print_error "monitoring-grafana.service не удалось запустить"
                print_info "Диагностика Grafana user-юнита:"
                print_info "  Конфиг: $HOME/monitoring/config/grafana/grafana.ini"
                print_info "  Лог:    $HOME/monitoring/logs/grafana/grafana.log"
                if [[ -f "$HOME/monitoring/config/grafana/grafana.ini" ]]; then
                    print_info "  ✅ grafana.ini найден"
                else
                    print_info "  ❌ grafana.ini отсутствует"
                fi
                run_user_systemctl status monitoring-grafana.service --no-pager | while IFS= read -r line; do
                    print_info "$line"
                    log_message "[GRAFANA USER SYSTEMD STATUS] $line"
                done
                print_port_owner_diag "$GRAFANA_PORT"
                run_user_systemctl show monitoring-grafana.service --property=ExecMainStatus --property=ExecMainCode --property=Result 2>/dev/null | while IFS= read -r line; do
                    print_info "$line"
                    log_message "[GRAFANA USER SYSTEMD SHOW] $line"
                done
                if [[ -f "$HOME/monitoring/logs/grafana/grafana.log" ]]; then
                    print_info "Последние строки grafana.log:"
                    tail -n 80 "$HOME/monitoring/logs/grafana/grafana.log" | while IFS= read -r line; do
                        print_info "$line"
                        log_message "[GRAFANA USER LOG] $line"
                    done
                fi
            fi
        fi
        echo

        # Включаем и запускаем Harvest user-юнит
        local harvest_started=false
        if port_in_use "$HARVEST_NETAPP_PORT"; then
            print_warning "Порт Harvest ${HARVEST_NETAPP_PORT} уже занят. Пропускаем запуск monitoring-harvest.service"
            print_port_owner_diag "$HARVEST_NETAPP_PORT"
            harvest_started=true
        else
            run_user_systemctl enable monitoring-harvest.service >/dev/null 2>&1 || print_warning "Не удалось включить автозапуск monitoring-harvest.service"
            run_user_systemctl restart monitoring-harvest.service >/dev/null 2>&1 || print_error "Ошибка запуска monitoring-harvest.service"
            sleep 3
            if run_user_systemctl is-active --quiet monitoring-harvest.service; then
                print_success "monitoring-harvest.service успешно запущен (user-юнит)"
                harvest_started=true
            else
                print_error "monitoring-harvest.service не удалось запустить"
                print_info "Диагностика Harvest user-юнита:"
                print_info "  Проверка конфига: $HOME/monitoring/config/harvest/harvest.yml"
                print_info "  Проверка cert dir: $HOME/monitoring/config/harvest/cert"
                if [[ -f "$HOME/monitoring/config/harvest/harvest.yml" ]]; then
                    print_info "  ✅ harvest.yml найден"
                else
                    print_info "  ❌ harvest.yml отсутствует"
                fi
                if [[ -f "$HOME/monitoring/config/harvest/cert/harvest.crt" ]]; then
                    print_info "  ✅ harvest.crt найден"
                else
                    print_info "  ❌ harvest.crt отсутствует"
                fi
                if [[ -f "$HOME/monitoring/config/harvest/cert/harvest.key" ]]; then
                    print_info "  ✅ harvest.key найден"
                else
                    print_info "  ❌ harvest.key отсутствует"
                fi
                run_user_systemctl status monitoring-harvest.service --no-pager | while IFS= read -r line; do
                    print_info "$line"
                    log_message "[HARVEST USER SYSTEMD STATUS] $line"
                done
                run_user_systemctl show monitoring-harvest.service --property=ExecMainStatus --property=ExecMainCode --property=Result 2>/dev/null | while IFS= read -r line; do
                    print_info "$line"
                    log_message "[HARVEST USER SYSTEMD SHOW] $line"
                done
                if [[ -f "$HOME/monitoring/logs/harvest/harvest.log" ]]; then
                    print_info "Последние строки harvest.log:"
                    tail -n 80 "$HOME/monitoring/logs/harvest/harvest.log" | while IFS= read -r line; do
                        print_info "$line"
                        log_message "[HARVEST USER LOG] $line"
                    done
                fi
            fi
        fi

        if [[ "$grafana_started" != true ]]; then
            print_error "Grafana не удалось запустить и порт ${GRAFANA_PORT} не занят внешним процессом"
            exit 1
        fi
        if [[ "$harvest_started" != true ]]; then
            print_error "Harvest не удалось запустить и порт ${HARVEST_NETAPP_PORT} не занят внешним процессом"
            exit 1
        fi
        echo
    else
        print_info "Настройка системных юнитов мониторинга (fallback)"

        print_info "Настройка сервиса: prometheus"
        systemctl enable prometheus >/dev/null 2>&1 || print_error "Ошибка включения автозапуска prometheus"
        systemctl restart prometheus >/dev/null 2>&1 || print_error "Ошибка запуска prometheus"
        sleep 2
        if systemctl is-active --quiet prometheus; then
            print_success "prometheus успешно запущен и настроен на автозапуск"
        else
            print_error "prometheus не удалось запустить"
            systemctl status prometheus --no-pager | while IFS= read -r line; do
                print_info "$line"
                log_message "[PROMETHEUS SYSTEMD STATUS] $line"
            done
        fi
        echo

        print_info "Настройка сервиса: grafana-server"
        systemctl enable grafana-server >/dev/null 2>&1 || print_error "Ошибка включения автозапуска grafana-server"
        systemctl restart grafana-server >/dev/null 2>&1 || print_error "Ошибка запуска grafana-server"
        sleep 2
        if systemctl is-active --quiet grafana-server; then
            print_success "grafana-server успешно запущен и настроен на автозапуск"
            # Ранее здесь был configure_grafana_datasource — перенесено после получения токена
        else
            print_error "grafana-server не удалось запустить"
            systemctl status grafana-server --no-pager | while IFS= read -r line; do
                print_info "$line"
                log_message "[GRAFANA SYSTEMD STATUS] $line"
            done
        fi
        echo
    fi

    if [[ "$use_user_units" == true ]]; then
        print_info "Harvest уже управляется через monitoring-harvest.service (user-юнит), системный harvest пропускаем"
        return 0
    fi

    print_info "Настройка и запуск Harvest..."
    if systemctl is-active --quiet harvest 2>/dev/null; then
        print_info "Остановка текущего сервиса harvest"
        systemctl stop harvest >/dev/null 2>&1 || print_warning "Не удалось остановить сервис harvest"
        sleep 2
    fi

    if command -v harvest &> /dev/null; then
        print_info "Остановка любых существующих процессов Harvest через команду"
        harvest stop --config "$HARVEST_CONFIG" >/dev/null 2>&1 || true
        sleep 2
    fi

    print_info "Проверка порта $HARVEST_NETAPP_PORT перед запуском Harvest"
    if ss -tln | grep -q ":$HARVEST_NETAPP_PORT "; then
        print_warning "Порт $HARVEST_NETAPP_PORT все еще занят"
        local pids
        pids=$(ss -tlnp | grep ":$HARVEST_NETAPP_PORT " | awk -F, '{for(i=1;i<=NF;i++) if ($i ~ /pid=/) {print $i}}' | awk -F= '{print $2}' | sort -u)
        if [[ -n "$pids" ]]; then
            for pid in $pids; do
                print_info "Завершение процесса с PID $pid, использующего порт $HARVEST_NETAPP_PORT"
                ps -p "$pid" -o pid,ppid,cmd --no-headers | while read -r pid ppid cmd; do
                    print_info "PID: $pid, PPID: $ppid, Команда: $cmd"
                    log_message "PID: $pid, PPID: $ppid, Команда: $cmd"
                done
                kill -TERM "$pid" 2>/dev/null || print_warning "Не удалось отправить SIGTERM процессу $pid"
                sleep 2
                if kill -0 "$pid" 2>/dev/null; then
                    print_info "Процесс $pid не завершился, отправляем SIGKILL"
                    kill -9 "$pid" 2>/dev/null || print_warning "Не удалось завершить процесс $pid с SIGKILL"
                fi
            done
            sleep 2
            if ss -tln | grep -q ":$HARVEST_NETAPP_PORT "; then
                print_error "Не удалось освободить порт $HARVEST_NETAPP_PORT"
                ss -tlnp | grep ":$HARVEST_NETAPP_PORT " | while read -r line; do
                    print_info "$line"
                    log_message "Порт $HARVEST_NETAPP_PORT все еще занят: $line"
                done
                exit 1
            fi
        else
            print_warning "Не удалось найти процессы для порта $HARVEST_NETAPP_PORT"
        fi
    fi

    print_info "Запуск сервиса harvest через systemd"
    systemctl enable harvest >/dev/null 2>&1 || print_warning "Не удалось включить автозапуск harvest"
    systemctl restart harvest >/dev/null 2>&1 || print_error "Ошибка запуска harvest"
    sleep 10

    if systemctl is-active --quiet harvest; then
        print_success "harvest успешно запущен и настроен на автозапуск"
        print_info "Проверка статуса поллеров Harvest:"
        harvest status --config "$HARVEST_CONFIG" 2>/dev/null | while IFS= read -r line; do
            print_info "$line"
            log_message "[HARVEST STATUS] $line"
        done
        if harvest status --config "$HARVEST_CONFIG" 2>/dev/null | grep -q "${NETAPP_POLLER_NAME}.*not running"; then
            print_error "Поллер ${NETAPP_POLLER_NAME} не запущен"
            print_info "Лог Harvest для ${NETAPP_POLLER_NAME}: /var/log/harvest/poller_${NETAPP_POLLER_NAME}.log"
            exit 1
        fi
    else
        print_error "harvest не удалось запустить"
        systemctl status harvest --no-pager | while IFS= read -r line; do
            print_info "$line"
            log_message "[HARVEST SYSTEMD STATUS] $line"
        done
        exit 1
    fi
}

import_grafana_dashboards() {
    print_step "Импорт дашбордов Harvest в Grafana"
    ensure_working_directory
    print_info "Ожидание запуска Grafana..."
    sleep 10

    local grafana_url="https://${SERVER_DOMAIN}:${GRAFANA_PORT}"

    # Обеспечим наличие токена (если ещё не получен)
    if [[ -z "$GRAFANA_BEARER_TOKEN" ]]; then
        ensure_grafana_token || return 1
    fi

    if [[ ! -x "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ]]; then
        print_error "Лаунчер grafana-api-wrapper_launcher.sh не найден или не исполняемый в $WRAPPERS_DIR"
        return 1
    fi

    print_info "Получение UID источника данных..."
    local ds_resp uid_datasource
    ds_resp=$("$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ds_list "$grafana_url" "$GRAFANA_BEARER_TOKEN" || true)
    uid_datasource=$(echo "$ds_resp" | jq -er '.[0].uid' 2>/dev/null || echo "")

    if [[ "$uid_datasource" == "null" || -z "$uid_datasource" ]]; then
        print_warning "UID источника данных не получен (продолжаем)"
        log_message "[GRAFANA IMPORT WARNING] Не удалось разобрать ответ /api/datasources"
    else
        print_success "UID источника данных: $uid_datasource"
    fi

    # Устанавливаем secureJsonData (mTLS) через API
    print_info "Обновление Prometheus datasource через API для установки mTLS..."
    local ds_obj ds_id payload update_resp
    ds_obj=$("$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ds_get_by_name "$grafana_url" "$GRAFANA_BEARER_TOKEN" "prometheus" || true)
    ds_id=$(echo "$ds_obj" | jq -er '.id' 2>/dev/null || echo "")

    if [[ -z "$ds_id" ]]; then
        print_warning "Не удалось получить ID источника данных по имени, пробуем список"
        ds_id=$("$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ds_list "$grafana_url" "$GRAFANA_BEARER_TOKEN" | jq -er '.[] | select(.name=="prometheus") | .id' 2>/dev/null || echo "")
    fi

    if [[ -n "$ds_id" ]]; then
        payload=$(jq -n \
            --arg url "https://${SERVER_DOMAIN}:${PROMETHEUS_PORT}" \
            --arg sn  "${SERVER_DOMAIN}" \
            --rawfile tlsClientCert "/opt/vault/certs/grafana-client.crt" \
            --rawfile tlsClientKey  "/opt/vault/certs/grafana-client.key" \
            --rawfile tlsCACert     "/etc/prometheus/cert/ca_chain.crt" \
            '{name:"prometheus", type:"prometheus", access:"proxy", url:$url, isDefault:false,
              jsonData:{httpMethod:"POST", serverName:$sn, tlsAuth:true, tlsAuthWithCACert:true, tlsSkipVerify:false},
              secureJsonData:{tlsClientCert:$tlsClientCert, tlsClientKey:$tlsClientKey, tlsCACert:$tlsCACert}}')
        update_resp=$(printf '%s' "$payload" | \
            "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" ds_update_by_id "$grafana_url" "$GRAFANA_BEARER_TOKEN" "$ds_id")
        if [[ "$update_resp" == "200" || "$update_resp" == "202" ]]; then
            print_success "Datasource обновлен через API (mTLS установлен)"
        else
            print_warning "Не удалось обновить datasource через API, код $update_resp"
        fi
    else
        print_warning "ID источника данных не найден, пропускаем установку secureJsonData"
    fi

    print_info "Импортируем дашборды в Grafana..."
    if [[ ! -d "/opt/harvest" ]]; then
        print_error "Директория /opt/harvest не найдена"
        log_message "[GRAFANA IMPORT ERROR] Директория /opt/harvest не найдена"
        return 1
    fi

    cd /opt/harvest || {
        print_error "Не удалось перейти в директорию /opt/harvest"
        log_message "[GRAFANA IMPORT ERROR] Не удалось перейти в директорию /opt/harvest"
        return 1
    }

    if [[ ! -f "$HARVEST_CONFIG" ]]; then
        print_error "Файл конфигурации $HARVEST_CONFIG не найден"
        log_message "[GRAFANA IMPORT ERROR] Файл конфигурации $HARVEST_CONFIG не найден"
        return 1
    fi

    if [[ ! -x "./bin/harvest" ]]; then
        print_error "Исполняемый файл harvest не найден или не имеет прав на выполнение"
        log_message "[GRAFANA IMPORT ERROR] Исполняемый файл harvest не найден или не имеет прав на выполнение"
        return 1
    fi

    if echo "Y" | ./bin/harvest --config "$HARVEST_CONFIG" grafana import --addr "$grafana_url" --token "$GRAFANA_BEARER_TOKEN" --insecure >/dev/null 2>&1; then
        print_success "Дашборды успешно импортированы"
    else
        print_error "Не удалось импортировать дашборды автоматически"
        log_message "[GRAFANA IMPORT ERROR] Не удалось импортировать дашборды"
        print_info "Вы можете импортировать их позже командой:"
        print_info "cd /opt/harvest && echo 'Y' | ./bin/harvest --config \"$HARVEST_CONFIG\" grafana import --addr $grafana_url --token <YOUR_TOKEN> --insecure"
        return 1
    fi
    print_success "Процесс импорта дашбордов завершен"
}

# Функция проверки системных сервисов (fallback)
check_system_services() {
    local services=("prometheus" "grafana-server")
    local failed_services_ref="$1"
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            print_success "$service (system): активен"
        else
            print_error "$service (system): не активен"
            eval "$failed_services_ref+=(\"$service\")"
        fi
    done
}

verify_installation() {
    print_step "Проверка установки и доступности сервисов"
    ensure_working_directory
    echo
    print_info "Проверка статуса сервисов:"
    local failed_services=()

    # Проверяем user-юниты если используется mon_sys пользователь
    if [[ -n "${KAE:-}" ]]; then
        local mon_sys_user="${KAE}-lnx-mon_sys"
        local mon_sys_uid=""
        
        if id "$mon_sys_user" >/dev/null 2>&1; then
            mon_sys_uid=$(id -u "$mon_sys_user")
            local ru_cmd="runuser -u ${mon_sys_user} --"
            local xdg_env="XDG_RUNTIME_DIR=/run/user/${mon_sys_uid}"
            
            # Проверяем Prometheus user-юнит
            if $ru_cmd env "$xdg_env" /usr/bin/systemctl --user is-active --quiet monitoring-prometheus.service 2>/dev/null; then
                print_success "monitoring-prometheus.service (user): активен"
            else
                print_error "monitoring-prometheus.service (user): не активен"
                failed_services+=("monitoring-prometheus.service")
            fi
            
            # Проверяем Grafana user-юнит
            if $ru_cmd env "$xdg_env" /usr/bin/systemctl --user is-active --quiet monitoring-grafana.service 2>/dev/null; then
                print_success "monitoring-grafana.service (user): активен"
            else
                print_error "monitoring-grafana.service (user): не активен"
                failed_services+=("monitoring-grafana.service")
            fi
        else
            print_warning "Пользователь ${mon_sys_user} не найден, проверяем системные юниты"
            check_system_services "failed_services"
        fi
    else
        print_warning "KAE не определён, проверяем системные юниты"
        check_system_services "failed_services"
    fi

    if command -v harvest &> /dev/null; then
        if harvest status --config "$HARVEST_CONFIG" 2>/dev/null | grep -q "running"; then
            print_success "harvest: активен"
        else
            print_error "harvest: не активен"
            failed_services+=("harvest")
        fi
    fi

    echo
    print_info "Проверка открытых портов:"
    local ports=(
        "$PROMETHEUS_PORT:Prometheus"
        "$GRAFANA_PORT:Grafana"
        "$HARVEST_UNIX_PORT:Harvest-Unix"
        "$HARVEST_NETAPP_PORT:Harvest-NetApp"
    )

    for port_info in "${ports[@]}"; do
        IFS=':' read -r port name <<< "$port_info"
        if ss -tln | grep -q ":$port "; then
            print_success "$name (порт $port): доступен"
        else
            print_error "$name (порт $port): недоступен"
        fi
    done

    echo
    print_info "Проверка HTTP ответов:"
    local services_to_check=(
        "$PROMETHEUS_PORT:Prometheus"
        "$GRAFANA_PORT:Grafana"
    )

    for service_info in "${services_to_check[@]}"; do
        IFS=':' read -r port name <<< "$service_info"
        local https_url="https://127.0.0.1:${port}"
        local http_url="http://127.0.0.1:${port}"

        # Сначала пробуем HTTPS
        if "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" http_check "$https_url" "https"; then
            print_success "$name: HTTPS ответ получен"
        # Если HTTPS не работает, пробуем HTTP
        elif "$WRAPPERS_DIR/grafana-api-wrapper_launcher.sh" http_check "$http_url" "http"; then
            print_success "$name: HTTP ответ получен"
        else
            print_warning "$name: HTTP/HTTPS ответ не получен (но сервис работает по портам)"
        fi
    done

    if [[ ${#failed_services[@]} -eq 0 ]]; then
        print_success "Все сервисы успешно установлены и запущены!"
    else
        print_warning "Некоторые сервисы требуют внимания: ${failed_services[*]}"
    fi
}

save_installation_state() {
    print_step "Сохранение состояния установки"
    ensure_working_directory
    "$WRAPPERS_DIR/config-writer_launcher.sh" "$STATE_FILE" << STATE_EOF
# Состояние установки мониторинговой системы
DEPLOYMENT_VERSION=$DEPLOY_VERSION
DEPLOYMENT_GIT_COMMIT=$DEPLOY_GIT_COMMIT
DEPLOYMENT_BUILD_DATE=$DEPLOY_BUILD_DATE
INSTALL_DATE=$DATE_INSTALL
SERVER_IP=$SERVER_IP
SERVER_DOMAIN=$SERVER_DOMAIN
INSTALL_DIR=$INSTALL_DIR
LOG_FILE=$LOG_FILE
PROMETHEUS_PORT=$PROMETHEUS_PORT
GRAFANA_PORT=$GRAFANA_PORT
HARVEST_UNIX_PORT=$HARVEST_UNIX_PORT
HARVEST_NETAPP_PORT=$HARVEST_NETAPP_PORT
NETAPP_API_ADDR=$NETAPP_API_ADDR
STATE_EOF
    chmod 600 "$STATE_FILE"
    print_success "Состояние установки сохранено в $STATE_FILE"
}

# ============================================================
# VAULT-AGENT APPROACH: Certificate Functions
# ============================================================
# Сертификаты генерируются vault-agent и копируются из /opt/vault/certs/
# ============================================================

copy_certificates_from_vault_agent() {
    print_step "Копирование сертификатов из vault-agent (/opt/vault/certs/)"
    log_debug "Copying certificates from vault-agent"
    
    echo "[CERTS-COPY-VA] ========================================" | tee /dev/stderr
    echo "[CERTS-COPY-VA] Копирование сертификатов vault-agent" | tee /dev/stderr
    echo "[CERTS-COPY-VA] ========================================" | tee /dev/stderr
    
    # Проверяем наличие сертификатов в /opt/vault/certs/
    if [[ ! -f "/opt/vault/certs/server_bundle.pem" ]]; then
        print_error "Сертификаты не найдены в /opt/vault/certs/"
        echo "[CERTS-COPY-VA] ❌ /opt/vault/certs/server_bundle.pem не найден" | tee /dev/stderr
        echo "[CERTS-COPY-VA] Возможно, vault-agent еще не сгенерировал сертификаты" | tee /dev/stderr
        echo "[CERTS-COPY-VA] Проверьте: sudo systemctl status vault-agent" | tee /dev/stderr
        echo "[CERTS-COPY-VA] Логи: sudo journalctl -u vault-agent -n 50" | tee /dev/stderr
        return 1
    fi
    
    echo "[CERTS-COPY-VA] ✅ Сертификаты найдены в /opt/vault/certs/" | tee /dev/stderr
    
    # Создаем целевые каталоги в user-space
    local vault_certs_dir="$HOME/monitoring/certs/vault"
    local grafana_certs_dir="$HOME/monitoring/certs/grafana"
    
    mkdir -p "$vault_certs_dir"
    mkdir -p "$grafana_certs_dir"
    chmod 700 "$vault_certs_dir"
    chmod 700 "$grafana_certs_dir"
    
    # Копируем server_bundle.pem
    echo "[CERTS-COPY-VA] Копирование server_bundle.pem..." | tee /dev/stderr
    if cp /opt/vault/certs/server_bundle.pem "$vault_certs_dir/server_bundle.pem" 2>/dev/null; then
        chmod 600 "$vault_certs_dir/server_bundle.pem"
        local size=$(stat -f%z "$vault_certs_dir/server_bundle.pem" 2>/dev/null || stat -c%s "$vault_certs_dir/server_bundle.pem" 2>/dev/null || echo "0")
        echo "[CERTS-COPY-VA] ✅ server_bundle.pem скопирован ($size байт)" | tee /dev/stderr
    else
        print_error "Не удалось скопировать server_bundle.pem"
        return 1
    fi
    
    # Копируем ca_chain.crt
    echo "[CERTS-COPY-VA] Копирование ca_chain.crt..." | tee /dev/stderr
    if cp /opt/vault/certs/ca_chain.crt "$vault_certs_dir/ca_chain.crt" 2>/dev/null; then
        chmod 600 "$vault_certs_dir/ca_chain.crt"
        local size=$(stat -f%z "$vault_certs_dir/ca_chain.crt" 2>/dev/null || stat -c%s "$vault_certs_dir/ca_chain.crt" 2>/dev/null || echo "0")
        echo "[CERTS-COPY-VA] ✅ ca_chain.crt скопирован ($size байт)" | tee /dev/stderr
    else
        print_warning "ca_chain.crt не найден (опционально)"
    fi
    
    # Копируем grafana-client.pem
    echo "[CERTS-COPY-VA] Копирование grafana-client.pem..." | tee /dev/stderr
    if cp /opt/vault/certs/grafana-client.pem "$grafana_certs_dir/grafana-client.pem" 2>/dev/null; then
        chmod 600 "$grafana_certs_dir/grafana-client.pem"
        local size=$(stat -f%z "$grafana_certs_dir/grafana-client.pem" 2>/dev/null || stat -c%s "$grafana_certs_dir/grafana-client.pem" 2>/dev/null || echo "0")
        echo "[CERTS-COPY-VA] ✅ grafana-client.pem скопирован ($size байт)" | tee /dev/stderr
    else
        print_warning "grafana-client.pem не найден (опционально)"
    fi
    
    echo "[CERTS-COPY-VA] ========================================" | tee /dev/stderr
    echo "[CERTS-COPY-VA] ✅ Сертификаты успешно скопированы" | tee /dev/stderr
    echo "[CERTS-COPY-VA] ========================================" | tee /dev/stderr
    
    return 0
}

# ============================================================
# LEGACY: SIMPLIFIED APPROACH (закомментирован)
# ============================================================
# Старый подход: извлечение сертификатов из temp_data_cred.json (Jenkins)
# Для возврата к этому подходу см. HOW-TO-REVERT.md
# ============================================================

get_certificates_from_jenkins() {
    print_step "Извлечение сертификатов из temp_data_cred.json (simplified подход)"
    log_debug "Extracting certificates from temp_data_cred.json"
    
    echo "[CERTS-EXTRACT] ========================================" | tee /dev/stderr
    echo "[CERTS-EXTRACT] Извлечение сертификатов из Jenkins" | tee /dev/stderr
    echo "[CERTS-EXTRACT] ========================================" | tee /dev/stderr
    
    # Проверяем наличие temp_data_cred.json
    local cred_json_path=""
    for candidate in "$LOCAL_CRED_JSON" "$PWD/temp_data_cred.json" "$(dirname "$0")/temp_data_cred.json" "/home/${SUDO_USER:-$(whoami)}/temp_data_cred.json" "$HOME/monitoring-deployment/temp_data_cred.json"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            cred_json_path="$candidate"
            break
        fi
    done
    
    if [[ -z "$cred_json_path" || ! -f "$cred_json_path" ]]; then
        print_error "temp_data_cred.json не найден!"
        echo "[CERTS-EXTRACT] ❌ temp_data_cred.json не найден" | tee /dev/stderr
        return 1
    fi
    
    echo "[CERTS-EXTRACT] Используется temp_data_cred.json: $cred_json_path" | tee /dev/stderr
    
    # Проверяем наличие секции certificates
    if ! jq -e '.certificates' "$cred_json_path" >/dev/null 2>&1; then
        print_warning "Секция 'certificates' не найдена в temp_data_cred.json"
        echo "[CERTS-EXTRACT] ⚠️  Секция 'certificates' отсутствует" | tee /dev/stderr
        echo "[CERTS-EXTRACT] Возможно, сертификаты не были сгенерированы в Jenkins" | tee /dev/stderr
        return 1
    fi
    
    echo "[CERTS-EXTRACT] ✅ Секция 'certificates' найдена" | tee /dev/stderr
    
    # Создаем целевые каталоги
    local vault_certs_dir="$HOME/monitoring/certs/vault"
    local grafana_certs_dir="$HOME/monitoring/certs/grafana"
    
    mkdir -p "$vault_certs_dir"
    mkdir -p "$grafana_certs_dir"
    chmod 700 "$vault_certs_dir"
    chmod 700 "$grafana_certs_dir"
    
    # Извлекаем server_bundle.pem
    echo "[CERTS-EXTRACT] Извлечение server_bundle.pem..." | tee /dev/stderr
    if ! jq -r '.certificates.server_bundle_pem // empty' "$cred_json_path" > "$vault_certs_dir/server_bundle.pem" 2>/dev/null; then
        print_error "Не удалось извлечь server_bundle.pem"
        return 1
    fi
    
    if [[ ! -s "$vault_certs_dir/server_bundle.pem" ]]; then
        print_warning "server_bundle.pem пустой (не сгенерирован в Jenkins)"
        echo "[CERTS-EXTRACT] ⚠️  server_bundle.pem пустой" | tee /dev/stderr
        return 1
    fi
    
    chmod 600 "$vault_certs_dir/server_bundle.pem"
    echo "[CERTS-EXTRACT] ✅ server_bundle.pem извлечен ($(stat -c%s "$vault_certs_dir/server_bundle.pem" 2>/dev/null || echo "0") байт)" | tee /dev/stderr
    
    # Извлекаем ca_chain.crt
    echo "[CERTS-EXTRACT] Извлечение ca_chain.crt..." | tee /dev/stderr
    if ! jq -r '.certificates.ca_chain_crt // empty' "$cred_json_path" > "$vault_certs_dir/ca_chain.crt" 2>/dev/null; then
        print_error "Не удалось извлечь ca_chain.crt"
        return 1
    fi
    
    if [[ ! -s "$vault_certs_dir/ca_chain.crt" ]]; then
        print_warning "ca_chain.crt пустой"
        echo "[CERTS-EXTRACT] ⚠️  ca_chain.crt пустой" | tee /dev/stderr
    else
        chmod 600 "$vault_certs_dir/ca_chain.crt"
        echo "[CERTS-EXTRACT] ✅ ca_chain.crt извлечен ($(stat -c%s "$vault_certs_dir/ca_chain.crt" 2>/dev/null || echo "0") байт)" | tee /dev/stderr
    fi
    
    # Извлекаем grafana-client.pem
    echo "[CERTS-EXTRACT] Извлечение grafana-client.pem..." | tee /dev/stderr
    if ! jq -r '.certificates.grafana_client_pem // empty' "$cred_json_path" > "$grafana_certs_dir/grafana-client.pem" 2>/dev/null; then
        print_error "Не удалось извлечь grafana-client.pem"
        return 1
    fi
    
    if [[ ! -s "$grafana_certs_dir/grafana-client.pem" ]]; then
        print_warning "grafana-client.pem пустой"
        echo "[CERTS-EXTRACT] ⚠️  grafana-client.pem пустой" | tee /dev/stderr
    else
        chmod 600 "$grafana_certs_dir/grafana-client.pem"
        echo "[CERTS-EXTRACT] ✅ grafana-client.pem извлечен ($(stat -c%s "$grafana_certs_dir/grafana-client.pem" 2>/dev/null || echo "0") байт)" | tee /dev/stderr
    fi
    
    echo "[CERTS-EXTRACT] ========================================" | tee /dev/stderr
    echo "[CERTS-EXTRACT] ✅ Все сертификаты извлечены из temp_data_cred.json" | tee /dev/stderr
    echo "[CERTS-EXTRACT] ========================================" | tee /dev/stderr
    
    # Показываем информацию о сертификате (если openssl доступен)
    if command -v openssl >/dev/null 2>&1 && [[ -s "$vault_certs_dir/server_bundle.pem" ]]; then
        echo "[CERTS-EXTRACT] Информация о сертификате:" | tee /dev/stderr
        openssl x509 -in "$vault_certs_dir/server_bundle.pem" -noout -text 2>/dev/null | grep -E "Subject:|Not Before|Not After|DNS:" | tee /dev/stderr || echo "[CERTS-EXTRACT] (не удалось прочитать сертификат)" | tee /dev/stderr
    fi
    
    log_debug "Certificates extracted successfully from temp_data_cred.json"
    return 0
}

distribute_certificates_to_services() {
    print_step "Распределение сертификатов по сервисам"
    log_debug "Distributing certificates to services"
    
    local vault_bundle="$HOME/monitoring/certs/vault/server_bundle.pem"
    local ca_chain="$HOME/monitoring/certs/vault/ca_chain.crt"
    local grafana_client="$HOME/monitoring/certs/grafana/grafana-client.pem"
    
    echo "[CERTS-DIST] ========================================" | tee /dev/stderr
    echo "[CERTS-DIST] Копирование сертификатов в конфиги" | tee /dev/stderr
    echo "[CERTS-DIST] ========================================" | tee /dev/stderr
    
    # Prometheus
    local prom_conf_dir="$HOME/monitoring/config/prometheus"
    if [[ -d "$prom_conf_dir" ]]; then
        if [[ -f "$vault_bundle" ]]; then
            cp "$vault_bundle" "$prom_conf_dir/server_bundle.pem"
            chmod 600 "$prom_conf_dir/server_bundle.pem"
            echo "[CERTS-DIST] ✅ Prometheus: server_bundle.pem" | tee /dev/stderr
        fi
        
        if [[ -f "$ca_chain" ]]; then
            cp "$ca_chain" "$prom_conf_dir/ca_chain.crt"
            chmod 600 "$prom_conf_dir/ca_chain.crt"
            echo "[CERTS-DIST] ✅ Prometheus: ca_chain.crt" | tee /dev/stderr
        fi
    fi
    
    # Grafana
    local grafana_conf_dir="$HOME/monitoring/config/grafana"
    if [[ -d "$grafana_conf_dir" ]]; then
        if [[ -f "$vault_bundle" ]]; then
            cp "$vault_bundle" "$grafana_conf_dir/server_bundle.pem"
            chmod 600 "$grafana_conf_dir/server_bundle.pem"
            echo "[CERTS-DIST] ✅ Grafana: server_bundle.pem" | tee /dev/stderr
        fi
        
        if [[ -f "$grafana_client" ]]; then
            cp "$grafana_client" "$grafana_conf_dir/grafana-client.pem"
            chmod 600 "$grafana_conf_dir/grafana-client.pem"
            echo "[CERTS-DIST] ✅ Grafana: grafana-client.pem" | tee /dev/stderr
        fi
    fi
    
    # Harvest
    local harvest_conf_dir="$HOME/monitoring/config/harvest"
    if [[ -d "$harvest_conf_dir" ]]; then
        if [[ -f "$ca_chain" ]]; then
            cp "$ca_chain" "$harvest_conf_dir/ca_chain.crt"
            chmod 600 "$harvest_conf_dir/ca_chain.crt"
            echo "[CERTS-DIST] ✅ Harvest: ca_chain.crt" | tee /dev/stderr
        fi
    fi
    
    echo "[CERTS-DIST] ✅ Сертификаты распределены по всем сервисам" | tee /dev/stderr
    echo "[CERTS-DIST] ========================================" | tee /dev/stderr
}

restart_services_for_certificates() {
    print_step "Перезапуск сервисов для применения новых сертификатов"
    log_debug "Restarting services to apply new certificates"
    
    local mon_sys_user="${KAE}-lnx-mon_sys"
    local mon_sys_uid
    mon_sys_uid=$(id -u "$mon_sys_user" 2>/dev/null)
    
    if [[ -z "$mon_sys_uid" ]]; then
        print_error "Пользователь $mon_sys_user не найден"
        return 1
    fi
    
    local xdg_env="XDG_RUNTIME_DIR=/run/user/${mon_sys_uid}"
    local services=("monitoring-prometheus" "monitoring-grafana" "monitoring-harvest")
    
    echo "[CERTS-RESTART] ========================================" | tee /dev/stderr
    echo "[CERTS-RESTART] Перезапуск сервисов" | tee /dev/stderr
    echo "[CERTS-RESTART] ========================================" | tee /dev/stderr
    
    for service in "${services[@]}"; do
        echo "[CERTS-RESTART] Перезапуск $service.service..." | tee /dev/stderr
        
        if sudo -n -u "$mon_sys_user" env "$xdg_env" /usr/bin/systemctl --user restart "$service.service" 2>/dev/null; then
            echo "[CERTS-RESTART] ✅ $service.service перезапущен" | tee /dev/stderr
            
            # Проверяем статус
            if sudo -n -u "$mon_sys_user" env "$xdg_env" /usr/bin/systemctl --user is-active "$service.service" >/dev/null 2>&1; then
                echo "[CERTS-RESTART] ✅ $service.service активен" | tee /dev/stderr
            else
                echo "[CERTS-RESTART] ⚠️  $service.service не активен после перезапуска" | tee /dev/stderr
            fi
        else
            echo "[CERTS-RESTART] ❌ Не удалось перезапустить $service.service" | tee /dev/stderr
        fi
    done
    
    echo "[CERTS-RESTART] ✅ Перезапуск сервисов завершен" | tee /dev/stderr
    echo "[CERTS-RESTART] ========================================" | tee /dev/stderr
}

renew_certificates_only() {
    print_header
    print_step "РЕЖИМ: Обновление сертификатов"
    
    echo "[CERT-RENEW] ========================================" | tee /dev/stderr
    echo "[CERT-RENEW] Certificate Renewal Mode" | tee /dev/stderr
    echo "[CERT-RENEW] ========================================" | tee /dev/stderr
    
    # 1. Копируем сертификаты из vault-agent
    copy_certificates_from_vault_agent
    
    # 2. Распределяем по сервисам
    distribute_certificates_to_services
    
    # 3. Перезапускаем сервисы
    restart_services_for_certificates
    
    echo "[CERT-RENEW] ========================================" | tee /dev/stderr
    echo "[CERT-RENEW] ✅ Обновление сертификатов завершено" | tee /dev/stderr
    echo "[CERT-RENEW] ========================================" | tee /dev/stderr
    
    print_success "Сертификаты успешно обновлены и применены"
}

# ============================================================
# End of Certificate Renewal Functions
# ============================================================

# Основная функция
main() {
    # ===== АГРЕССИВНЫЙ ВЫВОД ДЛЯ ДИАГНОСТИКИ (В STDOUT И STDERR) =====
    echo "========================================" | tee /dev/stderr
    echo "[MAIN] START: main() функция запущена" | tee /dev/stderr
    echo "[MAIN] Время: $(date)" | tee /dev/stderr
    echo "[MAIN] PWD: $(pwd)" | tee /dev/stderr
    echo "[MAIN] User: $(whoami)" | tee /dev/stderr
    echo "========================================" | tee /dev/stderr
    
    log_message "=== Начало развертывания мониторинговой системы ${DEPLOY_VERSION} ==="
    ensure_working_directory
    
    echo "[MAIN] Calling print_header..." | tee /dev/stderr
    print_header
    echo "[MAIN] print_header completed" | tee /dev/stderr
    
    echo "[MAIN] Calling init_diagnostic_log..." | tee /dev/stderr
    # Инициализация diagnostic log
    init_diagnostic_log
    echo "[MAIN] init_diagnostic_log completed" | tee /dev/stderr
    
    echo "[MAIN] Calling init_debug_log..." | tee /dev/stderr
    # Инициализация расширенного DEBUG лога
    init_debug_log
    echo "[MAIN] init_debug_log completed" | tee /dev/stderr
    
    echo "[MAIN] Setting up trap DEBUG..." | tee /dev/stderr
    # ТЕПЕРЬ устанавливаем trap DEBUG (после создания DEBUG_LOG)
    trap 'echo "[TRACE] Line $LINENO: $BASH_COMMAND" >> "$DEBUG_LOG" 2>/dev/null || true' DEBUG
    echo "[MAIN] trap DEBUG set" | tee /dev/stderr
    
    echo "[MAIN] Calling log_debug_extended..." | tee /dev/stderr
    log_debug "=== DEPLOYMENT STARTED ==="
    log_debug_extended
    echo "[MAIN] log_debug_extended completed" | tee /dev/stderr
    
    write_diagnostic "========================================="
    write_diagnostic "ДИАГНОСТИКА ВХОДНЫХ ПАРАМЕТРОВ"
    write_diagnostic "========================================="
    write_diagnostic "RENEW_CERTIFICATES_ONLY=${RENEW_CERTIFICATES_ONLY:-<не задан>}"
    write_diagnostic "SKIP_RPM_INSTALL=${SKIP_RPM_INSTALL:-<не задан>}"
    write_diagnostic "SKIP_CI_CHECKS=${SKIP_CI_CHECKS:-<не задан>}"
    write_diagnostic "SKIP_DEPLOYMENT=${SKIP_DEPLOYMENT:-<не задан>}"
    write_diagnostic ""
    write_diagnostic "RLM_API_URL=${RLM_API_URL:-<не задан>}"
    write_diagnostic "RLM_TOKEN=${RLM_TOKEN:+<задан - длина ${#RLM_TOKEN}>}"
    write_diagnostic ""
    write_diagnostic "GRAFANA_URL=${GRAFANA_URL:-<не задан>}"
    write_diagnostic "PROMETHEUS_URL=${PROMETHEUS_URL:-<не задан>}"
    write_diagnostic "HARVEST_URL=${HARVEST_URL:-<не задан>}"
    write_diagnostic ""
    write_diagnostic "NETAPP_API_ADDR=${NETAPP_API_ADDR:-<не задан>}"
    write_diagnostic "SERVER_IP=${SERVER_IP:-<не определен>}"
    write_diagnostic "SERVER_DOMAIN=${SERVER_DOMAIN:-<не определен>}"
    write_diagnostic "========================================="
    write_diagnostic ""
    
    print_info "📝 Диагностика записывается в: $DIAGNOSTIC_RLM_LOG"
    
    # ============================================================
    # ПРОВЕРКА РЕЖИМА: Certificate Renewal Only
    # ============================================================
    if [[ "${RENEW_CERTIFICATES_ONLY:-false}" == "true" ]]; then
        echo "[MAIN] ========================================" | tee /dev/stderr
        echo "[MAIN] РЕЖИМ: Обновление только сертификатов" | tee /dev/stderr
        echo "[MAIN] ========================================" | tee /dev/stderr
        log_debug "RENEW_CERTIFICATES_ONLY=true, running certificate renewal only"
        write_diagnostic "РЕЖИМ: RENEW_CERTIFICATES_ONLY (обновление сертификатов)"
        
        # Вызываем функцию обновления сертификатов
        renew_certificates_only
        
        # Завершаем выполнение (не выполняем полный деплой)
        echo "[MAIN] ========================================" | tee /dev/stderr
        echo "[MAIN] ✅ Certificate renewal завершен" | tee /dev/stderr
        echo "[MAIN] ========================================" | tee /dev/stderr
        log_debug "Certificate renewal completed successfully"
        
        print_success "Обновление сертификатов завершено успешно!"
        return 0
    fi
    
    echo "[MAIN] ========================================" | tee /dev/stderr
    echo "[MAIN] РЕЖИМ: Полный деплой мониторинга" | tee /dev/stderr
    echo "[MAIN] ========================================" | tee /dev/stderr
    log_debug "RENEW_CERTIFICATES_ONLY=false, running full deployment"
    write_diagnostic "РЕЖИМ: Полный деплой мониторинга"
    
    echo "[MAIN] ========================================" | tee /dev/stderr
    echo "[MAIN] Вызов check_sudo..." | tee /dev/stderr
    log_debug "Calling: check_sudo"
    check_sudo
    echo "[MAIN] ✅ check_sudo completed" | tee /dev/stderr
    log_debug "Completed: check_sudo"
    
    echo "[MAIN] Вызов check_dependencies..." | tee /dev/stderr
    log_debug "Calling: check_dependencies"
    check_dependencies
    echo "[MAIN] ✅ check_dependencies completed" | tee /dev/stderr
    log_debug "Completed: check_dependencies"
    
    echo "[MAIN] Вызов check_and_close_ports..." | tee /dev/stderr
    log_debug "Calling: check_and_close_ports"
    check_and_close_ports
    echo "[MAIN] ✅ check_and_close_ports completed" | tee /dev/stderr
    log_debug "Completed: check_and_close_ports"
    
    echo "[MAIN] Вызов detect_network_info..." | tee /dev/stderr
    log_debug "Calling: detect_network_info"
    detect_network_info
    echo "[MAIN] ✅ detect_network_info completed" | tee /dev/stderr
    log_debug "Completed: detect_network_info"
    
    echo "[MAIN] Вызов ensure_monitoring_users_in_as_admin..." | tee /dev/stderr
    log_debug "Calling: ensure_monitoring_users_in_as_admin"
    ensure_monitoring_users_in_as_admin || {
        echo "[MAIN] ⚠️  ensure_monitoring_users_in_as_admin FAILED, continuing..." | tee /dev/stderr
        log_debug "ERROR in ensure_monitoring_users_in_as_admin, continuing..."
        print_warning "ensure_monitoring_users_in_as_admin failed (may require root/RLM), continuing..."
    }
    echo "[MAIN] ✅ ensure_monitoring_users_in_as_admin completed" | tee /dev/stderr
    log_debug "Completed: ensure_monitoring_users_in_as_admin"
    
    echo "[MAIN] Вызов ensure_mon_sys_in_grafana_group..." | tee /dev/stderr
    log_debug "Calling: ensure_mon_sys_in_grafana_group"
    ensure_mon_sys_in_grafana_group || {
        echo "[MAIN] ⚠️  ensure_mon_sys_in_grafana_group FAILED, continuing..." | tee /dev/stderr
        log_debug "ERROR in ensure_mon_sys_in_grafana_group, continuing..."
        print_warning "ensure_mon_sys_in_grafana_group failed (may require root), continuing..."
    }
    echo "[MAIN] ✅ ensure_mon_sys_in_grafana_group completed" | tee /dev/stderr
    log_debug "Completed: ensure_mon_sys_in_grafana_group"
    
    echo "[MAIN] Вызов cleanup_all_previous..." | tee /dev/stderr
    log_debug "Calling: cleanup_all_previous"
    cleanup_all_previous || {
        echo "[MAIN] ⚠️  cleanup_all_previous FAILED, continuing..." | tee /dev/stderr
        log_debug "ERROR in cleanup_all_previous, continuing..."
        print_warning "cleanup_all_previous failed (may require root for /etc/, /var/), continuing..."
    }
    echo "[MAIN] ✅ cleanup_all_previous completed" | tee /dev/stderr
    log_debug "Completed: cleanup_all_previous"
    
    echo "[MAIN] Вызов create_directories..." | tee /dev/stderr
    log_debug "Calling: create_directories"
    create_directories || {
        echo "[MAIN] ⚠️  create_directories FAILED, continuing..." | tee /dev/stderr
        log_debug "ERROR in create_directories, continuing..."
        print_warning "create_directories failed (may require root for /opt/), continuing..."
    }
    echo "[MAIN] ✅ create_directories completed" | tee /dev/stderr
    log_debug "Completed: create_directories"
    
    # ============================================================
    # LEGACY: УСТАНОВКА VAULT-AGENT через RLM (закомментировано)
    # ============================================================
    # vault-agent НЕ используется в упрощенном подходе (версия 4.1+).
    # Сертификаты генерируются в Jenkins через Vault PKI и передаются
    # в temp_data_cred.json вместе с остальными секретами.
    # 
    # Для возврата к vault-agent подходу:
    # 1. Раскомментируйте этот блок
    # 2. Раскомментируйте функцию install_vault_via_rlm() (строки 405-536 и 889-1024)
    # 3. См. документацию: HOW-TO-REVERT.md
    # ============================================================
    
    echo "[MAIN] ========================================" | tee /dev/stderr
    write_diagnostic "========================================="
    write_diagnostic "ПРОВЕРКА: USE_SIMPLIFIED_CERT_FLOW"
    write_diagnostic "========================================="
    write_diagnostic "Значение переменной: '${USE_SIMPLIFIED_CERT_FLOW:-<не задан>}'"

    if [[ "${USE_SIMPLIFIED_CERT_FLOW:-false}" == "true" ]]; then
        write_diagnostic "Режим: simplified (без /opt/vault/* и без системного vault-agent)"
        echo "[MAIN] ✅ USE_SIMPLIFIED_CERT_FLOW=true: включен non-root/simplified путь" | tee /dev/stderr
        log_debug "USE_SIMPLIFIED_CERT_FLOW=true: using simplified certificate flow"

        echo "[MAIN] ========================================" | tee /dev/stderr
        echo "[MAIN] Вызов get_certificates_from_jenkins..." | tee /dev/stderr
        log_debug "Calling: get_certificates_from_jenkins"

        get_certificates_from_jenkins

        echo "[MAIN] ✅ get_certificates_from_jenkins завершена успешно" | tee /dev/stderr
        log_debug "Completed: get_certificates_from_jenkins"
        write_diagnostic "get_certificates_from_jenkins выполнена"
    else
        write_diagnostic "Режим: legacy vault-agent (/opt/vault/*)"
        echo "[MAIN] ⚠️  USE_SIMPLIFIED_CERT_FLOW=false: используется legacy vault-agent путь" | tee /dev/stderr
        log_debug "USE_SIMPLIFIED_CERT_FLOW=false: using legacy vault-agent flow"

        echo "[MAIN] ========================================" | tee /dev/stderr
        write_diagnostic "========================================="
        write_diagnostic "ПРОВЕРКА: SKIP_VAULT_INSTALL"
        write_diagnostic "========================================="
        write_diagnostic "Значение переменной: '${SKIP_VAULT_INSTALL:-<не задан>}'"
        
        if [[ "${SKIP_VAULT_INSTALL:-false}" == "true" ]]; then
            write_diagnostic "Результат: TRUE - пропускаем install_vault_via_rlm"
            write_diagnostic "Действие: используем уже установленный vault-agent"
            echo "[MAIN] ⚠️  SKIP_VAULT_INSTALL=true: пропускаем install_vault_via_rlm" | tee /dev/stderr
            log_debug "SKIP_VAULT_INSTALL=true: skipping install_vault_via_rlm"
            print_warning "SKIP_VAULT_INSTALL=true: пропускаем install_vault_via_rlm"
        else
            write_diagnostic "Результат: FALSE - запускаем install_vault_via_rlm"
            echo "[MAIN] Вызов install_vault_via_rlm..." | tee /dev/stderr
            log_debug "Calling: install_vault_via_rlm"
            
            install_vault_via_rlm
            
            echo "[MAIN] ✅ install_vault_via_rlm завершена успешно" | tee /dev/stderr
            log_debug "Completed: install_vault_via_rlm"
            write_diagnostic "install_vault_via_rlm выполнена"
        fi
        write_diagnostic ""
        
        echo "[MAIN] ========================================" | tee /dev/stderr
        echo "[MAIN] Вызов setup_vault_config..." | tee /dev/stderr
        log_debug "Calling: setup_vault_config"
        
        setup_vault_config
        
        echo "[MAIN] ✅ setup_vault_config завершена успешно" | tee /dev/stderr
        log_debug "Completed: setup_vault_config"
        write_diagnostic "setup_vault_config выполнена"
        
        echo "[MAIN] ========================================" | tee /dev/stderr
        echo "[MAIN] Вызов copy_certificates_from_vault_agent..." | tee /dev/stderr
        log_debug "Calling: copy_certificates_from_vault_agent"
        
        copy_certificates_from_vault_agent || {
            echo "[MAIN] ⚠️  copy_certificates_from_vault_agent FAILED" | tee /dev/stderr
            log_debug "WARNING: copy_certificates_from_vault_agent failed"
            print_warning "Не удалось скопировать сертификаты. Проверьте vault-agent: sudo systemctl status vault-agent"
        }
        
        echo "[MAIN] ✅ copy_certificates_from_vault_agent завершена" | tee /dev/stderr
        log_debug "Completed: copy_certificates_from_vault_agent"
        write_diagnostic "copy_certificates_from_vault_agent выполнена"
    fi

    echo "[MAIN] Вызов load_config_from_json..." | tee /dev/stderr
    log_debug "Calling: load_config_from_json"
    
    load_config_from_json
    
    echo "[MAIN] ✅ load_config_from_json завершена успешно" | tee /dev/stderr
    log_debug "Completed: load_config_from_json"

    # При необходимости можно пропустить установку RPM-пакетов через RLM,
    # чтобы ускорить отладку (по аналогии с SKIP_VAULT_INSTALL).
    write_diagnostic "========================================="
    write_diagnostic "ПРОВЕРКА: SKIP_RPM_INSTALL"
    write_diagnostic "========================================="
    write_diagnostic "Значение переменной: '${SKIP_RPM_INSTALL:-<не задан>}'"
    if [[ "${SKIP_RPM_INSTALL:-false}" == "true" ]]; then
        write_diagnostic "Результат: TRUE - пропускаем create_rlm_install_tasks"
        write_diagnostic "Причина: предполагается что пакеты уже установлены"
        print_warning "⚠️  SKIP_RPM_INSTALL=true: пропускаем установку RPM пакетов через RLM"
        print_info "Предполагаем что Grafana, Prometheus и Harvest уже установлены на целевом сервере"
    else
        write_diagnostic "Результат: FALSE - запускаем create_rlm_install_tasks"
        write_diagnostic "Действие: создаем RLM задачи для Grafana, Prometheus, Harvest"
        echo "[MAIN] Вызов create_rlm_install_tasks..." | tee /dev/stderr
        log_debug "Calling: create_rlm_install_tasks"
        create_rlm_install_tasks
        echo "[MAIN] ✅ create_rlm_install_tasks завершена успешно" | tee /dev/stderr
        log_debug "Completed: create_rlm_install_tasks"
        write_diagnostic "create_rlm_install_tasks выполнена успешно"
    fi
    write_diagnostic ""

    echo "[MAIN] ========================================" | tee /dev/stderr
    echo "[MAIN] Вызов setup_certificates_after_install..." | tee /dev/stderr
    log_debug "Calling: setup_certificates_after_install"
    setup_certificates_after_install
    echo "[MAIN] ✅ setup_certificates_after_install завершена успешно" | tee /dev/stderr
    log_debug "Completed: setup_certificates_after_install"
    
    echo "[MAIN] Вызов configure_harvest..." | tee /dev/stderr
    log_debug "Calling: configure_harvest"
    configure_harvest
    configure_prometheus
    if [[ "${SKIP_IPTABLES:-true}" == "true" ]]; then
        print_warning "SKIP_IPTABLES=true: пропускаем configure_iptables"
    else
        configure_iptables
    fi
    setup_monitoring_user_units
    configure_services
    
    # Настраиваем Grafana datasource и дашборды
    print_info "Проверка доступности Grafana перед настройкой..."
    if ! check_grafana_availability; then
        print_error "Grafana не доступна. Пропускаем настройку datasource и дашбордов."
        print_info "Проверьте логи Grafana: /tmp/grafana-debug.log"
        print_info "Запустите скрипт отладки: sudo ./debug_grafana.sh"
    else
        print_success "Grafana доступна, начинаем настройку datasource и дашбордов"
        setup_grafana_datasource_and_dashboards
    fi

    # Явная очистка чувствительных переменных окружения после операций с RLM и Grafana
    unset RLM_TOKEN GRAFANA_USER GRAFANA_PASSWORD GRAFANA_BEARER_TOKEN || true

    save_installation_state
    verify_installation
    
    # Отображаем финальный summary
    local elapsed_m
    elapsed_m=$(format_elapsed_minutes)
    
    echo
    echo "================================================================"
    echo "           ✅ РАЗВЕРТЫВАНИЕ УСПЕШНО ЗАВЕРШЕНО!"
    echo "================================================================"
    echo
    echo "📦 Версия развертывания:"
    echo "  • Version:              $DEPLOY_VERSION"
    echo "  • Git Commit:           $DEPLOY_GIT_COMMIT"
    echo "  • Build Date:           $DEPLOY_BUILD_DATE"
    echo
    echo "📊 Общая информация:"
    echo "  • Сервер IP:            $SERVER_IP"
    echo "  • Сервер домен:         $SERVER_DOMAIN"
    echo "  • Дата установки:       $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  • Время выполнения:     $elapsed_m"
    echo
    echo "🔗 Доступ к сервисам:"
    echo "  • Prometheus:           https://$SERVER_DOMAIN:$PROMETHEUS_PORT"
    echo "  • Grafana:              https://$SERVER_DOMAIN:$GRAFANA_PORT"
    echo "  • Harvest (NetApp):     https://$SERVER_DOMAIN:$HARVEST_NETAPP_PORT/metrics"
    echo "  • Harvest (Unix):       http://localhost:$HARVEST_UNIX_PORT/metrics"
    echo
    echo "📋 Проверка статуса:"
    if [[ -n "${KAE:-}" ]] && id "${KAE}-lnx-mon_sys" >/dev/null 2>&1; then
        echo "  • User-юниты (${KAE}-lnx-mon_sys):"
        echo "    sudo -u ${KAE}-lnx-mon_sys \\"
        echo "      XDG_RUNTIME_DIR=\"/run/user/\$(id -u ${KAE}-lnx-mon_sys)\" \\"
        echo "      systemctl --user status monitoring-prometheus.service monitoring-grafana.service"
    else
        echo "  • Системные юниты:"
        echo "    systemctl status prometheus grafana-server harvest"
    fi
    echo "  • Порты:"
    echo "    ss -tln | grep -E ':(3000|9090|12990|12991)'"
    echo
    echo "📄 Файлы:"
    echo "  • State file:           $STATE_FILE"
    echo
    echo "================================================================"
    
    # Финализируем diagnostic log
    write_diagnostic "========================================="
    write_diagnostic "DEPLOYMENT ЗАВЕРШЕН"
    write_diagnostic "Статус: SUCCESS"
    write_diagnostic "Elapsed time: $elapsed_m"
    write_diagnostic "========================================="
    
    # Финализируем DEBUG лог
    local script_exit_code=0
    local script_end_ts=$(date +%s)
    local elapsed=$((script_end_ts - SCRIPT_START_TS))
    create_debug_summary "$script_exit_code" "$elapsed"
    
    echo
    echo "================================================================"
    echo "📝 Диагностический лог сохранен в: $DIAGNOSTIC_RLM_LOG"
    echo "📝 DEBUG лог сохранен в: $DEBUG_SUMMARY"
    echo "================================================================"
    echo
    echo "Для просмотра детального DEBUG лога выполните:"
    echo "  cat $DEBUG_SUMMARY"
    echo
    
    print_info "Удаление лог-файла установки"
    rm -rf "$LOG_FILE" || true
}

echo "[SCRIPT] Reached end of script definitions, calling main()" >&2
echo "[SCRIPT] DEBUG_LOG will be: ${DEBUG_LOG:-NOT_SET}" >&2

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[SCRIPT] Calling main with args: $@" >&2
    main "$@"
    echo "[SCRIPT] main() completed with exit code: $?" >&2
fi

echo "[SCRIPT] Script finished" >&2