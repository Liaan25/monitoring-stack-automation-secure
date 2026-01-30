#!/bin/bash
# Генерация лаунчеров с проверкой sha256 для скриптов-обёрток.
# Запускается в Jenkins после git clone, чтобы на каждый коммит
# хеши соответствовали актуальным версиям обёрток.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

create_launcher() {
  local launcher_name="$1"    # например, firewall-manager_launcher.sh
  local wrapper_name="$2"     # например, firewall-manager.sh

  local wrapper_path="$SCRIPT_DIR/$wrapper_name"
  local launcher_path="$SCRIPT_DIR/$launcher_name"

  if [[ ! -f "$wrapper_path" ]]; then
    echo "[build-integrity-checkers] Обёртка не найдена: $wrapper_path" >&2
    exit 1
  fi

  # Гарантируем, что сама обёртка исполняемая (на случае, если в репозитории нет +x)
  chmod 700 "$wrapper_path"

  local hash
  hash=$(sha256sum "$wrapper_path" | awk '{print $1}')

  cat > "$launcher_path" <<EOF
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="\$SCRIPT_DIR/$wrapper_name"
EXPECTED_HASH="$hash"

calc_hash=\$(sha256sum "\$WRAPPER" 2>/dev/null | awk '{print \$1}')
if [[ "\$calc_hash" != "\$EXPECTED_HASH" ]]; then
  echo "[SECURITY] Hash mismatch for \$WRAPPER" >&2
  exit 1
fi

exec "\$WRAPPER" "\$@"
EOF

  chmod 700 "$launcher_path"
  echo "[build-integrity-checkers] Лаунчер создан: $launcher_path (hash=$hash)"
}

create_launcher "firewall-manager_launcher.sh" "firewall-manager.sh"
create_launcher "rlm-api-wrapper_launcher.sh" "rlm-api-wrapper.sh"
create_launcher "grafana-api-wrapper_launcher.sh" "grafana-api-wrapper.sh"
create_launcher "config-writer_launcher.sh" "config-writer.sh"
create_launcher "secrets-manager-wrapper_launcher.sh" "secrets-manager-wrapper.sh"


