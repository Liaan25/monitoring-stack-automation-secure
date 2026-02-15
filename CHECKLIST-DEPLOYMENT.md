# ✅ Чеклист для развертывания - Monitoring Stack (Secure Edition)

## 📋 Предварительные требования

### 1. IDM Заявка на sudo-права

- [ ] **Создана IDM заявка** для пользователя `${KAE}-lnx-mon_ci`
- [ ] **Добавлены System-level права** (копирование в `/opt/vault/conf/`, управление `vault-agent`)
- [ ] **Добавлены User-level права** (управление user-юнитами через `sudo -u mon_sys`)
- [ ] **Заявка Approved** в IDM
- [ ] **Заявка Deployed** (~10-30 минут после approval)
- [ ] **Права проверены** на сервере: `sudo -l` (должны быть видны новые правила)

**Где взять правила:** `sudoers.example` (замените `CI84324523` на ваш KAE)

---

### 2. Пользователи и группы

- [ ] **Создан пользователь** `${KAE}-lnx-mon_ci` (CI user для деплоя)
- [ ] **Создан пользователь** `${KAE}-lnx-mon_sys` (system user для runtime)
- [ ] **Создан пользователь** `${KAE}-lnx-va-start` (для vault-agent)
- [ ] **Создана группа** `${KAE}-lnx-va-read` (для чтения vault-agent данных)
- [ ] **`mon_ci` добавлен в группы:**
  - `${KAE}-lnx-va-read` (для чтения credentials)
  - `${KAE}-lnx-va-start` (для записи в `/opt/vault/conf/`)
  - `${KAE}-lnx-mon_sys` (для переключения через `sudo -u`)
  - `systemd-journal` (для чтения логов)
- [ ] **`mon_sys` добавлен в группы:**
  - `${KAE}-lnx-va-read` (для чтения credentials)
  - `systemd-journal` (для чтения логов)
  - `grafana` (если требуется)

---

### 3. Vault конфигурация

- [ ] **Vault-agent установлен** через RLM (в `/opt/vault/`)
- [ ] **Директория `/opt/vault/conf/` существует**
  - Владелец: `${KAE}-lnx-va-start:${KAE}-lnx-va-read`
  - Права: `750`
- [ ] **Директория `/opt/vault/log/` существует**
  - Владелец: `${KAE}-lnx-va-start:${KAE}-lnx-va-read`
  - Права: `750`
- [ ] **CA certificates установлены** в `/opt/vault/conf/ca-trust/`
- [ ] **Секреты подготовлены** в Vault (SecMan):
  - `kv/${KAE}/vault-agent` → `role_id`, `secret_id`
  - `kv/${KAE}/rpm-urls` → URLs для RPM пакетов
  - `kv/${KAE}/netapp-ssh` → SSH credentials для NetApp
  - `kv/${KAE}/grafana-web` → Web credentials для Grafana
  - `pki/${KAE}/sberca/issue` → PKI endpoint для генерации сертификатов

---

### 4. Jenkins Pipeline

- [ ] **Jenkinsfile настроен** с правильными параметрами:
  - `KAE` - ваш KAE (например, `CI10742292`)
  - `NAMESPACE_CI` - ваш namespace в Vault (например, `CI10742292`)
  - `SERVER_DOMAIN` - FQDN сервера
  - `ADMIN_EMAIL` - email для сертификатов
  - URLs для Prometheus, Grafana, Harvest, NetApp
- [ ] **Jenkins может подключиться** к целевому серверу по SSH
- [ ] **Jenkins имеет права** на запуск команд от `mon_ci` пользователя

---

## 🚀 Процесс развертывания

### Шаг 1: Проверка окружения

Выполните на **целевом сервере** от пользователя `mon_ci`:

```bash
# 1. Проверка пользователей
id ${KAE}-lnx-mon_ci
id ${KAE}-lnx-mon_sys
id ${KAE}-lnx-va-start

# 2. Проверка групп
groups ${KAE}-lnx-mon_ci
# Должны быть: mon_ci, va-read, va-start, mon_sys, systemd-journal

# 3. Проверка sudo-прав
sudo -l
# Должны быть видны правила из sudoers.example

# 4. Проверка vault-agent
sudo systemctl status vault-agent
# Должен быть установлен (даже если не запущен)

# 5. Проверка директорий
ls -lad /opt/vault/conf/ /opt/vault/log/
# Должны существовать с правильными правами
```

---

### Шаг 2: Запуск Jenkins Pipeline

1. **Откройте Jenkins** и найдите ваш pipeline
2. **Нажмите "Build with Parameters"**
3. **Проверьте параметры:**
   - KAE, NAMESPACE_CI, SERVER_DOMAIN корректны
   - URLs для всех компонентов корректны
4. **Запустите Build**

---

### Шаг 3: Мониторинг выполнения

Следите за логами Jenkins. Ключевые этапы:

