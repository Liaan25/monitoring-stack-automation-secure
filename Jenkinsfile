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
    def phaseFilterSafe = phaseName.replaceAll(/[^A-Za-z0-9]+/, '')
    return scriptContext.sh(returnStatus: true, script: """#!/bin/bash
set -e
chmod +x tools/remote_rpm_phase.sh
SSH_USER='${scriptContext.env.SSH_USER}' \
TARGET_SERVER='${pair.server}' \
DEPLOY_PATH='${scriptContext.env.DEPLOY_PATH}' \
CRED_JSON_FILE='${pair.credJsonFile}' \
TARGET_NETAPP='${pair.netapp}' \
RLM_TOKEN="\$RLM_TOKEN" \
PHASE_NAME='${phaseFilterSafe}' \
SEC_MAN_ADDR='${scriptContext.params.SEC_MAN_ADDR ?: ''}' \
NAMESPACE_CI='${scriptContext.params.NAMESPACE_CI ?: ''}' \
RLM_API_URL='${scriptContext.params.RLM_API_URL ?: ''}' \
GRAFANA_PORT='${scriptContext.params.GRAFANA_PORT ?: '3000'}' \
PROMETHEUS_PORT='${scriptContext.params.PROMETHEUS_PORT ?: '9090'}' \
RPM_URL_KV='${scriptContext.params.RPM_URL_KV ?: ''}' \
NETAPP_SSH_KV='${scriptContext.params.NETAPP_SSH_KV ?: ''}' \
GRAFANA_WEB_KV='${scriptContext.params.GRAFANA_WEB_KV ?: ''}' \
SBERCA_CERT_KV='${scriptContext.params.SBERCA_CERT_KV ?: ''}' \
ADMIN_EMAIL='${scriptContext.params.ADMIN_EMAIL ?: ''}' \
VICTORIA_METRICS_REMOTE_WRITE_URL='${scriptContext.params.VICTORIA_METRICS_REMOTE_WRITE_URL ?: ''}' \
USE_SIMPLIFIED_CERT_FLOW='${scriptContext.params.USE_SIMPLIFIED_CERT_FLOW ? 'true' : 'false'}' \
RUN_SERVICES_AS_MON_CI='${scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false'}' \
DEPLOY_VERSION='${scriptContext.env.VERSION_SHORT ?: 'unknown'}' \
DEPLOY_GIT_COMMIT='${scriptContext.env.VERSION_GIT_COMMIT ?: 'unknown'}' \
DEPLOY_BUILD_DATE='${scriptContext.env.VERSION_BUILD_TIMESTAMP ?: 'unknown'}' \
./tools/remote_rpm_phase.sh
""")
}

def runRemoteFullDeploy(scriptContext, Map pair, String effectiveSkipRpm) {
    return scriptContext.sh(returnStatus: true, script: """#!/bin/bash
set -e
chmod +x tools/remote_full_deploy.sh
SSH_USER='${scriptContext.env.SSH_USER}' \
TARGET_SERVER='${pair.server}' \
DEPLOY_PATH='${scriptContext.env.DEPLOY_PATH}' \
CRED_JSON_FILE='${pair.credJsonFile}' \
TARGET_NETAPP='${pair.netapp}' \
RLM_TOKEN="\$RLM_TOKEN" \
SEC_MAN_ADDR='${scriptContext.params.SEC_MAN_ADDR ?: ''}' \
NAMESPACE_CI='${scriptContext.params.NAMESPACE_CI ?: ''}' \
RLM_API_URL='${scriptContext.params.RLM_API_URL ?: ''}' \
GRAFANA_PORT='${scriptContext.params.GRAFANA_PORT ?: '3000'}' \
PROMETHEUS_PORT='${scriptContext.params.PROMETHEUS_PORT ?: '9090'}' \
RPM_URL_KV='${scriptContext.params.RPM_URL_KV ?: ''}' \
NETAPP_SSH_KV='${scriptContext.params.NETAPP_SSH_KV ?: ''}' \
GRAFANA_WEB_KV='${scriptContext.params.GRAFANA_WEB_KV ?: ''}' \
SBERCA_CERT_KV='${scriptContext.params.SBERCA_CERT_KV ?: ''}' \
ADMIN_EMAIL='${scriptContext.params.ADMIN_EMAIL ?: ''}' \
VICTORIA_METRICS_REMOTE_WRITE_URL='${scriptContext.params.VICTORIA_METRICS_REMOTE_WRITE_URL ?: ''}' \
RENEW_CERTIFICATES_ONLY='${scriptContext.params.RENEW_CERTIFICATES_ONLY ? 'true' : 'false'}' \
USE_SIMPLIFIED_CERT_FLOW='${scriptContext.params.USE_SIMPLIFIED_CERT_FLOW ? 'true' : 'false'}' \
EFFECTIVE_SKIP_RPM='${effectiveSkipRpm}' \
SKIP_IPTABLES='${scriptContext.params.SKIP_IPTABLES ? 'true' : 'false'}' \
RUN_SERVICES_AS_MON_CI='${scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false'}' \
DEPLOY_VERSION='${scriptContext.env.VERSION_SHORT ?: 'unknown'}' \
DEPLOY_GIT_COMMIT='${scriptContext.env.VERSION_GIT_COMMIT ?: 'unknown'}' \
DEPLOY_BUILD_DATE='${scriptContext.env.VERSION_BUILD_TIMESTAMP ?: 'unknown'}' \
./tools/remote_full_deploy.sh
""")
}

