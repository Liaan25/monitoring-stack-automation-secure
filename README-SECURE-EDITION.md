# Monitoring Stack - Secure Edition

**Версия:** 1.0.0 (Secure Edition)  
**Статус:** ✅ Соответствует требованиям ИБ Сбербанка  
**Дата:** 2026-02-15

---

## Что нового в Secure Edition?

### 🔒 Ключевые улучшения безопасности

- **User-Space Architecture**: Все конфиги, данные и логи в `$HOME/monitoring/` - НЕ требуется root
- **Разделение полномочий**: CI user (deployment) отделен от System user (runtime)
- **Безопасные секреты**: Wrapper'ы, /dev/shm (RAM), trap, НЕТ plain-text в env vars
- **Minimal Sudo**: Только необходимые команды с `NOEXEC` и без wildcards
- **Явные пути**: Все команды (`awk`, `sed`) с полными путями, НЕТ переменных в sudoers

### 📋 Соответствие требованиям ИБ

- ✅ NOEXEC в всех sudo правилах
- ✅ НЕТ переменных окружения в sudo
- ✅ Запрещенные команды заменены/обернуты
- ✅ systemctl status через группу systemd-journal
- ✅ iptables с явными правилами
- ✅ User units вместо system units
- ✅ Wrapper'ы с SHA256 checksums
- ✅ /dev/shm для временных секретов

Подробнее: [`docs/security-compliance.md`](docs/security-compliance.md)

---

## Быстрый старт

### 1. Предварительные требования

#### На Jenkins сервере:

- Jenkins с доступом к Vault (SecMan)
- Настроенный `withVault` plugin
- SSH доступ к целевому серверу

#### На целевом сервере:

**Пользователи** (создаются через IDM):
- `${KAE}-lnx-mon_ci` - ТУЗ для CI/CD
- `${KAE}-lnx-mon_sys` - СУЗ для запуска сервисов
- `${KAE}-lnx-va-start` - владелец /opt/vault/
- `${KAE}-lnx-va-read` - группа для чтения секретов

**Группы** (добавление через IDM):
- `mon_ci` → `as-admin`, `va-read`
- `mon_sys` → `grafana`, `systemd-journal`, `va-read`

**Установка через RLM:**
- Vault (через `https://rlm.sigma.sbrf.ru/dashboard/services/UVS_VAULT_INSTALL`)
- Prometheus, Grafana, Harvest (через `https://rlm.sigma.sbrf.ru/dashboard/services/UVS_LINUX_RPM`)

### 2. Установка sudo прав

**Создайте заявку в IDM:**

1. Откройте [`docs/sudo-rules-for-idm.txt`](docs/sudo-rules-for-idm.txt)
2. Замените `CI10742292` на ваш реальный KAE
3. Скопируйте правила в заявку IDM
4. Приложите wrapper'ы с SHA256 checksums:
   - `wrappers/vault-credentials-installer.sh`
   - `wrappers/vault-credentials-installer_launcher.sh`
5. Приложите документацию: `docs/security-compliance.md`

**Вычисление SHA256 checksum:**
```bash
cd wrappers/
sha256sum vault-credentials-installer.sh
# Результат: abc123...def  vault-credentials-installer.sh

# Замените в sudo-rules-for-idm.txt:
# sha256:REPLACE_WITH_ACTUAL_SHA256_CHECKSUM → sha256:abc123...def
```

### 3. Настройка Jenkins Pipeline

**Обновите параметры в Jenkinsfile:**

```groovy
parameters {
    string(name: 'SERVER_ADDRESS', defaultValue: 'your-server.domain')
    string(name: 'SEC_MAN_ADDR', defaultValue: 'vault.sberbank.ru')
    string(name: 'NAMESPACE_CI', defaultValue: 'CI10742292')
    
    // Vault KV пути
    string(name: 'VAULT_AGENT_KV', defaultValue: 'kv/CI10742292/vault-agent')
    string(name: 'RPM_URL_KV', defaultValue: 'kv/CI10742292/rpm-urls')
    string(name: 'NETAPP_SSH_KV', defaultValue: 'kv/CI10742292/netapp-ssh')
    string(name: 'GRAFANA_WEB_KV', defaultValue: 'kv/CI10742292/grafana-web')
    string(name: 'SBERCA_CERT_KV', defaultValue: 'pki/CI10742292/sberca/issue')
}
```

