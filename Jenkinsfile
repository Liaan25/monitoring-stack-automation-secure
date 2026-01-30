pipeline {
    agent none  // Не выбираем агент глобально - используем разные агенты для CI и CDL

    parameters {
        // ВАЖНО: После изменения defaultValue параметров, Jenkins не обновляет их автоматически в UI.
        // Для применения новых значений по умолчанию выполните "Build Now" один раз, затем используйте "Build with Parameters"
        
        string(name: 'SERVER_ADDRESS',     defaultValue: params.SERVER_ADDRESS ?: '',     description: 'Адрес сервера для подключения по SSH')
        string(name: 'SSH_CREDENTIALS_ID', defaultValue: params.SSH_CREDENTIALS_ID ?: '', description: 'ID Jenkins Credentials (SSH Username with private key) - должен быть для CI-пользователя')
        string(name: 'SEC_MAN_ADDR',       defaultValue: params.SEC_MAN_ADDR ?: '',       description: 'Адрес Vault для SecMan')
        string(name: 'NAMESPACE_CI',       defaultValue: params.NAMESPACE_CI ?: '',       description: 'Namespace для CI в Vault (например, kvSec_CI84324523)')
        string(name: 'NETAPP_API_ADDR',    defaultValue: params.NETAPP_API_ADDR ?: '',    description: 'FQDN/IP NetApp API (например, cl01-mgmt.example.org)')
        string(name: 'VAULT_AGENT_KV',     defaultValue: params.VAULT_AGENT_KV ?: '',     description: 'Путь KV в Vault для AppRole: secret "vault-agent" с ключами role_id, secret_id')
        string(name: 'RPM_URL_KV',         defaultValue: params.RPM_URL_KV ?: '',         description: 'Путь KV в Vault для RPM URL')
        string(name: 'NETAPP_SSH_KV',      defaultValue: params.NETAPP_SSH_KV ?: '',      description: 'Путь KV в Vault для NetApp SSH')
        string(name: 'GRAFANA_WEB_KV',     defaultValue: params.GRAFANA_WEB_KV ?: '',     description: 'Путь KV в Vault для Grafana Web')
        string(name: 'SBERCA_CERT_KV',     defaultValue: params.SBERCA_CERT_KV ?: '',     description: 'Путь KV в Vault для SberCA Cert')
        string(name: 'ADMIN_EMAIL',        defaultValue: params.ADMIN_EMAIL ?: '',        description: 'Email администратора для сертификатов')
        string(name: 'GRAFANA_PORT',       defaultValue: params.GRAFANA_PORT ?: '3000',   description: 'Порт Grafana')
        string(name: 'PROMETHEUS_PORT',    defaultValue: params.PROMETHEUS_PORT ?: '9090',description: 'Порт Prometheus')
        string(name: 'RLM_API_URL',        defaultValue: params.RLM_API_URL ?: '',        description: 'Базовый URL RLM API (например, https://api.rlm.sbrf.ru)')
        booleanParam(name: 'SKIP_VAULT_INSTALL', defaultValue: true, description: '✅ Пропустить установку Vault через RLM (использовать уже установленный vault-agent)')
        booleanParam(name: 'SKIP_RPM_INSTALL', defaultValue: false, description: '⚠️ Пропустить установку RPM пакетов (Grafana, Prometheus, Harvest) через RLM - использовать уже установленные пакеты')
        booleanParam(name: 'SKIP_CI_CHECKS', defaultValue: true, description: '⚡ Пропустить CI диагностику (очистка, отладка, проверки сети) - только получение из Vault и развертывание')
        booleanParam(name: 'SKIP_DEPLOYMENT', defaultValue: false, description: '🚫 Пропустить весь CDL этап (копирование и развертывание на сервер) - только CI проверки')
    }

    environment {
        // Извлекаем KAE из NAMESPACE_CI (например, kvSec_CI84324523 -> CI84324523)
        KAE = "${params.NAMESPACE_CI}".split('_')[1]
        
        // Динамическое формирование имен пользователей на основе KAE
        DEPLOY_USER = "${KAE}-lnx-mon_ci"       // CI-пользователь для развертывания
        MON_SYS_USER = "${KAE}-lnx-mon_sys"      // Sys-пользователь для запуска сервисов
        
        // Путь развертывания - домашний каталог CI-пользователя
        DEPLOY_PATH = "/home/${DEPLOY_USER}/monitoring-deployment"
    }

    stages {
        // ========================================================================
        // CI ЭТАП: Подготовка и проверка (clearAgent - чистый агент для сборки)
        // ========================================================================
        
        stage('CI: Информация о версии проекта') {
            agent { label "clearAgent&&sbel8&&!static" }
            steps {
                script {
                    // Получаем информацию о версии
                    echo "================================================"
                    echo "=== ВЕРСИЯ ПРОЕКТА - SECURE EDITION ==="
                    echo "================================================"
                    
                    // Делаем скрипт исполняемым (на Linux агенте)
                    sh 'chmod +x tools/get-version.sh || true'
                    
                    // Получаем и отображаем версию в виде баннера
                    def versionBanner = sh(script: './tools/get-version.sh banner', returnStdout: true).trim()
                    echo versionBanner
                    
                    // Сохраняем версионную информацию в переменные окружения
                    def versionEnv = sh(script: './tools/get-version.sh env', returnStdout: true).trim()
                    versionEnv.split('\n').each { line ->
                        def parts = line.split('=', 2)
                        if (parts.size() == 2) {
                            env."${parts[0]}" = parts[1]
                        }
                    }
                    
                    // Получаем короткую версию для использования в других местах
                    env.VERSION_SHORT = sh(script: './tools/get-version.sh short', returnStdout: true).trim()
                    
                    echo "[INFO] Версия проекта: ${env.VERSION_SHORT}"
                    echo "[INFO] Git commit: ${env.VERSION_GIT_COMMIT}"
                    echo "[INFO] Git branch: ${env.VERSION_GIT_BRANCH}"
                    echo "[INFO] Build timestamp: ${env.VERSION_BUILD_TIMESTAMP}"
                    echo "================================================"
                    echo "[INFO] Архитектура: Secure Edition (v4.0+)"
                    echo "[INFO] KAE: ${env.KAE}"
                    echo "[INFO] CI-пользователь: ${env.DEPLOY_USER}"
                    echo "[INFO] Sys-пользователь: ${env.MON_SYS_USER}"
                    echo "[INFO] Путь развертывания: ${env.DEPLOY_PATH}"
                    echo "================================================"
                }
            }
        }
        
        stage('CI: Очистка workspace и отладка') {
            agent { label "clearAgent&&sbel8&&!static" }
            when {
                expression { params.SKIP_CI_CHECKS != true }
            }
            steps {
                script {
                    // Вычисляем DATE_INSTALL здесь, где есть контекст агента
                    env.DATE_INSTALL = sh(script: "date '+%Y%m%d_%H%M%S'", returnStdout: true).trim()
                    
                    echo "================================================"
                    echo "=== НАЧАЛО ПАЙПЛАЙНА (SECURE MODE) ==="
                    echo "================================================"
                    echo "[INFO] Версия: ${env.VERSION_SHORT}"
                    echo "[INFO] Билд: ${currentBuild.number}"
                    echo "[INFO] DATE_INSTALL: ${env.DATE_INSTALL}"
                    
                    // Очистка workspace от старых временных файлов
                    echo "[INFO] Очистка workspace..."
                    sh '''
                        # Удаляем старые временные файлы
                        rm -f prep_clone*.sh scp_script*.sh verify_script*.sh deploy_script*.sh check_results*.sh cleanup_script*.sh get_domain*.sh get_ip*.sh 2>/dev/null || true
                        rm -f temp_data_cred.json 2>/dev/null || true
                    '''
                    echo "[SUCCESS] Workspace очищен"
                }
            }
        }
        
        stage('CI: Отладка параметров пайплайна') {
            agent { label "clearAgent&&sbel8&&!static" }
            when {
                expression { params.SKIP_CI_CHECKS != true }
            }
            steps {
                script {
                    echo "================================================"
                    echo "=== ПРОВЕРКА ПАРАМЕТРОВ (SECURE EDITION) ==="
                    echo "================================================"
                    
                    // Проверка обязательных параметров
                    if (!params.SERVER_ADDRESS?.trim()) {
                        error("❌ Не указан SERVER_ADDRESS")
                    }
                    if (!params.SSH_CREDENTIALS_ID?.trim()) {
                        error("❌ Не указан SSH_CREDENTIALS_ID")
                    }
                    if (!params.NAMESPACE_CI?.trim()) {
                        error("❌ Не указан NAMESPACE_CI (требуется для определения KAE)")
                    }
                    
                    echo "[OK] Параметры проверены"
                    echo "[INFO] Сервер: ${params.SERVER_ADDRESS}"
                    echo "[INFO] Подключение: ${env.DEPLOY_USER}@${params.SERVER_ADDRESS}"
                    echo "[SECURITY] Архитектура: User Units Only, Min Privileges"
                }
            }
        }
        
        stage('CI: Информация о коде и окружении') {
            agent { label "clearAgent&&sbel8&&!static" }
            when {
                expression { params.SKIP_CI_CHECKS != true }
            }
            steps {
                script {
                    echo "[INFO] === ИНФОРМАЦИЯ О КОДЕ ==="
                    echo "[INFO] Версия проекта: ${env.VERSION_SHORT}"
                    echo "[INFO] Git commit: ${env.VERSION_GIT_COMMIT_FULL}"
                    echo "[INFO] Git branch: ${env.VERSION_GIT_BRANCH}"
                    sh '''
                        echo "[INFO] Последние 3 коммита:"
                        git log --oneline -3 2>/dev/null || echo "[INFO] Git история недоступна"
                    '''
                }
            }
        }
        
        stage('CI: Расширенная диагностика сети и сервера') {
            agent { label "clearAgent&&sbel8&&!static" }
            when {
                expression { params.SKIP_CI_CHECKS != true }
            }
            steps {
                script {
                    echo "================================================"
                    echo "=== ДИАГНОСТИКА СЕТИ ==="
                    echo "================================================"
                    echo "[INFO] Проверка подключения к ${params.SERVER_ADDRESS}..."
                    
                    sh """
                        ping -c 3 ${params.SERVER_ADDRESS} || echo "[WARNING] Ping не прошел, но SSH может работать"
                    """
                }
            }
        }
        
        stage('CI: Получение секретов из Vault') {
            agent { label "clearAgent&&sbel8&&!static" }
            steps {
                script {
                    echo "[STEP] Получение секретов из Vault..."
                    
                    withCredentials([
                        string(credentialsId: 'vault-token', variable: 'VAULT_TOKEN')
                    ]) {
                        // Получаем секреты из Vault и сохраняем в temp_data_cred.json
                        sh """#!/bin/bash
set -euo pipefail

# Функция для получения секретов из Vault
get_vault_secret() {
    local kv_path="\$1"
    local field="\$2"
    
    curl -s -k \\
        -H "X-Vault-Token: \${VAULT_TOKEN}" \\
        "${params.SEC_MAN_ADDR}/v1/\${kv_path}" | \\
        jq -r ".data.data.\${field} // empty"
}

# Создаем JSON файл с credentials
cat > temp_data_cred.json <<EOF
{
  "vault-agent": {
    "role_id": "\$(get_vault_secret '${params.VAULT_AGENT_KV}' 'role_id')",
    "secret_id": "\$(get_vault_secret '${params.VAULT_AGENT_KV}' 'secret_id')"
  },
  "rpm_url": {
    "grafana": "\$(get_vault_secret '${params.RPM_URL_KV}' 'grafana')",
    "prometheus": "\$(get_vault_secret '${params.RPM_URL_KV}' 'prometheus')",
    "harvest": "\$(get_vault_secret '${params.RPM_URL_KV}' 'harvest')"
  },
  "netapp_ssh": {
    "user": "\$(get_vault_secret '${params.NETAPP_SSH_KV}' 'user')",
    "pass": "\$(get_vault_secret '${params.NETAPP_SSH_KV}' 'pass')"
  },
  "grafana_web": {
    "user": "\$(get_vault_secret '${params.GRAFANA_WEB_KV}' 'user')",
    "pass": "\$(get_vault_secret '${params.GRAFANA_WEB_KV}' 'pass')"
  }
}
EOF

echo "[INFO] Credentials получены и сохранены в temp_data_cred.json"
"""
                    }
                    
                    // Сохраняем credentials для использования в CDL стадиях
                    stash name: 'vault-credentials', includes: 'temp_data_cred.json'
                    
                    echo "[SUCCESS] Секреты успешно получены из Vault"
                }
            }
        }

        // ========================================================================
        // CDL ЭТАП: Развертывание на целевом сервере (masterLin для доступа)
        // ========================================================================

        stage('CDL: Копирование файлов на сервер') {
            agent { label "masterLin&&sbel8&&!static" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    // КРИТИЧЕСКИ ВАЖНО: Принудительно обновляем репозиторий
                    echo "[INFO] Обновление кода из Git (принудительно)..."
                    
                    // Используем checkout с опциями для принудительной очистки
                    checkout([
                        $class: 'GitSCM',
                        branches: scm.branches,
                        extensions: [
                            [$class: 'CleanBeforeCheckout'],
                            [$class: 'CleanCheckout']
                        ],
                        userRemoteConfigs: scm.userRemoteConfigs
                    ])
                    
                    // Проверяем версию
                    echo "[INFO] Текущая версия репозитория:"
                    sh '''
                        echo "========================================="
                        echo "ВЕРИФИКАЦИЯ ВЕРСИИ КОДА"
                        echo "========================================="
                        git log -1 --oneline
                        echo ""
                        echo "[INFO] Последние 5 коммитов:"
                        git log --oneline -5
                        echo "========================================="
                    '''
                    
                    // Восстанавливаем файл с credentials из stash
                    unstash 'vault-credentials'
                    
                    echo "[STEP] Копирование скрипта и файлов на сервер..."
                    sh '''
                        # Проверка необходимых файлов
                        [ ! -f "install-monitoring-stack.sh" ] && echo "[ERROR] install-monitoring-stack.sh не найден!" && exit 1
                        [ ! -d "wrappers" ] && echo "[ERROR] Папка wrappers не найдена!" && exit 1
                        [ ! -f "temp_data_cred.json" ] && echo "[ERROR] temp_data_cred.json не найден!" && exit 1
                        echo "[OK] Все файлы на месте"
                    '''
                    
                    withCredentials([
                        sshUserPrivateKey(credentialsId: params.SSH_CREDENTIALS_ID, keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')
                    ]) {
                        // ВАЖНО: SSH_USER должен совпадать с DEPLOY_USER
                        echo "[INFO] Подключение под пользователем: ${env.SSH_USER} (ожидается: ${env.DEPLOY_USER})"
                        
                        if (env.SSH_USER != env.DEPLOY_USER) {
                            echo "[WARNING] SSH_USER (${env.SSH_USER}) не совпадает с DEPLOY_USER (${env.DEPLOY_USER})"
                            echo "[WARNING] Убедитесь, что SSH credentials настроены для CI-пользователя!"
                        }
                        
                        // Генерируем лаунчеры
                        writeFile file: 'prep_clone.sh', text: '''#!/bin/bash
set -e

# Автоматически генерируем лаунчеры
if [ -f wrappers/build-integrity-checkers.sh ]; then
  /bin/bash wrappers/build-integrity-checkers.sh
fi
'''

                        // Создаем scp_script.sh для копирования в домашний каталог (БЕЗ sudo)
                        writeFile file: 'scp_script.sh', text: '''#!/bin/bash
set -e

# Проверяем наличие SSH ключа
if [ ! -f "''' + env.SSH_KEY + '''" ]; then
    echo "[ERROR] SSH ключ не найден"
    exit 1
fi

# Устанавливаем права на ключ
chmod 600 "''' + env.SSH_KEY + '''" 2>/dev/null || true

# 1. ТЕСТИРУЕМ SSH ПОДКЛЮЧЕНИЕ
echo ""
echo "[INFO] Тестируем SSH подключение к серверу..."

SSH_OPTS="-q -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes -o TCPKeepAlive=yes -o LogLevel=ERROR"

if ssh -i "''' + env.SSH_KEY + '''" $SSH_OPTS \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''' \
    "echo '[OK] SSH подключение успешно'" 2>/dev/null; then
    echo "[OK] SSH подключение работает"
else
    echo "[ERROR] SSH подключение к серверу ''' + params.SERVER_ADDRESS + ''' не удалось"
    echo "[INFO] Проверьте доступность SSH сервиса и сетевое подключение"
    exit 1
fi

# 2. СОЗДАЕМ ДИРЕКТОРИЮ В ДОМАШНЕМ КАТАЛОГЕ (БЕЗ sudo)
echo ""
echo "[INFO] Создание рабочей директории: ''' + env.DEPLOY_PATH + '''..."

if ssh -i "''' + env.SSH_KEY + '''" $SSH_OPTS \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''' \
    "mkdir -p ''' + env.DEPLOY_PATH + '''" 2>/dev/null; then
    echo "[OK] Директория создана"
else
    echo "[ERROR] Не удалось создать директорию"
    exit 1
fi

# 3. КОПИРУЕМ ФАЙЛЫ (БЕЗ sudo - в домашний каталог)
echo ""
echo "[INFO] Копирование файлов на сервер..."

if scp -q -i "''' + env.SSH_KEY + '''" -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    install-monitoring-stack.sh \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''':''' + env.DEPLOY_PATH + '''/install-monitoring-stack.sh 2>/dev/null; then
    echo "[OK] Скрипт скопирован"
else
    echo "[ERROR] Не удалось скопировать скрипт"
    exit 1
fi

if scp -q -i "''' + env.SSH_KEY + '''" -o StrictHostKeyChecking=no -o LogLevel=ERROR -r \
    wrappers \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''':''' + env.DEPLOY_PATH + '''/ 2>/dev/null; then
    echo "[OK] Wrappers скопированы"
else
    echo "[ERROR] Не удалось скопировать wrappers"
    exit 1
fi

if scp -q -i "''' + env.SSH_KEY + '''" -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    temp_data_cred.json \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''':''' + env.DEPLOY_PATH + '''/temp_data_cred.json 2>/dev/null; then
    echo "[OK] Credentials скопированы"
else
    echo "[ERROR] Не удалось скопировать credentials"
    exit 1
fi

echo ""
echo "[SUCCESS] Все файлы скопированы на сервер"
'''

                        // Создаем verify_script.sh
                        writeFile file: 'verify_script.sh', text: '''#!/bin/bash
set -e

echo "[INFO] Проверка скопированных файлов..."

ssh -i "''' + env.SSH_KEY + '''" -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''' 2>/dev/null << 'REMOTE_EOF'

[ ! -f "''' + env.DEPLOY_PATH + '''/install-monitoring-stack.sh" ] && echo "[ERROR] Скрипт не найден!" && exit 1
[ ! -d "''' + env.DEPLOY_PATH + '''/wrappers" ] && echo "[ERROR] Wrappers не найдены!" && exit 1
[ ! -f "''' + env.DEPLOY_PATH + '''/temp_data_cred.json" ] && echo "[ERROR] Credentials не найдены!" && exit 1

echo "[OK] Все файлы на месте"
REMOTE_EOF
'''
                        sh 'chmod +x prep_clone.sh scp_script.sh verify_script.sh'
                        
                        withEnv(['SSH_KEY=' + env.SSH_KEY, 'SSH_USER=' + env.SSH_USER]) {
                            sh './prep_clone.sh'
                            
                            // Retry логика
                            def maxRetries = 3
                            def retryDelay = 10
                            def lastError = null
                            
                            for (def attempt = 1; attempt <= maxRetries; attempt++) {
                                try {
                                    if (attempt > 1) echo "[INFO] Попытка $attempt из $maxRetries..."
                                    sh './scp_script.sh'
                                    lastError = null
                                    break
                                } catch (Exception e) {
                                    lastError = e
                                    if (attempt < maxRetries) {
                                        echo "[WARNING] Попытка не удалась, повтор через $retryDelay сек..."
                                        sleep(time: retryDelay, unit: 'SECONDS')
                                    }
                                }
                            }
                            
                            if (lastError) {
                                error("Ошибка копирования после $maxRetries попыток: ${lastError.message}")
                            }
                            
                            sh './verify_script.sh'
                        }
                        
                        sh 'rm -f prep_clone.sh scp_script.sh verify_script.sh'
                    }
                    echo "[SUCCESS] Репозиторий успешно скопирован на сервер ${params.SERVER_ADDRESS}"
                }
            }
        }

        stage('CDL: Выполнение развертывания') {
            agent { label "masterLin&&sbel8&&!static" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    echo "[STEP] Запуск развертывания на удаленном сервере..."
                    echo "[INFO] Режим: БЕЗ SUDO (User Units Only)"
                    
                    // Восстанавливаем credentials из stash (если нужно)
                    unstash 'vault-credentials'
                    
                    withCredentials([
                        sshUserPrivateKey(credentialsId: params.SSH_CREDENTIALS_ID, keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER'),
                        string(credentialsId: 'rlm-token', variable: 'RLM_TOKEN')
                    ]) {
                        def scriptTpl = '''#!/bin/bash
ssh -i "$SSH_KEY" -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$SSH_USER"@__SERVER_ADDRESS__ RLM_TOKEN="$RLM_TOKEN" /bin/bash -s 2>/dev/null <<'REMOTE_EOF'
set -e
USERNAME=$(whoami)
DEPLOY_DIR="__DEPLOY_PATH__"
REMOTE_SCRIPT_PATH="$DEPLOY_DIR/install-monitoring-stack.sh"

if [ ! -f "$REMOTE_SCRIPT_PATH" ]; then
    echo "[ERROR] Скрипт $REMOTE_SCRIPT_PATH не найден" && exit 1
fi

cd "$DEPLOY_DIR"
chmod +x "$REMOTE_SCRIPT_PATH"

echo "[INFO] sha256sum $REMOTE_SCRIPT_PATH:"
sha256sum "$REMOTE_SCRIPT_PATH" || echo "[WARNING] Не удалось вычислить sha256sum"

echo "[INFO] Нормализация перевода строк (CRLF -> LF)..."
if command -v dos2unix >/dev/null 2>&1; then
    dos2unix "$REMOTE_SCRIPT_PATH" || true
else
    sed -i 's/\r$//' "$REMOTE_SCRIPT_PATH" || true
fi

# Извлекаем RPM URLs из temp_data_cred.json
RPM_GRAFANA=$(jq -r '.rpm_url.grafana // empty' "$DEPLOY_DIR/temp_data_cred.json" 2>/dev/null || echo "")
RPM_PROMETHEUS=$(jq -r '.rpm_url.prometheus // empty' "$DEPLOY_DIR/temp_data_cred.json" 2>/dev/null || echo "")
RPM_HARVEST=$(jq -r '.rpm_url.harvest // empty' "$DEPLOY_DIR/temp_data_cred.json" 2>/dev/null || echo "")

echo "[INFO] RPM URLs из Vault:"
echo "  Grafana: $RPM_GRAFANA"
echo "  Prometheus: $RPM_PROMETHEUS"
echo "  Harvest: $RPM_HARVEST"

if [[ -z "$RPM_GRAFANA" || -z "$RPM_PROMETHEUS" || -z "$RPM_HARVEST" ]]; then
    echo "[ERROR] Один или несколько RPM URLs пусты!"
    echo "[ERROR] Содержимое temp_data_cred.json:"
    cat "$DEPLOY_DIR/temp_data_cred.json" | jq '.' || cat "$DEPLOY_DIR/temp_data_cred.json"
    exit 1
fi

echo "[INFO] Запуск скрипта (БЕЗ sudo - под CI-пользователем)..."
env \
  SEC_MAN_ADDR="__SEC_MAN_ADDR__" \
  NAMESPACE_CI="__NAMESPACE_CI__" \
  RLM_API_URL="__RLM_API_URL__" \
  RLM_TOKEN="$RLM_TOKEN" \
  NETAPP_API_ADDR="__NETAPP_API_ADDR__" \
  GRAFANA_PORT="__GRAFANA_PORT__" \
  PROMETHEUS_PORT="__PROMETHEUS_PORT__" \
  VAULT_AGENT_KV="__VAULT_AGENT_KV__" \
  RPM_URL_KV="__RPM_URL_KV__" \
  NETAPP_SSH_KV="__NETAPP_SSH_KV__" \
  GRAFANA_WEB_KV="__GRAFANA_WEB_KV__" \
  SBERCA_CERT_KV="__SBERCA_CERT_KV__" \
  ADMIN_EMAIL="__ADMIN_EMAIL__" \
  SKIP_VAULT_INSTALL="__SKIP_VAULT_INSTALL__" \
  SKIP_RPM_INSTALL="__SKIP_RPM_INSTALL__" \
  GRAFANA_URL="$RPM_GRAFANA" \
  PROMETHEUS_URL="$RPM_PROMETHEUS" \
  HARVEST_URL="$RPM_HARVEST" \
  DEPLOY_VERSION="__DEPLOY_VERSION__" \
  DEPLOY_GIT_COMMIT="__DEPLOY_GIT_COMMIT__" \
  DEPLOY_BUILD_DATE="__DEPLOY_BUILD_DATE__" \
  WRAPPERS_DIR="$DEPLOY_DIR/wrappers" \
  CRED_JSON_PATH="$DEPLOY_DIR/temp_data_cred.json" \
  /bin/bash "$REMOTE_SCRIPT_PATH"
REMOTE_EOF
'''
                        def finalScript = scriptTpl
                            .replace('__SERVER_ADDRESS__',     params.SERVER_ADDRESS     ?: '')
                            .replace('__DEPLOY_PATH__',        env.DEPLOY_PATH           ?: '')
                            .replace('__SEC_MAN_ADDR__',       params.SEC_MAN_ADDR       ?: '')
                            .replace('__NAMESPACE_CI__',       params.NAMESPACE_CI       ?: '')
                            .replace('__RLM_API_URL__',        params.RLM_API_URL        ?: '')
                            .replace('__NETAPP_API_ADDR__',    params.NETAPP_API_ADDR    ?: '')
                            .replace('__GRAFANA_PORT__',       params.GRAFANA_PORT       ?: '3000')
                            .replace('__PROMETHEUS_PORT__',    params.PROMETHEUS_PORT    ?: '9090')
                            .replace('__VAULT_AGENT_KV__',     params.VAULT_AGENT_KV     ?: '')
                            .replace('__RPM_URL_KV__',         params.RPM_URL_KV         ?: '')
                            .replace('__NETAPP_SSH_KV__',      params.NETAPP_SSH_KV      ?: '')
                            .replace('__GRAFANA_WEB_KV__',     params.GRAFANA_WEB_KV     ?: '')
                            .replace('__SBERCA_CERT_KV__',     params.SBERCA_CERT_KV     ?: '')
                            .replace('__ADMIN_EMAIL__',        params.ADMIN_EMAIL        ?: '')
                            .replace('__SKIP_VAULT_INSTALL__', params.SKIP_VAULT_INSTALL ? 'true' : 'false')
                            .replace('__SKIP_RPM_INSTALL__',   params.SKIP_RPM_INSTALL ? 'true' : 'false')
                            .replace('__DEPLOY_VERSION__',     env.VERSION_SHORT         ?: 'unknown')
                            .replace('__DEPLOY_GIT_COMMIT__',  env.VERSION_GIT_COMMIT    ?: 'unknown')
                            .replace('__DEPLOY_BUILD_DATE__',  env.VERSION_BUILD_DATE    ?: 'unknown')
                        writeFile file: 'deploy_script.sh', text: finalScript
                        sh 'chmod +x deploy_script.sh'
                        withEnv(['SSH_KEY=' + env.SSH_KEY, 'SSH_USER=' + env.SSH_USER]) {
                            sh './deploy_script.sh'
                        }
                        sh 'rm -f deploy_script.sh'
                    }
                }
            }
        }

        stage('CDL: Проверка результатов') {
            agent { label "masterLin&&sbel8&&!static" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    echo "[STEP] Проверка результатов развертывания (User Units)..."
                    withCredentials([sshUserPrivateKey(credentialsId: params.SSH_CREDENTIALS_ID, keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                        writeFile file: 'check_results.sh', text: '''#!/bin/bash
ssh -i "$SSH_KEY" -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "$SSH_USER"@''' + params.SERVER_ADDRESS + ''' 2>/dev/null << 'ENDSSH'
echo "================================================"
echo "ПРОВЕРКА СЕРВИСОВ (USER UNITS):"
echo "================================================"

# Получаем MON_SYS_USER из окружения или вычисляем
MON_SYS_USER="''' + env.MON_SYS_USER + '''"
MON_SYS_UID=$(id -u "$MON_SYS_USER" 2>/dev/null || echo "")

if [ -n "$MON_SYS_UID" ]; then
    echo "[INFO] Проверка user-юнитов для $MON_SYS_USER (UID: $MON_SYS_UID)..."
    
    # Проверяем через sudo (разрешено в sudoers)
    sudo -u "$MON_SYS_USER" env XDG_RUNTIME_DIR="/run/user/$MON_SYS_UID" \
        systemctl --user is-active monitoring-prometheus.service && \
        echo "[OK] Prometheus активен" || echo "[FAIL] Prometheus не активен"
    
    sudo -u "$MON_SYS_USER" env XDG_RUNTIME_DIR="/run/user/$MON_SYS_UID" \
        systemctl --user is-active monitoring-grafana.service && \
        echo "[OK] Grafana активна" || echo "[FAIL] Grafana не активна"
    
    sudo -u "$MON_SYS_USER" env XDG_RUNTIME_DIR="/run/user/$MON_SYS_UID" \
        systemctl --user is-active monitoring-harvest.service && \
        echo "[OK] Harvest активен" || echo "[FAIL] Harvest не активен"
else
    echo "[ERROR] Не удалось определить UID для $MON_SYS_USER"
fi

echo ""
echo "================================================"
echo "ПРОВЕРКА ПОРТОВ:"
echo "================================================"
ss -tln | grep -q ":''' + (params.PROMETHEUS_PORT ?: '9090') + ''' " && echo "[OK] Порт ''' + (params.PROMETHEUS_PORT ?: '9090') + ''' (Prometheus) открыт" || echo "[FAIL] Порт ''' + (params.PROMETHEUS_PORT ?: '9090') + ''' не открыт"
ss -tln | grep -q ":''' + (params.GRAFANA_PORT ?: '3000') + ''' " && echo "[OK] Порт ''' + (params.GRAFANA_PORT ?: '3000') + ''' (Grafana) открыт" || echo "[FAIL] Порт ''' + (params.GRAFANA_PORT ?: '3000') + ''' не открыт"
ss -tln | grep -q ":12990 " && echo "[OK] Порт 12990 (Harvest-NetApp) открыт" || echo "[FAIL] Порт 12990 не открыт"
ss -tln | grep -q ":12991 " && echo "[OK] Порт 12991 (Harvest-Unix) открыт" || echo "[FAIL] Порт 12991 не открыт"
exit 0
ENDSSH
'''
                        sh 'chmod +x check_results.sh'
                        def result
                        withEnv(['SSH_KEY=' + env.SSH_KEY, 'SSH_USER=' + env.SSH_USER]) {
                            result = sh(script: './check_results.sh', returnStdout: true).trim()
                        }
                        sh 'rm -f check_results.sh'
                        echo result
                    }
                }
            }
        }

        stage('CDL: Очистка') {
            agent { label "masterLin&&sbel8&&!static" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    echo "[STEP] Очистка временных файлов..."
                    sh "rm -rf temp_data_cred.json"
                    withCredentials([sshUserPrivateKey(credentialsId: params.SSH_CREDENTIALS_ID, keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                        writeFile file: 'cleanup_script.sh', text: '''#!/bin/bash
ssh -i "$SSH_KEY" -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "$SSH_USER"@''' + params.SERVER_ADDRESS + ''' \
    "rm -rf ''' + env.DEPLOY_PATH + '''/temp_data_cred.json" 2>/dev/null || true
'''
                        sh 'chmod +x cleanup_script.sh'
                        withEnv(['SSH_KEY=' + env.SSH_KEY, 'SSH_USER=' + env.SSH_USER]) {
                            sh './cleanup_script.sh'
                        }
                        sh 'rm -f cleanup_script.sh'
                    }
                    echo "[SUCCESS] Очистка завершена"
                }
            }
        }

        stage('CDL: Получение сведений о развертывании системы') {
            agent { label "masterLin&&sbel8&&!static" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    def domainName = ''
                    withCredentials([sshUserPrivateKey(credentialsId: params.SSH_CREDENTIALS_ID, keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                        writeFile file: 'get_domain.sh', text: '''#!/bin/bash
ssh -i "$SSH_KEY" -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "$SSH_USER"@''' + params.SERVER_ADDRESS + ''' \
    "nslookup ''' + params.SERVER_ADDRESS + ''' 2>/dev/null | grep 'name =' | awk '{print \\$4}' | sed 's/\\.$//' || echo ''" 2>/dev/null
'''
                        sh 'chmod +x get_domain.sh'
                        withEnv(['SSH_KEY=' + env.SSH_KEY, 'SSH_USER=' + env.SSH_USER]) {
                            domainName = sh(script: './get_domain.sh', returnStdout: true).trim()
                        }
                        sh 'rm -f get_domain.sh'
                    }
                    if (domainName == '') {
                        domainName = params.SERVER_ADDRESS
                    }
                    def serverIp = ''
                    withCredentials([sshUserPrivateKey(credentialsId: params.SSH_CREDENTIALS_ID, keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                        writeFile file: 'get_ip.sh', text: '''#!/bin/bash
ssh -i "$SSH_KEY" -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "$SSH_USER"@''' + params.SERVER_ADDRESS + ''' \
    "hostname -I | awk '{print \\$1}' || echo ''' + (params.SERVER_ADDRESS ?: '') + '''" 2>/dev/null
'''
                        sh 'chmod +x get_ip.sh'
                        withEnv(['SSH_KEY=' + env.SSH_KEY, 'SSH_USER=' + env.SSH_USER]) {
                            serverIp = sh(script: './get_ip.sh', returnStdout: true).trim()
                        }
                        sh 'rm -f get_ip.sh'
                    }
                    echo "================================================"
                    echo "[SUCCESS] Развертывание мониторинговой системы завершено!"
                    echo "================================================"
                    echo "[INFO] Архитектура: SECURE EDITION v4.0+"
                    echo "[INFO] Версия развертывания: ${env.VERSION_SHORT}"
                    echo "[INFO] Git commit: ${env.VERSION_GIT_COMMIT}"
                    echo "[INFO] Build timestamp: ${env.VERSION_BUILD_TIMESTAMP}"
                    echo "================================================"
                    echo "[INFO] KAE: ${env.KAE}"
                    echo "[INFO] CI-пользователь: ${env.DEPLOY_USER}"
                    echo "[INFO] Sys-пользователь: ${env.MON_SYS_USER}"
                    echo "[INFO] Service Model: User Units Only"
                    echo "================================================"
                    echo "[INFO] Доступ к сервисам:"
                    echo " • Prometheus: https://${serverIp}:${params.PROMETHEUS_PORT}"
                    echo " • Prometheus: https://${domainName}:${params.PROMETHEUS_PORT}"
                    echo " • Grafana: https://${serverIp}:${params.GRAFANA_PORT}"
                    echo " • Grafana: https://${domainName}:${params.GRAFANA_PORT}"
                    echo "[INFO] Информация о сервере:"
                    echo " • IP адрес: ${serverIp}"
                    echo " • Домен: ${domainName}"
                    echo "================================================"
                }
            }
        }
    }

    post {
        success {
            echo "================================================"
            echo "✅ Pipeline успешно завершен! (SECURE MODE)"
            echo "================================================"
        }
        failure {
            echo "================================================"
            echo "❌ Pipeline завершился с ошибкой!"
            echo "Проверьте логи для диагностики проблемы"
            echo "================================================"
        }
        always {
            echo "Время выполнения: ${currentBuild.durationString}"
        }
    }
}
