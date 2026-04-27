// ========================================================================
// ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (вынесены для уменьшения размера методов)
// ========================================================================

@NonCPS
def normalizeBool(def value, boolean defaultValue = false) {
    if (value == null) {
        return defaultValue
    }
    def s = value.toString().trim().toLowerCase()
    if (!s) {
        return defaultValue
    }
    return ['1', 'true', 'yes', 'y', 'on'].contains(s)
}

def runtimeParam(scriptContext, String key, String fallback = '') {
    def overrideVal = scriptContext.env."OVERRIDE_${key}"
    if (overrideVal != null && overrideVal.toString().trim()) {
        return overrideVal.toString()
    }
    def p = scriptContext.params?."${key}"
    if (p != null && p.toString().trim()) {
        return p.toString()
    }
    return fallback
}

def rollbackEnabled(scriptContext) {
    return normalizeBool(scriptContext.params?.ROLLBACK_TO_STABLE, false)
}

@NonCPS
def parseStableIndex(def parsed) {
    if (parsed instanceof List) {
        return parsed
    }
    if (parsed instanceof Map && parsed.versions instanceof List) {
        return parsed.versions
    }
    return []
}

def chooseAndApplyStableSnapshot(scriptContext) {
    if (!rollbackEnabled(scriptContext)) {
        scriptContext.echo "[STABLE] Rollback mode disabled; using manual parameters."
        return
    }

    def indexPath = 'ci/stable/index.json'
    if (!scriptContext.fileExists(indexPath)) {
        scriptContext.error("❌ [STABLE] Не найден ${indexPath}. Невозможно выполнить rollback.")
    }

    def parsedIndex = new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(indexPath))
    def versions = parseStableIndex(parsedIndex)
    if (!versions || versions.isEmpty()) {
        scriptContext.error("❌ [STABLE] В ${indexPath} нет стабильных snapshot-версий.")
    }

    def options = []
    def optionToId = [:]
    versions.each { item ->
        def id = (item?.id ?: item?.tag ?: '').toString().trim()
        if (!id) {
            return
        }
        def label = (item?.label ?: "${id} | commit=${(item?.commit_sha ?: 'n/a')} | profile=${(item?.run_profile ?: 'n/a')}").toString()
        options << label
        optionToId[label] = id
    }

    if (options.isEmpty()) {
        scriptContext.error("❌ [STABLE] Не удалось сформировать список выбора стабильных версий.")
    }

    def requestedId = (scriptContext.params?.STABLE_VERSION ?: '').toString().trim()
    def selectedId = requestedId
    if (!selectedId || !versions.find { ((it?.id ?: it?.tag ?: '').toString().trim()) == selectedId }) {
        def selectedLabel = scriptContext.input(
            message: 'Выберите стабильную версию для rollback',
            ok: 'Use selected snapshot',
            parameters: [[
                $class: 'ChoiceParameterDefinition',
                name: 'STABLE_VERSION',
                choices: options.join('\n'),
                description: 'Список стабильных snapshot-версий из ci/stable/index.json'
            ]]
        )
        selectedId = optionToId[selectedLabel]
    }

    def selected = versions.find { ((it?.id ?: it?.tag ?: '').toString().trim()) == selectedId }
    if (selected == null) {
        scriptContext.error("❌ [STABLE] Snapshot ${selectedId} не найден в ${indexPath}.")
    }

    def manifestPath = (selected?.manifest_path ?: "ci/stable/${selectedId}.json").toString()
    if (!scriptContext.fileExists(manifestPath)) {
        scriptContext.error("❌ [STABLE] Не найден manifest ${manifestPath} для snapshot ${selectedId}.")
    }
    def manifest = new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(manifestPath))
    def commitSha = (manifest?.commit_sha ?: '').toString().trim()
    if (!commitSha) {
        scriptContext.error("❌ [STABLE] В manifest отсутствует commit_sha: ${manifestPath}")
    }

    scriptContext.env.STABLE_SELECTED_ID = selectedId
    scriptContext.env.STABLE_MANIFEST_PATH = manifestPath
    scriptContext.env.ROLLBACK_COMMIT_SHA = commitSha

    def paramMap = (manifest?.pipeline_params instanceof Map) ? manifest.pipeline_params : [:]
    paramMap.each { k, v ->
        scriptContext.env."OVERRIDE_${k}" = (v == null ? '' : v.toString())
    }
    def targets = (manifest?.targets instanceof Map) ? manifest.targets : [:]
    targets.each { k, v ->
        scriptContext.env."OVERRIDE_${k}" = (v == null ? '' : v.toString())
    }

    scriptContext.currentBuild.displayName = "#${scriptContext.env.BUILD_NUMBER} rollback:${selectedId}"
    scriptContext.echo "[STABLE] Rollback selected: ${selectedId}"
    scriptContext.echo "[STABLE] Manifest: ${manifestPath}"
    scriptContext.echo "[STABLE] Commit: ${commitSha}"
}

def checkoutRollbackCommitIfNeeded(scriptContext) {
    def rollbackSha = scriptContext.env.ROLLBACK_COMMIT_SHA?.trim()
    if (!rollbackSha) {
        return
    }
    scriptContext.echo "[STABLE] Checkout rollback commit: ${rollbackSha}"
    scriptContext.sh """#!/bin/bash
set -euo pipefail
git fetch --all --tags --prune
git checkout -f "${rollbackSha}"
"""
}

def createStableSnapshotIfRequested(scriptContext) {
    if (!normalizeBool(scriptContext.params?.MARK_BUILD_AS_STABLE, false)) {
        scriptContext.echo "[STABLE] MARK_BUILD_AS_STABLE=false; snapshot creation skipped."
        return
    }
    if (rollbackEnabled(scriptContext)) {
        scriptContext.echo "[STABLE] Rollback run detected; stable snapshot auto-create skipped."
        return
    }

    def ts = scriptContext.sh(script: "date '+%Y-%m-%dT%H:%M:%S%z'", returnStdout: true).trim()
    def shortTs = scriptContext.sh(script: "date '+%Y%m%d-%H%M%S'", returnStdout: true).trim()
    def commitSha = scriptContext.sh(script: "git rev-parse HEAD", returnStdout: true).trim()
    def commitShort = scriptContext.sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
    def branchName = scriptContext.sh(script: "git rev-parse --abbrev-ref HEAD", returnStdout: true).trim()
    def stableId = "stable-${shortTs}-${commitShort}"
    def stableDir = 'ci/stable'
    def manifestPath = "${stableDir}/${stableId}.json"
    def indexPath = "${stableDir}/index.json"

    scriptContext.sh "mkdir -p '${stableDir}'"

    def capturedParams = [:]
    scriptContext.params.each { k, v ->
        capturedParams[k.toString()] = (v == null ? '' : v.toString())
    }
    def pipelineParams = [:]
    capturedParams.each { k, v ->
        if (!['ROLLBACK_TO_STABLE', 'STABLE_VERSION', 'MARK_BUILD_AS_STABLE'].contains(k)) {
            pipelineParams[k] = v
        }
    }

    def manifest = [
        id            : stableId,
        tag           : stableId,
        commit_sha    : commitSha,
        git_branch    : branchName,
        run_profile   : runtimeParam(scriptContext, 'RUN_PROFILE', ''),
        pipeline_params: pipelineParams,
        targets       : [
            SERVER_ADDRESS : runtimeParam(scriptContext, 'SERVER_ADDRESS', ''),
            NETAPP_API_ADDR: runtimeParam(scriptContext, 'NETAPP_API_ADDR', '')
        ],
        created_at    : ts,
        created_by    : (scriptContext.env.BUILD_USER_ID ?: scriptContext.env.BUILD_USER ?: 'jenkins'),
        build_url     : (scriptContext.env.BUILD_URL ?: ''),
        result        : 'SUCCESS'
    ]
    scriptContext.writeFile(file: manifestPath, text: groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(manifest)))

    def indexObj = [versions: []]
    if (scriptContext.fileExists(indexPath)) {
        def parsed = new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(indexPath))
        if (parsed instanceof Map && parsed.versions instanceof List) {
            indexObj = parsed
        } else if (parsed instanceof List) {
            indexObj = [versions: parsed]
        }
    }

    def entry = [
        id          : stableId,
        label       : "${stableId} | commit=${commitShort} | profile=${manifest.run_profile ?: 'n/a'} | ${ts}",
        commit_sha  : commitSha,
        run_profile : manifest.run_profile ?: '',
        created_at  : ts,
        result      : 'SUCCESS',
        manifest_path: manifestPath
    ]
    indexObj.versions = ([entry] + (indexObj.versions ?: [])).unique { it.id }.take(50)
    scriptContext.writeFile(file: indexPath, text: groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(indexObj)))

    scriptContext.sh """#!/bin/bash
set -euo pipefail
git add "${manifestPath}" "${indexPath}"
git -c user.name="jenkins" -c user.email="jenkins@local" commit -m "ci: add stable snapshot ${stableId}"
git tag -f "${stableId}" "${commitSha}"
git push origin HEAD
git push origin "refs/tags/${stableId}" --force
"""
    scriptContext.echo "[STABLE] Snapshot created: ${stableId}"
}

