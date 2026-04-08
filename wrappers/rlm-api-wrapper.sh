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
RLM_MTLS_DEBUG="${RLM_MTLS_DEBUG:-true}"
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

debug() {
  if [[ "${RLM_MTLS_DEBUG}" == "true" || "${LOG_LEVEL:-}" == "debug" ]]; then
    echo "[RLM_WRAPPER][DEBUG] $*" >&2
  fi
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
    debug "mTLS: используются внешние пути cert=${RLM_TLS_CERT_FILE}, key=${RLM_TLS_KEY_FILE}, cacert=${RLM_TLS_CA_FILE:-<not set>}"
    return 0
  fi

  # Авто-режим: читаем mTLS-материалы из temp_data_cred*.json, который уже кладется Jenkins-ом.
  local cred_json="${CRED_JSON_PATH:-}"
  if [[ -z "${cred_json}" || ! -f "${cred_json}" ]]; then
    debug "mTLS: CRED_JSON_PATH не задан или файл не найден, fallback без mTLS"
    return 0
  fi
  debug "mTLS: пробуем извлечь сертификаты из ${cred_json}"
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
    debug "mTLS: сертификатный bundle пуст в ${cred_json}, fallback без mTLS"
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
  debug "mTLS: материалы подготовлены cert=${RLM_TLS_CERT_FILE}, key=${RLM_TLS_KEY_FILE}, cacert=${RLM_TLS_CA_FILE:-<not set>}"
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
    debug "mTLS: включен для ${RLM_API_URL}"
  else
    # Legacy fallback: без mTLS сохраним старое поведение.
    out_arr+=(-k)
    debug "mTLS: НЕ включен для ${RLM_API_URL}, используется fallback -k"
  fi
}

parse_rlm_host_port() {
  local url_no_scheme host_port host port
  url_no_scheme="${RLM_API_URL#https://}"
  host_port="${url_no_scheme%%/*}"
  host="${host_port%%:*}"
  port="${host_port##*:}"
  if [[ "${host_port}" == "${host}" ]]; then
    port="443"
  fi
  echo "${host}:${port}"
}

run_connection_diagnostics() {
  local tls_args=()
  build_tls_args tls_args

  local host_port host port
  host_port="$(parse_rlm_host_port)"
  host="${host_port%%:*}"
  port="${host_port##*:}"

  debug "diag: MODE=${MODE}"
  debug "diag: runtime_user=$(id -un 2>/dev/null || echo unknown), uid=$(id -u 2>/dev/null || echo unknown), gid=$(id -g 2>/dev/null || echo unknown)"
  debug "diag: groups=$(id -Gn 2>/dev/null || echo unknown)"
  debug "diag: hostname=$(hostname 2>/dev/null || echo unknown), pwd=$(pwd), shell=${SHELL:-unknown}"
  debug "diag: env USER=${USER:-}, LOGNAME=${LOGNAME:-}, SUDO_USER=${SUDO_USER:-}, SSH_CONNECTION=${SSH_CONNECTION:-}"
  debug "diag: target rlm_url=${RLM_API_URL}, host=${host}, port=${port}"

  if command -v getent >/dev/null 2>&1; then
    debug "diag: dns(getent)=$(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  elif command -v nslookup >/dev/null 2>&1; then
    debug "diag: dns(nslookup)=$(nslookup "${host}" 2>/dev/null | sed -n 's/^Address: //p' | tr '\n' ' ' || true)"
  else
    debug "diag: dns tools not found (getent/nslookup)"
  fi

  local tcp_rc=1
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1 || tcp_rc=$?
    if [[ ${tcp_rc} -eq 0 ]]; then
      debug "diag: tcp_connect ${host}:${port} -> OK"
    else
      debug "diag: tcp_connect ${host}:${port} -> FAIL (rc=${tcp_rc})"
    fi
  else
    debug "diag: timeout command not found, tcp probe skipped"
  fi

  if command -v curl >/dev/null 2>&1; then
    local probe_http_code probe_out probe_rc=0
    probe_out="$(curl -sS -o /dev/null -w '%{http_code}' \
      "${tls_args[@]}" \
      --connect-timeout 7 --max-time 15 \
      -H "Accept: application/json" \
      -H "Authorization: Token ${RLM_TOKEN}" \
      "${RLM_API_URL}/api/tasks/0/" 2>&1)" || probe_rc=$?
    if [[ ${probe_rc} -eq 0 ]]; then
      probe_http_code="${probe_out##*$'\n'}"
      debug "diag: https_probe ${RLM_API_URL}/api/tasks/0/ -> HTTP ${probe_http_code}"
    else
      debug "diag: https_probe ${RLM_API_URL}/api/tasks/0/ -> FAIL (rc=${probe_rc}) output=${probe_out}"
    fi
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

  if [[ "$MODE" == create_* ]] && [[ "${RLM_MTLS_DEBUG}" == "true" || "${LOG_LEVEL:-}" == "debug" ]]; then
    run_connection_diagnostics
  fi

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


