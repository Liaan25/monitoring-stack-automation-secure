#!/bin/bash
# Диагностический скрипт для проверки извлечения секретов

echo "=== ДИАГНОСТИКА ИЗВЛЕЧЕНИЯ СЕКРЕТОВ ==="
echo ""

# 1. Проверяем наличие файла с секретами
SECRETS_FILE="/home/CI10742292-lnx-mon_ci/monitoring-deployment/temp_data_cred.json"
echo "1. Проверка файла секретов: $SECRETS_FILE"
if [[ -f "$SECRETS_FILE" ]]; then
    echo "✅ Файл существует"
    echo "   Размер: $(stat -c%s "$SECRETS_FILE") байт"
    echo "   Права: $(ls -la "$SECRETS_FILE")"
    
    # Проверяем содержимое
    echo "   Содержит поле vault-agent:"
    if jq -e '.vault-agent' "$SECRETS_FILE" >/dev/null 2>&1; then
        echo "   ✅ Поле vault-agent существует"
        echo "   role_id: $(jq -r '.vault-agent.role_id' "$SECRETS_FILE" 2>/dev/null | head -c 20)..."
        echo "   secret_id: $(jq -r '.vault-agent.secret_id' "$SECRETS_FILE" 2>/dev/null | head -c 20)..."
    else
        echo "   ❌ Поле vault-agent НЕ существует"
    fi
else
    echo "❌ Файл НЕ существует"
fi

echo ""
echo "2. Проверка наличия jq:"
if command -v jq >/dev/null 2>&1; then
    echo "✅ jq установлен: $(jq --version)"
else
    echo "❌ jq НЕ установлен"
fi

echo ""
echo "3. Проверка wrappers:"
WRAPPERS_DIR="/home/CI10742292-lnx-mon_ci/monitoring-deployment/wrappers"
echo "   Директория: $WRAPPERS_DIR"
if [[ -d "$WRAPPERS_DIR" ]]; then
    echo "   ✅ Директория существует"
    ls -la "$WRAPPERS_DIR/"
    
    WRAPPER="$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh"
    if [[ -f "$WRAPPER" ]]; then
        echo "   ✅ wrapper найден"
        echo "   Права: $(ls -la "$WRAPPER")"
        
        if [[ -x "$WRAPPER" ]]; then
            echo "   ✅ wrapper исполняемый"
            
            # Пробуем запустить wrapper
            echo ""
            echo "4. Тест работы wrapper:"
            echo "   Тест извлечения role_id:"
            result=$("$WRAPPER" extract_secret "$SECRETS_FILE" "vault-agent.role_id" 2>&1)
            exit_code=$?
            echo "   Код возврата: $exit_code"
            echo "   Результат: '$result'"
            echo "   Длина: ${#result}"
            
            echo ""
            echo "   Тест извлечения secret_id:"
            result=$("$WRAPPER" extract_secret "$SECRETS_FILE" "vault-agent.secret_id" 2>&1)
            exit_code=$?
            echo "   Код возврата: $exit_code"
            echo "   Результат: '$(echo "$result" | head -c 20)...'"
            echo "   Длина: ${#result}"
        else
            echo "   ❌ wrapper НЕ исполняемый"
            echo "   Попробуем сделать исполняемым:"
            chmod +x "$WRAPPER" 2>&1
            echo "   Результат chmod: $?"
        fi
    else
        echo "   ❌ wrapper НЕ найден"
    fi
else
    echo "   ❌ Директория wrappers НЕ существует"
fi

echo ""
echo "5. Проверка текущего пользователя:"
echo "   whoami: $(whoami)"
echo "   id: $(id)"
echo "   Группы: $(groups)"

echo ""
echo "6. Проверка путей:"
echo "   PWD: $PWD"
echo "   HOME: $HOME"
echo "   WRAPPERS_DIR: $WRAPPERS_DIR"

echo ""
echo "=== ДИАГНОСТИКА ЗАВЕРШЕНА ==="