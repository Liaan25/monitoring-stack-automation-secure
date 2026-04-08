#!/bin/bash
# Скрипт-обёртка для работы с RLM API.
# Поддерживает операции:
#   - create_vault_task: создание задачи vault_agent_config
#   - get_vault_status:  получение статуса задачи Vault
#   - create_rpm_task:   создание задачи LINUX_RPM_INSTALLER
#   - get_rpm_status:    получение статуса RPM-задачи
# Параметры (общие):
#   $1 - режим (см. выше)
#   $2 - базовый URL RLM_API_URL (https://... без переменных в sudoers)
#   $3 - токен RLM_TOKEN
# Остальные параметры зависят от режима, а payload передаётся через stdin.

set -euo pipefail

MODE="${1:-}"
RLM_API_URL="${2:-}"
RLM_TOKEN="${3:-}"
RLM_TLS_CERT_FILE="${RLM_TLS_CERT_FILE:-}"
RLM_TLS_KEY_FILE="${RLM_TLS_KEY_FILE:-}"
RLM_TLS_CA_FILE="${RLM_TLS_CA_FILE:-}"
RLM_MTLS_TMP_DIR=""

# Белый список допустимых базовых URL RLM.
# При необходимости добавьте сюда другие значения, согласованные с ИБ.
ALLOWED_RLM_BASES=(
  "https://simple-api.rlm.apps.prom-terra000049-ebm.ocp.sigma.sbrf.ru"
  "https://api.rlm.sber.ru"
)

log() {
  echo "[RLM_WRAPPER] $*"
}

fail() {
  echo "[RLM_WRAPPER][ERROR] $*" >&2
  exit 1
}

validate_url_base() {
  local url="${1%/}"
  # Разрешаем только https-ссылки без пробелов и управляющих символов
  [[ "$url" =~ ^https://[a-zA-Z0-9._:-]+(/.*)?$ ]] || fail "Недопустимый RLM_API_URL (формат): $url"

  local allowed=false
  local base
  for base in "${ALLOWED_RLM_BASES[@]}"; do
    if [[ "$url" == "$base" ]]; then
      allowed=true
      break
    fi
  done

  if [[ "$allowed" != true ]]; then
    fail "RLM_API_URL не входит в белый список: $url"
  fi
}

validate_token() {
  local token="$1"
  [[ -n "$token" ]] || fail "Пустой RLM_TOKEN"
}

validate_task_id() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || fail "Недопустимый task_id: $id"
}

cleanup_mtls_tmp_dir() {
  if [[ -n "${RLM_MTLS_TMP_DIR:-}" && -d "${RLM_MTLS_TMP_DIR}" ]]; then
    rm -rf "${RLM_MTLS_TMP_DIR}" >/dev/null 2>&1 || true
  fi
}

prepare_mtls_materials_if_needed() {
  # Если пути уже переданы извне и доступны - используем их.
  if [[ -n "${RLM_TLS_CERT_FILE}" && -n "${RLM_TLS_KEY_FILE}" ]]; then
    [[ -r "${RLM_TLS_CERT_FILE}" ]] || fail "RLM_TLS_CERT_FILE недоступен: ${RLM_TLS_CERT_FILE}"
    [[ -r "${RLM_TLS_KEY_FILE}" ]] || fail "RLM_TLS_KEY_FILE недоступен: ${RLM_TLS_KEY_FILE}"
    if [[ -n "${RLM_TLS_CA_FILE}" ]]; then
      [[ -r "${RLM_TLS_CA_FILE}" ]] || fail "RLM_TLS_CA_FILE недоступен: ${RLM_TLS_CA_FILE}"
    fi
    return 0
  fi

  # Авто-режим: читаем mTLS-материалы из temp_data_cred*.json, который уже кладется Jenkins-ом.
  local cred_json="${CRED_JSON_PATH:-}"
  if [[ -z "${cred_json}" || ! -f "${cred_json}" ]]; then
    return 0
  fi
  command -v jq >/dev/null 2>&1 || fail "Для mTLS требуется jq"
  command -v openssl >/dev/null 2>&1 || fail "Для mTLS требуется openssl"

  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/rlm-mtls-XXXXXX)"
  chmod 700 "${tmp_dir}" || true

  local bundle_file cert_file key_file ca_file
  bundle_file="${tmp_dir}/client_bundle.pem"
  cert_file="${tmp_dir}/client.crt"
  key_file="${tmp_dir}/client.key"
  ca_file="${tmp_dir}/ca_chain.crt"

  jq -r '.certificates.grafana_client_pem // .certificates.server_bundle_pem // empty' "${cred_json}" > "${bundle_file}" 2>/dev/null || true
  if [[ ! -s "${bundle_file}" ]]; then
    rm -rf "${tmp_dir}" >/dev/null 2>&1 || true
    return 0
  fi

  openssl pkey -in "${bundle_file}" -out "${key_file}" >/dev/null 2>&1 || fail "Не удалось извлечь приватный ключ для mTLS из ${cred_json}"
  openssl crl2pkcs7 -nocrl -certfile "${bundle_file}" | openssl pkcs7 -print_certs -out "${cert_file}" >/dev/null 2>&1 || fail "Не удалось извлечь сертификат для mTLS из ${cred_json}"

  jq -r '.certificates.ca_chain_crt // empty' "${cred_json}" > "${ca_file}" 2>/dev/null || true
  [[ -s "${ca_file}" ]] || rm -f "${ca_file}" >/dev/null 2>&1 || true

  chmod 600 "${bundle_file}" "${cert_file}" "${key_file}" >/dev/null 2>&1 || true
  [[ -f "${ca_file}" ]] && chmod 600 "${ca_file}" >/dev/null 2>&1 || true

  RLM_TLS_CERT_FILE="${cert_file}"
  RLM_TLS_KEY_FILE="${key_file}"
  RLM_TLS_CA_FILE="${ca_file}"
  RLM_MTLS_TMP_DIR="${tmp_dir}"
}

