#!/bin/bash
# Тест извлечения секретов

echo "=== ТЕСТ ИЗВЛЕЧЕНИЯ СЕКРЕТОВ ==="

# Создаем тестовый JSON файл
cat > test_cred.json << 'EOF'
{
  "vault-agent": {
    "role_id": "test-role-id-123456",
    "secret_id": "test-secret-id-789012"
  },
  "grafana_web": {
    "user": "admin",
    "pass": "admin123"
  }
}
EOF

echo "1. Содержимое test_cred.json:"
cat test_cred.json
echo ""

echo "2. Проверка наличия wrappers:"
if [[ -f "wrappers/secrets-manager-wrapper_launcher.sh" ]]; then
    echo "✅ wrapper найден"
    chmod +x wrappers/secrets-manager-wrapper_launcher.sh
else
    echo "❌ wrapper не найден"
    # Создаем простой mock wrapper
    mkdir -p wrappers
    cat > wrappers/secrets-manager-wrapper_launcher.sh << 'EOF'
#!/bin/bash
echo "mock-secret-value"
EOF
    chmod +x wrappers/secrets-manager-wrapper_launcher.sh
    echo "✅ mock wrapper создан"
fi

echo ""
echo "3. Тест извлечения role_id:"
WRAPPERS_DIR="wrappers"
result=$("$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" extract_secret "test_cred.json" "vault-agent.role_id" 2>&1)
echo "Результат: '$result'"
echo "Длина: ${#result}"

echo ""
echo "4. Тест извлечения несуществующего поля:"
result=$("$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" extract_secret "test_cred.json" "vault-agent.nonexistent" 2>&1)
echo "Результат: '$result'"
echo "Код возврата: $?"

echo ""
echo "=== ТЕСТ ЗАВЕРШЕН ==="