# Тестовый скрипт для проверки исправлений (PowerShell версия)

Write-Host "=== Тестирование исправлений для install-monitoring-stack.sh ==="
Write-Host ""

# 1. Проверка синтаксиса
Write-Host "1. Проверка синтаксиса скрипта..."
$bashPath = "C:\Program Files\Git\usr\bin\bash.exe"
if (Test-Path $bashPath) {
    & $bashPath -n install-monitoring-stack.sh
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Синтаксис корректен" -ForegroundColor Green
    } else {
        Write-Host "❌ Ошибка синтаксиса" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "⚠️  Bash не найден, пропускаем проверку синтаксиса" -ForegroundColor Yellow
}

Write-Host ""

# 2. Проверка первой строки (shebang)
Write-Host "2. Проверка shebang..."
$firstLine = Get-Content install-monitoring-stack.sh -First 1
if ($firstLine -eq "#!/bin/bash") {
    Write-Host "✅ Shebang корректен: $firstLine" -ForegroundColor Green
} else {
    Write-Host "❌ Неправильный shebang: $firstLine" -ForegroundColor Red
    exit 1
}

Write-Host ""

# 3. Проверка инициализации переменных SKIP_*
Write-Host "3. Проверка инициализации переменных SKIP_*..."
$skipVaultInit = Select-String -Path install-monitoring-stack.sh -Pattern ': "\${SKIP_VAULT_INSTALL:=false}"' -Quiet
if ($skipVaultInit) {
    Write-Host "✅ SKIP_VAULT_INSTALL инициализирована" -ForegroundColor Green
} else {
    Write-Host "❌ SKIP_VAULT_INSTALL не инициализирована" -ForegroundColor Red
}

$skipRpmInit = Select-String -Path install-monitoring-stack.sh -Pattern ': "\${SKIP_RPM_INSTALL:=false}"' -Quiet
if ($skipRpmInit) {
    Write-Host "✅ SKIP_RPM_INSTALL инициализирована" -ForegroundColor Green
} else {
    Write-Host "❌ SKIP_RPM_INSTALL не инициализирована" -ForegroundColor Red
}

$skipCiInit = Select-String -Path install-monitoring-stack.sh -Pattern ': "\${SKIP_CI_CHECKS:=false}"' -Quiet
if ($skipCiInit) {
    Write-Host "✅ SKIP_CI_CHECKS инициализирована" -ForegroundColor Green
} else {
    Write-Host "❌ SKIP_CI_CHECKS не инициализирована" -ForegroundColor Red
}

Write-Host ""

# 4. Проверка наличия критических функций
Write-Host "4. Проверка наличия критических функций..."
$requiredFunctions = @(
    "setup_vault_config",
    "setup_certificates_after_install", 
    "copy_certs_to_user_dirs",
    "main"
)

foreach ($func in $requiredFunctions) {
    $found = Select-String -Path install-monitoring-stack.sh -Pattern "^$func\(\)" -Quiet
    if ($found) {
        Write-Host "✅ Функция $func найдена" -ForegroundColor Green
    } else {
        Write-Host "❌ Функция $func не найдена" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Тестирование завершено ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Рекомендации:" -ForegroundColor Yellow
Write-Host "1. Запустите полный пайплайн для проверки всех исправлений"
Write-Host "2. Проверьте логи на наличие ошибок генерации agent.hcl"
Write-Host "3. Убедитесь что vault-agent создает сертификаты"
Write-Host "4. Проверьте что сертификаты копируются в user-space"