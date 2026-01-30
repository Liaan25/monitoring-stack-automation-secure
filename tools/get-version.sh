#!/bin/bash
# Скрипт для получения полной информации о версии проекта
# Используется в Jenkins pipeline для отображения версии при сборке

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/VERSION"

# Функция для получения базовой версии из файла VERSION
get_base_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE" | tr -d '[:space:]'
    else
        echo "0.0.0"
    fi
}

# Функция для получения git commit hash (короткий)
get_git_commit() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git rev-parse --short HEAD 2>/dev/null || echo "unknown"
    else
        echo "nogit"
    fi
}

# Функция для получения git commit hash (полный)
get_git_commit_full() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git rev-parse HEAD 2>/dev/null || echo "unknown"
    else
        echo "nogit"
    fi
}

# Функция для получения git branch
get_git_branch() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
    else
        echo "nobranch"
    fi
}

# Функция для получения даты сборки
get_build_date() {
    date '+%Y-%m-%d %H:%M:%S %Z'
}

# Функция для получения timestamp
get_build_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# Функция для проверки наличия uncommitted changes
has_uncommitted_changes() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
            echo "true"
        else
            echo "false"
        fi
    else
        echo "unknown"
    fi
}

# Главная функция
main() {
    local mode="${1:-full}"
    
    local base_version
    local git_commit
    local git_commit_full
    local git_branch
    local build_date
    local build_timestamp
    local has_changes
    
    base_version=$(get_base_version)
    git_commit=$(get_git_commit)
    git_commit_full=$(get_git_commit_full)
    git_branch=$(get_git_branch)
    build_date=$(get_build_date)
    build_timestamp=$(get_build_timestamp)
    has_changes=$(has_uncommitted_changes)
    
    case "$mode" in
        version|base)
            # Только версия: 3.0.0
            echo "$base_version"
            ;;
        short)
            # Короткая версия с коммитом: 3.0.0-a1b2c3d
            if [[ "$has_changes" == "true" ]]; then
                echo "${base_version}-${git_commit}-dirty"
            else
                echo "${base_version}-${git_commit}"
            fi
            ;;
        full)
            # Полная версия с веткой и датой: 3.0.0-a1b2c3d (master, 2026-01-23)
            local dirty=""
            [[ "$has_changes" == "true" ]] && dirty=" [UNCOMMITTED CHANGES]"
            echo "${base_version}-${git_commit} (${git_branch}, ${build_date})${dirty}"
            ;;
        json)
            # JSON формат для использования в скриптах
            cat <<EOF
{
  "version": "${base_version}",
  "git_commit": "${git_commit}",
  "git_commit_full": "${git_commit_full}",
  "git_branch": "${git_branch}",
  "build_date": "${build_date}",
  "build_timestamp": "${build_timestamp}",
  "has_uncommitted_changes": ${has_changes}
}
EOF
            ;;
        env)
            # Environment variables формат для экспорта
            cat <<EOF
VERSION_BASE=${base_version}
VERSION_GIT_COMMIT=${git_commit}
VERSION_GIT_COMMIT_FULL=${git_commit_full}
VERSION_GIT_BRANCH=${git_branch}
VERSION_BUILD_DATE=${build_date}
VERSION_BUILD_TIMESTAMP=${build_timestamp}
VERSION_HAS_CHANGES=${has_changes}
VERSION_FULL=${base_version}-${git_commit}
EOF
            ;;
        banner)
            # Красивый баннер для вывода в консоль
            local dirty_marker=""
            [[ "$has_changes" == "true" ]] && dirty_marker=" ⚠️  UNCOMMITTED CHANGES"
            cat <<EOF
╔════════════════════════════════════════════════════════════════╗
║          MONITORING STACK AUTOMATION - VERSION INFO           ║
╠════════════════════════════════════════════════════════════════╣
║  Version:        ${base_version}
║  Git Commit:     ${git_commit} (${git_branch})
║  Full Hash:      ${git_commit_full}
║  Build Date:     ${build_date}
║  Build ID:       ${build_timestamp}${dirty_marker}
╚════════════════════════════════════════════════════════════════╝
EOF
            ;;
        help|--help|-h)
            cat <<EOF
Usage: $0 [mode]

Modes:
  version, base  - Только базовая версия (3.0.0)
  short          - Короткая версия с коммитом (3.0.0-a1b2c3d)
  full           - Полная версия (по умолчанию)
  json           - JSON формат
  env            - Environment variables формат
  banner         - Красивый баннер для консоли
  help           - Эта справка

Examples:
  $0              # Полная версия
  $0 version      # Только номер версии
  $0 banner       # Красивый баннер
  $0 json         # JSON вывод
EOF
            ;;
        *)
            echo "Unknown mode: $mode. Use --help for usage." >&2
            exit 1
            ;;
    esac
}

main "$@"