def runRemoteVerification(scriptContext, Map pair) {
    return scriptContext.sh(script: """#!/bin/bash
set -e
chmod +x tools/remote_verify.sh
SSH_USER='${scriptContext.env.SSH_USER}' \
TARGET_SERVER='${pair.server}' \
RUN_SERVICES_AS_MON_CI='${scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false'}' \
DEPLOY_USER='${scriptContext.env.DEPLOY_USER}' \
MON_SYS_USER='${scriptContext.env.MON_SYS_USER}' \
PROMETHEUS_PORT='${scriptContext.params.PROMETHEUS_PORT ?: '9090'}' \
GRAFANA_PORT='${scriptContext.params.GRAFANA_PORT ?: '3300'}' \
./tools/remote_verify.sh
""", returnStdout: true).trim()
}

def runRemoteCopy(scriptContext, Map pair) {
    return scriptContext.sh(returnStatus: true, script: """#!/bin/bash
set -e
chmod +x tools/remote_copy.sh
SSH_USER='${scriptContext.env.SSH_USER}' \
TARGET_SERVER='${pair.server}' \
DEPLOY_PATH='${scriptContext.env.DEPLOY_PATH}' \
CRED_JSON_FILE='${pair.credJsonFile}' \
./tools/remote_copy.sh
""")
}

def getRemoteDomain(scriptContext, String serverAddress) {
    return scriptContext.sh(
        script: """#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  "${scriptContext.env.SSH_USER}"@"${serverAddress}" \
  "nslookup ${serverAddress} 2>/dev/null | grep 'name =' | awk '{print \\\$4}' | sed 's/\\.\$//' || echo ''" 2>/dev/null
""",
        returnStdout: true
    ).trim()
}

def getRemoteIp(scriptContext, String serverAddress) {
    return scriptContext.sh(
        script: """#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  "${scriptContext.env.SSH_USER}"@"${serverAddress}" \
  "hostname -I | awk '{print \\\$1}' || echo ${serverAddress}" 2>/dev/null
""",
        returnStdout: true
    ).trim()
}

