#!/bin/bash
# Минимальный тест - копия первых 15 строк основного скрипта

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

echo "[SCRIPT_START] Test completed successfully" >&2