**Vault секреты должны содержать:**

`kv/CI10742292/vault-agent`:
```json
{
  "role_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "secret_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

`kv/CI10742292/rpm-urls`:
```json
{
  "prometheus": "https://nexus.../prometheus-2.x.rpm",
  "grafana": "https://nexus.../grafana-9.x.rpm",
  "harvest": "https://nexus.../harvest-24.x.rpm"
}
```

### 4. Запуск деплоя

**Через Jenkins:**

```groovy
pipeline {
    agent any
    
    stages {
        stage('Deploy Monitoring Stack') {
            steps {
                build job: 'monitoring-stack-deploy',
                parameters: [
                    string(name: 'SERVER_ADDRESS', value: 'my-server.domain'),
                    string(name: 'NAMESPACE_CI', value: 'CI10742292')
                ]
            }
        }
    }
}
```

**Вручную (для тестирования):**

```bash
# 1. На Jenkins: Получение секретов
vault read -format=json kv/CI10742292/vault-agent > temp_data_cred.json
vault read -format=json kv/CI10742292/rpm-urls >> temp_data_cred.json
vault read -format=json kv/CI10742292/netapp-ssh >> temp_data_cred.json
vault read -format=json kv/CI10742292/grafana-web >> temp_data_cred.json

# 2. Копирование на целевой сервер
scp -r . mon_ci@target-server:/home/mon_ci/monitoring-deployment/
scp temp_data_cred.json mon_ci@target-server:/home/mon_ci/

# 3. На целевом сервере: Запуск
ssh mon_ci@target-server
cd /home/mon_ci/monitoring-deployment/
bash install-monitoring-stack.sh
```

### 5. Проверка развертывания

**После успешного деплоя:**

```bash
# Проверка user units
sudo -u CI10742292-lnx-mon_sys systemctl --user status monitoring-prometheus.service
sudo -u CI10742292-lnx-mon_sys systemctl --user status monitoring-grafana.service
sudo -u CI10742292-lnx-mon_sys systemctl --user status monitoring-harvest.service

# Проверка портов
ss -tlnp | grep -E ':(9090|3000|12990)'

# Проверка веб-интерфейсов
curl -k https://localhost:9090/-/healthy  # Prometheus
curl -k https://localhost:3000/api/health # Grafana

# Проверка логов
tail -f $HOME/monitoring/logs/prometheus/prometheus.log
tail -f $HOME/monitoring/logs/grafana/grafana.log
```

---

## Архитектура

### Структура директорий

```
$HOME/monitoring/                    # User-space root
├── config/                          # Конфигурации (mon_ci пишет, mon_sys читает)
│   ├── grafana/
│   │   └── grafana.ini
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   ├── web-config.yml
│   │   └── consoles/
│   ├── harvest/
│   │   └── harvest.yml
│   └── vault/
│       ├── agent.hcl (копия)
│       ├── role_id.txt
│       └── secret_id.txt
├── data/                            # Данные сервисов (mon_sys пишет)
│   ├── grafana/
│   ├── prometheus/
│   └── harvest/
├── logs/                            # Логи (mon_sys пишет)
│   ├── grafana/
│   ├── prometheus/
│   └── harvest/
├── certs/                           # Сертификаты (скопированы из /opt/vault/certs/)
│   ├── grafana/
│   │   ├── crt.crt
│   │   └── key.key
│   ├── prometheus/
│   │   ├── server.crt
│   │   └── server.key
│   └── harvest/
│       ├── harvest.crt
│       └── harvest.key
└── state/
    └── deployment_state             # Состояние деплоя

~/.config/systemd/user/              # User systemd units (mon_sys)
├── monitoring-prometheus.service
├── monitoring-grafana.service
├── monitoring-harvest.service
└── monitoring.target
```

### Системные пути (только чтение для mon_sys)

```
/usr/bin/prometheus                  # RPM бинарник
/usr/sbin/grafana-server             # RPM бинарник
/opt/harvest/bin/harvest             # RPM бинарник

