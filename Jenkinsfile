// ========================================================================
// ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (вынесены для уменьшения размера методов)
// ========================================================================

@NonCPS
def computeEnvironmentVariables() {
    if (!env.KAE && params.NAMESPACE_CI) {
        def parts = params.NAMESPACE_CI.split('_')
        env.KAE = parts.size() > 1 ? parts[1] : 'UNKNOWN'
        env.DEPLOY_USER = "${env.KAE}-lnx-mon_ci"
        env.MON_SYS_USER = "${env.KAE}-lnx-mon_sys"
        env.DEPLOY_PATH = "/home/${env.DEPLOY_USER}/monitoring-deployment"
    }
}

def withVaultSshCredentials(scriptContext, Closure body) {
    def sshCredentialsId = scriptContext.params.SSH_CREDENTIALS_ID?.trim()
    if (!sshCredentialsId) {
        scriptContext.error("❌ Не указан SSH_CREDENTIALS_ID (Jenkins credentials для SSH)")
    }

    def sshLogin = scriptContext.params.SSH_LOGIN?.trim()
    if (!sshLogin) {
        scriptContext.error("❌ Не указан SSH_LOGIN (обязателен для Vault SSH credentials)")
    }

    scriptContext.withCredentials([[
        $class: 'VaultSignedSSHKeyCredentialBinding',
        credentialsId: sshCredentialsId,
        privateKeyVar: 'SSH_PRIVATE_KEY',
        passphraseVar: 'SSH_PRIVATE_KEY_PASS'
    ]]) {
        scriptContext.sshagent([]) {
            scriptContext.sh '''#!/bin/bash
set +x
set -e

ASKPASS_SCRIPT=".send_ps.sh"
cat > "$ASKPASS_SCRIPT" <<'EOF'
#!/bin/sh
echo "$SSH_PRIVATE_KEY_PASS"
EOF
chmod 700 "$ASKPASS_SCRIPT"

DISPLAY=1 SSH_ASKPASS="$PWD/$ASKPASS_SCRIPT" ssh-add "$SSH_PRIVATE_KEY" < /dev/null
rm -f "$ASKPASS_SCRIPT"
'''
            scriptContext.withEnv(["SSH_USER=" + sshLogin]) {
                body()
            }
        }
    }
}

