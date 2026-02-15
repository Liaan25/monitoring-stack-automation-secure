#!/bin/bash
# Скрипт-обёртка для безопасной записи конфигурационных файлов.
# Принимает путь к файлу из белого списка и читает содержимое из stdin.
#
# Использование:
#   config-writer.sh /etc/grafana/grafana.ini <<EOF
#   ...контент...
#   EOF

set -euo pipefail

TARGET_PATH="${1:-}"

log() {
  echo "[CONFIG_WRITER] $*"
}

fail() {
  echo "[CONFIG_WRITER][ERROR] $*" >&2
  exit 1
}

validate_target() {
  local path="$1"
  
  # Для Secure Edition: разрешаем пути в домашней директории пользователя
  # Это соответствует архитектуре Secure Edition (все файлы в user-space)
  local home_pattern="^$HOME/"
  
  if [[ "$path" =~ $home_pattern ]]; then
    # Разрешаем только определенные поддиректории в домашней директории
    case "$path" in
      "$HOME"/monitoring/config/vault/agent.hcl|\
      "$HOME"/monitoring/config/vault/role_id.txt|\
      "$HOME"/monitoring/config/vault/secret_id.txt|\
      "$HOME"/monitoring/config/grafana/grafana.ini|\
      "$HOME"/monitoring/config/prometheus/prometheus.yml|\
      "$HOME"/monitoring/config/prometheus/web-config.yml|\
      "$HOME"/monitoring/config/prometheus/prometheus.env|\
      "$HOME"/monitoring/config/harvest/harvest.yml|\
      "$HOME"/monitoring/state/deployment_state)
        return 0
        ;;
      *)
        # Также разрешаем любые файлы в monitoring/ для гибкости
        # но с проверкой что это действительно monitoring директория
        if [[ "$path" == "$HOME"/monitoring/* ]]; then
          return 0
        fi
        ;;
    esac
  fi
  
  # Системные пути (для обратной совместимости)
  case "$path" in
    /etc/environment.d/99-monitoring-vars.conf|\
    /opt/vault/conf/agent.hcl|\
    /opt/vault/conf/role_id.txt|\
    /opt/vault/conf/secret_id.txt|\
    /etc/grafana/grafana.ini|\
    /etc/prometheus/web-config.yml|\
    /etc/prometheus/prometheus.env|\
    /etc/profile.d/harvest.sh|\
    /opt/harvest/harvest.yml|\
    /etc/systemd/system/harvest.service|\
    /etc/prometheus/prometheus.yml|\
    /var/lib/monitoring_deployment_state)
      return 0
      ;;
    *)
      fail "Путь не входит в белый список: $path"
      ;;
  esac
}

main() {
  [[ -n "$TARGET_PATH" ]] || fail "Не задан целевой файл"
  validate_target "$TARGET_PATH"

  local dir
  dir="$(dirname "$TARGET_PATH")"
  mkdir -p "$dir"

  # Пишем stdin в целевой файл
  cat > "$TARGET_PATH"

  log "Файл записан: $TARGET_PATH"
}

main "$@"