/opt/vault/conf/                     # Vault agent config (va-start владелец)
├── agent.hcl
├── role_id.txt                      # Права: 640 (va-start:va-read)
├── secret_id.txt                    # Права: 640 (va-start:va-read)
└── data_sec.json                    # Сгенерирован vault-agent

/opt/vault/certs/                    # Сертификаты SberCA (vault-agent генерирует)
├── server_bundle.pem                # Права: 640 (va-start:va-read)
├── ca_chain.crt
└── grafana-client.pem
```

---

## Troubleshooting

### Проблема: Секреты не извлекаются

**Симптом:**
```
[VAULT-CONFIG] ⚠️  Секреты НЕ извлечены через wrapper
```

**Решение:**

1. Проверьте наличие `temp_data_cred.json`:
   ```bash
   ls -la ~/temp_data_cred.json
   ```

2. Проверьте структуру JSON:
   ```bash
   jq '.' ~/temp_data_cred.json
   # Должны быть ключи: vault-agent, rpm_url, netapp_ssh, grafana_web
   ```

3. Проверьте права на wrapper:
   ```bash
   ls -la wrappers/secrets-manager-wrapper_launcher.sh
   chmod +x wrappers/secrets-manager-wrapper_launcher.sh
   ```

4. Проверьте whitelist в wrapper'е:
   ```bash
   grep -A 10 "allowed_dirs" wrappers/secrets-manager-wrapper.sh
   # Должны быть: /opt/vault/conf, /tmp, /dev/shm, $HOME
   ```

### Проблема: vault-agent не аутентифицируется

**Симптом:**
```
[VAULT-CONFIG] ⚠️  vault-agent НЕ сможет аутентифицироваться!
```

**Решение:**

1. Проверьте что credentials скопированы в /opt/vault/conf/:
   ```bash
   sudo ls -la /opt/vault/conf/role_id.txt
   sudo ls -la /opt/vault/conf/secret_id.txt
   # Владелец: va-start, Группа: va-read, Права: 640
   ```

2. Проверьте agent.hcl:
   ```bash
   sudo cat /opt/vault/conf/agent.hcl | grep role_id_file_path
   # НЕ должно быть %your_role_id_file_path%
   # Должно быть: /opt/vault/conf/role_id.txt
   ```

3. Перезапустите vault-agent:
   ```bash
   sudo systemctl restart vault-agent
   sudo systemctl status vault-agent
   ```

4. Проверьте логи vault-agent:
   ```bash
   sudo journalctl -u vault-agent -n 50
   ```

### Проблема: User units не запускаются

**Симптом:**
```
Failed to connect to bus: No such file or directory
```

**Решение:**

1. Включите linger для mon_sys:
   ```bash
   sudo linuxadm-enable-linger CI10742292-lnx-mon_sys
   loginctl show-user CI10742292-lnx-mon_sys | grep Linger
   # Ожидаем: Linger=yes
   ```

2. Проверьте что XDG_RUNTIME_DIR установлена:
   ```bash
   sudo -u CI10742292-lnx-mon_sys bash -c 'echo $XDG_RUNTIME_DIR'
   # Ожидаем: /run/user/<UID>
   ```

3. Проверьте права на unit files:
   ```bash
   ls -la ~/.config/systemd/user/monitoring-*.service
   ```

4. Перезагрузите daemon:
   ```bash
   sudo -u CI10742292-lnx-mon_sys systemctl --user daemon-reload
   ```

### Проблема: Нет доступа к /opt/vault/conf/

**Симптом:**
```
Permission denied: /opt/vault/conf/
```

**Решение:**

1. Проверьте группы пользователя:
   ```bash
   id CI10742292-lnx-mon_ci
   # Должна быть группа: va-read
   ```

2. Добавьте в группу через IDM:
   - Заявка: "Добавить пользователя в группу"
   - Группа: `CI10742292-lnx-va-read`
   - Пользователь: `CI10742292-lnx-mon_ci`

3. После добавления - перелогиньтесь:
   ```bash
   exit
   ssh mon_ci@server
   ```

---

## Миграция с Legacy на Secure Edition

### Что изменилось?

| Аспект | Legacy | Secure Edition |
|--------|--------|----------------|
| Конфиги | `/etc/grafana/`, `/etc/prometheus/` | `$HOME/monitoring/config/` |
| Данные | `/var/lib/grafana/`, `/var/lib/prometheus/` | `$HOME/monitoring/data/` |
| Логи | `/var/log/grafana/`, `/tmp/` | `$HOME/monitoring/logs/` |
| Systemd | System units | User units |
| Sudo | `ALL=(ALL:ALL)` | Minimal whitelist с NOEXEC |

### Шаги миграции:

1. **Backup Legacy данных:**
   ```bash
   sudo tar czf /tmp/legacy-monitoring-backup.tar.gz \
       /etc/grafana/ \
       /etc/prometheus/ \
       /var/lib/grafana/ \
       /var/lib/prometheus/
   ```

2. **Остановите Legacy сервисы:**
   ```bash
   sudo systemctl stop grafana-server prometheus harvest
   sudo systemctl disable grafana-server prometheus harvest
   ```

3. **Разверните Secure Edition** (см. Быстрый старт)

4. **Импортируйте данные Grafana:**
   ```bash
   # Копируем БД Grafana
   sudo cp /var/lib/grafana/grafana.db $HOME/monitoring/data/grafana/
   chown mon_sys:mon_sys $HOME/monitoring/data/grafana/grafana.db
   ```

5. **Импортируйте данные Prometheus:**
   ```bash
   # Копируем TSDB
   sudo cp -r /var/lib/prometheus/* $HOME/monitoring/data/prometheus/
   chown -R mon_sys:mon_sys $HOME/monitoring/data/prometheus/
   ```

6. **Проверка:**
   ```bash
   sudo -u CI10742292-lnx-mon_sys systemctl --user restart monitoring-grafana.service
   sudo -u CI10742292-lnx-mon_sys systemctl --user restart monitoring-prometheus.service
   ```

---

## FAQ

**Q: Почему нельзя использовать `/opt/` или `/etc/` для конфигов?**  
A: Требования ИБ: конфиги должны быть в user-space (`$HOME/monitoring/`), чтобы их изменение не требовало root. Бинарники RPM остаются в системных путях (readonly).

**Q: Как работают sudo права с NOEXEC?**  
A: `NOEXEC` предотвращает запуск подпроцессов из sudo команды, что блокирует эскалацию привилегий. Например, нельзя сделать `sudo vim` → `:!bash` → получить root shell.

**Q: Зачем нужны wrapper'ы с SHA256?**  
A: Wrapper'ы защищены checksums в sudoers. Если кто-то изменит wrapper (добавит вредоносный код), checksum не совпадет и sudo откажет в выполнении.

**Q: Можно ли использовать systemctl без sudo для user units?**  
A: Да! Для управления **своими** user units sudo НЕ нужен. Sudo нужен только для управления user units **другого** пользователя (mon_ci управляет units mon_sys).

**Q: Как vault-agent получает секреты если role_id/secret_id в plain-text файлах?**  
A: Файлы имеют права 640 (владелец: va-start, группа: va-read). Только пользователи в группе va-read могут прочитать. После аутентификации vault-agent создает data_sec.json с актуальными секретами.

**Q: Что делать если забыл пароль от Grafana?**  
A: Пароль хранится в Vault (kv/CI.../grafana-web). Извлечь можно через wrapper:
```bash
./wrappers/secrets-manager-wrapper_launcher.sh extract_secret \
    /opt/vault/conf/data_sec.json grafana_web.pass
```

---

## Документация

- [`docs/security-compliance.md`](docs/security-compliance.md) - Полное соответствие требованиям ИБ
- [`docs/sudo-rules-for-idm.txt`](docs/sudo-rules-for-idm.txt) - Правила для заявки IDM
- [План адаптации под ИБ](иб-compliant_monitoring_stack_885496be.plan.md) - Детальный план изменений

---

## Лицензия

Внутренний проект Сбербанка.

---

## Контакты

**Вопросы по проекту:**  
- GitHub Issues: [ссылка]  
- Email: [контакт]

**Вопросы по ИБ:**  
- УАиРКБ ЦКЗ Сбербанк  
- Документация: https://mapp.sberbank.ru/cybersecurity/