def computeEnvironmentVariables(scriptContext) {
    def namespaceCi = runtimeParam(scriptContext, 'NAMESPACE_CI', '')
    if (!env.KAE && namespaceCi) {
        def parts = namespaceCi.split('_')
        env.KAE = parts.size() > 1 ? parts[1] : 'UNKNOWN'
        env.DEPLOY_USER = "${env.KAE}-lnx-mon_ci"
        env.MON_SYS_USER = "${env.KAE}-lnx-mon_sys"
        def mountName = runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', 'monitoring').replaceAll('^/+', '')
        def stackDirName = runtimeParam(scriptContext, 'MONITORING_STACK_DIR_NAME', 'mon-harvest-prometheus-grafana')
        env.DEPLOY_PATH = "/${mountName}/${stackDirName}/monitoring-deployment"
    }
    def netappAddr = runtimeParam(scriptContext, 'NETAPP_API_ADDR', '')
    def netappHost = netappAddr.tokenize('.') ? netappAddr.tokenize('.')[0] : ''
    def netappPoller = netappHost ? (netappHost.substring(0, 1).toUpperCase() + netappHost.substring(1).toLowerCase()) : 'Unknown'
    def netappPollerSafe = netappPoller.replaceAll(/[^A-Za-z0-9_-]/, '_')

    def serverAddr = runtimeParam(scriptContext, 'SERVER_ADDRESS', '')
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

def restoreDeployStatus(scriptContext) {
    scriptContext.sh 'mkdir -p .deploy-status'
    def candidates = []
    if (scriptContext.env.DEPLOY_STATUS_STASH_LAST?.trim()) {
        candidates << scriptContext.env.DEPLOY_STATUS_STASH_LAST.trim()
    }
    candidates << 'deploy-status-all'

    boolean restored = false
    candidates.unique().each { stashName ->
        if (restored) {
            return
        }
        try {
            scriptContext.unstash(stashName)
            restored = true
            scriptContext.echo "[INFO] deploy-status восстановлен из stash: ${stashName}"
        } catch (ignored) {
            // Пробуем следующий stash-кандидат
        }
    }

    if (!restored) {
        scriptContext.echo "[INFO] deploy-status stash не найден, продолжаем с пустым локальным статусом"
    }
}

def persistDeployStatus(scriptContext) {
    scriptContext.sh 'mkdir -p .deploy-status'
    int seq
    try {
        seq = (scriptContext.env.DEPLOY_STATUS_STASH_SEQ ?: '0').toInteger()
    } catch (ignored) {
        seq = 0
    }
    seq += 1
    scriptContext.env.DEPLOY_STATUS_STASH_SEQ = seq.toString()
    def stashName = "deploy-status-all-${scriptContext.env.BUILD_NUMBER ?: '0'}-${seq}"
    scriptContext.stash name: stashName, includes: '.deploy-status/*.json', allowEmpty: true
    scriptContext.env.DEPLOY_STATUS_STASH_LAST = stashName
}

@NonCPS
def buildVerifyFallbackReport(Map pair, String deployUser, String prometheusPort, String grafanaPort) {
    return [
        server: pair.server,
        server_domain: pair.server,
        server_ip: pair.server,
        runtime_user: deployUser,
        versions: [grafana: 'N/A', prometheus: 'N/A', harvest: 'N/A', node_exporter: 'N/A'],
        services: [
            prometheus: [url: "https://${pair.server}:${prometheusPort}", code: '000', status: 'fail'],
            grafana: [url: "https://${pair.server}:${grafanaPort}", code: '000', status: 'fail'],
            harvest_netapp: [url: "https://${pair.server}:12996/metrics", code: '000', status: 'fail'],
            harvest_unix: [url: "http://localhost:12995/metrics", code: '000', status: 'fail'],
            node_exporter: [url: "http://${pair.server}:9100/metrics", code: '000', status: 'fail']
        ]
    ]
}

def printFinalDeploymentReport(scriptContext, List reports) {
    scriptContext.echo "================================================================"
    scriptContext.echo "           ✅ РАЗВЕРТЫВАНИЕ УСПЕШНО ЗАВЕРШЕНО!"
    scriptContext.echo "================================================================"
    scriptContext.echo ""
    scriptContext.echo "📦 Версия развертывания:"
    scriptContext.echo "  • Version:              ${scriptContext.env.VERSION_SHORT}"
    scriptContext.echo "  • Git Commit:           ${scriptContext.env.VERSION_GIT_COMMIT}"
    scriptContext.echo "  • Build Date:           ${scriptContext.env.VERSION_BUILD_TIMESTAMP}"
    scriptContext.echo ""
    scriptContext.echo "📊 Сводка по серверам:"
    reports.each { r ->
        def srv = r.server_domain ?: r.server
        def ip = r.server_ip ?: 'N/A'
        def runtimeUser = r.runtime_user ?: scriptContext.env.DEPLOY_USER
        def v = r.versions ?: [:]
        def s = r.services ?: [:]
        scriptContext.echo "------------------------------------------------"
        scriptContext.echo "• Сервер: ${srv} (${ip})"
        scriptContext.echo "  • Runtime user:         ${runtimeUser}"
        scriptContext.echo "  • Grafana version:      ${v.grafana ?: 'N/A'}"
        scriptContext.echo "  • Prometheus version:   ${v.prometheus ?: 'N/A'}"
        scriptContext.echo "  • Harvest version:      ${v.harvest ?: 'N/A'}"
        scriptContext.echo "  • Node Exporter ver.:   ${v.node_exporter ?: 'N/A'}"
        scriptContext.echo "  • Prometheus:           ${s.prometheus?.url ?: 'N/A'} (status: ${s.prometheus?.code ?: '000'} - ${s.prometheus?.status ?: 'fail'})"
        scriptContext.echo "  • Grafana:              ${s.grafana?.url ?: 'N/A'} (status: ${s.grafana?.code ?: '000'} - ${s.grafana?.status ?: 'fail'})"
        scriptContext.echo "  • Harvest (NetApp):     ${s.harvest_netapp?.url ?: 'N/A'} (status: ${s.harvest_netapp?.code ?: '000'} - ${s.harvest_netapp?.status ?: 'fail'})"
        scriptContext.echo "  • Harvest (Unix):       ${s.harvest_unix?.url ?: 'N/A'} (status: ${s.harvest_unix?.code ?: '000'} - ${s.harvest_unix?.status ?: 'fail'})"
        scriptContext.echo "  • Node Exporter:        ${s.node_exporter?.url ?: 'N/A'} (status: ${s.node_exporter?.code ?: '000'} - ${s.node_exporter?.status ?: 'fail'})"
    }
    scriptContext.echo "------------------------------------------------"
    def mountName = runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', 'monitoring').replaceAll('^/+', '')
    def stackDirName = runtimeParam(scriptContext, 'MONITORING_STACK_DIR_NAME', 'mon-harvest-prometheus-grafana')
    def runtimeBase = "/${mountName}/${stackDirName}"
    scriptContext.echo "📄 Конфигурационные файлы:"
    scriptContext.echo "  • Prometheus:           ${runtimeBase}/config/prometheus/prometheus.yml"
    scriptContext.echo "  • Prometheus TLS:       ${runtimeBase}/config/prometheus/web-config.yml"
    scriptContext.echo "  • Grafana:              ${runtimeBase}/config/grafana/grafana.ini"
    scriptContext.echo "  • Harvest Unix:         ${runtimeBase}/config/harvest/harvest-unix.yml"
    scriptContext.echo "  • Harvest NetApp:       ${runtimeBase}/config/harvest/harvest-netapp.yml"
    scriptContext.echo "  • Harvest cert/key:     ${runtimeBase}/config/harvest/cert/harvest.{crt,key}"
    scriptContext.echo "  • State file:           ${runtimeBase}/state/deployment_state"
    scriptContext.echo "================================================================"
}

def loadRlmTokenFromVaultJson(scriptContext) {
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    def primaryCred = deploymentPairs[0].credJsonFile
    if (!scriptContext.fileExists(primaryCred)) {
        scriptContext.error("❌ Не найден файл с секретами: ${primaryCred}")
    }

    def json = new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(primaryCred))
    def token = (json?.rlm_api?.token ?: '').toString().trim()
    if (!token) {
        scriptContext.error("❌ В Vault KV не найден RLM токен (ключ: rlm-token)")
    }
    return token
}

