#!/bin/bash
# Скрипт для отладки проблем с install-monitoring-stack.sh

echo "=== Проверка скрипта install-monitoring-stack.sh ==="
echo

# 1. Проверка первых 20 строк
echo "1. Первые 20 строк скрипта:"
echo "----------------------------------------"
head -20 install-monitoring-stack.sh | cat -A
echo "----------------------------------------"
echo

# 2. Проверка невидимых символов
echo "2. Проверка на невидимые символы (первые 5 строк):"
echo "----------------------------------------"
head -5 install-monitoring-stack.sh | od -c | head -20
echo "----------------------------------------"
echo

# 3. Проверка shebang
echo "3. Проверка shebang:"
first_line=$(head -1 install-monitoring-stack.sh)
echo "Первая строка: '$first_line'"
if [[ "$first_line" == "#!/bin/bash" ]]; then
    echo "✅ Shebang корректен"
else
    echo "❌ Shebang некорректен"
    echo "Ожидалось: '#!/bin/bash'"
    echo "Получено: '$first_line'"
fi
echo

# 4. Проверка синтаксиса
echo "4. Проверка синтаксиса:"
if bash -n install-monitoring-stack.sh; then
    echo "✅ Синтаксис корректен"
else
    echo "❌ Ошибка синтаксиса"
    echo "Вывод проверки:"
    bash -n install-monitoring-stack.sh 2>&1
fi
echo

# 5. Проверка исполняемости
echo "5. Проверка прав доступа:"
ls -la install-monitoring-stack.sh
echo

# 6. Тестовый запуск первых команд
echo "6. Тестовый запуск первых команд скрипта:"
echo "----------------------------------------"
# Создаем временный скрипт с первыми 50 строками
head -50 install-monitoring-stack.sh > /tmp/test_script.sh
chmod +x /tmp/test_script.sh
echo "Запускаем первые 50 строк..."
/tmp/test_script.sh
echo "Код возврата: $?"
echo "----------------------------------------"