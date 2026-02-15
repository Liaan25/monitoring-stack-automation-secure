# Обновление сертификатов мониторинга (Certificate Renewal Mode)

**Дата создания:** 15.02.2026  
**Версия:** 4.1  
**Подход:** Simplified (без vault-agent)  

---

## 📋 Содержание

1. [Введение](#введение)
2. [Когда нужно обновлять сертификаты](#когда-нужно-обновлять-сертификаты)
3. [Режим Certificate Renewal Only](#режим-certificate-renewal-only)
4. [Запуск через Jenkins](#запуск-через-jenkins)
5. [Ручное обновление сертификатов](#ручное-обновление-сертификатов)
6. [Проверка работоспособности](#проверка-работоспособности)
7. [Troubleshooting](#troubleshooting)

---

## Введение

Начиная с версии **4.1**, проект использует **упрощенный подход** для управления сертификатами:

- ✅ **User-space только** — все файлы в `$HOME/monitoring/`
- ✅ **Без sudo** для файловых операций
- ✅ **Без vault-agent** — сертификаты получаются из Jenkins
- ✅ **Быстрое обновление** — режим `RENEW_CERTIFICATES_ONLY`

Сертификаты мониторинга (Prometheus, Grafana, Harvest) имеют **срок действия 3 года** (по умолчанию в Vault SecMan).

---

## Когда нужно обновлять сертификаты

### Плановое обновление:

- 🔄 **Каждые 3 года** — истечение срока действия сертификата
- 🔄 **При изменении FQDN** сервера
- 🔄 **При смене SAN** (альтернативных имен)

### Внеплановое обновление:

- ⚠️ **Компрометация** приватного ключа
- ⚠️ **Отзыв сертификата** (revocation)
- ⚠️ **Изменение политик** безопасности

---

## Режим Certificate Renewal Only

### Что это?

**Certificate Renewal Only** — специальный режим деплоймента, который:

1. ✅ **Получает новые сертификаты** из Jenkins или Vault
2. ✅ **Распределяет их** по конфигам сервисов (Prometheus, Grafana, Harvest)
3. ✅ **Перезапускает сервисы** для применения новых сертификатов
4. ❌ **НЕ переустанавливает** пакеты (Grafana, Prometheus, Harvest)
5. ❌ **НЕ изменяет** конфигурацию мониторинга

### Преимущества:

- ⚡ **Быстро** — выполняется за ~1-2 минуты
- 🔒 **Безопасно** — минимальное вмешательство в работающую систему
- 📝 **Просто** — один параметр в Jenkins

---

## Запуск через Jenkins

### Параметры Jenkins Pipeline

В вашем `Jenkinsfile` добавлен параметр:

```groovy
pipeline {
    parameters {
        booleanParam(
            name: 'RENEW_CERTIFICATES_ONLY',
            defaultValue: false,
            description: 'Только обновить сертификаты (без переустановки пакетов)'
        )
        // ... другие параметры
    }
}
```

### Шаг 1: Подготовка сертификатов

Сертификаты должны находиться в **Jenkins workspace** в каталоге `certs/`:

```
${JENKINS_WORKSPACE}/
├── certs/
│   ├── server_bundle.pem      # Основной сертификат + ключ + CA chain
│   ├── ca_chain.crt            # CA chain отдельно
│   └── grafana-client.pem      # Клиентский сертификат для Grafana
└── install-monitoring-stack.sh
```

#### Как получить сертификаты из Vault:

```bash
# На сервере Jenkins или локально:

# Экспортируйте переменные
export VAULT_ADDR="https://secman.sigma.sbrf.ru:8200"
export VAULT_NAMESPACE="CI84324523"  # Ваш KAE

# Авторизуйтесь в Vault
vault login -method=approle \
    role_id="<your_role_id>" \
    secret_id="<your_secret_id>"

# Получите сертификат
vault write pki/CI84324523/sberca/issue \
    common_name="tvlds-mvp001939.ca.sbrf.ru" \
    email="monitoring@sberbank.ru" \
    alt_names="tvlds-mvp001939.ca.sbrf.ru" \
    ttl="26280h" \
    -format=json > cert.json

# Извлеките компоненты
jq -r '.data.private_key' cert.json > server.key
jq -r '.data.certificate' cert.json > server.crt
jq -r '.data.issuing_ca' cert.json > ca_chain.crt

# Создайте bundle
cat server.key server.crt ca_chain.crt > server_bundle.pem

# Скопируйте в workspace Jenkins
cp server_bundle.pem ca_chain.crt ${JENKINS_WORKSPACE}/certs/
```

---

### Шаг 2: Запуск Jenkins Job

1. Откройте ваш **Jenkins Pipeline**
2. Нажмите **"Build with Parameters"**
3. Установите параметры:
   ```
   ✅ RENEW_CERTIFICATES_ONLY = true
   
   Остальные параметры (опционально):
   - SERVER_DOMAIN = tvlds-mvp001939.ca.sbrf.ru
   - SERVER_IP = <IP сервера>
   - KAE = CI84324523
   ```
4. Нажмите **"Build"**

---

### Шаг 3: Мониторинг выполнения

Jenkins выполнит следующие шаги:

```
[CERT-RENEW] ========================================
[CERT-RENEW] Certificate Renewal Mode
[CERT-RENEW] ========================================

1. [CERTS-JENKINS] Получение сертификатов из Jenkins...
   ✅ Скопирован server_bundle.pem
   ✅ Скопирован ca_chain.crt
   ✅ Скопирован grafana-client.pem

2. [CERTS-DIST] Распределение сертификатов по сервисам...
   ✅ Prometheus: server_bundle.pem
   ✅ Prometheus: ca_chain.crt
   ✅ Grafana: server_bundle.pem
   ✅ Grafana: grafana-client.pem
   ✅ Harvest: ca_chain.crt

3. [CERTS-RESTART] Перезапуск сервисов...
   ✅ monitoring-prometheus.service перезапущен
   ✅ monitoring-grafana.service перезапущен
   ✅ monitoring-harvest.service перезапущен

[CERT-RENEW] ✅ Обновление сертификатов завершено
```

**Ожидаемое время выполнения:** 1-2 минуты

---

## Ручное обновление сертификатов

Если Jenkins недоступен, можно обновить сертификаты вручную:

### Шаг 1: Подготовка сертификатов на сервере

```bash
# Логин под ci-пользователем
ssh CI84324523-lnx-mon_ci@tvlds-mvp001939

# Создайте каталог для новых сертификатов
mkdir -p ~/monitoring/certs/new

# Скопируйте новые сертификаты
# (из Jenkins, Vault или из другого источника)
cp server_bundle.pem ~/monitoring/certs/new/
cp ca_chain.crt ~/monitoring/certs/new/
cp grafana-client.pem ~/monitoring/certs/new/

# Установите правильные права
chmod 600 ~/monitoring/certs/new/*.pem ~/monitoring/certs/new/*.crt
```

---

### Шаг 2: Распределение по сервисам

```bash
# Prometheus
cp ~/monitoring/certs/new/server_bundle.pem ~/monitoring/config/prometheus/
cp ~/monitoring/certs/new/ca_chain.crt ~/monitoring/config/prometheus/
chmod 600 ~/monitoring/config/prometheus/server_bundle.pem
chmod 600 ~/monitoring/config/prometheus/ca_chain.crt

# Grafana
cp ~/monitoring/certs/new/server_bundle.pem ~/monitoring/config/grafana/
cp ~/monitoring/certs/new/grafana-client.pem ~/monitoring/config/grafana/
chmod 600 ~/monitoring/config/grafana/server_bundle.pem
chmod 600 ~/monitoring/config/grafana/grafana-client.pem

# Harvest
cp ~/monitoring/certs/new/ca_chain.crt ~/monitoring/config/harvest/
chmod 600 ~/monitoring/config/harvest/ca_chain.crt
```

---

### Шаг 3: Перезапуск сервисов

```bash
# Получите UID sys-пользователя
MON_SYS_UID=$(id -u CI84324523-lnx-mon_sys)
XDG_ENV="XDG_RUNTIME_DIR=/run/user/${MON_SYS_UID}"

# Перезапустите сервисы
sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    systemctl --user restart monitoring-prometheus.service

sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    systemctl --user restart monitoring-grafana.service

sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    systemctl --user restart monitoring-harvest.service
```

---

### Шаг 4: Проверка

```bash
# Проверьте статус сервисов
sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    systemctl --user status monitoring-prometheus.service

sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    systemctl --user status monitoring-grafana.service

sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    systemctl --user status monitoring-harvest.service
```

**Ожидаемый результат для каждого:**
```
● monitoring-<service>.service - <Description>
     Active: active (running) since <время>
```

---

## Проверка работоспособности

### 1. Проверка сертификатов

```bash
# Prometheus
openssl x509 -in ~/monitoring/config/prometheus/server_bundle.pem \
    -noout -text | grep -E "Not Before|Not After|Subject:"

# Grafana
openssl x509 -in ~/monitoring/config/grafana/server_bundle.pem \
    -noout -text | grep -E "Not Before|Not After|Subject:"

# Harvest
openssl x509 -in ~/monitoring/config/harvest/ca_chain.crt \
    -noout -text | grep -E "Not Before|Not After|Subject:"
```

**Ожидаемый результат:**
```
        Not Before: Feb 15 14:00:00 2026 GMT
        Not After : Feb 15 14:00:00 2029 GMT  # +3 года
        Subject: CN=tvlds-mvp001939.ca.sbrf.ru
```

---

### 2. Проверка HTTPS доступа

```bash
# Prometheus
curl -k https://tvlds-mvp001939.ca.sbrf.ru:9090/-/healthy

# Grafana
curl -k https://tvlds-mvp001939.ca.sbrf.ru:3000/api/health

# Harvest (UNIX socket, проверка через Prometheus)
curl -k https://tvlds-mvp001939.ca.sbrf.ru:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="harvest")'
```

---

### 3. Проверка логов

```bash
# Prometheus
sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    journalctl --user -u monitoring-prometheus.service -n 50

# Grafana
sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    journalctl --user -u monitoring-grafana.service -n 50

# Harvest
sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
    journalctl --user -u monitoring-harvest.service -n 50
```

**Не должно быть:**
- ❌ `certificate expired`
- ❌ `certificate not valid`
- ❌ `TLS handshake error`

---

## Troubleshooting

### Проблема: Сертификат не обновился

**Симптомы:**
```
curl: (60) SSL certificate problem: certificate has expired
```

**Решение:**

1. Проверьте что новый сертификат скопирован:
   ```bash
   ls -lah ~/monitoring/config/prometheus/server_bundle.pem
   # Дата модификации должна быть свежей
   ```

2. Проверьте содержимое сертификата:
   ```bash
   openssl x509 -in ~/monitoring/config/prometheus/server_bundle.pem \
       -noout -dates
   ```

3. Если сертификат старый — скопируйте заново из `~/monitoring/certs/new/`

---

### Проблема: Сервис не перезапустился

**Симптомы:**
```
Job for monitoring-prometheus.service failed.
```

**Решение:**

1. Проверьте логи:
   ```bash
   sudo -n -u CI84324523-lnx-mon_sys env "$XDG_ENV" \
       journalctl --user -u monitoring-prometheus.service -n 100
   ```

2. Проверьте синтаксис конфига:
   ```bash
   ~/monitoring/bin/prometheus/promtool check config \
       ~/monitoring/config/prometheus/prometheus.yml
   ```

3. Проверьте права на файлы:
   ```bash
   ls -lah ~/monitoring/config/prometheus/server_bundle.pem
   # Владелец должен быть mon_ci или mon_sys
   # Права: -rw------- (600)
   ```

---

### Проблема: Jenkins не находит сертификаты

**Симптомы:**
```
[CERTS-JENKINS] ⚠️ Каталог /path/to/certs не найден
```

**Решение:**

1. Убедитесь что в `Jenkinsfile` правильно указан путь:
   ```groovy
   environment {
       JENKINS_WORKSPACE = "${env.WORKSPACE}"
   }
   ```

2. Создайте каталог `certs/` в workspace:
   ```bash
   mkdir -p ${WORKSPACE}/certs
   ```

3. Скопируйте сертификаты:
   ```bash
   cp server_bundle.pem ${WORKSPACE}/certs/
   cp ca_chain.crt ${WORKSPACE}/certs/
   cp grafana-client.pem ${WORKSPACE}/certs/
   ```

---

### Проблема: Нет sudo-прав для перезапуска

**Симптомы:**
```
[sudo] password for CI84324523-lnx-mon_ci:
sudo: a password is required
```

**Решение:**

1. Проверьте что есть права в IDM:
   ```bash
   sudo -l | grep systemctl
   ```

   **Должно быть:**
   ```
   (CI84324523-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-prometheus.service
   ```

2. Если прав нет — создайте заявку в IDM:
   - Используйте шаблон из `sudoers.example` (строки 16-34)
   - Раскомментируйте User-level секцию
   - Отправьте на согласование

---

## Автоматизация обновления

### Cron-задача для напоминания

Создайте напоминание за **30 дней** до истечения сертификата:

```bash
# Добавьте в crontab (crontab -e)
0 9 * * * /home/CI84324523-lnx-mon_ci/scripts/check-cert-expiry.sh

# Скрипт check-cert-expiry.sh:
#!/bin/bash
CERT_FILE="$HOME/monitoring/config/prometheus/server_bundle.pem"
DAYS_UNTIL_EXPIRY=$(( ($(date -d "$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))

if [[ $DAYS_UNTIL_EXPIRY -lt 30 ]]; then
    echo "⚠️ Сертификат истекает через $DAYS_UNTIL_EXPIRY дней!"
    # Отправьте уведомление в Slack/Email/etc
fi
```

---

## Сравнение подходов обновления

| Метод | Время | Риск | Сложность | Рекомендуется |
|-------|-------|------|-----------|---------------|
| **Certificate Renewal Mode (Jenkins)** | ~1-2 мин | Низкий | Низкая | ✅ Да (основной метод) |
| **Ручное обновление** | ~5-10 мин | Средний | Средняя | ⚠️ Только при недоступности Jenkins |
| **Полный редеплой** | ~15-30 мин | Высокий | Высокая | ❌ Не рекомендуется для обновления сертификатов |
| **vault-agent (LEGACY)** | Автоматически | Низкий | Высокая | 🔄 Требует sudo и vault-agent |

---

## Контакты и поддержка

При возникновении вопросов:

1. **Проверьте документацию:**
   - `HOW-TO-REVERT.md` — для возврата к vault-agent
   - `SECURITY-COMPLIANCE.md` — требования безопасности

2. **Проверьте логи:**
   - Jenkins Console Output
   - `/tmp/monitoring-deployment.log`
   - `journalctl --user -u monitoring-*.service`

3. **Обратитесь к команде:**
   - Администратор Vault: для получения новых сертификатов
   - DevOps/CI: для настройки Jenkins Pipeline

---

**Последнее обновление:** 15.02.2026  
**Автор:** Monitoring Stack Automation Team  
**Версия документа:** 1.0