pipeline {
    agent none

    parameters {
        string(name: 'SERVER_ADDRESS',     defaultValue: params.SERVER_ADDRESS ?: '',     description: 'Адрес сервера для подключения по SSH')
        string(name: 'SSH_CREDENTIALS_ID', defaultValue: params.SSH_CREDENTIALS_ID ?: '', description: 'Jenkins Credential ID для SSH (Vault SSH private key with signed public key Credential)')
        string(name: 'SSH_LOGIN',         defaultValue: params.SSH_LOGIN ?: '',             description: 'Логин для SSH (обязательно для Vault SSH credentials)')
        string(name: 'SEC_MAN_ADDR',       defaultValue: params.SEC_MAN_ADDR ?: '',       description: 'Адрес Vault для SecMan')
        string(name: 'NAMESPACE_CI',       defaultValue: params.NAMESPACE_CI ?: '',       description: 'Namespace для CI в Vault')
        string(name: 'NETAPP_API_ADDR',    defaultValue: params.NETAPP_API_ADDR ?: '',    description: 'FQDN/IP NetApp API')
        string(name: 'VAULT_AGENT_KV',     defaultValue: params.VAULT_AGENT_KV ?: '',     description: 'Путь KV в Vault для AppRole')
        string(name: 'RPM_URL_KV',         defaultValue: params.RPM_URL_KV ?: '',         description: 'Путь KV в Vault для RPM URL')
        string(name: 'NETAPP_SSH_KV',      defaultValue: params.NETAPP_SSH_KV ?: '',      description: 'Путь KV в Vault для NetApp SSH')
        string(name: 'GRAFANA_WEB_KV',     defaultValue: params.GRAFANA_WEB_KV ?: '',     description: 'Путь KV в Vault для Grafana Web')
        string(name: 'SBERCA_CERT_KV',     defaultValue: params.SBERCA_CERT_KV ?: '',     description: 'Путь KV в Vault для SberCA Cert')
        string(name: 'ADMIN_EMAIL',        defaultValue: params.ADMIN_EMAIL ?: '',        description: 'Email администратора')
        string(name: 'GRAFANA_PORT',       defaultValue: params.GRAFANA_PORT ?: '3300',   description: 'Порт Grafana')
        string(name: 'PROMETHEUS_PORT',    defaultValue: params.PROMETHEUS_PORT ?: '9090',description: 'Порт Prometheus')
        string(name: 'RLM_API_URL',        defaultValue: params.RLM_API_URL ?: '',        description: 'Базовый URL RLM API')
        string(name: 'RLM_TOKEN_CREDENTIAL_ID', defaultValue: params.RLM_TOKEN_CREDENTIAL_ID ?: 'rlm-token', description: 'Jenkins Credential ID для RLM API токена')
        string(name: 'VAULT_CREDENTIAL_ID', defaultValue: params.VAULT_CREDENTIAL_ID ?: 'vault-agent-dev', description: 'Jenkins Credential ID для Vault')
        booleanParam(name: 'RENEW_CERTIFICATES_ONLY', defaultValue: false, description: '🔄 Только обновить сертификаты')
        booleanParam(name: 'USE_SIMPLIFIED_CERT_FLOW', defaultValue: true, description: '✅ Использовать non-root/simplified certificate flow (без /opt/vault/*). Отключите только для legacy rollback.')
        booleanParam(name: 'SKIP_RPM_INSTALL', defaultValue: false, description: '⚠️ Пропустить установку RPM пакетов')
        booleanParam(name: 'SKIP_IPTABLES', defaultValue: true, description: '✅ Пропустить настройку iptables (для non-root/ограниченных sudo)')
        booleanParam(name: 'RUN_SERVICES_AS_MON_CI', defaultValue: true, description: '🧪 Временно запускать user-юниты от mon_ci (без mon_sys). Для возврата к mon_sys отключите.')
        booleanParam(name: 'SKIP_CI_CHECKS', defaultValue: true, description: '⚡ Пропустить CI диагностику')
        booleanParam(name: 'SKIP_DEPLOYMENT', defaultValue: false, description: '🚫 Пропустить CDL этап')
    }

    stages {
        // ========================================================================
        // CI ЭТАП: Подготовка и проверка (clearAgent - чистый агент для сборки)
        // ========================================================================
        
        stage('CI: Информация о версии проекта') {
            agent { label "clearAgent&&sbel8&&!static" }
            steps {
                script {
                    computeEnvironmentVariables()
                    
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
                    computeEnvironmentVariables()
                    
                    // Вычисляем DATE_INSTALL здесь, где есть контекст агента
                    env.DATE_INSTALL = sh(script: "date '+%Y%m%d_%H%M%S'", returnStdout: true).trim()
                    
                    echo "================================================"
                    echo "=== НАЧАЛО ПАЙПЛАЙНА (SECURE MODE) ==="
                    echo "================================================"
                    echo "[INFO] Версия: ${env.VERSION_SHORT ?: 'unknown'}"
                    echo "[INFO] Билд: ${currentBuild.number}"
                    echo "[INFO] DATE_INSTALL: ${env.DATE_INSTALL}"
                    echo "[INFO] KAE: ${env.KAE}"
                    echo "[INFO] CI-пользователь: ${env.DEPLOY_USER}"
                    
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
                    computeEnvironmentVariables()
                    
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
                    if (!params.SSH_LOGIN?.trim()) {
                        error("❌ Не указан SSH_LOGIN")
                    }
                    if (!params.RLM_TOKEN_CREDENTIAL_ID?.trim()) {
                        error("❌ Не указан RLM_TOKEN_CREDENTIAL_ID")
                    }
                    if (!params.NAMESPACE_CI?.trim()) {
                        error("❌ Не указан NAMESPACE_CI (требуется для определения KAE)")
                    }
                    
                    echo "[OK] Параметры проверены"
                    echo "[INFO] Сервер: ${params.SERVER_ADDRESS}"
                    echo "[INFO] KAE: ${env.KAE}"
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
                    computeEnvironmentVariables()
                    
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
                    computeEnvironmentVariables()
                    
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
                    computeEnvironmentVariables()
                    
                    echo "[STEP] Получение секретов из Vault..."
                    
                    // Проверяем наличие credential ID
                    def vaultCredId = params.VAULT_CREDENTIAL_ID ?: 'vault-agent-dev'
                    echo "[INFO] Используется Vault Credential ID: ${vaultCredId}"
                    
                    // Формируем массив vaultSecrets для withVault плагина (как в v3.x)
                    def vaultSecrets = []
                    
                    if (params.VAULT_AGENT_KV?.trim()) {
                        vaultSecrets << [path: params.VAULT_AGENT_KV, secretValues: [
                            [envVar: 'VA_ROLE_ID',    vaultKey: 'role_id'],
                            [envVar: 'VA_SECRET_ID',  vaultKey: 'secret_id']
                        ]]
                    }
                    if (params.RPM_URL_KV?.trim()) {
                        vaultSecrets << [path: params.RPM_URL_KV, secretValues: [
                            [envVar: 'VA_RPM_HARVEST',    vaultKey: 'harvest'],
                            [envVar: 'VA_RPM_PROMETHEUS', vaultKey: 'prometheus'],
                            [envVar: 'VA_RPM_GRAFANA',    vaultKey: 'grafana']
                        ]]
                    }
                    if (params.NETAPP_SSH_KV?.trim()) {
                        vaultSecrets << [path: params.NETAPP_SSH_KV, secretValues: [
                            [envVar: 'VA_NETAPP_SSH_ADDR', vaultKey: 'addr'],
                            [envVar: 'VA_NETAPP_SSH_USER', vaultKey: 'user'],
                            [envVar: 'VA_NETAPP_SSH_PASS', vaultKey: 'pass']
                        ]]
                    }
                    if (params.GRAFANA_WEB_KV?.trim()) {
                        vaultSecrets << [path: params.GRAFANA_WEB_KV, secretValues: [
                            [envVar: 'VA_GRAFANA_WEB_USER', vaultKey: 'user'],
                            [envVar: 'VA_GRAFANA_WEB_PASS', vaultKey: 'pass']
                        ]]
                    }
                    if (vaultSecrets.isEmpty()) {
                        echo "[WARNING] KV пути не заданы"
                        // Создаем пустой JSON
                        def emptyData = [
                            "vault-agent": [role_id: '', secret_id: ''],
                            "rpm_url": [harvest: '', prometheus: '', grafana: ''],
                            "netapp_ssh": [addr: '', user: '', pass: ''],
                            "grafana_web": [user: '', pass: ''],
                            "certificates": [server_bundle_pem: '', ca_chain_crt: '', grafana_client_pem: '']
                        ]
                        writeFile file: 'temp_data_cred.json', text: groovy.json.JsonOutput.toJson(emptyData)
                    } else {
                        try {
                            // ВАЖНО: Используем withVault() плагин (как в v3.x), а не withCredentials()
                            // Это работает с типом credential "Vault App Role Credential"
                            withVault([
                                configuration: [
                                    vaultUrl: "https://${params.SEC_MAN_ADDR}",
                                    engineVersion: 1,
                                    skipSslVerification: false,
                                    vaultCredentialId: vaultCredId,
                                    vaultNamespace: params.NAMESPACE_CI?.trim()
                                ],
                                vaultSecrets: vaultSecrets
                            ]) {
                                // Секреты загружены в переменные окружения (VA_ROLE_ID, VA_SECRET_ID и т.д.)
                                def serverBundlePem = ''
                                def caChainCrt = ''
                                def grafanaClientPem = ''

                                // SberCA нужно вызывать через fetch (POST), а не через withVault read.
                                if (params.SBERCA_CERT_KV?.trim()) {
                                    def requestedPath = params.SBERCA_CERT_KV.trim()
                                    def vaultNamespace = params.NAMESPACE_CI?.trim()
                                    def apiPath = requestedPath.replaceAll('^/+', '')
                                    if (apiPath.startsWith('v1/')) {
                                        apiPath = apiPath.substring(3)
                                    }
                                    if (vaultNamespace && apiPath.startsWith("${vaultNamespace}/")) {
                                        apiPath = apiPath.substring(vaultNamespace.length() + 1)
                                    }

                                    // Поддержка legacy ввода, где mount ошибочно задается как /SBERCA/fetch/<mount>/fetch/<role>.
                                    // Нормализуем к корректному формату: /SBERCA/<mount>/fetch/<role>.
                                    apiPath = apiPath.replace('/SBERCA/fetch/', '/SBERCA/')

                                    if (!apiPath.contains('/SBERCA/') || !apiPath.contains('/fetch/')) {
                                        error("❌ SBERCA_CERT_KV имеет неверный формат. Ожидается: <NAMESPACE>/.../SBERCA/<mount>/fetch/<role>")
                                    }

                                    if (apiPath.contains('/fetch/') && apiPath.split('/fetch/').size() > 2) {
                                        error("❌ SBERCA_CERT_KV содержит лишний '/fetch/'. Используйте формат: <NAMESPACE>/.../SBERCA/<mount>/fetch/<role>")
                                    }

                                    if (requestedPath != apiPath && requestedPath != "${vaultNamespace}/${apiPath}") {
                                        echo "[SBERCA-DIAG] Нормализация пути SBERCA_CERT_KV"
                                        echo "[SBERCA-DIAG] requested_path: ${requestedPath}"
                                        echo "[SBERCA-DIAG] normalized_api_path: ${apiPath}"
                                    }

                                    def certRequestPayload = groovy.json.JsonOutput.toJson([
                                        common_name: (params.SERVER_ADDRESS ?: '').trim(),
                                        email: (params.ADMIN_EMAIL?.trim() ?: 'noreply@sberbank.ru'),
                                        format: 'pem',
                                        alt_names: (params.SERVER_ADDRESS ?: '').trim()
                                    ])
                                    writeFile file: 'sberca_request_payload.json', text: certRequestPayload
                                    writeFile file: 'sberca_api_path.txt', text: apiPath
                                    writeFile file: 'sberca_namespace.txt', text: (vaultNamespace ?: '')
                                    writeFile file: 'sberca_url.txt', text: "https://${params.SEC_MAN_ADDR}"

                                    try {
                                        withCredentials([[
                                            $class: 'VaultTokenCredentialBinding',
                                            credentialsId: vaultCredId,
                                            vaultNamespace: vaultNamespace,
                                            vaultAddr: "https://${params.SEC_MAN_ADDR}"
                                        ]]) {
                                            def certResponseRaw = sh(
                                                script: '''#!/bin/bash
set -euo pipefail
set +x

SBERCA_URL="$(cat sberca_url.txt)"
SBERCA_API_PATH="$(cat sberca_api_path.txt)"
SBERCA_NAMESPACE="$(cat sberca_namespace.txt)"

NS_HEADER=()
if [[ -n "${SBERCA_NAMESPACE}" ]]; then
  NS_HEADER=(-H "X-Vault-Namespace: ${SBERCA_NAMESPACE}")
fi

REQ_URL="${SBERCA_URL}/v1/${SBERCA_API_PATH}"

echo "[SBERCA-DIAG] ========================================" >&2
echo "[SBERCA-DIAG] Подготовка запроса к SberCA fetch" >&2
echo "[SBERCA-DIAG] namespace: ${SBERCA_NAMESPACE:-<empty>}" >&2
echo "[SBERCA-DIAG] api_path: ${SBERCA_API_PATH}" >&2
echo "[SBERCA-DIAG] request_url: ${REQ_URL}" >&2
echo "[SBERCA-DIAG] payload_json: $(cat sberca_request_payload.json)" >&2
echo "[SBERCA-DIAG] curl шаблон: curl -X POST <REQ_URL> -H 'X-Vault-Token: ***' -H 'X-Vault-Namespace: ...' -H 'Content-Type: application/json' --data @sberca_request_payload.json" >&2
echo "[SBERCA-DIAG] ========================================" >&2

# Диагностика прав токена на путь fetch
CAP_PAYLOAD=$(printf '{"paths":["%s"]}' "${SBERCA_API_PATH}")
CAP_RESP_FILE="$(mktemp)"
CAP_HTTP_CODE=$(curl -sS -o "${CAP_RESP_FILE}" -w "%{http_code}" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${NS_HEADER[@]}" \
  -H "Content-Type: application/json" \
  --request POST \
  --data "${CAP_PAYLOAD}" \
  "${SBERCA_URL}/v1/sys/capabilities-self" || true)

echo "[SBERCA-DIAG] capabilities-self http_code: ${CAP_HTTP_CODE}" >&2
echo "[SBERCA-DIAG] capabilities-self response: $(cat "${CAP_RESP_FILE}" 2>/dev/null || true)" >&2
rm -f "${CAP_RESP_FILE}"

# Основной вызов fetch
FETCH_RESP_FILE="$(mktemp)"
FETCH_HTTP_CODE=$(curl -sS -o "${FETCH_RESP_FILE}" -w "%{http_code}" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${NS_HEADER[@]}" \
  -H "Content-Type: application/json" \
  --request POST \
  --data @sberca_request_payload.json \
  "${REQ_URL}" || true)

echo "[SBERCA-DIAG] fetch http_code: ${FETCH_HTTP_CODE}" >&2
if [[ "${FETCH_HTTP_CODE}" -lt 200 || "${FETCH_HTTP_CODE}" -gt 299 ]]; then
  echo "[SBERCA-DIAG] fetch error response: $(cat "${FETCH_RESP_FILE}" 2>/dev/null || true)" >&2
  rm -f "${FETCH_RESP_FILE}"
  exit 22
fi

cat "${FETCH_RESP_FILE}"
rm -f "${FETCH_RESP_FILE}"
''',
                                                returnStdout: true
                                            ).trim()

                                            def certResponse = new groovy.json.JsonSlurperClassic().parseText(certResponseRaw)
                                            def cert = (certResponse?.data?.certificate ?: '').toString().trim()
                                            def pkey = (certResponse?.data?.private_key ?: '').toString().trim()
                                            def issuingCa = (certResponse?.data?.issuing_ca ?: '').toString().trim()

                                            def chainObj = certResponse?.data?.ca_chain
                                            def chainText = ''
                                            if (chainObj instanceof List) {
                                                chainText = chainObj.findAll { it != null }.collect { it.toString() }.join('\n')
                                            } else if (chainObj != null) {
                                                chainText = chainObj.toString().trim()
                                            }

                                            serverBundlePem = [pkey, cert, issuingCa].findAll { it?.trim() }.join('\n')
                                            caChainCrt = chainText?.trim() ? chainText : issuingCa
                                            grafanaClientPem = [pkey, cert, issuingCa].findAll { it?.trim() }.join('\n')

                                            if (!serverBundlePem?.trim()) {
                                                error("❌ SberCA fetch вернул пустой server_bundle_pem")
                                            }
                                        }
                                    } finally {
                                        sh 'rm -f sberca_request_payload.json sberca_api_path.txt sberca_namespace.txt sberca_url.txt'
                                    }
                                }

                                def data = [
                                    "vault-agent": [
                                        role_id: (env.VA_ROLE_ID ?: ''),
                                        secret_id: (env.VA_SECRET_ID ?: '')
                                    ],
                                    "rpm_url": [
                                        harvest: (env.VA_RPM_HARVEST ?: ''),
                                        prometheus: (env.VA_RPM_PROMETHEUS ?: ''),
                                        grafana: (env.VA_RPM_GRAFANA ?: '')
                                    ],
                                    "netapp_ssh": [
                                        addr: (env.VA_NETAPP_SSH_ADDR ?: ''),
                                        user: (env.VA_NETAPP_SSH_USER ?: ''),
                                        pass: (env.VA_NETAPP_SSH_PASS ?: '')
                                    ],
                                    "grafana_web": [
                                        user: (env.VA_GRAFANA_WEB_USER ?: ''),
                                        pass: (env.VA_GRAFANA_WEB_PASS ?: '')
                                    ],
                                    "certificates": [
                                        server_bundle_pem: serverBundlePem,
                                        ca_chain_crt: caChainCrt,
                                        grafana_client_pem: grafanaClientPem
                                    ]
                                ]
                                
                                writeFile file: 'temp_data_cred.json', text: groovy.json.JsonOutput.toJson(data)
                                echo "[INFO] certificates in temp_data_cred.json: " +
                                     "server_bundle_pem=${serverBundlePem ? 'yes' : 'no'}, " +
                                     "ca_chain_crt=${caChainCrt ? 'yes' : 'no'}, " +
                                     "grafana_client_pem=${grafanaClientPem ? 'yes' : 'no'}"
                            }
                        } catch (Exception e) {
                            echo "[ERROR] Ошибка Vault: ${e.message}"
                            error("❌ Не удалось получить данные из Vault")
                        }
                    }
                    
                    // Проверка файла
                    sh '''
                        [ ! -f "temp_data_cred.json" ] && echo "[ERROR] Файл не создан!" && exit 1
                        
                        if command -v jq >/dev/null 2>&1; then
                            jq empty temp_data_cred.json 2>/dev/null || { echo "[ERROR] Невалидный JSON!"; exit 1; }
                        fi
                    '''
                    
                    // Сохраняем для CDL этапа
                    stash name: 'vault-credentials', includes: 'temp_data_cred.json'
                    
                    echo "[SUCCESS] Данные из Vault получены"
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
                    computeEnvironmentVariables()
                    
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
                    
                    withVaultSshCredentials(this) {
                        def expectedSshUser = params.SSH_LOGIN?.trim() ? params.SSH_LOGIN.trim() : env.DEPLOY_USER
                        echo "[INFO] Подключение под пользователем настроено (ожидается: ${expectedSshUser})"
                        
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

# 1. ТЕСТИРУЕМ SSH ПОДКЛЮЧЕНИЕ
echo ""
echo "[INFO] Тестируем SSH подключение к серверу..."

SSH_OPTS="-q -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes -o TCPKeepAlive=yes -o LogLevel=ERROR"

if ssh $SSH_OPTS \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''' \
    "echo '[OK] SSH подключение успешно'" 2>/dev/null; then
    echo "[OK] SSH подключение работает"
else
    echo "[ERROR] SSH подключение к серверу ''' + params.SERVER_ADDRESS + ''' не удалось"
    echo "[INFO] Проверьте доступность SSH сервиса и сетевое подключение"
    exit 1
fi

# 2. ДИАГНОСТИКА И СОЗДАНИЕ ДИРЕКТОРИИ
echo ""
echo "[INFO] Проверка home директории пользователя..."

# Проверяем существование home директории
ssh $SSH_OPTS \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''' << 'DIAG_EOF'
set -e

HOME_DIR="$HOME"
echo "[INFO] HOME переменная: $HOME_DIR"

# Проверяем существование home директории
if [ ! -d "$HOME_DIR" ]; then
    echo "[ERROR] Home директория $HOME_DIR не существует!"
    echo "[INFO] Пользователь: $(whoami)"
    echo "[INFO] UID/GID: $(id)"
    echo "[ERROR] Необходимо создать home директорию для пользователя"
    echo "[SOLUTION] Выполните на сервере: sudo mkhomedir_helper $(whoami)"
    exit 1
fi

# Проверяем права на запись
if [ ! -w "$HOME_DIR" ]; then
    echo "[ERROR] Нет прав на запись в $HOME_DIR"
    ls -ld "$HOME_DIR"
    exit 1
fi

echo "[OK] Home директория существует и доступна для записи"
DIAG_EOF

# Создаем рабочую директорию
echo ""
echo "[INFO] Создание рабочей директории: ''' + env.DEPLOY_PATH + '''..."

if ssh $SSH_OPTS \
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

if scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    install-monitoring-stack.sh \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''':''' + env.DEPLOY_PATH + '''/install-monitoring-stack.sh 2>/dev/null; then
    echo "[OK] Скрипт скопирован"
else
    echo "[ERROR] Не удалось скопировать скрипт"
    exit 1
fi

if scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR -r \
    wrappers \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''':''' + env.DEPLOY_PATH + '''/ 2>/dev/null; then
    echo "[OK] Wrappers скопированы"
else
    echo "[ERROR] Не удалось скопировать wrappers"
    exit 1
fi

if scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
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

ssh -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "''' + env.SSH_USER + '''"@''' + params.SERVER_ADDRESS + ''' 2>/dev/null << 'REMOTE_EOF'

[ ! -f "''' + env.DEPLOY_PATH + '''/install-monitoring-stack.sh" ] && echo "[ERROR] Скрипт не найден!" && exit 1
[ ! -d "''' + env.DEPLOY_PATH + '''/wrappers" ] && echo "[ERROR] Wrappers не найдены!" && exit 1
[ ! -f "''' + env.DEPLOY_PATH + '''/temp_data_cred.json" ] && echo "[ERROR] Credentials не найдены!" && exit 1

echo "[OK] Все файлы на месте"
REMOTE_EOF
'''
                        sh 'chmod +x prep_clone.sh scp_script.sh verify_script.sh'
                        
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
                    computeEnvironmentVariables()
                    
                    echo "[STEP] Запуск развертывания на удаленном сервере..."
                    echo "[INFO] Режим: БЕЗ SUDO (User Units Only)"
                    
                    // Восстанавливаем credentials из stash (если нужно)
                    unstash 'vault-credentials'
                    
                    withCredentials([
                        string(credentialsId: params.RLM_TOKEN_CREDENTIAL_ID, variable: 'RLM_TOKEN')
                    ]) {
                        withVaultSshCredentials(this) {
                        def scriptTpl = '''#!/bin/bash
ssh -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$SSH_USER"@__SERVER_ADDRESS__ RLM_TOKEN="$RLM_TOKEN" /bin/bash -s <<'REMOTE_EOF'
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
  RENEW_CERTIFICATES_ONLY="__RENEW_CERTIFICATES_ONLY__" \
  USE_SIMPLIFIED_CERT_FLOW="__USE_SIMPLIFIED_CERT_FLOW__" \
  SKIP_RPM_INSTALL="__SKIP_RPM_INSTALL__" \
  SKIP_IPTABLES="__SKIP_IPTABLES__" \
  RUN_SERVICES_AS_MON_CI="__RUN_SERVICES_AS_MON_CI__" \
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
                            .replace('__ADMIN_EMAIL__',               params.ADMIN_EMAIL             ?: '')
                            .replace('__RENEW_CERTIFICATES_ONLY__',  params.RENEW_CERTIFICATES_ONLY ? 'true' : 'false')
                            .replace('__USE_SIMPLIFIED_CERT_FLOW__', params.USE_SIMPLIFIED_CERT_FLOW ? 'true' : 'false')
                            .replace('__SKIP_RPM_INSTALL__',         params.SKIP_RPM_INSTALL        ? 'true' : 'false')
                            .replace('__SKIP_IPTABLES__',            params.SKIP_IPTABLES           ? 'true' : 'false')
                            .replace('__RUN_SERVICES_AS_MON_CI__',   params.RUN_SERVICES_AS_MON_CI  ? 'true' : 'false')
                            .replace('__DEPLOY_VERSION__',     env.VERSION_SHORT         ?: 'unknown')
                            .replace('__DEPLOY_GIT_COMMIT__',  env.VERSION_GIT_COMMIT    ?: 'unknown')
                            .replace('__DEPLOY_BUILD_DATE__',  env.VERSION_BUILD_DATE    ?: 'unknown')
                        writeFile file: 'deploy_script.sh', text: finalScript
                        sh 'chmod +x deploy_script.sh'
                        sh './deploy_script.sh'
                        sh 'rm -f deploy_script.sh'
                        }
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
                    computeEnvironmentVariables()
                    
                    echo "[STEP] Проверка результатов развертывания (User Units)..."
                    withVaultSshCredentials(this) {
                        writeFile file: 'check_results.sh', text: '''#!/bin/bash
ssh -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR \
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
                        result = sh(script: './check_results.sh', returnStdout: true).trim()
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
                    computeEnvironmentVariables()
                    
                    echo "[STEP] Очистка временных файлов..."
                    sh "rm -rf temp_data_cred.json"
                    withVaultSshCredentials(this) {
                        writeFile file: 'cleanup_script.sh', text: '''#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "$SSH_USER"@''' + params.SERVER_ADDRESS + ''' \
    "rm -rf ''' + env.DEPLOY_PATH + '''/temp_data_cred.json" 2>/dev/null || true
'''
                        sh 'chmod +x cleanup_script.sh'
                        sh './cleanup_script.sh'
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
                    computeEnvironmentVariables()
                    
                    def domainName = ''
                    withVaultSshCredentials(this) {
                        writeFile file: 'get_domain.sh', text: '''#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "$SSH_USER"@''' + params.SERVER_ADDRESS + ''' \
    "nslookup ''' + params.SERVER_ADDRESS + ''' 2>/dev/null | grep 'name =' | awk '{print \\$4}' | sed 's/\\.$//' || echo ''" 2>/dev/null
'''
                        sh 'chmod +x get_domain.sh'
                        domainName = sh(script: './get_domain.sh', returnStdout: true).trim()
                        sh 'rm -f get_domain.sh'
                    }
                    if (domainName == '') {
                        domainName = params.SERVER_ADDRESS
                    }
                    def serverIp = ''
                    withVaultSshCredentials(this) {
                        writeFile file: 'get_ip.sh', text: '''#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "$SSH_USER"@''' + params.SERVER_ADDRESS + ''' \
    "hostname -I | awk '{print \\$1}' || echo ''' + (params.SERVER_ADDRESS ?: '') + '''" 2>/dev/null
'''
                        sh 'chmod +x get_ip.sh'
                        serverIp = sh(script: './get_ip.sh', returnStdout: true).trim()
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
