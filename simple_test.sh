#!/bin/bash
# Простой тест первых строк скрипта

echo "=== Тест первых 50 строк install-monitoring-stack.sh ==="

# Создаем временный файл с первыми 50 строками
head -50 install-monitoring-stack.sh > test_first_50.sh
chmod +x test_first_50.sh

echo "Запускаем тестовый скрипт..."
echo "----------------------------------------"
./test_first_50.sh
exit_code=$?
echo "----------------------------------------"
echo "Код возврата: $exit_code"

if [ $exit_code -eq 0 ]; then
    echo "✅ Первые 50 строк работают"
else
    echo "❌ Ошибка в первых 50 строках"
    
    # Попробуем запустить по строкам
    echo ""
    echo "=== Построчная отладка ==="
    line_num=1
    while IFS= read -r line; do
        if [ $line_num -le 50 ]; then
            echo "Строка $line_num: $line"
            # Проверяем непустые строки
            if [[ -n "$line" && ! "$line" =~ ^# ]]; then
                # Пробуем выполнить команду
                if [[ "$line" =~ ^echo ]]; then
                    eval "$line" 2>/dev/null || echo "  ⚠️  Ошибка в строке $line_num"
                fi
            fi
            ((line_num++))
        else
            break
        fi
    done < install-monitoring-stack.sh
fi

# Очистка
rm -f test_first_50.sh