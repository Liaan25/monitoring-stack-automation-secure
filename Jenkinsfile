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
    def netappAddr = params.NETAPP_API_ADDR?.trim() ?: ''
    def netappHost = netappAddr.tokenize('.') ? netappAddr.tokenize('.')[0] : ''
    def netappPoller = netappHost ? (netappHost.substring(0, 1).toUpperCase() + netappHost.substring(1).toLowerCase()) : 'Unknown'
    def netappPollerSafe = netappPoller.replaceAll(/[^A-Za-z0-9_-]/, '_')

    def serverAddr = params.SERVER_ADDRESS?.trim() ?: ''
    def serverPrefix = serverAddr.tokenize('.') ? serverAddr.tokenize('.')[0] : 'server'
    def serverPrefixSafe = serverPrefix.replaceAll(/[^A-Za-z0-9_-]/, '_')

    env.NETAPP_POLLER_NAME = netappPoller
    env.CRED_JSON_FILE = "temp_data_cred_${netappPollerSafe}_${serverPrefixSafe}.json"
    env.SERVER_ADDRESS_EFFECTIVE = serverAddr.tokenize(';') ? serverAddr.tokenize(';')[0].trim() : ''
    env.NETAPP_API_ADDR_EFFECTIVE = netappAddr.tokenize(';') ? netappAddr.tokenize(';')[0].trim() : ''
}

@NonCPS
def buildDeploymentPairs(String serverAddressesRaw, String netappAddressesRaw) {
    def servers = (serverAddressesRaw ?: '').split(';').collect { it.trim() }.findAll { it }
    def netapps = (netappAddressesRaw ?: '').split(';').collect { it.trim() }.findAll { it }

    if (servers.isEmpty()) {
        throw new IllegalArgumentException("❌ Не указан SERVER_ADDRESS")
    }
    if (netapps.isEmpty()) {
        throw new IllegalArgumentException("❌ Не указан NETAPP_API_ADDR")
    }
    if (servers.size() != netapps.size()) {
        throw new IllegalArgumentException("❌ Количество SERVER_ADDRESS (${servers.size()}) не равно количеству NETAPP_API_ADDR (${netapps.size()})")
    }

    def pairs = []
    for (int i = 0; i < servers.size(); i++) {
        def server = servers[i]
        def netapp = netapps[i]
        def netappHost = netapp.tokenize('.') ? netapp.tokenize('.')[0] : ''
        def poller = netappHost ? (netappHost.substring(0, 1).toUpperCase() + netappHost.substring(1).toLowerCase()) : 'Unknown'
        def pollerSafe = poller.replaceAll(/[^A-Za-z0-9_-]/, '_')
        def serverPrefix = server.tokenize('.') ? server.tokenize('.')[0] : "server${i + 1}"
        def serverPrefixSafe = serverPrefix.replaceAll(/[^A-Za-z0-9_-]/, '_')
        def credJsonFile = "temp_data_cred_${pollerSafe}_${serverPrefixSafe}.json"

        pairs << [
            index: i + 1,
            server: server,
            netapp: netapp,
            poller: poller,
            pollerSafe: pollerSafe,
            serverPrefixSafe: serverPrefixSafe,
            credJsonFile: credJsonFile
        ]
    }
    return pairs
}

