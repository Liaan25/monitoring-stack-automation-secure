#!/bin/bash
# Launcher для vault-credentials-installer.sh
# Соответствует паттерну других launcher'ов в проекте
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SCRIPT="${SCRIPT_DIR}/vault-credentials-installer.sh"

# Проверка существования wrapper'а
if [[ ! -f "$WRAPPER_SCRIPT" ]]; then
    echo "[ERROR] Wrapper не найден: $WRAPPER_SCRIPT" >&2
    exit 1
fi

# Проверка что wrapper исполняемый
if [[ ! -x "$WRAPPER_SCRIPT" ]]; then
    echo "[ERROR] Wrapper не исполняемый: $WRAPPER_SCRIPT" >&2
    exit 1
fi

# Запуск wrapper'а с переданными аргументами
exec "$WRAPPER_SCRIPT" "$@"