def fetchVaultCredentialsForAllPairs(scriptContext) {
    computeEnvironmentVariables()
    def deploymentPairs = buildDeploymentPairs(scriptContext.params.SERVER_ADDRESS, scriptContext.params.NETAPP_API_ADDR)
    def allServerNamesForSberca = deploymentPairs.collect { it.server }.join(',')
    def primaryServerNameForSberca = deploymentPairs[0].server
    def vaultCredId = scriptContext.params.VAULT_CREDENTIAL_ID ?: 'vault-agent-dev'

    scriptContext.echo "[STEP] Получение секретов из Vault..."
    scriptContext.echo "[INFO] Используется Vault Credential ID: ${vaultCredId}"

    def vaultSecrets = []
    if (scriptContext.params.RPM_URL_KV?.trim()) {
        vaultSecrets << [path: scriptContext.params.RPM_URL_KV, secretValues: [
            [envVar: 'VA_RPM_HARVEST', vaultKey: 'harvest'],
            [envVar: 'VA_RPM_PROMETHEUS', vaultKey: 'prometheus'],
            [envVar: 'VA_RPM_GRAFANA', vaultKey: 'grafana'],
            [envVar: 'VA_RPM_NODE_EXPORTER', vaultKey: 'node_exporter']
        ]]
    }
    if (scriptContext.params.NETAPP_SSH_KV?.trim()) {
        vaultSecrets << [path: scriptContext.params.NETAPP_SSH_KV, secretValues: [
            [envVar: 'VA_NETAPP_SSH_ADDR', vaultKey: 'addr'],
            [envVar: 'VA_NETAPP_SSH_USER', vaultKey: 'user'],
            [envVar: 'VA_NETAPP_SSH_PASS', vaultKey: 'pass']
        ]]
    }
    if (scriptContext.params.NODE_EXPORTER_TUZ_KV?.trim()) {
        vaultSecrets << [path: scriptContext.params.NODE_EXPORTER_TUZ_KV, secretValues: [
            [envVar: 'VA_NODE_EXPORTER_TUZ_USER', vaultKey: 'user'],
            [envVar: 'VA_NODE_EXPORTER_TUZ_PASS', vaultKey: 'pass']
        ]]
    }
    if (scriptContext.params.GRAFANA_WEB_KV?.trim()) {
        vaultSecrets << [path: scriptContext.params.GRAFANA_WEB_KV, secretValues: [
            [envVar: 'VA_GRAFANA_WEB_USER', vaultKey: 'user'],
            [envVar: 'VA_GRAFANA_WEB_PASS', vaultKey: 'pass']
        ]]
    }

    if (vaultSecrets.isEmpty()) {
        scriptContext.echo "[WARNING] KV пути не заданы"
        def emptyData = [
            "vault-agent": [role_id: '', secret_id: ''],
            "rpm_url": [harvest: '', prometheus: '', grafana: '', node_exporter: ''],
            "netapp_ssh": [addr: '', user: '', pass: ''],
            "node_exporter_tuz": [user: '', pass: ''],
            "grafana_web": [user: '', pass: ''],
            "certificates": [server_bundle_pem: '', ca_chain_crt: '', grafana_client_pem: '']
        ]
        scriptContext.writeFile file: scriptContext.env.CRED_JSON_FILE, text: groovy.json.JsonOutput.toJson(emptyData)
    } else {
        try {
            scriptContext.withVault([
                configuration: [
                    vaultUrl: "https://${scriptContext.params.SEC_MAN_ADDR}",
                    engineVersion: 1,
                    skipSslVerification: false,
                    vaultCredentialId: vaultCredId,
                    vaultNamespace: scriptContext.params.NAMESPACE_CI?.trim()
                ],
                vaultSecrets: vaultSecrets
            ]) {
                def serverBundlePem = ''
                def caChainCrt = ''
                def grafanaClientPem = ''

                if (scriptContext.params.SBERCA_CERT_KV?.trim()) {
                    def requestedPath = scriptContext.params.SBERCA_CERT_KV.trim()
                    def vaultNamespace = scriptContext.params.NAMESPACE_CI?.trim()
                    def apiPath = requestedPath.replaceAll('^/+', '')
                    if (apiPath.startsWith('v1/')) { apiPath = apiPath.substring(3) }
                    if (vaultNamespace && apiPath.startsWith("${vaultNamespace}/")) { apiPath = apiPath.substring(vaultNamespace.length() + 1) }
                    apiPath = apiPath.replace('/SBERCA/fetch/', '/SBERCA/')
                    if (!apiPath.contains('/SBERCA/') || !apiPath.contains('/fetch/')) {
                        scriptContext.error("❌ SBERCA_CERT_KV имеет неверный формат. Ожидается: <NAMESPACE>/.../SBERCA/<mount>/fetch/<role>")
                    }
                    if (apiPath.contains('/fetch/') && apiPath.split('/fetch/').size() > 2) {
                        scriptContext.error("❌ SBERCA_CERT_KV содержит лишний '/fetch/'. Используйте формат: <NAMESPACE>/.../SBERCA/<mount>/fetch/<role>")
                    }
                    if (requestedPath != apiPath && requestedPath != "${vaultNamespace}/${apiPath}") {
                        scriptContext.echo "[SBERCA-DIAG] Нормализация пути SBERCA_CERT_KV"
                        scriptContext.echo "[SBERCA-DIAG] requested_path: ${requestedPath}"
                        scriptContext.echo "[SBERCA-DIAG] normalized_api_path: ${apiPath}"
                    }
                    def certRequestPayload = groovy.json.JsonOutput.toJson([
                        common_name: (primaryServerNameForSberca ?: '').trim(),
                        email: (scriptContext.params.ADMIN_EMAIL?.trim() ?: 'noreply@sberbank.ru'),
                        format: 'pem',
                        alt_names: (allServerNamesForSberca ?: '').trim()
                    ])
                    scriptContext.withCredentials([[
                        $class: 'VaultTokenCredentialBinding',
                        credentialsId: vaultCredId,
                        vaultNamespace: vaultNamespace,
                        vaultAddr: "https://${scriptContext.params.SEC_MAN_ADDR}"
                    ]]) {
                        def certResponseRaw = scriptContext.sh(
                            script: """#!/bin/bash
set -euo pipefail
chmod +x tools/fetch_sberca.sh
SBERCA_URL='https://${scriptContext.params.SEC_MAN_ADDR}' \\
SBERCA_API_PATH='${apiPath}' \\
SBERCA_NAMESPACE='${vaultNamespace ?: ''}' \\
SBERCA_REQUEST_PAYLOAD='${certRequestPayload.replace("'", "'\"'\"'")}' \\
./tools/fetch_sberca.sh
""",
                            returnStdout: true
                        ).trim()
                        def certResponse = new groovy.json.JsonSlurperClassic().parseText(certResponseRaw)
                        def cert = (certResponse?.data?.certificate ?: '').toString().trim()
                        def pkey = (certResponse?.data?.private_key ?: '').toString().trim()
                        def issuingCa = (certResponse?.data?.issuing_ca ?: '').toString().trim()
                        def chainObj = certResponse?.data?.ca_chain
                        def chainText = ''
                        if (chainObj instanceof List) { chainText = chainObj.findAll { it != null }.collect { it.toString() }.join('\n') }
                        else if (chainObj != null) { chainText = chainObj.toString().trim() }
                        serverBundlePem = [pkey, cert, issuingCa].findAll { it?.trim() }.join('\n')
                        caChainCrt = chainText?.trim() ? chainText : issuingCa
                        grafanaClientPem = [pkey, cert, issuingCa].findAll { it?.trim() }.join('\n')
                        if (!serverBundlePem?.trim()) { scriptContext.error("❌ SberCA fetch вернул пустой server_bundle_pem") }
                    }
                }

                def data = [
                    "vault-agent": [role_id: (scriptContext.env.VA_ROLE_ID ?: ''), secret_id: (scriptContext.env.VA_SECRET_ID ?: '')],
                    "rpm_url": [harvest: (scriptContext.env.VA_RPM_HARVEST ?: ''), prometheus: (scriptContext.env.VA_RPM_PROMETHEUS ?: ''), grafana: (scriptContext.env.VA_RPM_GRAFANA ?: ''), node_exporter: (scriptContext.env.VA_RPM_NODE_EXPORTER ?: '')],
                    "netapp_ssh": [addr: (scriptContext.env.VA_NETAPP_SSH_ADDR ?: ''), user: (scriptContext.env.VA_NETAPP_SSH_USER ?: ''), pass: (scriptContext.env.VA_NETAPP_SSH_PASS ?: '')],
                    "node_exporter_tuz": [user: (scriptContext.env.VA_NODE_EXPORTER_TUZ_USER ?: ''), pass: (scriptContext.env.VA_NODE_EXPORTER_TUZ_PASS ?: '')],
                    "grafana_web": [user: (scriptContext.env.VA_GRAFANA_WEB_USER ?: ''), pass: (scriptContext.env.VA_GRAFANA_WEB_PASS ?: '')],
                    "certificates": [server_bundle_pem: serverBundlePem, ca_chain_crt: caChainCrt, grafana_client_pem: grafanaClientPem]
                ]
                scriptContext.writeFile file: scriptContext.env.CRED_JSON_FILE, text: groovy.json.JsonOutput.toJson(data)
            }
        } catch (Exception e) {
            scriptContext.echo "[ERROR] Ошибка Vault: ${e.message}"
            scriptContext.error("❌ Не удалось получить данные из Vault")
        }
    }

    deploymentPairs.each { pair ->
        if (pair.credJsonFile != scriptContext.env.CRED_JSON_FILE) {
            scriptContext.sh "cp -f '${scriptContext.env.CRED_JSON_FILE}' '${pair.credJsonFile}'"
        }
        scriptContext.sh """#!/bin/bash
[ ! -f "${pair.credJsonFile}" ] && echo "[ERROR] Файл ${pair.credJsonFile} не создан!" && exit 1
if command -v jq >/dev/null 2>&1; then
  jq empty "${pair.credJsonFile}" 2>/dev/null || { echo "[ERROR] Невалидный JSON: ${pair.credJsonFile}!"; exit 1; }
fi
"""
    }
    scriptContext.stash name: 'vault-credentials', includes: 'temp_data_cred_*.json,temp_data_cred.json'
    scriptContext.echo "[SUCCESS] Данные из Vault получены"
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
        string(name: 'NODE_EXPORTER_TUZ_KV', defaultValue: params.NODE_EXPORTER_TUZ_KV ?: '', description: 'Путь KV в Vault для кредов Node Exporter tar.gz (ключи: user, pass)')
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
                    fetchVaultCredentialsForAllPairs(this)
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
                                int rc = runRemoteCopy(this, p)
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
                        domainName = getRemoteDomain(this, env.SERVER_ADDRESS_EFFECTIVE)
                    }
                    if (domainName == '') {
                        domainName = env.SERVER_ADDRESS_EFFECTIVE
                    }
                    def serverIp = ''
                    withVaultSshCredentials(this) {
                        serverIp = getRemoteIp(this, env.SERVER_ADDRESS_EFFECTIVE)
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
