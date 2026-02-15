# Monitoring Stack Security Compliance

**Версия:** 1.0.0 (Secure Edition)  
**Дата:** 2026-02-15  
**Статус:** Соответствует требованиям ИБ Сбербанка

---

## Оглавление

1. [Обзор архитектуры](#обзор-архитектуры)
2. [Разделение полномочий](#разделение-полномочий)
3. [Управление секретами](#управление-секретами)
4. [Соответствие требованиям ИБ](#соответствие-требованиям-иб)
5. [Диаграммы и схемы](#диаграммы-и-схемы)
6. [Аудит и мониторинг безопасности](#аудит-и-мониторинг-безопасности)

---

## Обзор архитектуры

### Принципы Secure Edition

Monitoring Stack Secure Edition спроектирован в соответствии с принципами:

- **Least Privilege** (минимально необходимые привилегии)
- **Separation of Duties** (разделение полномочий)
- **Defense in Depth** (эшелонированная защита)
- **Secure by Default** (безопасность по умолчанию)

### Ключевые отличия от Legacy версии

| Аспект | Legacy Edition | Secure Edition | Обоснование ИБ |
|--------|---------------|----------------|----------------|
| **Установка ПО** | `/opt/`, `/etc/` | Системные RPM + user-space configs | Разделение бинарников и конфигов |
| **Конфигурация** | `/etc/grafana/`, `/etc/prometheus/` | `$HOME/monitoring/config/` | Не требует root для изменений |
| **Данные** | `/var/lib/grafana/`, `/var/lib/prometheus/` | `$HOME/monitoring/data/` | Изоляция данных от системы |
| **Логи** | `/var/log/`, `/tmp/` | `$HOME/monitoring/logs/` | Не требует sudo для чтения |
| **Секреты** | Переменные окружения, `jq` | Wrapper + /dev/shm | Нет plain-text в env vars |
| **Systemd Units** | System units (`/etc/systemd/system/`) | User units (`~/.config/systemd/user/`) | Управление без root |
| **Sudo права** | `ALL=(ALL:ALL) NOPASSWD` | Минимальный whitelist с NOEXEC | Нет эскалации привилегий |
| **Команды** | `awk`, `sed`, `cat` | `/usr/bin/awk`, wrapper'ы | Явные пути, валидация |

---

## Разделение полномочий

### Учетные записи и их роли

#### 1. **CI Пользователь** (`${KAE}-lnx-mon_ci`)

**Тип:** Технологическая учетная запись (ТУЗ)  
**Назначение:** Deployment, CI/CD pipeline  
**Группы:** `as-admin`, `${KAE}-lnx-va-read`

**Права доступа:**
- ✅ Чтение секретов из `/opt/vault/conf/data_sec.json` (через группу va-read)
- ✅ Копирование credentials в `/opt/vault/conf/` (через wrapper с sudo)
- ✅ Создание/изменение конфигов в `$HOME/monitoring/config/`
- ✅ Управление user units от имени mon_sys (через sudo)
- ❌ НЕТ доступа к runtime процессам мониторинговых сервисов
- ❌ НЕТ доступа к изменению бинарников RPM

**Обоснование:**
- При компрометации mon_ci нельзя изменить исполняемые файлы мониторинга
- Возможен только деплой новой конфигурации (что логируется в RLM/Jenkins)

#### 2. **System Пользователь** (`${KAE}-lnx-mon_sys`)

**Тип:** Сервисная учетная запись (СУЗ)  
**Назначение:** Запуск мониторинговых сервисов  
**Группы:** `grafana`, `systemd-journal`, `${KAE}-lnx-va-read`

**Права доступа:**
- ✅ Чтение конфигов из `$HOME/monitoring/config/` (созданных mon_ci)
- ✅ Чтение секретов из `/opt/vault/conf/data_sec.json` (через группу va-read)
- ✅ Запись данных в `$HOME/monitoring/data/`
- ✅ Запись логов в `$HOME/monitoring/logs/`
- ✅ Чтение системных логов (через группу systemd-journal)
- ❌ НЕТ доступа к изменению конфигов (только чтение)
- ❌ НЕТ доступа к деплою или изменению бинарников

**Обоснование:**
- При компрометации mon_sys нельзя задеплоить вредоносный код
- Можно только записывать данные/логи мониторинга (что ожидаемо)

#### 3. **Vault Agent Пользователи** (`${KAE}-lnx-va-start`, `${KAE}-lnx-va-read`)

**Тип:** Системные учетные записи для vault-agent  
**Назначение:** Управление секретами и сертификатами

**Права доступа:**
- `va-start`: владелец `/opt/vault/conf/`, запуск vault-agent
- `va-read`: группа для чтения секретов из `/opt/vault/conf/`

**Обоснование:**
- Даже администраторы мониторинга не могут напрямую читать секреты vault-agent
- Доступ только через группы (управляется IDM)

### Матрица прав доступа

| Ресурс | mon_ci | mon_sys | va-start | va-read (группа) |
|--------|--------|---------|----------|------------------|
| `/opt/vault/conf/` (запись) | ❌ (через wrapper) | ❌ | ✅ | ❌ |
| `/opt/vault/conf/data_sec.json` (чтение) | ✅ (группа) | ✅ (группа) | ✅ | ✅ |
| `$HOME/monitoring/config/` (запись) | ✅ | ❌ | ❌ | ❌ |
| `$HOME/monitoring/config/` (чтение) | ✅ | ✅ | ❌ | ❌ |
| `$HOME/monitoring/data/` | ✅ | ✅ | ❌ | ❌ |
| `$HOME/monitoring/logs/` | ✅ | ✅ | ❌ | ❌ |
| User units (управление) | ✅ (sudo) | ✅ (owner) | ❌ | ❌ |
| Системные RPM бинарники | ❌ | ❌ (exec only) | ❌ | ❌ |

---

## Управление секретами

### Архитектура работы с секретами

```
┌──────────────┐
│   Jenkins    │  1. withVault (AppRole auth)
│     CI       │     - role_id, secret_id извлекаются
└──────┬───────┘     - записываются в temp_data_cred.json
       │
       │ 2. scp temp_data_cred.json
       ▼
┌──────────────────────┐
│  Target Server       │
│  mon_ci пользователь │
└──────┬───────────────┘
       │
       │ 3. secrets-manager-wrapper.sh
       │    - Извлечение role_id, secret_id
       │    - Запись в $HOME/monitoring/config/vault/
       │    - trap для очистки переменных
       ▼
┌──────────────────────────────┐
│  vault-credentials-installer │
│  (wrapper с SHA256)          │
└──────┬───────────────────────┘
       │
       │ 4. sudo копирование в /opt/vault/conf/
       │    - Установка прав 640
       │    - Владелец: va-start
       │    - Группа: va-read
       ▼
┌──────────────────┐
│  /opt/vault/conf/│
│  - role_id.txt   │  5. vault-agent читает credentials
│  - secret_id.txt │     аутентифицируется в Vault
└──────┬───────────┘     генерирует data_sec.json и certs/
       │
       │ 6. vault-agent template
       ▼
┌────────────────────────┐
│ /opt/vault/conf/       │
│   data_sec.json (640)  │  7. mon_ci и mon_sys читают секреты
│                        │     через wrapper (группа va-read)
│ /opt/vault/certs/      │     копируют в user-space
│   *.pem (640)          │
└────────────────────────┘
```

### Безопасная обработка секретов

#### 1. **НЕТ plain-text в переменных окружения**

**❌ Legacy (запрещено ИБ):**
```bash
GRAFANA_PASSWORD=$(jq -r '.grafana_web.pass' file.json)
export GRAFANA_PASSWORD  # Видно в /proc/<PID>/environ
```

**✅ Secure Edition:**
```bash
# Использование wrapper'а
local grafana_password
grafana_password=$("$WRAPPERS_DIR/secrets-manager-wrapper_launcher.sh" \
    extract_secret "$cred_json" "grafana_web.pass")

# Установка trap для автоочистки
trap 'unset grafana_password' RETURN

# Использование секрета (НЕ экспортируется в env)
./some_command --password "$grafana_password"

# При выходе из функции переменная автоматически очищается
```

#### 2. **Временное хранение в /dev/shm (RAM)**

**Требование ИБ:** Секреты должны храниться в RAM (не на диске)

```bash
# Создание защищенной директории в /dev/shm
SECRETS_DIR=$(create_secure_secrets_dir)  # /dev/shm/monitoring-secrets-$$
chmod 700 "$SECRETS_DIR"

# Запись секрета во временный файл
echo "$secret" > "$SECRETS_DIR/temp_secret.txt"
chmod 600 "$SECRETS_DIR/temp_secret.txt"

# Использование
some_command --credentials-file "$SECRETS_DIR/temp_secret.txt"

# Безопасная очистка (перезапись + удаление)
shred -n 3 -z -u "$SECRETS_DIR/temp_secret.txt"
rm -rf "$SECRETS_DIR"
```

#### 3. **Wrapper'ы с whitelist'ами**

**secrets-manager-wrapper.sh** защищает от:
- Чтения произвольных JSON файлов
- Извлечения незапланированных полей
- Передачи секретов в stdout без контроля

**Whitelist директорий:**
- `/opt/vault/conf/` - системные секреты
- `/tmp/` - временные файлы CI
- `/dev/shm/` - секреты в RAM
- `$HOME/` - user-space файлы

**Whitelist полей:**
- `grafana_web.user`, `grafana_web.pass`
- `vault-agent.role_id`, `vault-agent.secret_id`
- `netapp_ssh.addr`, `netapp_ssh.user`, `netapp_ssh.pass`

---

## Соответствие требованиям ИБ

### ✅ Выполненные требования

#### 1. **NOEXEC в sudo правилах**

**Требование:** Все sudo правила должны иметь параметр `NOEXEC` для предотвращения эскалации.

**Реализация:**
```sudoers
ALL=(mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-prometheus.service
```

**Проверка:** `sudo -l | grep NOEXEC`

---

#### 2. **Отсутствие переменных окружения в sudo**

**Требование:** В sudo правилах запрещены переменные окружения (`$VAR`).

**❌ Неправильно (Legacy):**
```sudoers
ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart $SERVICE
```

**✅ Правильно (Secure Edition):**
```sudoers
ALL=(mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-prometheus.service
ALL=(mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-grafana.service
ALL=(mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-harvest.service
```

---

#### 3. **Запрещенные команды заменены или обернуты**

**Требование:** `awk`, `sed`, `cat`, `curl` и другие запрещенные команды нельзя использовать напрямую.

**Реализация:**

| Команда | Статус | Решение |
|---------|--------|---------|
| `awk` | ✅ Разрешена с явным путем | `/usr/bin/awk` |
| `sed` | ✅ Разрешена с явным путем | `/usr/bin/sed` |
| `cat` (для секретов) | ✅ Заменена на wrapper | `secrets-manager-wrapper.sh` |
| `curl` (для Nexus) | ❌ НЕ используется | RLM для установки RPM |
| `cat` (для конфигов) | ✅ Только для записи `cat > file` | Не читаем секреты |

---

#### 4. **systemctl status через группу systemd-journal**

**Требование:** Вместо sudo прав на `journalctl` добавить пользователя в группу `systemd-journal`.

**Реализация:**
```bash
# Добавление через IDM или RLM
usermod -aG systemd-journal ${KAE}-lnx-mon_sys

# Проверка
id ${KAE}-lnx-mon_sys | grep systemd-journal
```

**Результат:** mon_sys может читать логи без sudo.

---

#### 5. **iptables с явными правилами**

**Требование:** Использовать firewall-manager wrapper с валидацией правил.

**Реализация:**
- `firewall-manager_launcher.sh` с whitelist'ом портов
- Проверка что порты в диапазоне 1024-65535
- Запрет на открытие системных портов (< 1024) без обоснования

**Whitelist портов:**
- 9090 (Prometheus)
- 3000 (Grafana)
- 12990-12999 (Harvest)

---

#### 6. **Удаление логов/юнитов через yum/rpm remove**

**Требование:** Не удалять systemd units/logs в /etc/ напрямую, использовать package manager.

**Реализация в Secure Edition:**
- ✅ User units в `~/.config/systemd/user/` (можем удалять без sudo)
- ✅ Логи в `$HOME/monitoring/logs/` (можем удалять без sudo)
- ✅ НЕТ создания system units в `/etc/systemd/system/`

---

#### 7. **Минимальные привилегии (Least Privilege)**

**Требование:** Не запрашивать sudo на команды `pwd`, `ps`, `hostname`, `id`, `grep`.

**Реализация:**
- ✅ Все базовые команды выполняются БЕЗ sudo
- ✅ Sudo только для:
  - Управления user units от имени mon_sys
  - Копирования credentials в /opt/vault/conf/
  - (опционально) Перезапуска vault-agent

---

#### 8. **User-space архитектура**

**Требование:** ПО должно работать/настраиваться под непривилегированной УЗ.

**Реализация:**
```
$HOME/monitoring/
├── config/          # Конфигурация (mon_ci пишет, mon_sys читает)
│   ├── grafana/grafana.ini
│   ├── prometheus/prometheus.yml
│   ├── harvest/harvest.yml
│   └── vault/agent.hcl (копия)
├── data/            # Данные сервисов (mon_sys пишет)
│   ├── grafana/
│   ├── prometheus/
│   └── harvest/
├── logs/            # Логи (mon_sys пишет)
│   ├── grafana/
│   ├── prometheus/
│   └── harvest/
├── certs/           # Сертификаты (скопированы из /opt/vault/certs/)
│   ├── grafana/
│   ├── prometheus/
│   └── harvest/
└── state/           # Состояние деплоя
    └── deployment_state
```

**Преимущества:**
- НЕ требуется root для большинства операций
- Изоляция данных мониторинга от системы
- Простое резервное копирование (`tar $HOME/monitoring`)
- Легкая очистка при удалении (`rm -rf $HOME/monitoring`)

---

#### 9. **Wrapper'ы с SHA256 checksums**

**Требование:** Скрипты обёртки должны быть защищены checksums для предотвращения модификации.

**Реализация:**
```bash
# build-integrity-checkers.sh генерирует launcher'ы с проверкой SHA256
vault-credentials-installer_integrity_checker.sh:
  - Вычисляет SHA256 wrapper'а при каждом запуске
  - Сравнивает с ожидаемым (из sudoers)
  - Запрещает выполнение при несовпадении
```

**Sudoers:**
```
ALL=(root) NOEXEC: NOPASSWD: sha256:abc123...def /path/to/wrapper.sh
```

---

### Аудит и мониторинг безопасности

#### Логирование операций

Все критические операции логируются:

1. **RLM Operations Log:**
   - Установка vault через RLM
   - Установка RPM пакетов
   - Добавление пользователей в группы

2. **Jenkins Pipeline Log:**
   - Извлечение секретов из Vault
   - Копирование файлов на целевой сервер
   - Запуск deployment скрипта

3. **Deployment Script Log:**
   - Все операции с секретами (SECURITY: без plain-text)
   - Создание/изменение конфигов
   - Управление сервисами

4. **System Audit Log** (`/var/log/audit/audit.log`):
   - Все sudo операции
   - Изменения в /opt/vault/conf/
   - Запуск wrapper'ов

#### Проверка соответствия

**После развертывания выполните:**

```bash
# 1. Проверка sudo правил
sudo -l -U ${KAE}-lnx-mon_ci

# 2. Проверка групп
id ${KAE}-lnx-mon_ci
id ${KAE}-lnx-mon_sys

# 3. Проверка прав на файлы
ls -la /opt/vault/conf/role_id.txt
# Ожидаем: va-start:va-read 640

ls -la $HOME/monitoring/config/grafana/grafana.ini
# Ожидаем: mon_ci:mon_ci 644 (или 640)

# 4. Проверка user units
sudo -u ${KAE}-lnx-mon_sys systemctl --user status monitoring-prometheus.service

# 5. Проверка отсутствия секретов в environment
sudo cat /proc/$(pgrep prometheus)/environ | strings | grep -i password
# Ожидаем: НЕТ результатов
```

---

## Заключение

Monitoring Stack Secure Edition полностью соответствует требованиям ИБ Сбербанка:

✅ **Принцип минимальных полномочий** - каждая УЗ имеет только необходимые права  
✅ **Разделение обязанностей** - mon_ci (deploy) отделен от mon_sys (runtime)  
✅ **Безопасное управление секретами** - wrapper'ы, /dev/shm, trap, no env vars  
✅ **User-space архитектура** - большинство операций без sudo  
✅ **Явные sudo правила** - NOEXEC, без wildcards, с SHA256 checksums  
✅ **Аудит и логирование** - все операции записываются в логи

### Контакты

**Вопросы по проекту:**  
- GitHub: `monitoring-stack-automation-secure`  
- Email: [укажите контакт]

**Вопросы по ИБ:**  
- УАиРКБ ЦКЗ Сбербанк  
- Confluence: [ссылки на документацию ИБ]

---

**Дата последнего обновления:** 2026-02-15  
**Версия документа:** 1.0.0