```
[VAULT-CONFIG] Извлечение секретов в /tmp/ через jq
  ↓
[VAULT-CONFIG] ✅ Секреты успешно извлечены
  ↓
[VAULT-CONFIG] Копирование credentials в /opt/vault/conf/
  ↓
[VAULT-CONFIG] ✅ role_id.txt скопирован
[VAULT-CONFIG] ✅ secret_id.txt скопирован
  ↓
[VAULT-CONFIG] Создание /opt/vault/certs/
  ↓
[VAULT-CONFIG] ✅ /opt/vault/certs/ создана
  ↓
[VAULT-CONFIG] Попытка перезапуска vault-agent...
  ↓
[VAULT-CONFIG] ✅ vault-agent перезапущен успешно
  ↓
[VAULT-CONFIG] Ожидание стабилизации vault-agent (5 сек)...
  ↓
[VAULT-CONFIG] ✅ vault-agent активен (running)
  ↓
[VAULT-CONFIG] Ожидание генерации сертификатов (5 сек)...
  ↓
[VAULT-CONFIG] ✅ Сертификаты успешно сгенерированы
```

**Если видите ошибки** - см. раздел "Troubleshooting" ниже.

---

### Шаг 4: Проверка результата

Выполните на **целевом сервере**:

```bash
# 1. Проверка credentials
ls -lah /opt/vault/conf/role_id.txt /opt/vault/conf/secret_id.txt

# Ожидаемый вывод:
# -rw-r----- 1 ${KAE}-lnx-va-start ${KAE}-lnx-va-read 37 Feb 15 17:14 role_id.txt
# -rw-r----- 1 ${KAE}-lnx-va-start ${KAE}-lnx-va-read 37 Feb 15 17:14 secret_id.txt

# 2. Проверка vault-agent
sudo systemctl status vault-agent --no-pager

# Ожидаемый вывод:
# Active: active (running)

# 3. Проверка сертификатов
ls -lah /opt/vault/certs/

# Должны быть:
# - server_bundle.pem (5-10 KB)
# - ca_chain.crt (2-5 KB)
# - grafana-client.pem (5-10 KB)

# 4. Проверка содержимого сертификата
sudo openssl x509 -in /opt/vault/certs/server_bundle.pem -noout -text | head -20

# Должно показать: Subject, Issuer, Validity (Not Before, Not After)

# 5. Проверка user-юнитов
sudo -u ${KAE}-lnx-mon_sys bash -c '
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user is-active monitoring-prometheus.service
systemctl --user is-active monitoring-grafana.service
systemctl --user is-active monitoring-harvest.service
'

# Ожидаемый вывод:
# active
# active
# active

# 6. Проверка портов
ss -tulpn | grep -E ':(9090|3000|9091)'

# Должны быть открыты:
# 9090 - Prometheus
# 3000 - Grafana
# 9091 - Harvest (опционально)
```

---

## ⚠️ Troubleshooting

### Проблема 1: "sudo: a password is required"

**Симптомы:**
```
[VAULT-CONFIG] ❌ Не удалось скопировать role_id.txt (требуется sudo)
```

**Причина:** sudo-права еще не применились из IDM заявки

**Решение:**
1. Проверьте статус IDM заявки (должна быть Approved и Deployed)
2. Подождите 10-30 минут после deployment
3. **Перелогиньтесь** на сервере: `exit` → `ssh ...`
4. Проверьте: `sudo -l` (должны быть видны новые правила)
5. Если не помогло - обратитесь в IDM Support (@idminfra)

---

### Проблема 2: vault-agent не запускается или сразу падает

**Симптомы:**
```
[VAULT-CONFIG] ⚠️ vault-agent не активен после перезапуска
```

**Диагностика:**
```bash
# Проверьте логи vault-agent
sudo journalctl -u vault-agent -n 100 --no-pager | grep -i error

# ИЛИ
sudo tail -100 /opt/vault/log/agent.log | jq -r 'select(.level=="error")'
```

**Частые ошибки:**

#### Ошибка 1: "no such host" или "dial tcp: lookup secman.sigma.sbrf.ru"

**Причина:** DNS не может резолвить Vault адрес

**Решение:**
```bash
# Проверьте DNS
nslookup secman.sigma.sbrf.ru

# Если не работает - добавьте в /etc/hosts:
echo "10.X.X.X secman.sigma.sbrf.ru" | sudo tee -a /etc/hosts

# ИЛИ обратитесь к администратору сети
```

#### Ошибка 2: "permission denied" на role_id.txt/secret_id.txt

**Причина:** Неправильные права на файлы

**Решение:**
```bash
# Проверьте текущие права
ls -lah /opt/vault/conf/role_id.txt /opt/vault/conf/secret_id.txt

# Должно быть:
# -rw-r----- 1 ${KAE}-lnx-va-start ${KAE}-lnx-va-read

# Если неправильно - исправьте:
sudo chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/conf/role_id.txt
sudo chmod 640 /opt/vault/conf/role_id.txt
# (аналогично для secret_id.txt)
```

#### Ошибка 3: "invalid role_id" или "permission denied" (API error)