def withVaultSshCredentials(scriptContext, Closure body) {
    def sshCredentialsId = runtimeParam(scriptContext, 'SSH_CREDENTIALS_ID', '').trim()
    if (!sshCredentialsId) {
        scriptContext.error("❌ Не указан SSH_CREDENTIALS_ID (Jenkins credentials для SSH)")
    }

    def sshLogin = runtimeParam(scriptContext, 'SSH_LOGIN', '').trim()
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
TARGET_SERVER='${pair.server}' \
DEPLOY_PATH='${scriptContext.env.DEPLOY_PATH}' \
CRED_JSON_FILE='${pair.credJsonFile}' \
TARGET_NETAPP='${pair.netapp}' \
RLM_TOKEN="\$RLM_TOKEN" \
PHASE_NAME='${phaseFilterSafe}' \
LOG_LEVEL='${runtimeParam(scriptContext, 'LOG_LEVEL', 'normal')}' \
MONITORING_MOUNT_NAME='${runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', 'monitoring')}' \
MONITORING_STACK_DIR_NAME='${runtimeParam(scriptContext, 'MONITORING_STACK_DIR_NAME', 'mon-harvest-prometheus-grafana')}' \
SEC_MAN_ADDR='${runtimeParam(scriptContext, 'SEC_MAN_ADDR', '')}' \
NAMESPACE_CI='${runtimeParam(scriptContext, 'NAMESPACE_CI', '')}' \
RLM_API_URL='${runtimeParam(scriptContext, 'RLM_API_URL', '')}' \
GRAFANA_PORT='${runtimeParam(scriptContext, 'GRAFANA_PORT', '3000')}' \
PROMETHEUS_PORT='${runtimeParam(scriptContext, 'PROMETHEUS_PORT', '9090')}' \
RPM_URL_KV='${runtimeParam(scriptContext, 'RPM_URL_KV', '')}' \
NETAPP_SSH_KV='${runtimeParam(scriptContext, 'NETAPP_SSH_KV', '')}' \
GRAFANA_WEB_KV='${runtimeParam(scriptContext, 'GRAFANA_WEB_KV', '')}' \
SBERCA_CERT_KV='${runtimeParam(scriptContext, 'SBERCA_CERT_KV', '')}' \
ADMIN_EMAIL='${runtimeParam(scriptContext, 'ADMIN_EMAIL', '')}' \
VICTORIA_METRICS_REMOTE_WRITE_URL='${runtimeParam(scriptContext, 'VICTORIA_METRICS_REMOTE_WRITE_URL', '')}' \
USE_SIMPLIFIED_CERT_FLOW='${normalizeBool(runtimeParam(scriptContext, 'USE_SIMPLIFIED_CERT_FLOW', scriptContext.params.USE_SIMPLIFIED_CERT_FLOW ? 'true' : 'false')) ? 'true' : 'false'}' \
PROMETHEUS_LOCAL_INSTALL_FROM_ARCHIVE='${normalizeBool(runtimeParam(scriptContext, 'PROMETHEUS_LOCAL_INSTALL_FROM_ARCHIVE', scriptContext.params.PROMETHEUS_LOCAL_INSTALL_FROM_ARCHIVE ? 'true' : 'false')) ? 'true' : 'false'}' \
DOWNLOAD_CHECK_ENABLED='${normalizeBool(runtimeParam(scriptContext, 'DOWNLOAD_CHECK_ENABLED', scriptContext.params.DOWNLOAD_CHECK_ENABLED ? 'true' : 'false')) ? 'true' : 'false'}' \
SKIP_RLM_ADD_USER_GROUP_TASK='${normalizeBool(runtimeParam(scriptContext, 'SKIP_RLM_ADD_USER_GROUP_TASK', scriptContext.params.SKIP_RLM_ADD_USER_GROUP_TASK ? 'true' : 'false')) ? 'true' : 'false'}' \
RUN_SERVICES_AS_MON_CI='${normalizeBool(runtimeParam(scriptContext, 'RUN_SERVICES_AS_MON_CI', scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false')) ? 'true' : 'false'}' \
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
TARGET_SERVER='${pair.server}' \
DEPLOY_PATH='${scriptContext.env.DEPLOY_PATH}' \
CRED_JSON_FILE='${pair.credJsonFile}' \
TARGET_NETAPP='${pair.netapp}' \
RLM_TOKEN="\$RLM_TOKEN" \
LOG_LEVEL='${runtimeParam(scriptContext, 'LOG_LEVEL', 'normal')}' \
MONITORING_MOUNT_NAME='${runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', 'monitoring')}' \
MONITORING_STACK_DIR_NAME='${runtimeParam(scriptContext, 'MONITORING_STACK_DIR_NAME', 'mon-harvest-prometheus-grafana')}' \
SEC_MAN_ADDR='${runtimeParam(scriptContext, 'SEC_MAN_ADDR', '')}' \
NAMESPACE_CI='${runtimeParam(scriptContext, 'NAMESPACE_CI', '')}' \
RLM_API_URL='${runtimeParam(scriptContext, 'RLM_API_URL', '')}' \
GRAFANA_PORT='${runtimeParam(scriptContext, 'GRAFANA_PORT', '3000')}' \
PROMETHEUS_PORT='${runtimeParam(scriptContext, 'PROMETHEUS_PORT', '9090')}' \
RPM_URL_KV='${runtimeParam(scriptContext, 'RPM_URL_KV', '')}' \
NETAPP_SSH_KV='${runtimeParam(scriptContext, 'NETAPP_SSH_KV', '')}' \
GRAFANA_WEB_KV='${runtimeParam(scriptContext, 'GRAFANA_WEB_KV', '')}' \
SBERCA_CERT_KV='${runtimeParam(scriptContext, 'SBERCA_CERT_KV', '')}' \
ADMIN_EMAIL='${runtimeParam(scriptContext, 'ADMIN_EMAIL', '')}' \
VICTORIA_METRICS_REMOTE_WRITE_URL='${runtimeParam(scriptContext, 'VICTORIA_METRICS_REMOTE_WRITE_URL', '')}' \
RENEW_CERTIFICATES_ONLY='${normalizeBool(runtimeParam(scriptContext, 'RENEW_CERTIFICATES_ONLY', scriptContext.params.RENEW_CERTIFICATES_ONLY ? 'true' : 'false')) ? 'true' : 'false'}' \
USE_SIMPLIFIED_CERT_FLOW='${normalizeBool(runtimeParam(scriptContext, 'USE_SIMPLIFIED_CERT_FLOW', scriptContext.params.USE_SIMPLIFIED_CERT_FLOW ? 'true' : 'false')) ? 'true' : 'false'}' \
PROMETHEUS_LOCAL_INSTALL_FROM_ARCHIVE='${normalizeBool(runtimeParam(scriptContext, 'PROMETHEUS_LOCAL_INSTALL_FROM_ARCHIVE', scriptContext.params.PROMETHEUS_LOCAL_INSTALL_FROM_ARCHIVE ? 'true' : 'false')) ? 'true' : 'false'}' \
DOWNLOAD_CHECK_ENABLED='${normalizeBool(runtimeParam(scriptContext, 'DOWNLOAD_CHECK_ENABLED', scriptContext.params.DOWNLOAD_CHECK_ENABLED ? 'true' : 'false')) ? 'true' : 'false'}' \
SKIP_RLM_ADD_USER_GROUP_TASK='${normalizeBool(runtimeParam(scriptContext, 'SKIP_RLM_ADD_USER_GROUP_TASK', scriptContext.params.SKIP_RLM_ADD_USER_GROUP_TASK ? 'true' : 'false')) ? 'true' : 'false'}' \
EFFECTIVE_SKIP_RPM='${effectiveSkipRpm}' \
SKIP_IPTABLES='${normalizeBool(runtimeParam(scriptContext, 'SKIP_IPTABLES', scriptContext.params.SKIP_IPTABLES ? 'true' : 'false')) ? 'true' : 'false'}' \
RUN_SERVICES_AS_MON_CI='${normalizeBool(runtimeParam(scriptContext, 'RUN_SERVICES_AS_MON_CI', scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false')) ? 'true' : 'false'}' \
DEPLOY_VERSION='${scriptContext.env.VERSION_SHORT ?: 'unknown'}' \
DEPLOY_GIT_COMMIT='${scriptContext.env.VERSION_GIT_COMMIT ?: 'unknown'}' \
DEPLOY_BUILD_DATE='${scriptContext.env.VERSION_BUILD_TIMESTAMP ?: 'unknown'}' \
./tools/remote_full_deploy.sh
""")
}

def runRemoteVerification(scriptContext, Map pair) {
    return scriptContext.withEnv([
        "TARGET_SERVER=${pair.server}",
        "RUN_SERVICES_AS_MON_CI=${normalizeBool(runtimeParam(scriptContext, 'RUN_SERVICES_AS_MON_CI', scriptContext.params.RUN_SERVICES_AS_MON_CI ? 'true' : 'false')) ? 'true' : 'false'}",
        "DEPLOY_USER=${scriptContext.env.DEPLOY_USER}",
        "MON_SYS_USER=${scriptContext.env.MON_SYS_USER}",
        "PROMETHEUS_PORT=${runtimeParam(scriptContext, 'PROMETHEUS_PORT', '9090')}",
        "GRAFANA_PORT=${runtimeParam(scriptContext, 'GRAFANA_PORT', '3300')}"
    ]) {
        scriptContext.sh(script: '''#!/bin/bash
set -e
chmod +x tools/remote_verify.sh
./tools/remote_verify.sh
''', returnStdout: true).trim()
    }
}

def runRemoteCopy(scriptContext, Map pair) {
    return scriptContext.sh(returnStatus: true, script: """#!/bin/bash
set -e
chmod +x tools/remote_copy.sh
TARGET_SERVER='${pair.server}' \
DEPLOY_PATH='${scriptContext.env.DEPLOY_PATH}' \
CRED_JSON_FILE='${pair.credJsonFile}' \
./tools/remote_copy.sh
""")
}

def runRlmMonitoringFsTask(scriptContext, Map pair) {
    def output = scriptContext.sh(returnStdout: true, script: """#!/bin/bash
set -e
chmod +x tools/rlm_monitoring_fs.sh
set +e
OUTPUT=\$(
RLM_API_URL='${runtimeParam(scriptContext, 'RLM_API_URL', '')}' \
RLM_TOKEN="\$RLM_TOKEN" \
NAMESPACE_CI='${runtimeParam(scriptContext, 'NAMESPACE_CI', '')}' \
SERVER_FQDN='${pair.server}' \
SERVER_IP='${pair.server}' \
TARGET_NETAPP='${pair.netapp}' \
MOUNT_NAME='${runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', 'monitoring')}' \
VG_NAME='rootvg' \
LV_NAME='${runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', 'monitoring')}' \
TABLE_ID='${runtimeParam(scriptContext, 'RLM_FS_TABLE_ID', 'uvslinuxtemplatewithtestandpromandvirt')}' \
SIZE_GB='${runtimeParam(scriptContext, 'MONITORING_FS_EXTEND_GB', '0')}' \
FORCE_FS_APPLY='${normalizeBool(runtimeParam(scriptContext, 'FORCE_RLM_FS_APPLY', scriptContext.params.FORCE_RLM_FS_APPLY ? 'true' : 'false'), false) ? 'true' : 'false'}' \
RLM_MAX_ATTEMPTS='120' \
RLM_SLEEP_SEC='10' \
SSH_USER="\$SSH_USER" \
CRED_JSON_FILE='${pair.credJsonFile}' \
./tools/rlm_monitoring_fs.sh 2>&1
)
RC=\$?
echo "\$OUTPUT"
REASON=\$(printf "%s\\n" "\$OUTPUT" | sed -n 's/.*\\[RLM-FS-RESULT\\] reason=//p' | tail -1)
echo "__RLM_FS_META__ rc=\${RC} reason=\${REASON:-unknown}"
exit 0
""").trim()
    scriptContext.echo output
    def meta = output.readLines().find { it.startsWith('__RLM_FS_META__') } ?: '__RLM_FS_META__ rc=1 reason=unknown'
    def rcMatcher = (meta =~ /rc=(\d+)/)
    def reasonMatcher = (meta =~ /reason=([A-Za-z0-9._-]+)/)
    int rc = rcMatcher.find() ? rcMatcher.group(1).toInteger() : 1
    String reason = reasonMatcher.find() ? reasonMatcher.group(1) : 'unknown'
    return [rc: rc, reason: reason]
}

def getRemoteDomain(scriptContext, String serverAddress) {
    return scriptContext.sh(
        script: """#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  "\$SSH_USER"@"${serverAddress}" \
  "nslookup ${serverAddress} 2>/dev/null | grep 'name =' | awk '{print \\\$4}' | sed 's/\\.\$//' || echo ''" 2>/dev/null
""",
        returnStdout: true
    ).trim()
}

def getRemoteIp(scriptContext, String serverAddress) {
    return scriptContext.sh(
        script: """#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  "\$SSH_USER"@"${serverAddress}" \
  "hostname -I | awk '{print \\\$1}' || echo ${serverAddress}" 2>/dev/null
""",
        returnStdout: true
    ).trim()
}

def fetchVaultCredentialsForAllPairs(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    def allServerNamesForSberca = deploymentPairs.collect { it.server }.findAll { it?.trim() }.collect { it.trim() }.unique().join(',')
    def primaryServerNameForSberca = deploymentPairs[0].server
    def vaultCredId = runtimeParam(scriptContext, 'VAULT_CREDENTIAL_ID', 'vault-agent-dev')

    scriptContext.echo "[STEP] Получение секретов из Vault..."
    scriptContext.echo "[INFO] Используется Vault Credential ID: ${vaultCredId}"

    def vaultSecrets = []
    if (runtimeParam(scriptContext, 'RPM_URL_KV', '').trim()) {
        vaultSecrets << [path: runtimeParam(scriptContext, 'RPM_URL_KV', ''), secretValues: [
            [envVar: 'VA_RPM_HARVEST', vaultKey: 'harvest'],
            [envVar: 'VA_RPM_PROMETHEUS', vaultKey: 'prometheus'],
            [envVar: 'VA_RPM_GRAFANA', vaultKey: 'grafana'],
            [envVar: 'VA_RPM_NODE_EXPORTER', vaultKey: 'node_exporter']
        ]]
    }
    if (runtimeParam(scriptContext, 'NETAPP_SSH_KV', '').trim()) {
        vaultSecrets << [path: runtimeParam(scriptContext, 'NETAPP_SSH_KV', ''), secretValues: [
            [envVar: 'VA_NETAPP_SSH_ADDR', vaultKey: 'addr'],
            [envVar: 'VA_NETAPP_SSH_USER', vaultKey: 'user'],
            [envVar: 'VA_NETAPP_SSH_PASS', vaultKey: 'pass']
        ]]
    }
    if (runtimeParam(scriptContext, 'NODE_EXPORTER_TUZ_KV', '').trim()) {
        vaultSecrets << [path: runtimeParam(scriptContext, 'NODE_EXPORTER_TUZ_KV', ''), secretValues: [
            [envVar: 'VA_NODE_EXPORTER_TUZ_USER', vaultKey: 'user'],
            [envVar: 'VA_NODE_EXPORTER_TUZ_PASS', vaultKey: 'pass']
        ]]
    }
    if (runtimeParam(scriptContext, 'GRAFANA_WEB_KV', '').trim()) {
        vaultSecrets << [path: runtimeParam(scriptContext, 'GRAFANA_WEB_KV', ''), secretValues: [
            [envVar: 'VA_GRAFANA_WEB_USER', vaultKey: 'user'],
            [envVar: 'VA_GRAFANA_WEB_PASS', vaultKey: 'pass']
        ]]
    }
    if (runtimeParam(scriptContext, 'RLM_TOKEN_KV', '').trim()) {
        vaultSecrets << [path: runtimeParam(scriptContext, 'RLM_TOKEN_KV', ''), secretValues: [
            [envVar: 'VA_RLM_TOKEN', vaultKey: 'rlm-token']
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
            "rlm_api": [token: ''],
            "certificates": [server_bundle_pem: '', ca_chain_crt: '', grafana_client_pem: '']
        ]
        scriptContext.writeFile file: scriptContext.env.CRED_JSON_FILE, text: groovy.json.JsonOutput.toJson(emptyData)
    } else {
        try {
            scriptContext.withVault([
                configuration: [
                    vaultUrl: "https://${runtimeParam(scriptContext, 'SEC_MAN_ADDR', '')}",
                    engineVersion: 1,
                    skipSslVerification: false,
                    vaultCredentialId: vaultCredId,
                    vaultNamespace: runtimeParam(scriptContext, 'NAMESPACE_CI', '').trim()
                ],
                vaultSecrets: vaultSecrets
            ]) {
                def serverBundlePem = ''
                def caChainCrt = ''
                def grafanaClientPem = ''

                if (runtimeParam(scriptContext, 'SBERCA_CERT_KV', '').trim()) {
                    def requestedPath = runtimeParam(scriptContext, 'SBERCA_CERT_KV', '').trim()
                    def vaultNamespace = runtimeParam(scriptContext, 'NAMESPACE_CI', '').trim()
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
                        email: (runtimeParam(scriptContext, 'ADMIN_EMAIL', '').trim() ?: 'noreply@sberbank.ru'),
                        format: 'pem',
                        alt_names: (allServerNamesForSberca ?: '').trim()
                    ])
                    scriptContext.withCredentials([[
                        $class: 'VaultTokenCredentialBinding',
                        credentialsId: vaultCredId,
                        vaultNamespace: vaultNamespace,
                        vaultAddr: "https://${runtimeParam(scriptContext, 'SEC_MAN_ADDR', '')}"
                    ]]) {
                        def certPayloadEscaped = certRequestPayload.replace("'", "'\"'\"'")
                        def certResponseRaw = scriptContext.withEnv([
                            'SBERCA_URL=https://' + runtimeParam(scriptContext, 'SEC_MAN_ADDR', ''),
                            'SBERCA_API_PATH=' + apiPath,
                            'SBERCA_REQUEST_PAYLOAD=' + certPayloadEscaped
                        ]) {
                            scriptContext.sh(
                            script: '''#!/bin/bash
set -euo pipefail
chmod +x tools/fetch_sberca.sh
./tools/fetch_sberca.sh
''',
                            returnStdout: true
                        ).trim()
                        }
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
                    "rlm_api": [token: (scriptContext.env.VA_RLM_TOKEN ?: '')],
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

def runSyncRpmStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    restoreDeployStatus(scriptContext)

    scriptContext.echo "[STEP] Синхронная lockstep установка RPM по всем серверам"
    scriptContext.echo "[INFO] Принцип: Grafana -> Prometheus -> Harvest -> Node Exporter"
    def rpmPhases = ['Grafana', 'Prometheus', 'Harvest', 'Node Exporter']

    scriptContext.unstash 'vault-credentials'
    def rlmToken = loadRlmTokenFromVaultJson(scriptContext)
    scriptContext.withEnv(['RLM_TOKEN=' + rlmToken]) {
        withVaultSshCredentials(scriptContext) {
            rpmPhases.each { phaseName ->
                def phaseSlug = phaseName.toLowerCase().replaceAll(/[^a-z0-9]+/, '_')
                scriptContext.echo "================================================"
                scriptContext.echo "[SYNC-RPM] ФАЗА START: ${phaseName}"
                scriptContext.echo "================================================"

                def parallelPhase = [:]
                deploymentPairs.each { pair ->
                    def p = pair
                    parallelPhase["rpm-${phaseSlug}-${p.server}"] = {
                        int rc = runRemoteRpmPhaseInstall(scriptContext, p, phaseName)
                        def statusObj = [
                            server: p.server,
                            netapp: p.netapp,
                            stage: "rpm-${phaseSlug}",
                            status: (rc == 0 ? 'SUCCESS' : 'FAILED'),
                            reason: (rc == 0 ? 'ok' : "exit_code_${rc}")
                        ]
                        scriptContext.writeFile file: ".deploy-status/rpm_${phaseSlug}_${p.serverPrefixSafe}.json", text: groovy.json.JsonOutput.toJson(statusObj)
                    }
                }
                scriptContext.parallel parallelPhase

                def phaseRows = []
                deploymentPairs.each { p ->
                    def f = ".deploy-status/rpm_${phaseSlug}_${p.serverPrefixSafe}.json"
                    if (scriptContext.fileExists(f)) {
                        phaseRows << new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(f))
                    } else {
                        phaseRows << [server: p.server, netapp: p.netapp, stage: "rpm-${phaseSlug}", status: 'FAILED', reason: 'no_status_file']
                    }
                }
                def phaseSummary = renderDeploySummary("СВОДКА ${phaseName.toUpperCase()} (LOCKSTEP)", phaseRows)
                scriptContext.echo phaseSummary
                scriptContext.env.DEPLOY_STATUS_SUMMARY = (scriptContext.env.DEPLOY_STATUS_SUMMARY ? (scriptContext.env.DEPLOY_STATUS_SUMMARY + "\n" + phaseSummary) : phaseSummary)
                persistDeployStatus(scriptContext)
                if (phaseRows.any { it.status != 'SUCCESS' }) {
                    scriptContext.error("❌ Фаза ${phaseName} завершилась с ошибками. Переход к следующей фазе остановлен.")
                }

                scriptContext.echo "[SYNC-RPM] Все серверы завершили фазу ${phaseName}. Переходим к следующей через 5с..."
                scriptContext.sh 'sleep 5'
            }
        }
    }
}

def runDeployStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    restoreDeployStatus(scriptContext)
    def syncRpmPhases = normalizeBool(runtimeParam(scriptContext, 'SYNC_RPM_PHASES', scriptContext.params.SYNC_RPM_PHASES ? 'true' : 'false'), false)
    def effectiveSkipRpm = syncRpmPhases ? 'true' : (normalizeBool(runtimeParam(scriptContext, 'SKIP_RPM_INSTALL', scriptContext.params.SKIP_RPM_INSTALL ? 'true' : 'false'), false) ? 'true' : 'false')

    scriptContext.echo "[STEP] Запуск развертывания на удаленных серверах..."
    if (syncRpmPhases) {
        scriptContext.echo "[INFO] Режим: SKIP_RPM_INSTALL=true (RPM уже установлены в lockstep-фазах)"
    } else {
        scriptContext.echo "[INFO] Режим: стандартный (учитываем параметр SKIP_RPM_INSTALL=${effectiveSkipRpm})"
    }

    scriptContext.unstash 'vault-credentials'
    def rlmToken = loadRlmTokenFromVaultJson(scriptContext)
    scriptContext.withEnv(['RLM_TOKEN=' + rlmToken]) {
        withVaultSshCredentials(scriptContext) {
            def parallelDeploy = [:]
            deploymentPairs.each { pair ->
                def p = pair
                parallelDeploy["deploy-${p.server}"] = {
                    int rc = runRemoteFullDeploy(scriptContext, p, effectiveSkipRpm)
                    def statusObj = [
                        server: p.server,
                        netapp: p.netapp,
                        stage: 'deploy',
                        status: (rc == 0 ? 'SUCCESS' : 'FAILED'),
                        reason: (rc == 0 ? 'ok' : "exit_code_${rc}")
                    ]
                    scriptContext.writeFile file: ".deploy-status/deploy_${p.serverPrefixSafe}.json", text: groovy.json.JsonOutput.toJson(statusObj)
                }
            }
            scriptContext.parallel parallelDeploy
        }
    }

    def deployRows = []
    deploymentPairs.each { p ->
        def f = ".deploy-status/deploy_${p.serverPrefixSafe}.json"
        if (scriptContext.fileExists(f)) {
            deployRows << new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(f))
        } else {
            deployRows << [server: p.server, netapp: p.netapp, stage: 'deploy', status: 'FAILED', reason: 'no_status_file']
        }
    }
    def deploySummary = renderDeploySummary("СВОДКА DEPLOY", deployRows)
    scriptContext.echo deploySummary
    scriptContext.env.DEPLOY_STATUS_SUMMARY = (scriptContext.env.DEPLOY_STATUS_SUMMARY ? (scriptContext.env.DEPLOY_STATUS_SUMMARY + "\n" + deploySummary) : deploySummary)
    persistDeployStatus(scriptContext)
    if (deployRows.any { it.status != 'SUCCESS' }) {
        scriptContext.error("❌ Ошибка развертывания на одном или нескольких серверах")
    }
}

def runVerifyStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    restoreDeployStatus(scriptContext)

    scriptContext.echo "[STEP] Проверка результатов развертывания (User Units)..."
    withVaultSshCredentials(scriptContext) {
        def parallelChecks = [:]
        deploymentPairs.each { pair ->
            def p = pair
            parallelChecks["check-${p.server}"] = {
                def result = runRemoteVerification(scriptContext, p)
                scriptContext.echo result
                def marker = result.readLines().find { it.startsWith('__VERIFY_JSON__') }
                if (marker) {
                    scriptContext.writeFile file: ".deploy-status/verify_${p.serverPrefixSafe}.json", text: marker.substring('__VERIFY_JSON__'.length())
                } else {
                    def fallback = buildVerifyFallbackReport(
                        p,
                        scriptContext.env.DEPLOY_USER ?: '',
                        runtimeParam(scriptContext, 'PROMETHEUS_PORT', '9090'),
                        runtimeParam(scriptContext, 'GRAFANA_PORT', '3300')
                    )
                    scriptContext.writeFile file: ".deploy-status/verify_${p.serverPrefixSafe}.json", text: groovy.json.JsonOutput.toJson(fallback)
                }
            }
        }
        scriptContext.parallel parallelChecks
    }

    def verifyRows = []
    deploymentPairs.each { p ->
        def f = ".deploy-status/verify_${p.serverPrefixSafe}.json"
        if (scriptContext.fileExists(f)) {
            def row = new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(f))
            def svc = row.services ?: [:]
            def ok = [svc.prometheus, svc.grafana, svc.harvest_netapp, svc.node_exporter].every { it?.status == 'ok' }
            verifyRows << [
                server: p.server,
                netapp: p.netapp,
                stage: 'verify',
                status: (ok ? 'SUCCESS' : 'FAILED'),
                reason: (ok ? 'ok' : 'service_check_failed')
            ]
        } else {
            verifyRows << [server: p.server, netapp: p.netapp, stage: 'verify', status: 'FAILED', reason: 'no_status_file']
        }
    }
    def verifySummary = renderDeploySummary("СВОДКА VERIFY", verifyRows)
    scriptContext.echo verifySummary
    scriptContext.env.DEPLOY_STATUS_SUMMARY = (scriptContext.env.DEPLOY_STATUS_SUMMARY ? (scriptContext.env.DEPLOY_STATUS_SUMMARY + "\n" + verifySummary) : verifySummary)
    persistDeployStatus(scriptContext)
}

def runCiVersionStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    scriptContext.echo "================================================"
    scriptContext.echo "=== ВЕРСИЯ ПРОЕКТА - SECURE EDITION ==="
    scriptContext.echo "================================================"
    scriptContext.sh 'chmod +x tools/get-version.sh || true'
    def versionBanner = scriptContext.sh(script: './tools/get-version.sh banner', returnStdout: true).trim()
    scriptContext.echo versionBanner
    def versionEnv = scriptContext.sh(script: './tools/get-version.sh env', returnStdout: true).trim()
    versionEnv.split('\n').each { line ->
        def parts = line.split('=', 2)
        if (parts.size() == 2) {
            scriptContext.env."${parts[0]}" = parts[1]
        }
    }
    scriptContext.env.VERSION_SHORT = scriptContext.sh(script: './tools/get-version.sh short', returnStdout: true).trim()
    scriptContext.echo "[INFO] Версия проекта: ${scriptContext.env.VERSION_SHORT}"
    scriptContext.echo "[INFO] Git commit: ${scriptContext.env.VERSION_GIT_COMMIT}"
    scriptContext.echo "[INFO] Git branch: ${scriptContext.env.VERSION_GIT_BRANCH}"
    scriptContext.echo "[INFO] Build timestamp: ${scriptContext.env.VERSION_BUILD_TIMESTAMP}"
    scriptContext.echo "================================================"
    scriptContext.echo "[INFO] Архитектура: Secure Edition (v4.0+)"
    scriptContext.echo "[INFO] KAE: ${scriptContext.env.KAE}"
    scriptContext.echo "[INFO] CI-пользователь: ${scriptContext.env.DEPLOY_USER}"
    scriptContext.echo "[INFO] Sys-пользователь: ${scriptContext.env.MON_SYS_USER}"
    scriptContext.echo "[INFO] Путь развертывания: ${scriptContext.env.DEPLOY_PATH}"
    scriptContext.echo "================================================"
}

def runCiWorkspaceCleanupStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    scriptContext.env.DATE_INSTALL = scriptContext.sh(script: "date '+%Y%m%d_%H%M%S'", returnStdout: true).trim()
    scriptContext.echo "================================================"
    scriptContext.echo "=== НАЧАЛО ПАЙПЛАЙНА (SECURE MODE) ==="
    scriptContext.echo "================================================"
    scriptContext.echo "[INFO] Версия: ${scriptContext.env.VERSION_SHORT ?: 'unknown'}"
    scriptContext.echo "[INFO] Билд: ${scriptContext.env.BUILD_NUMBER ?: 'N/A'}"
    scriptContext.echo "[INFO] DATE_INSTALL: ${scriptContext.env.DATE_INSTALL}"
    scriptContext.echo "[INFO] KAE: ${scriptContext.env.KAE}"
    scriptContext.echo "[INFO] CI-пользователь: ${scriptContext.env.DEPLOY_USER}"
    scriptContext.echo "[INFO] Очистка workspace..."
    scriptContext.sh '''
        rm -f prep_clone*.sh scp_script*.sh verify_script*.sh deploy_script*.sh check_results*.sh cleanup_script*.sh get_domain*.sh get_ip*.sh 2>/dev/null || true
        rm -f temp_data_cred*.json 2>/dev/null || true
    '''
    scriptContext.echo "[SUCCESS] Workspace очищен"
}

def runCiParamsDebugStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    scriptContext.echo "================================================"
    scriptContext.echo "=== ПРОВЕРКА ПАРАМЕТРОВ (SECURE EDITION) ==="
    scriptContext.echo "================================================"
    if (!runtimeParam(scriptContext, 'SERVER_ADDRESS', '').trim()) { scriptContext.error("❌ Не указан SERVER_ADDRESS") }
    if (!runtimeParam(scriptContext, 'SSH_CREDENTIALS_ID', '').trim()) { scriptContext.error("❌ Не указан SSH_CREDENTIALS_ID") }
    if (!runtimeParam(scriptContext, 'SSH_LOGIN', '').trim()) { scriptContext.error("❌ Не указан SSH_LOGIN") }
    if (!runtimeParam(scriptContext, 'RLM_TOKEN_KV', '').trim()) { scriptContext.error("❌ Не указан RLM_TOKEN_KV (путь KV с RLM токеном)") }
    if (!runtimeParam(scriptContext, 'NAMESPACE_CI', '').trim()) { scriptContext.error("❌ Не указан NAMESPACE_CI (требуется для определения KAE)") }
    def mountName = runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', '')
    if (!mountName.trim() || !(mountName ==~ /[A-Za-z0-9._-]+/)) {
        scriptContext.error("❌ MONITORING_MOUNT_NAME должен быть непустым и содержать только [A-Za-z0-9._-] (без /)")
    }
    def fsExtendGb = runtimeParam(scriptContext, 'MONITORING_FS_EXTEND_GB', '')
    if (!fsExtendGb.trim()) { scriptContext.error("❌ MONITORING_FS_EXTEND_GB не задан") }
    if (!(fsExtendGb ==~ /[0-9]+/) || fsExtendGb.toInteger() <= 0) {
        scriptContext.error("❌ MONITORING_FS_EXTEND_GB должен быть положительным целым числом")
    }
    scriptContext.echo "[INFO] FS mount: /${mountName}, size=${fsExtendGb}GB, force=${runtimeParam(scriptContext, 'FORCE_RLM_FS_APPLY', '')}, table_id=${runtimeParam(scriptContext, 'RLM_FS_TABLE_ID', '')}"
    scriptContext.echo "[OK] Параметры проверены"
    scriptContext.echo "[INFO] Сервер: ${scriptContext.env.SERVER_ADDRESS_EFFECTIVE}"
    scriptContext.echo "[INFO] KAE: ${scriptContext.env.KAE}"
    scriptContext.echo "[INFO] Подключение: ${scriptContext.env.DEPLOY_USER}@${scriptContext.env.SERVER_ADDRESS_EFFECTIVE}"
    scriptContext.echo "[SECURITY] Архитектура: User Units Only, Min Privileges"
}

def runCiCodeInfoStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    scriptContext.echo "[INFO] === ИНФОРМАЦИЯ О КОДЕ ==="
    scriptContext.echo "[INFO] Версия проекта: ${scriptContext.env.VERSION_SHORT}"
    scriptContext.echo "[INFO] Git commit: ${scriptContext.env.VERSION_GIT_COMMIT_FULL}"
    scriptContext.echo "[INFO] Git branch: ${scriptContext.env.VERSION_GIT_BRANCH}"
    scriptContext.sh '''
        echo "[INFO] Последние 3 коммита:"
        git log --oneline -3 2>/dev/null || echo "[INFO] Git история недоступна"
    '''
}

def runCiNetworkDiagnosticsStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    scriptContext.echo "================================================"
    scriptContext.echo "=== ДИАГНОСТИКА СЕТИ ==="
    scriptContext.echo "================================================"
    scriptContext.echo "[INFO] Проверка подключения к ${scriptContext.env.SERVER_ADDRESS_EFFECTIVE}..."
    scriptContext.sh """
        ping -c 3 ${scriptContext.env.SERVER_ADDRESS_EFFECTIVE} || echo "[WARNING] Ping не прошел, но SSH может работать"
    """
}

def runFsMountStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    restoreDeployStatus(scriptContext)
    scriptContext.unstash 'vault-credentials'
    def rlmToken = loadRlmTokenFromVaultJson(scriptContext)
    scriptContext.echo "[STEP] Обязательная подготовка mount ПЕРЕД копированием файлов"
    scriptContext.echo "[INFO] mount=/${runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', 'monitoring')}, size_gb=${runtimeParam(scriptContext, 'MONITORING_FS_EXTEND_GB', '')}, table_id=${runtimeParam(scriptContext, 'RLM_FS_TABLE_ID', '')}, vg=rootvg, lv=${runtimeParam(scriptContext, 'MONITORING_MOUNT_NAME', 'monitoring')}, force=${runtimeParam(scriptContext, 'FORCE_RLM_FS_APPLY', 'false')}"
    scriptContext.withEnv(['RLM_TOKEN=' + rlmToken]) {
        withVaultSshCredentials(scriptContext) {
            def parallelFs = [:]
            deploymentPairs.each { pair ->
                def p = pair
                parallelFs["fs-${p.server}"] = {
                    def fsResult = runRlmMonitoringFsTask(scriptContext, p)
                    int rc = (fsResult.rc == null ? 1 : (fsResult.rc as int))
                    String reason = fsResult.reason ?: (rc == 0 ? 'ok' : "exit_code_${rc}")
                    def statusObj = [server: p.server, netapp: p.netapp, stage: 'fs-mount', status: (rc == 0 ? 'SUCCESS' : 'FAILED'), reason: reason]
                    scriptContext.writeFile file: ".deploy-status/fs_${p.serverPrefixSafe}.json", text: groovy.json.JsonOutput.toJson(statusObj)
                }
            }
            scriptContext.parallel parallelFs
        }
    }
    def fsRows = []
    deploymentPairs.each { p ->
        def f = ".deploy-status/fs_${p.serverPrefixSafe}.json"
        if (scriptContext.fileExists(f)) {
            fsRows << new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(f))
        } else {
            fsRows << [server: p.server, netapp: p.netapp, stage: 'fs-mount', status: 'FAILED', reason: 'no_status_file']
        }
    }
    def fsSummary = renderDeploySummary("СВОДКА RLM FS /monitoring", fsRows)
    scriptContext.echo fsSummary
    scriptContext.env.DEPLOY_STATUS_SUMMARY = (scriptContext.env.DEPLOY_STATUS_SUMMARY ? (scriptContext.env.DEPLOY_STATUS_SUMMARY + "\n" + fsSummary) : fsSummary)
    persistDeployStatus(scriptContext)
    if (fsRows.any { it.status != 'SUCCESS' }) {
        scriptContext.error("❌ Этап RLM FS mount завершился с ошибками")
    }
    scriptContext.echo "[SUCCESS] RLM FS mount успешно выполнен на всех серверах"
}

def runCopyStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    restoreDeployStatus(scriptContext)
    scriptContext.echo "[INFO] Используем уже загруженный workspace без дополнительного checkout"
    scriptContext.unstash 'vault-credentials'
    scriptContext.echo "[STEP] Копирование скрипта и файлов на сервер..."
    scriptContext.sh '''
        [ ! -f "install-monitoring-stack.sh" ] && echo "[ERROR] install-monitoring-stack.sh не найден!" && exit 1
        [ ! -d "wrappers" ] && echo "[ERROR] Папка wrappers не найдена!" && exit 1
        if [ -f wrappers/build-integrity-checkers.sh ]; then
          /bin/bash wrappers/build-integrity-checkers.sh
        fi
    '''
    withVaultSshCredentials(scriptContext) {
        def expectedSshUser = runtimeParam(scriptContext, 'SSH_LOGIN', '').trim() ? runtimeParam(scriptContext, 'SSH_LOGIN', '').trim() : scriptContext.env.DEPLOY_USER
        scriptContext.echo '[INFO] Подключение под пользователем настроено (ожидается: ' + expectedSshUser + ')'
        def parallelCopies = [:]
        deploymentPairs.each { pair ->
            def p = pair
            parallelCopies["copy-${p.server}"] = {
                int rc = runRemoteCopy(scriptContext, p)
                def statusObj = [server: p.server, netapp: p.netapp, stage: 'copy', status: (rc == 0 ? 'SUCCESS' : 'FAILED'), reason: (rc == 0 ? 'ok' : "exit_code_${rc}")]
                scriptContext.writeFile file: ".deploy-status/copy_${p.serverPrefixSafe}.json", text: groovy.json.JsonOutput.toJson(statusObj)
            }
        }
        scriptContext.parallel parallelCopies
    }
    def copyRows = []
    deploymentPairs.each { p ->
        def f = ".deploy-status/copy_${p.serverPrefixSafe}.json"
        if (scriptContext.fileExists(f)) {
            copyRows << new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(f))
        } else {
            copyRows << [server: p.server, netapp: p.netapp, stage: 'copy', status: 'FAILED', reason: 'no_status_file']
        }
    }
    def copySummary = renderDeploySummary("СВОДКА COPY", copyRows)
    scriptContext.echo copySummary
    scriptContext.env.DEPLOY_STATUS_SUMMARY = copySummary
    persistDeployStatus(scriptContext)
    if (copyRows.any { it.status != 'SUCCESS' }) {
        scriptContext.error("❌ Ошибка копирования на одном или нескольких серверах")
    }
    scriptContext.echo "[SUCCESS] Копирование завершено для всех серверов"
}

def runCleanupStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    restoreDeployStatus(scriptContext)
    scriptContext.echo "[STEP] Очистка временных файлов..."
    scriptContext.sh "rm -rf temp_data_cred.json temp_data_cred_*.json"
    withVaultSshCredentials(scriptContext) {
        def parallelCleanup = [:]
        deploymentPairs.each { pair ->
            def p = pair
            parallelCleanup["cleanup-${p.server}"] = {
                scriptContext.sh """#!/bin/bash
ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "\$SSH_USER"@"${p.server}" \
    "rm -rf ${scriptContext.env.DEPLOY_PATH}/${p.credJsonFile} ${scriptContext.env.DEPLOY_PATH}/temp_data_cred.json ${scriptContext.env.DEPLOY_PATH}/temp_data_cred_*.json" 2>/dev/null || true
"""
            }
        }
        scriptContext.parallel parallelCleanup
    }
    scriptContext.echo "[SUCCESS] Очистка завершена"
    persistDeployStatus(scriptContext)
}

def runFinalInfoStage(scriptContext) {
    computeEnvironmentVariables(scriptContext)
    checkoutRollbackCommitIfNeeded(scriptContext)
    restoreDeployStatus(scriptContext)
    def deploymentPairs = buildDeploymentPairs(runtimeParam(scriptContext, 'SERVER_ADDRESS', ''), runtimeParam(scriptContext, 'NETAPP_API_ADDR', ''))
    def reports = []
    deploymentPairs.each { p ->
        def f = ".deploy-status/verify_${p.serverPrefixSafe}.json"
        if (scriptContext.fileExists(f)) {
            reports << new groovy.json.JsonSlurperClassic().parseText(scriptContext.readFile(f))
        } else {
            reports << buildVerifyFallbackReport(
                p,
                scriptContext.env.DEPLOY_USER ?: '',
                runtimeParam(scriptContext, 'PROMETHEUS_PORT', '9090'),
                runtimeParam(scriptContext, 'GRAFANA_PORT', '3300')
            )
        }
    }
    printFinalDeploymentReport(scriptContext, reports)
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
        string(name: 'RLM_TOKEN_KV',       defaultValue: params.RLM_TOKEN_KV ?: '',       description: 'Путь KV в Vault для RLM API токена')
        string(name: 'SBERCA_CERT_KV',     defaultValue: params.SBERCA_CERT_KV ?: '',     description: 'Путь KV в Vault для SberCA Cert')
        string(name: 'ADMIN_EMAIL',        defaultValue: params.ADMIN_EMAIL ?: '',        description: 'Email администратора')
        string(name: 'GRAFANA_PORT',       defaultValue: params.GRAFANA_PORT ?: '3300',   description: 'Порт Grafana')
        string(name: 'PROMETHEUS_PORT',    defaultValue: params.PROMETHEUS_PORT ?: '9090',description: 'Порт Prometheus')
        string(name: 'RLM_API_URL',        defaultValue: params.RLM_API_URL ?: '',        description: 'Базовый URL RLM API')
        string(name: 'VAULT_CREDENTIAL_ID', defaultValue: params.VAULT_CREDENTIAL_ID ?: 'vault-agent-dev', description: 'Jenkins Credential ID для Vault')
        choice(name: 'LOG_LEVEL', choices: ['normal', 'debug'], description: 'Уровень логирования для консоли Jenkins (normal=минимум шума, debug=полный вывод)')
        booleanParam(name: 'ROLLBACK_TO_STABLE', defaultValue: false, description: '↩️ Запустить rollback из сохраненного stable snapshot')
        string(name: 'STABLE_VERSION', defaultValue: '', description: 'ID стабильной версии (опционально). Если пусто в rollback mode, выбор будет через input dropdown')
        booleanParam(name: 'MARK_BUILD_AS_STABLE', defaultValue: false, description: '⭐ Пометить успешный запуск как stable snapshot и сохранить в ci/stable')
        booleanParam(name: 'RENEW_CERTIFICATES_ONLY', defaultValue: false, description: '🔄 Только обновить сертификаты')
        booleanParam(name: 'USE_SIMPLIFIED_CERT_FLOW', defaultValue: true, description: '✅ Использовать non-root/simplified certificate flow (без /opt/vault/*). Отключите только для legacy rollback.')
        booleanParam(name: 'PROMETHEUS_LOCAL_INSTALL_FROM_ARCHIVE', defaultValue: true, description: '✅ Устанавливать Prometheus из архива по URL (без RLM-задачи). false = оставить текущую RLM-установку RPM.')
        booleanParam(name: 'DOWNLOAD_CHECK_ENABLED', defaultValue: false, description: '⬇️ Выполнять precheck тестовой загрузки пакетов перед установкой (Grafana/Prometheus/Harvest/Node Exporter)')
        booleanParam(name: 'SKIP_RLM_ADD_USER_GROUP_TASK', defaultValue: false, description: '👥 Пропустить создание и проверку RLM задачи UVS_LINUX_ADD_USERS_GROUP')
        booleanParam(name: 'SKIP_RPM_INSTALL', defaultValue: false, description: '⚠️ Пропустить установку RPM пакетов')
        booleanParam(name: 'SYNC_RPM_PHASES', defaultValue: true, description: '🔄 Синхронная lockstep-установка RPM по всем серверам (Grafana -> Prometheus -> Harvest -> Node Exporter)')
        booleanParam(name: 'SKIP_IPTABLES', defaultValue: true, description: '✅ Пропустить настройку iptables (для non-root/ограниченных sudo)')
        booleanParam(name: 'RUN_SERVICES_AS_MON_CI', defaultValue: true, description: '🧪 Временно запускать user-юниты от mon_ci (без mon_sys). Для возврата к mon_sys отключите.')
        booleanParam(name: 'SKIP_CI_CHECKS', defaultValue: false, description: '⚡ Пропустить CI диагностику')
        booleanParam(name: 'SKIP_DEPLOYMENT', defaultValue: false, description: '🚫 Пропустить CDL этап')
        booleanParam(name: 'USE_PROD_AGENT_PROFILE', defaultValue: true, description: 'Использовать PROD-профиль лейблов агентов (true=PROD, false=DEV)')
        string(name: 'DEV_CI_AGENT_LABEL', defaultValue: params.DEV_CI_AGENT_LABEL ?: 'clearAgent&&sbel8&&!static', description: 'Лейбл CI-агента для DEV')
        string(name: 'DEV_CDL_AGENT_LABEL', defaultValue: params.DEV_CDL_AGENT_LABEL ?: 'masterLin&&sbel8&&!static', description: 'Лейбл CDL-агента для DEV')
        string(name: 'PROD_CI_AGENT_LABEL', defaultValue: params.PROD_CI_AGENT_LABEL ?: 'slave_linux_vinata58||slave_linux_vinata59', description: 'Лейбл CI-агента для PROD')
        string(name: 'PROD_CDL_AGENT_LABEL', defaultValue: params.PROD_CDL_AGENT_LABEL ?: 'slave_linux_vinata58||slave_linux_vinata59', description: 'Лейбл CDL-агента для PROD')
        string(name: 'MONITORING_MOUNT_NAME', defaultValue: params.MONITORING_MOUNT_NAME ?: 'monitoring', description: 'Имя mount point без "/" (например monitoring => /monitoring)')
        string(name: 'MONITORING_STACK_DIR_NAME', defaultValue: params.MONITORING_STACK_DIR_NAME ?: 'mon-harvest-prometheus-grafana', description: 'Подкаталог в mount point для runtime мониторинга')
        string(name: 'MONITORING_FS_EXTEND_GB', defaultValue: params.MONITORING_FS_EXTEND_GB ?: '10', description: 'Размер (ГБ) для UVS_LINUX_EXTEND_FS2')
        booleanParam(name: 'FORCE_RLM_FS_APPLY', defaultValue: false, description: 'Принудительно запускать UVS_LINUX_EXTEND_FS2 даже если mount уже существует (для изменения размера)')
        string(name: 'RLM_FS_TABLE_ID', defaultValue: params.RLM_FS_TABLE_ID ?: 'uvslinuxtemplatewithtestandpromandvirt', description: 'table_id для UVS_LINUX_EXTEND_FS2')
    }

    stages {
        stage('CI: Выбор agent-профиля') {
            agent none
            steps {
                script {
                    def selectedCi = params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL
                    def selectedCdl = params.USE_PROD_AGENT_PROFILE ? params.PROD_CDL_AGENT_LABEL : params.DEV_CDL_AGENT_LABEL
                    echo "[INFO] Agent profile: ${params.USE_PROD_AGENT_PROFILE ? 'PROD' : 'DEV'}"
                    echo "[INFO] CI label: ${selectedCi}"
                    echo "[INFO] CDL label: ${selectedCdl}"
                }
            }
        }

        stage('CI: Выбор stable snapshot (rollback)') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL}" }
            steps {
                script {
                    chooseAndApplyStableSnapshot(this)
                }
            }
        }

        // ========================================================================
        // CI ЭТАП: Подготовка и проверка (clearAgent - чистый агент для сборки)
        // ========================================================================
        
        stage('CI: Информация о версии проекта') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL}" }
            steps {
                script {
                    runCiVersionStage(this)
                }
            }
        }
        
        stage('CI: Очистка workspace и отладка') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL}" }
            when {
                expression { params.SKIP_CI_CHECKS != true }
            }
            steps {
                script {
                    runCiWorkspaceCleanupStage(this)
                }
            }
        }
        
        stage('CI: Отладка параметров пайплайна') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL}" }
            when {
                expression { params.SKIP_CI_CHECKS != true }
            }
            steps {
                script {
                    runCiParamsDebugStage(this)
                }
            }
        }
        
        stage('CI: Информация о коде и окружении') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL}" }
            when {
                expression { params.SKIP_CI_CHECKS != true }
            }
            steps {
                script {
                    runCiCodeInfoStage(this)
                }
            }
        }
        
        stage('CI: Расширенная диагностика сети и сервера') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL}" }
            when {
                expression { params.SKIP_CI_CHECKS != true }
            }
            steps {
                script {
                    runCiNetworkDiagnosticsStage(this)
                }
            }
        }
        
        stage('CI: Получение секретов из Vault') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL}" }
            steps {
                script {
                    fetchVaultCredentialsForAllPairs(this)
                }
            }
        }

        // ========================================================================
        // CDL ЭТАП: Развертывание на целевом сервере (masterLin для доступа)
        // ========================================================================

        stage('CDL: Подготовка mount через RLM') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CDL_AGENT_LABEL : params.DEV_CDL_AGENT_LABEL}" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    runFsMountStage(this)
                }
            }
        }

        stage('CDL: Копирование файлов на сервер') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CDL_AGENT_LABEL : params.DEV_CDL_AGENT_LABEL}" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    runCopyStage(this)
                }
            }
        }

        stage('CDL: Синхронная фазовая установка RPM') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CDL_AGENT_LABEL : params.DEV_CDL_AGENT_LABEL}" }
            when {
                expression {
                    params.SKIP_DEPLOYMENT != true &&
                    normalizeBool(env.OVERRIDE_SYNC_RPM_PHASES ?: (params.SYNC_RPM_PHASES ? 'true' : 'false'), false)
                }
            }
            steps {
                script {
                    runSyncRpmStage(this)
                }
            }
        }

        stage('CDL: Выполнение развертывания') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CDL_AGENT_LABEL : params.DEV_CDL_AGENT_LABEL}" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    runDeployStage(this)
                }
            }
        }

        stage('CDL: Проверка результатов') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CDL_AGENT_LABEL : params.DEV_CDL_AGENT_LABEL}" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    runVerifyStage(this)
                }
            }
        }

        stage('CDL: Очистка') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CDL_AGENT_LABEL : params.DEV_CDL_AGENT_LABEL}" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    runCleanupStage(this)
                }
            }
        }

        stage('CDL: Получение сведений о развертывании системы') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CDL_AGENT_LABEL : params.DEV_CDL_AGENT_LABEL}" }
            when {
                expression { params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    runFinalInfoStage(this)
                }
            }
        }

        stage('CI: Сохранение stable snapshot') {
            agent { label "${params.USE_PROD_AGENT_PROFILE ? params.PROD_CI_AGENT_LABEL : params.DEV_CI_AGENT_LABEL}" }
            when {
                expression { params.MARK_BUILD_AS_STABLE == true && params.ROLLBACK_TO_STABLE != true && params.SKIP_DEPLOYMENT != true }
            }
            steps {
                script {
                    createStableSnapshotIfRequested(this)
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
                if (currentBuild.currentResult != 'SUCCESS' && env.DEPLOY_STATUS_SUMMARY?.trim()) {
                    echo env.DEPLOY_STATUS_SUMMARY
                } else if (currentBuild.currentResult != 'SUCCESS') {
                    echo "================================================"
                    echo "📋 СВОДКА ПО СЕРВЕРАМ: недоступна (ветки не стартовали)"
                    echo "================================================"
                }
            }
            echo "Время выполнения: ${currentBuild.durationString}"
        }
    }
}
