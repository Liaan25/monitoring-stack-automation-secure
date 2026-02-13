#!/bin/bash
# Тестовый скрипт для проверки исправлений

echo "=== Тестирование исправлений для install-monitoring-stack.sh ==="
echo

# 1. Проверка синтаксиса
echo "1. Проверка синтаксиса скрипта..."
if bash -n install-monitoring-stack.sh; then
    echo "✅ Синтаксис корректен"
else
    echo "❌ Ошибка синтаксиса"
    exit 1
fi

echo

# 2. Проверка первой строки (shebang)
echo "2. Проверка shebang..."
first_line=$(head -1 install-monitoring-stack.sh)
if [[ "$first_line" == "#!/bin/bash" ]]; then
    echo "✅ Shebang корректен: $first_line"
else
    echo "❌ Неправильный shebang: $first_line"
    exit 1
fi

echo

# 3. Проверка инициализации переменных SKIP_*
echo "3. Проверка инициализации переменных SKIP_*..."
if grep -q ': "\${SKIP_VAULT_INSTALL:=false}"' install-monitoring-stack.sh; then
    echo "✅ SKIP_VAULT_INSTALL инициализирована"
else
    echo "❌ SKIP_VAULT_INSTALL не инициализирована"
fi

if grep -q ': "\${SKIP_RPM_INSTALL:=false}"' install-monitoring-stack.sh; then
    echo "✅ SKIP_RPM_INSTALL инициализирована"
else
    echo "❌ SKIP_RPM_INSTALL не инициализирована"
fi

if grep -q ': "\${SKIP_CI_CHECKS:=false}"' install-monitoring-stack.sh; then
    echo "✅ SKIP_CI_CHECKS инициализирована"
else
    echo "❌ SKIP_CI_CHECKS не инициализирована"
fi

echo

# 4. Проверка исправления в генерации agent.hcl
echo "4. Проверка исправления в генерации agent.hcl..."
# Проверяем что нет лишнего EOF в строке 2028
if grep -n "EOF" install-monitoring-stack.sh | grep -A1 -B1 "2028:"; then
    echo "⚠️  Проверьте строку 2028 на наличие лишнего EOF"
else
    echo "✅ Проблема с лишним EOF исправлена"
fi

echo

# 5. Проверка соответствия backup версии
echo "5. Сравнение с backup версией..."
diff_count=$(diff -u install-monitoring-stack.sh install-monitoring-stack.sh.backup | grep -c "^[-+]" || true)
if [[ $diff_count -gt 10 ]]; then
    echo "⚠️  Много различий с backup версией ($diff_count строк)"
    echo "   (это может быть нормально, если были внесены исправления)"
else
    echo "✅ Минимальные различия с backup версией"
fi

echo

# 6. Проверка наличия критических функций
echo "6. Проверка наличия критических функций..."
required_functions=(
    "setup_vault_config"
    "setup_certificates_after_install"
    "copy_certs_to_user_dirs"
    "main"
)

for func in "${required_functions[@]}"; do
    if grep -q "^$func()" install-monitoring-stack.sh; then
        echo "✅ Функция $func найдена"
    else
        echo "❌ Функция $func не найдена"
    fi
done

echo
echo "=== Тестирование завершено ==="
echo
echo "Рекомендации:"
echo "1. Запустите полный пайплайн для проверки всех исправлений"
echo "2. Проверьте логи на наличие ошибок генерации agent.hcl"
echo "3. Убедитесь что vault-agent создает сертификаты"
echo "4. Проверьте что сертификаты копируются в user-space"