**Причина:** Неправильные credentials в `temp_data_cred.json` или истекли

**Решение:**
```bash
# Проверьте содержимое role_id
sudo cat /opt/vault/conf/role_id.txt

# Должен быть UUID формата: d315f65d-c49b-598a-0b16-ba858619fc70

# Если пустой или неправильный - перепроверьте temp_data_cred.json
cat ~/temp_data_cred.json | jq '.["vault-agent"]'

# Если секреты истекли - запросите новые в SecMan/Vault
```

---

### Проблема 3: Сертификаты не генерируются

**Симптомы:**
```
ls: cannot access '/opt/vault/certs/': No such file or directory
```

ИЛИ файлы есть, но пустые (0 байт).

**Диагностика:**
```bash
# 1. Проверьте vault-agent работает
sudo systemctl is-active vault-agent

# 2. Проверьте логи (ищем ошибки template rendering)
sudo journalctl -u vault-agent -n 200 --no-pager | grep -i template

# 3. Проверьте agent.hcl содержит template блоки
sudo cat /opt/vault/conf/agent.hcl | grep -A 5 "template {"
```

**Частые причины:**

#### Причина 1: vault-agent не аутентифицировался

**Решение:** См. "Проблема 2" выше - сначала исправьте аутентификацию

#### Причина 2: Неправильный PKI path в agent.hcl

**Проверка:**
```bash
sudo grep "pki/" /opt/vault/conf/agent.hcl

# Должно быть:
# pki/CI10742292/sberca/issue
```

**Решение:** Проверьте что `SBERCA_CERT_KV` в Jenkinsfile правильный

#### Причина 3: Нет прав на запись в `/opt/vault/certs/`

**Проверка:**
```bash
ls -lad /opt/vault/certs/
# Должно быть: drwxr-x--- ... ${KAE}-lnx-va-start ${KAE}-lnx-va-read

sudo -u ${KAE}-lnx-va-start touch /opt/vault/certs/test.txt
# Должно работать без ошибок
```

**Решение:**
```bash
sudo chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/certs
sudo chmod 750 /opt/vault/certs
sudo systemctl restart vault-agent
```

---

### Проблема 4: User-юниты не запускаются

**Симптомы:**
```
inactive
inactive
inactive
```

**Диагностика:**
```bash
sudo -u ${KAE}-lnx-mon_sys bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user status monitoring-prometheus.service
systemctl --user status monitoring-grafana.service
```

**Частые причины:**

#### Причина 1: Linger не включен

**Проверка:**
```bash
ls /var/lib/systemd/linger/
# Должен быть файл с именем ${KAE}-lnx-mon_sys
```

**Решение:**
```bash
sudo loginctl enable-linger ${KAE}-lnx-mon_sys
```

#### Причина 2: Неправильные пути в юнитах

**Проверка:**
```bash
sudo -u ${KAE}-lnx-mon_sys bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user cat monitoring-prometheus.service | grep ExecStart

# Должно быть:
# ExecStart=/usr/bin/prometheus --config.file=/home/${USER}/monitoring/config/prometheus/prometheus.yml ...
```

**Решение:** Проверьте что `setup_monitoring_user_units()` правильно генерирует юниты

---

## 📞 Поддержка

Если ничего не помогло:

1. **Соберите диагностику:**
   ```bash
   # Запустите диагностический скрипт (если есть)
   sudo -u ${KAE}-lnx-mon_ci bash /tmp/monitoring-fix-and-diagnose.sh
   
   # Соберите логи
   sudo journalctl -u vault-agent -n 500 --no-pager > /tmp/vault-agent.log
   sudo systemctl status vault-agent --no-pager > /tmp/vault-agent-status.txt
   ls -laR /opt/vault/ > /tmp/vault-structure.txt
   ```

2. **Отправьте файлы:**
   - `/tmp/vault-agent.log`
   - `/tmp/vault-agent-status.txt`
   - `/tmp/vault-structure.txt`
   - Jenkins Console Output

3. **Обратитесь:**
   - Monitoring Team
   - ИБ Team (для вопросов по sudo-правилам)
   - IDM Support (@idminfra) - для вопросов по IDM заявкам

---

## ✅ Финальная проверка

После успешного развертывания все пункты должны быть ✅:

- [ ] **vault-agent запущен** и активен (running)
- [ ] **credentials установлены** в `/opt/vault/conf/` с правильными правами
- [ ] **сертификаты сгенерированы** в `/opt/vault/certs/` (не пустые)
- [ ] **Prometheus доступен** на http://${SERVER_DOMAIN}:9090
- [ ] **Grafana доступна** на https://${SERVER_DOMAIN}:3000
- [ ] **Harvest работает** (опционально, если используется)
- [ ] **User-юниты активны** (monitoring-prometheus, monitoring-grafana)
- [ ] **Логи не содержат ERROR** (проверьте `sudo journalctl -u vault-agent -n 100`)

---

**Готово!** 🎉

Ваш Monitoring Stack успешно развернут в Secure Edition с полным соответствием требованиям ИБ!