@NonCPS
def renderDeploySummary(String title, List<Map> rows) {
    def header = []
    header << "================================================"
    header << "📋 ${title}"
    header << "================================================"
    header << "server | netapp | stage | status | reason"
    rows.each { r ->
        header << "${r.server} | ${r.netapp} | ${r.stage} | ${r.status} | ${r.reason}"
    }
    header << "================================================"
    return header.join('\n')
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

def runRemoteRpmPhaseInstall(scriptContext, Map pair, String phaseName) {
    return scriptContext.sh(returnStatus: true, script: """#!/bin/bash
set -e
ssh -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "${scriptContext.env.SSH_USER}"@"${pair.server}" RLM_TOKEN="$RLM_TOKEN" /bin/bash -s <<'REMOTE_EOF'
set -e
DEPLOY_DIR="${scriptContext.env.DEPLOY_PATH}"
REMOTE_SCRIPT_PATH="\$DEPLOY_DIR/install-monitoring-stack.sh"
CRED_JSON_FILE="${pair.credJsonFile}"
TARGET_NETAPP="${pair.netapp}"

if [ ! -f "\$REMOTE_SCRIPT_PATH" ]; then
  echo "[ERROR] Скрипт \$REMOTE_SCRIPT_PATH не найден" && exit 1
fi

cd "\$DEPLOY_DIR"
chmod +x "\$REMOTE_SCRIPT_PATH"
if command -v dos2unix >/dev/null 2>&1; then
  dos2unix "\$REMOTE_SCRIPT_PATH" || true
else
  sed -i 's/\\r\$//' "\$REMOTE_SCRIPT_PATH" || true
fi

RPM_GRAFANA=\$(jq -r '.rpm_url.grafana // empty' "\$DEPLOY_DIR/\$CRED_JSON_FILE" 2>/dev/null || echo "")
RPM_PROMETHEUS=\$(jq -r '.rpm_url.prometheus // empty' "\$DEPLOY_DIR/\$CRED_JSON_FILE" 2>/dev/null || echo "")
RPM_HARVEST=\$(jq -r '.rpm_url.harvest // empty' "\$DEPLOY_DIR/\$CRED_JSON_FILE" 2>/dev/null || echo "")
RPM_NODE_EXPORTER=\$(jq -r '.rpm_url.node_exporter // empty' "\$DEPLOY_DIR/\$CRED_JSON_FILE" 2>/dev/null || echo "")

case "${phaseName}" in
  "Grafana")
    [[ -z "\$RPM_GRAFANA" ]] && echo "[ERROR] Пустой RPM URL для Grafana" && exit 1
    ;;
  "Prometheus")
    [[ -z "\$RPM_PROMETHEUS" ]] && echo "[ERROR] Пустой RPM URL для Prometheus" && exit 1
    ;;
  "Harvest")
    [[ -z "\$RPM_HARVEST" ]] && echo "[ERROR] Пустой RPM URL для Harvest" && exit 1
    ;;
esac

env \\
  SEC_MAN_ADDR="${scriptContext.params.SEC_MAN_ADDR ?: ''}" \\
  NAMESPACE_CI="${scriptContext.params.NAMESPACE_CI ?: ''}" \\
  RLM_API_URL="${scriptContext.params.RLM_API_URL ?: ''}" \\
  RLM_TOKEN="\$RLM_TOKEN" \\
  DEPLOY_TARGET_SERVER="${pair.server}" \\
  DEPLOY_TARGET_NETAPP="${pair.netapp}" \\
  NETAPP_API_ADDR="\$TARGET_NETAPP" \\
  GRAFANA_PORT="${scriptContext.params.GRAFANA_PORT ?: '3000'}" \\
  PROMETHEUS_PORT="${scriptContext.params.PROMETHEUS_PORT ?: '9090'}" \\
  RPM_URL_KV="${scriptContext.params.RPM_URL_KV ?: ''}" \\
  NETAPP_SSH_KV="${scriptContext.params.NETAPP_SSH_KV ?: ''}" \\
  GRAFANA_WEB_KV="${scriptContext.params.GRAFANA_WEB_KV ?: ''}" \\
  SBERCA_CERT_KV="${scriptContext.params.SBERCA_CERT_KV ?: ''}" \\
  ADMIN_EMAIL="${scriptContext.params.ADMIN_EMAIL ?: ''}" \\
  VICTORIA_METRICS_REMOTE_WRITE_URL="${scriptContext.params.VICTORIA_METRICS_REMOTE_WRITE_URL ?: ''}" \\
  RENEW_CERTIFICATES_ONLY="false" \\
  USE_SIMPLIFIED_CERT_FLOW="${scriptContext.params.USE_SIMPLIFIED_CERT_FLOW ? 'true' : 'false'}" \\
  SKIP_RPM_INSTALL="false" \\
  SKIP_IPTABLES="true" \\
  RUN_SERVICES_AS_MON_CI="${scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false'}" \\
  GRAFANA_URL="\$RPM_GRAFANA" \\
  PROMETHEUS_URL="\$RPM_PROMETHEUS" \\
  HARVEST_URL="\$RPM_HARVEST" \\
  NODE_EXPORTER_URL="\$RPM_NODE_EXPORTER" \\
  DEPLOY_VERSION="${scriptContext.env.VERSION_SHORT ?: 'unknown'}" \\
  DEPLOY_GIT_COMMIT="${scriptContext.env.VERSION_GIT_COMMIT ?: 'unknown'}" \\
  DEPLOY_BUILD_DATE="${scriptContext.env.VERSION_BUILD_DATE ?: 'unknown'}" \\
  WRAPPERS_DIR="\$DEPLOY_DIR/wrappers" \\
  CRED_JSON_PATH="\$DEPLOY_DIR/\$CRED_JSON_FILE" \\
  RLM_PHASE_ONLY="true" \\
  RLM_PACKAGE_FILTER="${phaseName}" \\
  /bin/bash "\$REMOTE_SCRIPT_PATH"
REMOTE_EOF
echo "[SYNC-RPM] [${pair.server}] ${phaseName}: локальный success, ожидаем остальные серверы..."
sleep 5
""")
}

def runRemoteFullDeploy(scriptContext, Map pair, String effectiveSkipRpm) {
    return scriptContext.sh(returnStatus: true, script: """#!/bin/bash
set -e
ssh -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "${scriptContext.env.SSH_USER}"@"${pair.server}" RLM_TOKEN="$RLM_TOKEN" /bin/bash -s <<'REMOTE_EOF'
set -e
DEPLOY_DIR="${scriptContext.env.DEPLOY_PATH}"
REMOTE_SCRIPT_PATH="\$DEPLOY_DIR/install-monitoring-stack.sh"
CRED_JSON_FILE="${pair.credJsonFile}"
TARGET_NETAPP="${pair.netapp}"

if [ ! -f "\$REMOTE_SCRIPT_PATH" ]; then
  echo "[ERROR] Скрипт \$REMOTE_SCRIPT_PATH не найден" && exit 1
fi

cd "\$DEPLOY_DIR"
chmod +x "\$REMOTE_SCRIPT_PATH"
if command -v dos2unix >/dev/null 2>&1; then
  dos2unix "\$REMOTE_SCRIPT_PATH" || true
else
  sed -i 's/\\r\$//' "\$REMOTE_SCRIPT_PATH" || true
fi

RPM_GRAFANA=\$(jq -r '.rpm_url.grafana // empty' "\$DEPLOY_DIR/\$CRED_JSON_FILE" 2>/dev/null || echo "")
RPM_PROMETHEUS=\$(jq -r '.rpm_url.prometheus // empty' "\$DEPLOY_DIR/\$CRED_JSON_FILE" 2>/dev/null || echo "")
RPM_HARVEST=\$(jq -r '.rpm_url.harvest // empty' "\$DEPLOY_DIR/\$CRED_JSON_FILE" 2>/dev/null || echo "")
RPM_NODE_EXPORTER=\$(jq -r '.rpm_url.node_exporter // empty' "\$DEPLOY_DIR/\$CRED_JSON_FILE" 2>/dev/null || echo "")

if [[ -z "\$RPM_GRAFANA" || -z "\$RPM_PROMETHEUS" || -z "\$RPM_HARVEST" ]]; then
  echo "[ERROR] Один или несколько RPM URLs пусты для \$CRED_JSON_FILE"
  exit 1
fi

env \\
  SEC_MAN_ADDR="${scriptContext.params.SEC_MAN_ADDR ?: ''}" \\
  NAMESPACE_CI="${scriptContext.params.NAMESPACE_CI ?: ''}" \\
  RLM_API_URL="${scriptContext.params.RLM_API_URL ?: ''}" \\
  RLM_TOKEN="\$RLM_TOKEN" \\
  DEPLOY_TARGET_SERVER="${pair.server}" \\
  DEPLOY_TARGET_NETAPP="${pair.netapp}" \\
  NETAPP_API_ADDR="\$TARGET_NETAPP" \\
  GRAFANA_PORT="${scriptContext.params.GRAFANA_PORT ?: '3000'}" \\
  PROMETHEUS_PORT="${scriptContext.params.PROMETHEUS_PORT ?: '9090'}" \\
  RPM_URL_KV="${scriptContext.params.RPM_URL_KV ?: ''}" \\
  NETAPP_SSH_KV="${scriptContext.params.NETAPP_SSH_KV ?: ''}" \\
  GRAFANA_WEB_KV="${scriptContext.params.GRAFANA_WEB_KV ?: ''}" \\
  SBERCA_CERT_KV="${scriptContext.params.SBERCA_CERT_KV ?: ''}" \\
  ADMIN_EMAIL="${scriptContext.params.ADMIN_EMAIL ?: ''}" \\
  VICTORIA_METRICS_REMOTE_WRITE_URL="${scriptContext.params.VICTORIA_METRICS_REMOTE_WRITE_URL ?: ''}" \\
  RENEW_CERTIFICATES_ONLY="${scriptContext.params.RENEW_CERTIFICATES_ONLY ? 'true' : 'false'}" \\
  USE_SIMPLIFIED_CERT_FLOW="${scriptContext.params.USE_SIMPLIFIED_CERT_FLOW ? 'true' : 'false'}" \\
  SKIP_RPM_INSTALL="${effectiveSkipRpm}" \\
  SKIP_IPTABLES="${scriptContext.params.SKIP_IPTABLES ? 'true' : 'false'}" \\
  RUN_SERVICES_AS_MON_CI="${scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false'}" \\
  GRAFANA_URL="\$RPM_GRAFANA" \\
  PROMETHEUS_URL="\$RPM_PROMETHEUS" \\
  HARVEST_URL="\$RPM_HARVEST" \\
  NODE_EXPORTER_URL="\$RPM_NODE_EXPORTER" \\
  DEPLOY_VERSION="${scriptContext.env.VERSION_SHORT ?: 'unknown'}" \\
  DEPLOY_GIT_COMMIT="${scriptContext.env.VERSION_GIT_COMMIT ?: 'unknown'}" \\
  DEPLOY_BUILD_DATE="${scriptContext.env.VERSION_BUILD_DATE ?: 'unknown'}" \\
  WRAPPERS_DIR="\$DEPLOY_DIR/wrappers" \\
  CRED_JSON_PATH="\$DEPLOY_DIR/\$CRED_JSON_FILE" \\
  /bin/bash "\$REMOTE_SCRIPT_PATH"
REMOTE_EOF
""")
}

def runRemoteVerification(scriptContext, Map pair) {
    def runAsMonCi = scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false'
    def runtimeUser = scriptContext.params.RUN_SERVICES_AS_MON_CI ? scriptContext.env.DEPLOY_USER : scriptContext.env.MON_SYS_USER
    def promPort = scriptContext.params.PROMETHEUS_PORT ?: '9090'
    def grafanaPort = scriptContext.params.GRAFANA_PORT ?: '3300'
    return scriptContext.sh(script: """#!/bin/bash
ssh -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "${scriptContext.env.SSH_USER}"@"${pair.server}" 2>/dev/null << 'ENDSSH'
echo "================================================"
echo "СЕРВЕР: ${pair.server}"
echo "ПРОВЕРКА СЕРВИСОВ (USER UNITS):"
echo "================================================"

if [ "${runAsMonCi}" = "true" ]; then
    RUNTIME_USER="${scriptContext.env.DEPLOY_USER}"
else
    RUNTIME_USER="${scriptContext.env.MON_SYS_USER}"
fi
RUNTIME_UID=\$(id -u "\$RUNTIME_USER" 2>/dev/null || echo "")

if [ -n "\$RUNTIME_UID" ]; then
    echo "[INFO] Проверка user-юнитов для \$RUNTIME_USER (UID: \$RUNTIME_UID)..."
    sudo -u "\$RUNTIME_USER" env XDG_RUNTIME_DIR="/run/user/\$RUNTIME_UID" systemctl --user is-active monitoring-prometheus.service && echo "[OK] Prometheus активен" || echo "[FAIL] Prometheus не активен"
    sudo -u "\$RUNTIME_USER" env XDG_RUNTIME_DIR="/run/user/\$RUNTIME_UID" systemctl --user is-active monitoring-grafana.service && echo "[OK] Grafana активна" || echo "[FAIL] Grafana не активна"
    sudo -u "\$RUNTIME_USER" env XDG_RUNTIME_DIR="/run/user/\$RUNTIME_UID" systemctl --user is-active monitoring-harvest-unix.service && echo "[OK] Harvest Unix активен" || echo "[FAIL] Harvest Unix не активен"
    sudo -u "\$RUNTIME_USER" env XDG_RUNTIME_DIR="/run/user/\$RUNTIME_UID" systemctl --user is-active monitoring-harvest-netapp.service && echo "[OK] Harvest NetApp активен" || echo "[FAIL] Harvest NetApp не активен"
else
    echo "[ERROR] Не удалось определить UID для ${runtimeUser}"
fi

echo ""
echo "================================================"
echo "ПРОВЕРКА ПОРТОВ:"
echo "================================================"
ss -tln | grep -q ":${promPort} " && echo "[OK] Порт ${promPort} (Prometheus) открыт" || echo "[FAIL] Порт ${promPort} не открыт"
ss -tln | grep -q ":${grafanaPort} " && echo "[OK] Порт ${grafanaPort} (Grafana) открыт" || echo "[FAIL] Порт ${grafanaPort} не открыт"
ss -tln | grep -q ":12996 " && echo "[OK] Порт 12996 (Harvest-NetApp) открыт" || echo "[FAIL] Порт 12996 не открыт"
ss -tln | grep -q ":12995 " && echo "[OK] Порт 12995 (Harvest-Unix) открыт" || echo "[FAIL] Порт 12995 не открыт"
ENDSSH
""", returnStdout: true).trim()
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
        string(name: 'RPM_URL_KV',         defaultValue: params.RPM_URL_KV ?: '',         description: 'Путь KV в Vault для RPM URL')
        string(name: 'VICTORIA_METRICS_REMOTE_WRITE_URL', defaultValue: params.VICTORIA_METRICS_REMOTE_WRITE_URL ?: '', description: 'URL VictoriaMetrics для Prometheus remote_write (например http://10.73.129.70:8480/insert/0/prometheus)')
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
        booleanParam(name: 'SYNC_RPM_PHASES', defaultValue: true, description: '🔄 Синхронная lockstep-установка RPM по всем серверам (Grafana -> Prometheus -> Harvest -> Node Exporter)')
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
                        rm -f temp_data_cred*.json 2>/dev/null || true
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
                    echo "[INFO] Сервер: ${env.SERVER_ADDRESS_EFFECTIVE}"
                    echo "[INFO] KAE: ${env.KAE}"
                    echo "[INFO] Подключение: ${env.DEPLOY_USER}@${env.SERVER_ADDRESS_EFFECTIVE}"
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
                    echo "[INFO] Проверка подключения к ${env.SERVER_ADDRESS_EFFECTIVE}..."
                    
                    sh """
                        ping -c 3 ${env.SERVER_ADDRESS_EFFECTIVE} || echo "[WARNING] Ping не прошел, но SSH может работать"
                    """
                }
            }
        }
        
        stage('CI: Получение секретов из Vault') {
            agent { label "clearAgent&&sbel8&&!static" }
            steps {
                script {
                    computeEnvironmentVariables()
                    def deploymentPairs = buildDeploymentPairs(params.SERVER_ADDRESS, params.NETAPP_API_ADDR)
                    def allServerNamesForSberca = deploymentPairs.collect { it.server }.join(',')
                    def primaryServerNameForSberca = deploymentPairs[0].server
                    
                    echo "[STEP] Получение секретов из Vault..."
                    
                    // Проверяем наличие credential ID
                    def vaultCredId = params.VAULT_CREDENTIAL_ID ?: 'vault-agent-dev'
                    echo "[INFO] Используется Vault Credential ID: ${vaultCredId}"
                    
                    // Формируем массив vaultSecrets для withVault плагина (как в v3.x)
                    def vaultSecrets = []
                    
                    if (params.RPM_URL_KV?.trim()) {
                        vaultSecrets << [path: params.RPM_URL_KV, secretValues: [
                            [envVar: 'VA_RPM_HARVEST',    vaultKey: 'harvest'],
                            [envVar: 'VA_RPM_PROMETHEUS', vaultKey: 'prometheus'],
                            [envVar: 'VA_RPM_GRAFANA',    vaultKey: 'grafana'],
                            [envVar: 'VA_RPM_NODE_EXPORTER', vaultKey: 'node_exporter']
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
                            "rpm_url": [harvest: '', prometheus: '', grafana: '', node_exporter: ''],
                            "netapp_ssh": [addr: '', user: '', pass: ''],
                            "grafana_web": [user: '', pass: ''],
                            "certificates": [server_bundle_pem: '', ca_chain_crt: '', grafana_client_pem: '']
                        ]
                        writeFile file: env.CRED_JSON_FILE, text: groovy.json.JsonOutput.toJson(emptyData)
                        deploymentPairs.each { pair ->
                            if (pair.credJsonFile != env.CRED_JSON_FILE) {
                                sh """#!/bin/bash
                                    cp -f "${env.CRED_JSON_FILE}" "${pair.credJsonFile}"
                                """
                            }
                        }
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
                                        common_name: (primaryServerNameForSberca ?: '').trim(),
                                        email: (params.ADMIN_EMAIL?.trim() ?: 'noreply@sberbank.ru'),
                                        format: 'pem',
                                        alt_names: (allServerNamesForSberca ?: '').trim()
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
                                        grafana: (env.VA_RPM_GRAFANA ?: ''),
                                        node_exporter: (env.VA_RPM_NODE_EXPORTER ?: '')
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
                                
                                writeFile file: env.CRED_JSON_FILE, text: groovy.json.JsonOutput.toJson(data)
                                echo "[INFO] credentials file: ${env.CRED_JSON_FILE}"
                                echo "[INFO] certificates in ${env.CRED_JSON_FILE}: " +
                                     "server_bundle_pem=${serverBundlePem ? 'yes' : 'no'}, " +
                                     "ca_chain_crt=${caChainCrt ? 'yes' : 'no'}, " +
                                     "grafana_client_pem=${grafanaClientPem ? 'yes' : 'no'}"
                                deploymentPairs.each { pair ->
                                    if (pair.credJsonFile != env.CRED_JSON_FILE) {
                                        sh """#!/bin/bash
                                            cp -f "${env.CRED_JSON_FILE}" "${pair.credJsonFile}"
                                        """
                                    }
                                }
                            }
                        } catch (Exception e) {
                            echo "[ERROR] Ошибка Vault: ${e.message}"
                            error("❌ Не удалось получить данные из Vault")
                        }
                    }
                    
                    // Проверка файла
                    deploymentPairs.each { pair ->
                        sh """#!/bin/bash
                            [ ! -f "${pair.credJsonFile}" ] && echo "[ERROR] Файл ${pair.credJsonFile} не создан!" && exit 1
                            if command -v jq >/dev/null 2>&1; then
                                jq empty "${pair.credJsonFile}" 2>/dev/null || { echo "[ERROR] Невалидный JSON: ${pair.credJsonFile}!"; exit 1; }
                            fi
                        """
                    }
                    
                    // Сохраняем для CDL этапа
                    stash name: 'vault-credentials', includes: 'temp_data_cred_*.json,temp_data_cred.json'
                    
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
                    def deploymentPairs = buildDeploymentPairs(params.SERVER_ADDRESS, params.NETAPP_API_ADDR)
                    sh 'mkdir -p .deploy-status'
                    
                    echo "[INFO] Используем уже загруженный workspace без дополнительного checkout"
                    
                    // Восстанавливаем credentials-файлы из stash
                    unstash 'vault-credentials'
                    
                    echo "[STEP] Копирование скрипта и файлов на сервер..."
                    sh '''
                        [ ! -f "install-monitoring-stack.sh" ] && echo "[ERROR] install-monitoring-stack.sh не найден!" && exit 1
                        [ ! -d "wrappers" ] && echo "[ERROR] Папка wrappers не найдена!" && exit 1
                        if [ -f wrappers/build-integrity-checkers.sh ]; then
                          /bin/bash wrappers/build-integrity-checkers.sh
                        fi
                    '''
                    
                    withVaultSshCredentials(this) {
                        def expectedSshUser = params.SSH_LOGIN?.trim() ? params.SSH_LOGIN.trim() : env.DEPLOY_USER
                        echo '[INFO] Подключение под пользователем настроено (ожидается: ' + expectedSshUser + ')'
                        def parallelCopies = [:]
                        deploymentPairs.each { pair ->
                            def p = pair
                            parallelCopies["copy-${p.server}"] = {
                                int rc = sh(returnStatus: true, script: """#!/bin/bash
set -e
SSH_OPTS="-q -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes -o TCPKeepAlive=yes -o LogLevel=ERROR"
[ ! -f "${p.credJsonFile}" ] && echo "[ERROR] ${p.credJsonFile} не найден!" && exit 1

echo "[INFO] [${p.server}] Тестируем SSH подключение..."
ssh \$SSH_OPTS "${env.SSH_USER}@${p.server}" "echo '[OK] SSH подключение успешно'" 2>/dev/null

echo "[INFO] [${p.server}] Создаем рабочую директорию ${env.DEPLOY_PATH}..."
ssh \$SSH_OPTS "${env.SSH_USER}@${p.server}" "mkdir -p '${env.DEPLOY_PATH}'" 2>/dev/null

echo "[INFO] [${p.server}] Копируем скрипт, wrappers и credentials..."
scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    install-monitoring-stack.sh \
    "${env.SSH_USER}@${p.server}:${env.DEPLOY_PATH}/install-monitoring-stack.sh" 2>/dev/null
scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR -r \
    wrappers \
    "${env.SSH_USER}@${p.server}:${env.DEPLOY_PATH}/" 2>/dev/null
scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "${p.credJsonFile}" \
    "${env.SSH_USER}@${p.server}:${env.DEPLOY_PATH}/${p.credJsonFile}" 2>/dev/null

ssh -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "${env.SSH_USER}@${p.server}" 2>/dev/null << 'REMOTE_EOF'
[ ! -f "${env.DEPLOY_PATH}/install-monitoring-stack.sh" ] && echo "[ERROR] Скрипт не найден!" && exit 1
[ ! -d "${env.DEPLOY_PATH}/wrappers" ] && echo "[ERROR] Wrappers не найдены!" && exit 1
[ ! -f "${env.DEPLOY_PATH}/${p.credJsonFile}" ] && echo "[ERROR] Credentials не найдены!" && exit 1
echo "[OK] Все файлы на месте"
REMOTE_EOF
echo "[SUCCESS] [${p.server}] Копирование завершено"
""")
                                def statusObj = [
                                    server: p.server,
                                    netapp: p.netapp,
                                    stage: 'copy',
                                    status: (rc == 0 ? 'SUCCESS' : 'FAILED'),
                                    reason: (rc == 0 ? 'ok' : "exit_code_${rc}")
                                ]
                                writeFile file: ".deploy-status/copy_${p.serverPrefixSafe}.json", text: groovy.json.JsonOutput.toJson(statusObj)
                            }
                        }
                        parallel parallelCopies
                    }
                    def copyRows = []
                    deploymentPairs.each { p ->
                        def f = ".deploy-status/copy_${p.serverPrefixSafe}.json"
                        if (fileExists(f)) {
                            copyRows << new groovy.json.JsonSlurperClassic().parseText(readFile(f))
                        } else {
                            copyRows << [server: p.server, netapp: p.netapp, stage: 'copy', status: 'FAILED', reason: 'no_status_file']
                        }
                    }
                    def copySummary = renderDeploySummary("СВОДКА COPY", copyRows)
                    echo copySummary
                    env.DEPLOY_STATUS_SUMMARY = copySummary
                    if (copyRows.any { it.status != 'SUCCESS' }) {
                        error("❌ Ошибка копирования на одном или нескольких серверах")
                    }
                    echo "[SUCCESS] Копирование завершено для всех серверов"
                }
            }
        }

        stage('CDL: Синхронная фазовая установка RPM') {
            agent { label "masterLin&&sbel8&&!static" }
            when {
                expression { params.SKIP_DEPLOYMENT != true && params.SYNC_RPM_PHASES == true }
            }
            steps {
                script {
                    computeEnvironmentVariables()
                    def deploymentPairs = buildDeploymentPairs(params.SERVER_ADDRESS, params.NETAPP_API_ADDR)
                    sh 'mkdir -p .deploy-status'

                    echo "[STEP] Синхронная lockstep установка RPM по всем серверам"
                    echo "[INFO] Принцип: Grafana -> Prometheus -> Harvest -> Node Exporter"
                    def rpmPhases = ['Grafana', 'Prometheus', 'Harvest', 'Node Exporter']

                    withCredentials([
                        string(credentialsId: params.RLM_TOKEN_CREDENTIAL_ID, variable: 'RLM_TOKEN')
                    ]) {
                        withVaultSshCredentials(this) {
                            rpmPhases.each { phaseName ->
                                def phaseSlug = phaseName.toLowerCase().replaceAll(/[^a-z0-9]+/, '_')
                                echo "================================================"
                                echo "[SYNC-RPM] ФАЗА START: ${phaseName}"
                                echo "================================================"

                                def parallelPhase = [:]
                                deploymentPairs.each { pair ->
                                    def p = pair
                                    parallelPhase["rpm-${phaseSlug}-${p.server}"] = {
                                        int rc = runRemoteRpmPhaseInstall(this, p, phaseName)
                                        def statusObj = [
                                            server: p.server,
                                            netapp: p.netapp,
                                            stage: "rpm-${phaseSlug}",
                                            status: (rc == 0 ? 'SUCCESS' : 'FAILED'),
                                            reason: (rc == 0 ? 'ok' : "exit_code_${rc}")
                                        ]
                                        writeFile file: ".deploy-status/rpm_${phaseSlug}_${p.serverPrefixSafe}.json", text: groovy.json.JsonOutput.toJson(statusObj)
                                    }
                                }
                                parallel parallelPhase

                                def phaseRows = []
                                deploymentPairs.each { p ->
                                    def f = ".deploy-status/rpm_${phaseSlug}_${p.serverPrefixSafe}.json"
                                    if (fileExists(f)) {
                                        phaseRows << new groovy.json.JsonSlurperClassic().parseText(readFile(f))
                                    } else {
                                        phaseRows << [server: p.server, netapp: p.netapp, stage: "rpm-${phaseSlug}", status: 'FAILED', reason: 'no_status_file']
                                    }
                                }
                                def phaseSummary = renderDeploySummary("СВОДКА ${phaseName.toUpperCase()} (LOCKSTEP)", phaseRows)
                                echo phaseSummary
                                env.DEPLOY_STATUS_SUMMARY = (env.DEPLOY_STATUS_SUMMARY ? (env.DEPLOY_STATUS_SUMMARY + "\n" + phaseSummary) : phaseSummary)
                                if (phaseRows.any { it.status != 'SUCCESS' }) {
                                    error("❌ Фаза ${phaseName} завершилась с ошибками. Переход к следующей фазе остановлен.")
                                }

                                echo "[SYNC-RPM] Все серверы завершили фазу ${phaseName}. Переходим к следующей через 5с..."
                                sh 'sleep 5'
                            }
                        }
                    }
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
                    def deploymentPairs = buildDeploymentPairs(params.SERVER_ADDRESS, params.NETAPP_API_ADDR)
                    sh 'mkdir -p .deploy-status'
                    def effectiveSkipRpm = params.SYNC_RPM_PHASES ? 'true' : (params.SKIP_RPM_INSTALL ? 'true' : 'false')

                    echo "[STEP] Запуск развертывания на удаленных серверах..."
                    if (params.SYNC_RPM_PHASES) {
                        echo "[INFO] Режим: SKIP_RPM_INSTALL=true (RPM уже установлены в lockstep-фазах)"
                    } else {
                        echo "[INFO] Режим: стандартный (учитываем параметр SKIP_RPM_INSTALL=${effectiveSkipRpm})"
                    }

                    unstash 'vault-credentials'
                    withCredentials([
                        string(credentialsId: params.RLM_TOKEN_CREDENTIAL_ID, variable: 'RLM_TOKEN')
                    ]) {
                        withVaultSshCredentials(this) {
                            def parallelDeploy = [:]
                            deploymentPairs.each { pair ->
                                def p = pair
                                parallelDeploy["deploy-${p.server}"] = {
                                    int rc = runRemoteFullDeploy(this, p, effectiveSkipRpm)
                                    def statusObj = [
                                        server: p.server,
                                        netapp: p.netapp,
                                        stage: 'deploy',
                                        status: (rc == 0 ? 'SUCCESS' : 'FAILED'),
                                        reason: (rc == 0 ? 'ok' : "exit_code_${rc}")
                                    ]
                                    writeFile file: ".deploy-status/deploy_${p.serverPrefixSafe}.json", text: groovy.json.JsonOutput.toJson(statusObj)
                                }
                            }
                            parallel parallelDeploy
                        }
                    }

                    def deployRows = []
                    deploymentPairs.each { p ->
                        def f = ".deploy-status/deploy_${p.serverPrefixSafe}.json"
                        if (fileExists(f)) {
                            deployRows << new groovy.json.JsonSlurperClassic().parseText(readFile(f))
                        } else {
                            deployRows << [server: p.server, netapp: p.netapp, stage: 'deploy', status: 'FAILED', reason: 'no_status_file']
                        }
                    }
                    def deploySummary = renderDeploySummary("СВОДКА DEPLOY", deployRows)
                    echo deploySummary
                    env.DEPLOY_STATUS_SUMMARY = (env.DEPLOY_STATUS_SUMMARY ? (env.DEPLOY_STATUS_SUMMARY + "\n" + deploySummary) : deploySummary)
                    if (deployRows.any { it.status != 'SUCCESS' }) {
                        error("❌ Ошибка развертывания на одном или нескольких серверах")
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
                    def deploymentPairs = buildDeploymentPairs(params.SERVER_ADDRESS, params.NETAPP_API_ADDR)
                    
                    echo "[STEP] Проверка результатов развертывания (User Units)..."
                    withVaultSshCredentials(this) {
                        def parallelChecks = [:]
                        deploymentPairs.each { pair ->
                            def p = pair
                            parallelChecks["check-${p.server}"] = {
                                def result = runRemoteVerification(this, p)
                                echo result
                            }
                        }
                        parallel parallelChecks
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
                    def deploymentPairs = buildDeploymentPairs(params.SERVER_ADDRESS, params.NETAPP_API_ADDR)
                    
                    echo "[STEP] Очистка временных файлов..."
                    sh "rm -rf temp_data_cred.json temp_data_cred_*.json"
                    withVaultSshCredentials(this) {
                        def parallelCleanup = [:]
                        deploymentPairs.each { pair ->
                            def p = pair
                            parallelCleanup["cleanup-${p.server}"] = {
                                sh """#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "${env.SSH_USER}"@"${p.server}" \
    "rm -rf ${env.DEPLOY_PATH}/${p.credJsonFile} ${env.DEPLOY_PATH}/temp_data_cred.json ${env.DEPLOY_PATH}/temp_data_cred_*.json" 2>/dev/null || true
"""
                            }
                        }
                        parallel parallelCleanup
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
    "$SSH_USER"@''' + env.SERVER_ADDRESS_EFFECTIVE + ''' \
    "nslookup ''' + env.SERVER_ADDRESS_EFFECTIVE + ''' 2>/dev/null | grep 'name =' | awk '{print \\$4}' | sed 's/\\.$//' || echo ''" 2>/dev/null
'''
                        sh 'chmod +x get_domain.sh'
                        domainName = sh(script: './get_domain.sh', returnStdout: true).trim()
                        sh 'rm -f get_domain.sh'
                    }
                    if (domainName == '') {
                        domainName = env.SERVER_ADDRESS_EFFECTIVE
                    }
                    def serverIp = ''
                    withVaultSshCredentials(this) {
                        writeFile file: 'get_ip.sh', text: '''#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "$SSH_USER"@''' + env.SERVER_ADDRESS_EFFECTIVE + ''' \
    "hostname -I | awk '{print \\$1}' || echo ''' + (env.SERVER_ADDRESS_EFFECTIVE ?: '') + '''" 2>/dev/null
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
                    echo "[INFO] Рекомендации по проверке и диагностике (SECURE / user-units):"
                    echo " • Runtime user: ${env.DEPLOY_USER}"
                    echo " • Статус user-юнитов:"
                    echo "   XDG_RUNTIME_DIR=\"/run/user/\$(id -u ${env.DEPLOY_USER})\" systemctl --user status monitoring-prometheus.service monitoring-grafana.service monitoring-harvest-unix.service monitoring-harvest-netapp.service"
                    echo " • Active/Enabled:"
                    echo "   systemctl --user is-active monitoring-prometheus.service monitoring-grafana.service monitoring-harvest-unix.service monitoring-harvest-netapp.service"
                    echo "   systemctl --user is-enabled monitoring-prometheus.service monitoring-grafana.service monitoring-harvest-unix.service monitoring-harvest-netapp.service"
                    echo " • Linger:"
                    echo "   loginctl show-user ${env.DEPLOY_USER} -p Linger"
                    echo " • Проверка портов:"
                    echo "   ss -tln | grep -E ':(3300|9090|12996|12995)'"
                    echo " • Конфиги:"
                    echo "   ~/monitoring/config/prometheus/prometheus.yml"
                    echo "   ~/monitoring/config/prometheus/web-config.yml"
                    echo "   ~/monitoring/config/grafana/grafana.ini"
                    echo "   ~/monitoring/config/harvest/harvest-unix.yml"
                    echo "   ~/monitoring/config/harvest/harvest-netapp.yml"
                    echo " • Journal логи:"
                    echo "   journalctl --user -u monitoring-prometheus.service -n 200 --no-pager"
                    echo "   journalctl --user -u monitoring-grafana.service -n 200 --no-pager"
                    echo "   journalctl --user -u monitoring-harvest-unix.service -n 200 --no-pager"
                    echo "   journalctl --user -u monitoring-harvest-netapp.service -n 200 --no-pager"
                    echo " • File логи:"
                    echo "   tail -n 200 ~/monitoring/logs/prometheus/* 2>/dev/null"
                    echo "   tail -n 200 ~/monitoring/logs/grafana/* 2>/dev/null"
                    echo "   tail -n 200 ~/monitoring/logs/harvest/harvest.log 2>/dev/null"
                    echo " • API проверки:"
                    echo "   curl -k -sS https://${domainName}:${params.PROMETHEUS_PORT}/-/ready"
                    echo "   curl -k -sS https://${domainName}:${params.GRAFANA_PORT}/api/health"
                    echo "   curl -k -sS https://${domainName}:12996/metrics | head"
                    echo "   curl -sS  http://127.0.0.1:12995/metrics | head"
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
            script {
                if (env.DEPLOY_STATUS_SUMMARY?.trim()) {
                    echo env.DEPLOY_STATUS_SUMMARY
                } else {
                    echo "================================================"
                    echo "📋 СВОДКА ПО СЕРВЕРАМ: недоступна (ветки не стартовали)"
                    echo "================================================"
                }
            }
            echo "Время выполнения: ${currentBuild.durationString}"
        }
    }
}