build_tls_args() {
  local -n out_arr=$1
  out_arr=()
  prepare_mtls_materials_if_needed

  if [[ -n "${RLM_TLS_CERT_FILE}" && -n "${RLM_TLS_KEY_FILE}" ]]; then
    [[ -r "${RLM_TLS_CERT_FILE}" ]] || fail "RLM_TLS_CERT_FILE недоступен: ${RLM_TLS_CERT_FILE}"
    [[ -r "${RLM_TLS_KEY_FILE}" ]] || fail "RLM_TLS_KEY_FILE недоступен: ${RLM_TLS_KEY_FILE}"
    out_arr+=(--tlsv1.2 --cert "${RLM_TLS_CERT_FILE}" --key "${RLM_TLS_KEY_FILE}")
    if [[ -n "${RLM_TLS_CA_FILE}" && -r "${RLM_TLS_CA_FILE}" ]]; then
      out_arr+=(--cacert "${RLM_TLS_CA_FILE}")
    fi
  else
    # Legacy fallback: без mTLS сохраним старое поведение.
    out_arr+=(-k)
  fi
}

create_task() {
  local payload
  payload="$(cat)"
  [[ -n "$payload" ]] || fail "Пустой payload для создания задачи"
  local tls_args=()
  build_tls_args tls_args

  curl -sS -X POST "${RLM_API_URL}/api/tasks.json" \
    -H "Accept: application/json" \
    -H "Authorization: Token ${RLM_TOKEN}" \
    -H "Content-Type: application/json" \
    "${tls_args[@]}" \
    --connect-timeout 10 --max-time 30 \
    -d "$payload"
}

get_status() {
  local task_id="$1"
  validate_task_id "$task_id"
  local tls_args=()
  build_tls_args tls_args

  curl -sS -X GET "${RLM_API_URL}/api/tasks/${task_id}/" \
    -H "Accept: application/json" \
    -H "Authorization: Token ${RLM_TOKEN}" \
    -H "Content-Type: application/json" \
    "${tls_args[@]}" \
    --connect-timeout 10 --max-time 30
}

main() {
  [[ -n "$MODE" ]] || fail "Не указан режим работы обёртки (MODE)"
  trap cleanup_mtls_tmp_dir EXIT
  validate_url_base "$RLM_API_URL"
  validate_token "$RLM_TOKEN"

  case "$MODE" in
    create_vault_task|create_rpm_task|create_group_task)
      # Все режимы создания задач используют один и тот же POST /api/tasks.json,
      # различается только service/params в payload, которые формирует внешний скрипт.
      create_task
      ;;
    get_vault_status|get_rpm_status|get_group_status)
      # Все режимы получения статуса используют один и тот же GET /api/tasks/<id>/.
      local task_id="${4:-}"
      [[ -n "$task_id" ]] || fail "Не указан task_id для режима $MODE"
      get_status "$task_id"
      ;;
    *)
      fail "Неизвестный режим: $MODE"
      ;;
  esac
}

main "$@"


