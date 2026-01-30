#!/bin/bash
# Скрипт для автоматического обновления версии во всех файлах документации

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/VERSION"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функции для вывода
print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Функция для обновления версии в файле
update_version_in_file() {
    local file="$1"
    local old_version="$2"
    local new_version="$3"
    
    if [[ ! -f "$file" ]]; then
        print_error "Файл не найден: $file"
        return 1
    fi
    
    # Создаем backup
    cp "$file" "${file}.bak"
    
    # Обновляем версию (разные паттерны для разных файлов)
    if sed -i "s/Version: ${old_version}/Version: ${new_version}/g" "$file" 2>/dev/null; then
        :
    fi
    if sed -i "s/version-${old_version}-/version-${new_version}-/g" "$file" 2>/dev/null; then
        :
    fi
    if sed -i "s/v${old_version}/v${new_version}/g" "$file" 2>/dev/null; then
        :
    fi
    if sed -i "s/**Version:** ${old_version}/**Version:** ${new_version}/g" "$file" 2>/dev/null; then
        :
    fi
    
    # Проверяем изменения
    if diff -q "$file" "${file}.bak" >/dev/null 2>&1; then
        print_info "Файл не изменен: $file"
        rm "${file}.bak"
        return 0
    else
        print_success "Обновлен: $file"
        rm "${file}.bak"
        return 0
    fi
}

# Главная функция
main() {
    local new_version="${1:-}"
    
    if [[ -z "$new_version" ]]; then
        print_error "Не указана новая версия"
        echo "Usage: $0 <new_version>"
        echo "Example: $0 3.1.0"
        exit 1
    fi
    
    # Проверка формата версии (semantic versioning)
    if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "Неверный формат версии: $new_version"
        echo "Используйте формат: MAJOR.MINOR.PATCH (например, 3.1.0)"
        exit 1
    fi
    
    # Получаем текущую версию
    local current_version=""
    if [[ -f "$VERSION_FILE" ]]; then
        current_version=$(cat "$VERSION_FILE" | tr -d '[:space:]')
    fi
    
    if [[ -z "$current_version" ]]; then
        print_error "Не удалось прочитать текущую версию из $VERSION_FILE"
        exit 1
    fi
    
    print_info "Текущая версия: $current_version"
    print_info "Новая версия: $new_version"
    echo
    
    # Подтверждение
    read -p "Продолжить обновление версии? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Отменено пользователем"
        exit 0
    fi
    
    echo
    print_info "Обновление версии в файлах..."
    echo
    
    # 1. Обновляем файл VERSION
    echo "$new_version" > "$VERSION_FILE"
    print_success "Обновлен: VERSION"
    
    # 2. Обновляем AI_GUIDE.md
    update_version_in_file "$PROJECT_ROOT/AI_GUIDE.md" "$current_version" "$new_version"
    
    # 3. Обновляем README.md
    update_version_in_file "$PROJECT_ROOT/README.md" "$current_version" "$new_version"
    
    # 4. Обновляем PROJECT_INFO.md
    update_version_in_file "$PROJECT_ROOT/PROJECT_INFO.md" "$current_version" "$new_version"
    
    # 5. Обновляем VERSIONING.md
    update_version_in_file "$PROJECT_ROOT/VERSIONING.md" "$current_version" "$new_version"
    
    echo
    print_success "Версия успешно обновлена с $current_version на $new_version"
    echo
    print_info "Следующие шаги:"
    echo "  1. Обновите CHANGELOG.md с описанием изменений"
    echo "  2. Выполните: git add VERSION AI_GUIDE.md README.md PROJECT_INFO.md VERSIONING.md CHANGELOG.md"
    echo "  3. Выполните: git commit -m \"chore: bump version to $new_version\""
    echo "  4. Выполните: git tag -a v$new_version -m \"Release version $new_version\""
    echo "  5. Выполните: git push origin master && git push origin v$new_version"
    echo
}

main "$@"
