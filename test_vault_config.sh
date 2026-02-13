#!/bin/bash
# Тестовый скрипт для проверки исправлений vault-config

set -e

echo "=== ТЕСТИРОВАНИЕ ИСПРАВЛЕНИЙ VAULT-CONFIG ==="
echo ""

# Создаем тестовые переменные окружения
export NAMESPACE_CI="CI04523276_CI10742292"
export KAE="CI10742292"
export SEC_MAN_ADDR="T.SECRETS.DELTA.SBRF.RU"
export RPM_URL_KV="kv/path/rpm_url"
export NETAPP_SSH_KV="kv/path/netapp_ssh"
export GRAFANA_WEB_KV="kv/path/grafana_web"
export VAULT_AGENT_KV="kv/path/vault_agent"
export SBERCA_CERT_KV="kv/path/sberca_cert"
export ADMIN_EMAIL="admin@example.com"
export SERVER_DOMAIN="test-server.example.com"

# Создаем временный каталог для теста
TEST_DIR=$(mktemp -d)
echo "Тестовый каталог: $TEST_DIR"
cd "$TEST_DIR"

# Создаем структуру каталогов
mkdir -p wrappers monitoring/config/vault monitoring/logs/vault monitoring/certs/vault

# Создаем mock wrappers
cat > wrappers/secrets-manager-wrapper_launcher.sh << 'EOF'
#!/bin/bash
echo "mock-secret-value"
EOF
chmod +x wrappers/secrets-manager-wrapper_launcher.sh

# Создаем тестовый cred.json
cat > temp_data_cred.json << 'EOF'
{
  "vault-agent": {
    "role_id": "test-role-id-123",
    "secret_id": "test-secret-id-456"
  },
  "grafana_web": {
    "user": "admin",
    "pass": "admin123"
  },
  "netapp_ssh": {
    "addr": "siena.delta.sbrf.ru",
    "user": "sshuser",
    "pass": "sshpass"
  },
  "rpm_url": {
    "grafana": "https://example.com/grafana.rpm",
    "prometheus": "https://example.com/prometheus.rpm",
    "harvest": "https://example.com/harvest.rpm"
  }
}
EOF

# Копируем исправленный скрипт
cp "../../monitoring-stack-automation-secure/install-monitoring-stack.sh" .
# Вырезаем только функцию setup_vault_config для тестирования
sed -n '/^setup_vault_config() {/,/^}/p' install-monitoring-stack.sh > test_vault_func.sh

# Добавляем необходимые вспомогательные функции
cat >> test_vault_func.sh << 'EOF'

# Mock функции
print_step() { echo "[STEP] $1"; }
print_error() { echo "[ERROR] $1"; }
print_success() { echo "[SUCCESS] $1"; }
print_warning() { echo "[WARNING] $1"; }
print_info() { echo "[INFO] $1"; }
log_debug() { echo "[DEBUG] $1"; }
ensure_working_directory() { echo "[ENSURE] Working directory: $PWD"; }
ensure_user_in_va_start_group() { 
    echo "[ENSURE] Mock: adding user $1 to va-start group"; 
    return 0; 
}

# Mock переменные
WRAPPERS_DIR="$PWD/wrappers"
VAULT_CONF_DIR="$PWD/monitoring/config/vault"
VAULT_LOG_DIR="$PWD/monitoring/logs/vault"
VAULT_CERTS_DIR="$PWD/monitoring/certs/vault"
VAULT_AGENT_HCL="$VAULT_CONF_DIR/agent.hcl"
VAULT_ROLE_ID_FILE="$VAULT_CONF_DIR/role_id.txt"
VAULT_SECRET_ID_FILE="$VAULT_CONF_DIR/secret_id.txt"
LOCAL_CRED_JSON="$PWD/temp_data_cred.json"
DIAGNOSTIC_RLM_LOG="$PWD/diagnostic.log"

# Запускаем тест
echo "=== ЗАПУСК ТЕСТА setup_vault_config ==="
setup_vault_config

echo ""
echo "=== ПРОВЕРКА РЕЗУЛЬТАТОВ ==="

# Проверяем созданные файлы
echo "1. Проверка user-space файлов:"
ls -la monitoring/config/vault/

echo ""
echo "2. Проверка содержимого user-space agent.hcl:"
if [[ -f "monitoring/config/vault/agent.hcl" ]]; then
    echo "✅ Файл создан"
    # Проверяем наличие правильных путей
    if grep -q "\$HOME/monitoring" monitoring/config/vault/agent.hcl; then
        echo "✅ Содержит user-space пути"
    else
        echo "❌ НЕ содержит user-space пути"
    fi
else
    echo "❌ Файл НЕ создан"
fi

echo ""
echo "3. Проверка role_id и secret_id:"
if [[ -f "monitoring/config/vault/role_id.txt" ]]; then
    echo "✅ role_id.txt создан"
    echo "   Содержимое: $(cat monitoring/config/vault/role_id.txt)"
else
    echo "❌ role_id.txt НЕ создан"
fi

if [[ -f "monitoring/config/vault/secret_id.txt" ]]; then
    echo "✅ secret_id.txt создан"
    echo "   Содержимое: $(cat monitoring/config/vault/secret_id.txt | head -c 20)..."
else
    echo "❌ secret_id.txt НЕ создан"
fi

echo ""
echo "=== ТЕСТ ЗАВЕРШЕН ==="
EOF

# Запускаем тест
chmod +x test_vault_func.sh
./test_vault_func.sh

# Очистка
cd /
rm -rf "$TEST_DIR"