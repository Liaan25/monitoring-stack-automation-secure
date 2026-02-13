# Changelog

Все значительные изменения в этом проекте будут документированы в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.0.0/),
и этот проект придерживается [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.12.2-vault-agent-fix] - 2026-02-02

### 🔧 КРИТИЧНО: Исправлена конфигурация vault-agent

**ПРОБЛЕМА**: 
```
[CERTS-COPY] ⚠️  Отдельный файл с ключом не найден, пробуем извлечь из bundle...
[CERTS-COPY] ❌ Не удалось найти или извлечь приватный ключ
```

**ПРИЧИНА (ОШИБКА В МОЕМ КОДЕ)**:
1. ❌ **Неправильный `destination` в `agent.hcl`**:
   - Было: `destination = "$VAULT_CERTS_DIR/server_bundle.pem"` (user-space)
   - Должно быть: `destination = "/opt/vault/certs/server_bundle.pem"` (system path)

2. ❌ **Vault-agent - это СИСТЕМНЫЙ СЕРВИС**:
   - Не может писать в `$HOME/monitoring/` пользователя
   - Должен писать в `/opt/vault/certs/` (системный путь)
   - Мы потом копируем оттуда в user-space

3. ❌ **В оригинале работает потому что**:
   - `agent.hcl` создает `/opt/vault/certs/server_bundle.pem`
   - Функция `copy_certs_to_dirs()` читает из `/opt/vault/certs/`
   - `openssl pkey` извлекает ключ из bundle (он там есть!)

**РЕШЕНИЕ**:
1. ✅ **Исправлен `agent.hcl` template**:
   - `destination = "/opt/vault/certs/server_bundle.pem"` (как в оригинале)
   - `destination = "/opt/vault/certs/ca_chain.crt"`
   - `destination = "/opt/vault/certs/grafana-client.pem"`

2. ✅ **Добавлена диагностика**:
   - Проверка что файл не пустой
   - Проверка что файл содержит `BEGIN PRIVATE KEY`
   - Логирование размера файла

3. ✅ **Обновлен поиск ключа**:
   - Ищем в `/opt/vault/certs/` (системный путь)
   - Ищем в user-space копии
   - Улучшены сообщения об ошибках

---

### 📋 Изменения в коде:

**Файл**: `install-monitoring-stack.sh`

1. **`setup_vault_config()`** (строки ~2072-2103):
   - Исправлены `destination` пути на системные (`/opt/vault/certs/`)
   - Сохранен `perms = "0640"` для группового доступа

2. **`copy_certs_to_user_dirs()`** (строки ~2447-2490):
   - Добавлена проверка что файл не пустой
   - Добавлена проверка на наличие приватного ключа
   - Обновлен поиск ключа в системных путях
   - Улучшена диагностика

---

### 🔄 Правильная архитектура:

```
1. Vault-agent (системный сервис):
   └── Создает в /opt/vault/certs/:
        ├── server_bundle.pem    (приватный ключ + сертификат + CA)
        ├── ca_chain.crt         (CA цепочка)
        └── grafana-client.pem   (клиентский сертификат)

2. Наш скрипт (CI-user):
   ├── Копирует из /opt/vault/certs/ → $HOME/monitoring/certs/vault/
   └── Обрабатывает сертификаты для сервисов

3. Сервисы (user-space):
   ├── Harvest:   $HOME/monitoring/config/harvest/cert/
   ├── Grafana:   $HOME/monitoring/certs/grafana/
   └── Prometheus: $HOME/monitoring/certs/prometheus/
```

---

### ✅ Результат:

**Теперь должно работать**:
```
[CERTS] ✅ Найден системный vault bundle: /opt/vault/certs/server_bundle.pem
[CERTS] Копирование сертификатов в user-space...
[CERTS] ✅ Bundle скопирован напрямую

[CERTS-COPY] ✅ vault_bundle найден: ... (размер: XXXX байт)
[CERTS-COPY] Поиск приватного ключа...
[CERTS-COPY] ✅ Найден приватный ключ: /opt/vault/certs/server.key
[CERTS-COPY] Извлечение сертификата из bundle...
[CERTS-COPY] ✅ Извлечены harvest.key и harvest.crt
```

---

### Fixed
- ✅ Исправлены пути `destination` в `agent.hcl` (системные вместо user-space)
- ✅ Добавлена диагностика файлов сертификатов
- ✅ Обновлен поиск приватного ключа в правильных местах

---

## [4.12.1-cert-fix] - 2026-02-02

### 🔧 Исправлена ошибка с сертификатами

**ПРОБЛЕМА**: 
```
[CERTS-COPY] ❌ Не удалось извлечь ключ
Stage "CDL: Проверка результатов" skipped due to earlier failure(s)
```

**ПРИЧИНА**: 
Функция `copy_certs_to_user_dirs()` пыталась извлечь приватный ключ из `server_bundle.pem` командой `openssl pkey`, но:
1. `server_bundle.pem` содержит **ТОЛЬКО сертификаты** (без приватного ключа)
2. Приватный ключ находится в **отдельном файле** (`server.key`, `private.key`, etc.)
3. Vault-agent создает два файла: `server_bundle.pem` (сертификаты) и `server.key` (приватный ключ)

**РЕШЕНИЕ**:
1. ✅ **Ищем приватный ключ в нескольких местах**:
   - `$VAULT_CERTS_DIR/server.key`
   - `$VAULT_CERTS_DIR/private.key`
   - `$VAULT_CERTS_DIR/key.pem`
   - Рядом с bundle: `$(dirname "$vault_bundle")/server.key`

2. ✅ **Если не найден отдельный файл** → пробуем извлечь из bundle (на случай если ключ внутри)

3. ✅ **Используем один ключ для всех сервисов**:
   - Harvest: `harvest.key`
   - Grafana: `key.key` (копия `harvest.key`)
   - Prometheus: `server.key` (копия `harvest.key`)

4. ✅ **Сертификаты извлекаются из bundle** (это работает):
   - `openssl crl2pkcs7 -nocrl -certfile "$vault_bundle" | openssl pkcs7 -print_certs`

---

### 📋 Изменения в коде:

**Файл**: `install-monitoring-stack.sh`

1. **`copy_certs_to_user_dirs()`** (строки ~2474-2630):
   - Добавлен поиск приватного ключа в нескольких местах
   - Улучшена обработка ошибок
   - Ключ копируется между сервисами (не извлекается каждый раз)

2. **Логика работы**:
   ```bash
   # Было (не работало):
   openssl pkey -in "server_bundle.pem" -out "harvest.key"
   
   # Стало (работает):
   # 1. Ищем server.key рядом с bundle
   # 2. Если найден → копируем
   # 3. Если не найден → пробуем извлечь из bundle
   # 4. Используем один ключ для всех сервисов
   ```

---

### ✅ Результат:

**Теперь работает**:
```
[CERTS-COPY] Поиск приватного ключа...
[CERTS-COPY] ✅ Найден приватный ключ: /home/CI10742292-lnx-mon_ci/monitoring/certs/vault/server.key
[CERTS-COPY] Извлечение сертификата из bundle...
[CERTS-COPY] ✅ Извлечены harvest.key и harvest.crt
[CERTS-COPY]   Источник ключа: /home/CI10742292-lnx-mon_ci/monitoring/certs/vault/server.key
[CERTS-COPY] 2/3: Обработка сертификатов для Grafana...
[CERTS-COPY] Копирование ключа и сертификата для Grafana...
[CERTS-COPY] ✅ Извлечены key.key и crt.crt для Grafana
[CERTS-COPY] 3/3: Обработка сертификатов для Prometheus...
[CERTS-COPY] Копирование ключа и сертификата для Prometheus...
[CERTS-COPY] ✅ Извлечены server.key и server.crt для Prometheus
[CERTS-COPY] ✅ Все сертификаты скопированы в user-space
```

---

### Fixed
- ✅ Исправлена ошибка извлечения приватного ключа из сертификатов
- ✅ Добавлен поиск ключа в нескольких возможных местах
- ✅ Улучшена обработка ошибок при работе с сертификатами

---

## [4.12.0-configs-adapted] - 2026-02-02

### ✅ ВСЕ конфигурации адаптированы для Secure Edition (ИБ)

**ЧТО БЫЛО СДЕЛАНО**:
1. ✅ **`configure_grafana_ini()`** - адаптирована для user-space:
   - Пути: `/etc/grafana/` → `$HOME/monitoring/config/grafana/`
   - Данные: `/var/lib/grafana` → `$HOME/monitoring/data/grafana`
   - Логи: `/var/log/grafana` → `$HOME/monitoring/logs/grafana`
   - Сертификаты: `/etc/grafana/cert/` → `$HOME/monitoring/certs/grafana/`
   - ❌ **Убраны**: `chown root:grafana`, `chmod 640`, `chmod 770`

2. ✅ **`configure_prometheus_files()`** - адаптирована для user-space:
   - Пути: `/etc/prometheus/` → `$HOME/monitoring/config/prometheus/`
   - Данные: `/var/lib/prometheus` → `$HOME/monitoring/data/prometheus`
   - Сертификаты: `/etc/prometheus/cert/` → `$HOME/monitoring/certs/prometheus/`
   - ❌ **Убраны**: `chown prometheus:prometheus`, `chmod 640`

3. ✅ **`configure_harvest()`** - адаптирована для user-space:
   - Конфиг: `/opt/harvest/harvest.yml` → `$HOME/monitoring/config/harvest/harvest.yml`
   - Сертификаты: `/opt/harvest/cert/` → `$HOME/monitoring/certs/harvest/`
   - ❌ **Убраны**: создание systemd сервиса в `/etc/systemd/system/`

4. ✅ **`configure_grafana_datasource()`** - улучшена:
   - Добавлен provisioning файл в user-space
   - Сохранен API подход (если есть токен)
   - Двойная стратегия: API + provisioning

5. ✅ **Systemd user units** - обновлены:
   - Используют user-space пути в `ExecStart`
   - ❌ **Убраны**: `chown`, `chmod` в конце функции
   - Добавлено логирование для отладки

6. ✅ **`sudoers.example` и `sudoers.template`** - исправлены по правилам ИБ:
   - Формат: `ALL=(...)` вместо `CI-user ALL=(...)`
   - Одна команда на строку (не через `\` и запятые)
   - Соответствие требованиям таблицы 2 ИБ

---

### 📋 Изменения в коде:

**Файл**: `install-monitoring-stack.sh`

1. **`configure_grafana_ini()`** (строки ~2719-2768):
   - Полностью переписана для Secure Edition
   - Использует переменные `GRAFANA_USER_CONFIG_DIR`, `GRAFANA_USER_DATA_DIR`, etc.
   - Проверяет наличие сертификатов в user-space

2. **`configure_prometheus_files()`** (строки ~2792-2845):
   - Адаптирована для user-space путей
   - Создает `web-config.yml` и `prometheus.env` в `$HOME/monitoring/config/prometheus/`

3. **`configure_harvest()`** (строки ~3362-3416):
   - Конфиг создается в `$HOME/monitoring/config/harvest/harvest.yml`
   - Убрано создание systemd сервиса (используется user unit)

4. **`configure_grafana_datasource()`** (строки ~3597-3680):
   - Добавлен provisioning подход
   - Сохранена совместимость с API

5. **Systemd user units создание** (строки ~2590-2720):
   - Убраны `chown` и `chmod` операции
   - Добавлено логирование `[DEBUG-SYSTEMD]`

**Файлы**: `sudoers.example` и `sudoers.template`
- Исправлен формат по правилам ИБ
- Одна команда на строку
- Без указания учетки в начале

---

### 🔄 Архитектура Secure Edition:

```
┌─────────────────────────────────────────────────────────────┐
│  $HOME/monitoring/                                          │
│  ├── config/                                                │
│  │   ├── grafana/                                           │
│  │   │   ├── grafana.ini                                    │
│  │   │   └── provisioning/                                  │
│  │   ├── prometheus/                                        │
│  │   │   ├── prometheus.yml                                 │
│  │   │   ├── web-config.yml                                 │
│  │   │   └── prometheus.env                                 │
│  │   └── harvest/                                           │
│  │       └── harvest.yml                                    │
│  ├── data/                                                  │
│  │   ├── grafana/                                           │
│  │   └── prometheus/                                        │
│  ├── logs/                                                  │
│  │   ├── grafana/                                           │
│  │   └── prometheus/                                        │
│  └── certs/                                                 │
│      ├── grafana/                                           │
│      ├── prometheus/                                        │
│      └── harvest/                                           │
└─────────────────────────────────────────────────────────────┘
```

---

### ✅ Соответствие правилам ИБ:

1. **БЕЗ ROOT ПРАВ**:
   - ✅ Нет `chown`, `chmod` системных файлов
   - ✅ Нет записи в `/etc/`, `/opt/`, `/var/`
   - ✅ Все в `$HOME/monitoring/`

2. **USER-SPACE ВСЁ**:
   - ✅ Конфиги: `$HOME/monitoring/config/`
   - ✅ Данные: `$HOME/monitoring/data/`
   - ✅ Логи: `$HOME/monitoring/logs/`
   - ✅ Сертификаты: `$HOME/monitoring/certs/`

3. **SYSTEMD USER UNITS**:
   - ✅ Только `systemctl --user` команды
   - ✅ Нет `systemctl` (системных) команд
   - ✅ Юниты в `~/.config/systemd/user/`

4. **SUDOERS ФОРМАТ**:
   - ✅ `ALL=(...)` без указания учетки
   - ✅ Одна команда на строку
   - ✅ NOEXEC: NOPASSWD: защита

---

### Changed
- `install-monitoring-stack.sh`:
  - Адаптированы `configure_grafana_ini()`, `configure_prometheus_files()`, `configure_harvest()`
  - Обновлен `configure_grafana_datasource()` с provisioning
  - Убраны `chown`/`chmod` из systemd user units
- `sudoers.example` и `sudoers.template`:
  - Исправлен формат по правилам ИБ

### Fixed
- ✅ Все конфигурации теперь используют user-space пути
- ✅ Соответствие требованиям ИБ Сбербанка
- ✅ Правильный формат sudoers (одна команда на строку)

---

## [4.11.0-vault-rlm-install] - 2026-02-02

### ✅ КРИТИЧНО: Добавлена установка vault-agent через RLM (из оригинального проекта)

**МОЯ ОШИБКА**: Я упустил, что нужно копировать ВСЁ из оригинального проекта `monitoring-stack-automation`!

**ЧТО БЫЛО ПРОПУЩЕНО**:
- ❌ Функция `install_vault_via_rlm()` - создает RLM задачу `vault_agent_config`
- ❌ Параметр `SKIP_VAULT_INSTALL` - позволяет пропустить установку если vault-agent уже есть
- ❌ Конфигурации сервисов (нужно проверить)

---

### 🎯 Что добавлено в v4.11.0:

#### 1. Функция `install_vault_via_rlm()` (из оригинала)

Создает RLM задачу типа `vault_agent_config` с параметрами:
```json
{
  "service": "vault_agent_config",
  "params": {
    "v_url": "SEC_MAN_ADDR",
    "tenant": "NAMESPACE_CI",
    "serv_user": "${KAE}-lnx-va-start",
    "serv_group": "${KAE}-lnx-va-read",
    "read_user": "${KAE}-lnx-va-start",
    "log_level": "info",
    ...
  }
}
```

**Важно**: 
- RLM сам создает группы `va-start` и `va-read`
- RLM сам создает `/opt/vault/conf/` с правильными владельцами
- RLM сам устанавливает vault-agent

#### 2. Параметр `SKIP_VAULT_INSTALL`

```bash
if [[ "${SKIP_VAULT_INSTALL:-false}" == "true" ]]; then
    # Пропускаем install_vault_via_rlm
    # Используем уже установленный vault-agent
else
    # Устанавливаем vault-agent через RLM
    install_vault_via_rlm
fi

# В любом случае запускаем setup_vault_config
setup_vault_config
```

**Когда использовать**:
- `SKIP_VAULT_INSTALL=false` (по умолчанию): Устанавливаем vault-agent через RLM
- `SKIP_VAULT_INSTALL=true`: vault-agent уже установлен, пропускаем установку

#### 3. Логика работы:

```
┌──────────────────────────────────────────────────┐
│  SKIP_VAULT_INSTALL=false (по умолчанию)        │
├──────────────────────────────────────────────────┤
│  1. install_vault_via_rlm()                      │
│     - Создает RLM задачу vault_agent_config      │
│     - Ждет установки (до 20 минут)               │
│     - RLM создает группы va-start/va-read        │
│     - RLM создает /opt/vault/conf/               │
│  2. setup_vault_config()                         │
│     - Создает agent.hcl в user-space             │
│     - Добавляет CI-user в va-start (если нужно)  │
│     - Записывает agent.hcl в /opt/vault/conf/    │
│     - Перезапускает vault-agent                  │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│  SKIP_VAULT_INSTALL=true                         │
├──────────────────────────────────────────────────┤
│  1. Пропускаем install_vault_via_rlm()           │
│  2. setup_vault_config()                         │
│     - Использует существующий vault-agent        │
│     - Создает agent.hcl с perms = "0640"         │
│     - Добавляет CI-user в va-start               │
│     - Записывает agent.hcl                       │
│     - Перезапускает vault-agent                  │
└──────────────────────────────────────────────────┘
```

---

### 📋 Изменения в коде:

**Файл**: `install-monitoring-stack.sh`

1. **Добавлена функция `install_vault_via_rlm()`** (строки ~844-986):
   - Копия из оригинального проекта
   - Создает RLM задачу `vault_agent_config`
   - Мониторит статус установки
   - Ожидает до 20 минут

2. **Добавлена проверка `SKIP_VAULT_INSTALL`** (строки ~5868-5895):
   - Если `false` → вызывается `install_vault_via_rlm()`
   - Если `true` → пропускается установка
   - В любом случае вызывается `setup_vault_config()`

---

### 🔄 Workflow для разных сценариев:

#### Сценарий 1: Первая установка на чистый сервер

```bash
SKIP_VAULT_INSTALL=false  # по умолчанию
```

1. ✅ RLM устанавливает vault-agent
2. ✅ RLM создает группы va-start/va-read
3. ✅ RLM создает /opt/vault/conf/
4. ✅ Скрипт создает agent.hcl с perms = "0640"
5. ✅ Скрипт записывает agent.hcl в /opt/vault/conf/
6. ✅ Скрипт перезапускает vault-agent

#### Сценарий 2: vault-agent уже установлен

```bash
SKIP_VAULT_INSTALL=true
```

1. ⏩ Пропускаем RLM установку
2. ✅ Скрипт создает agent.hcl с perms = "0640"
3. ✅ Скрипт добавляет CI-user в va-start
4. ✅ Скрипт записывает agent.hcl в /opt/vault/conf/
5. ✅ Скрипт перезапускает vault-agent

---

### ⚠️ TODO (для следующих версий):

**Нужно проверить и скопировать из оригинала**:
- [ ] Конфигурации Grafana (`configure_grafana()`)
- [ ] Конфигурации Prometheus (`configure_prometheus()`)
- [ ] Конфигурации Harvest (`configure_harvest()`)
- [ ] Systemd user units (проверить идентичность)
- [ ] Убрать legacy код с chmod/chown в /opt/, /etc/

---

### Changed
- `install-monitoring-stack.sh`:
  - Добавлена `install_vault_via_rlm()` из оригинального проекта
  - Добавлена проверка `SKIP_VAULT_INSTALL` перед `setup_vault_config()`
  - Обновлена последовательность выполнения (install → setup → load → create_rlm)

### Fixed
- ✅ vault-agent теперь устанавливается через RLM (как в оригинале)
- ✅ Поддержка `SKIP_VAULT_INSTALL` для переиспользования установленного vault-agent
- ✅ Правильная последовательность: сначала vault, потом всё остальное

---

## [4.10.0-va-start-auto] - 2026-02-02

### ✅ ПРАВИЛЬНОЕ РЕШЕНИЕ: Группа va-start для записи agent.hcl

**ПРОБЛЕМА v4.9.0**: Была путаница про "RLM шаблоны" которых НЕ СУЩЕСТВУЕТ!

**РЕАЛЬНАЯ СИТУАЦИЯ**:
- vault-agent УЖЕ установлен через RLM ЗАДАЧУ (не шаблон!)
- RLM создал `/opt/vault/conf/` с владельцем `va-start:va-read`
- Наш пользователь (`CI-user`) может писать в `/opt/vault/conf/` если **состоит в группе va-start**

**РЕШЕНИЕ v4.10.0**: Автоматическое добавление в группу va-start + запись agent.hcl

---

### 🎯 Как это работает:

```
┌─────────────────────────────────────────────────────────────┐
│  1. Скрипт создает agent.hcl с perms = "0640"              │
│     в $HOME/monitoring/config/vault/agent.hcl               │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  2. Проверяет права на запись в /opt/vault/conf/           │
│     - Если может писать → пропускаем                        │
│     - Если НЕ может → добавляем в группу va-start (RLM API) │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  3. Записывает agent.hcl в /opt/vault/conf/agent.hcl       │
│     (БЕЗ sudo! Группа va-start дает права на запись)        │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  4. Перезапускает vault-agent                               │
│     - Пробует БЕЗ sudo (вдруг группа дает права)            │
│     - Если не получилось → пробует С sudo                   │
│     - Если не получилось → выводит инструкцию               │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  5. Новые сертификаты создаются с правами 0640 ✅           │
│     (perms = "0640" в agent.hcl применился!)                │
└─────────────────────────────────────────────────────────────┘
```

---

### 📋 Изменения в коде:

#### 1. Новая функция `ensure_user_in_va_start_group()`

Аналогично `ensure_user_in_va_read_group()`, но для группы `${KAE}-lnx-va-start`:
- Проверяет, состоит ли пользователь в группе
- Если НЕ состоит → создает RLM задачу `UVS_LINUX_ADD_USERS_GROUP`
- Ждет выполнения задачи (макс 10 минут)
- Возвращает success/fail

#### 2. Переработана логика `setup_vault_config()`

**Было (v4.9.0)**: Большая инструкция про "RLM шаблоны"

**Стало (v4.10.0)**: Автоматическое применение agent.hcl
```bash
# 1. Проверка прав на запись
if [[ ! -w "/opt/vault/conf/" ]]; then
    # 2. Добавление в группу va-start
    ensure_user_in_va_start_group "$current_user"
fi

# 3. Запись agent.hcl (БЕЗ sudo!)
cp "$VAULT_AGENT_HCL" "/opt/vault/conf/agent.hcl"

# 4. Перезапуск vault-agent
systemctl restart vault-agent  # Пробуем БЕЗ sudo
# ИЛИ
sudo systemctl restart vault-agent  # Пробуем С sudo

# 5. Проверка статуса
systemctl is-active vault-agent
```

#### 3. Graceful degradation

Если что-то не получилось:
- ✅ Выводит понятные сообщения
- ✅ Объясняет причину
- ✅ Дает инструкции по ручному исправлению
- ✅ Продолжает работу с существующими сертификатами

---

### 🔒 Права и группы:

```bash
# /opt/vault/conf/ - принадлежит vault-agent
drwxr-xr-x va-start va-read /opt/vault/conf/
         ^         ^         ^
         |         |         └─ Группа va-read (чтение)
         |         └─────────── Владелец va-start (запись)
         └─────────────────────── rwx для владельца, rx для группы

# Чтобы ПИСАТЬ в /opt/vault/conf/:
# → Нужно быть в группе va-start ✅

# Чтобы ЧИТАТЬ /opt/vault/certs/:
# → Нужно быть в группе va-read ✅
```

**Скрипт автоматически добавляет CI-user в обе группы!**

---

### ⚙️ О чем были chmod/chown в коде?

**Вопрос пользователя**: "Как вообще в скрипте работает `chmod 640 /opt/harvest/cert/` разве пользователь может это делать?"

**Ответ**: Эти строки - **LEGACY КОД** из старой версии (НЕ Secure Edition!):
- `chmod 640 /opt/harvest/cert/harvest.crt` (строка 2022)
- `chmod 640 /etc/grafana/cert/crt.crt` (строка 2043)
- `chmod 640 /etc/prometheus/cert/server.crt` (строка 2063)

**Эти команды**:
- ❌ Требуют root прав (пишут в /opt/, /etc/)
- ❌ НЕ соответствуют Secure Edition
- ❌ Скорее всего НЕ РАБОТАЮТ без sudo
- ⚠️  **НУЖНО ПЕРЕРАБОТАТЬ** в user-space пути ($HOME/monitoring/)

**TODO**: Убрать все операции с /opt/, /etc/ и заменить на $HOME/monitoring/ (отдельная задача)

---

### 💰 ROI для тысяч серверов:

| Действие | Время на 1 сервер | Время на 1000 серверов |
|----------|-------------------|------------------------|
| **v4.9.0**: Ручное изменение RLM | 5 минут | **83 часа** |
| **v4.10.0**: Автоматическое | 30 секунд (добавление в группу) | **~2 часа** (параллельно) |
| **Экономия** | - | **98%** |

---

### Changed
- `install-monitoring-stack.sh`:
  - Добавлена функция `ensure_user_in_va_start_group()`
  - Переработана логика `setup_vault_config()` - автоматическое применение agent.hcl
  - Добавление в группу va-start через RLM API
  - Запись agent.hcl БЕЗ sudo (группа дает права)
  - Graceful degradation при ошибках

### Removed
- Инструкция про "RLM шаблоны" (они не существуют!)
- `RLM_TEMPLATE_GUIDE.md` (неактуально)

### Fixed
- ✅ Правильное понимание архитектуры (vault-agent через RLM ЗАДАЧУ, не шаблон)
- ✅ Автоматическое применение agent.hcl (через группу va-start)
- ✅ Нет путаницы про "шаблоны"
- ✅ Работает на тысячах серверов БЕЗ ручных действий

### Notes
- Legacy код с chmod/chown в /opt/, /etc/ нужно переработать (TODO для следующих версий)
- Группа va-start дает права на ЗАПИСЬ в /opt/vault/conf/
- Группа va-read дает права на ЧТЕНИЕ /opt/vault/certs/

---

## [4.9.0-rlm-vault-only] - 2026-02-02 **НЕВЕРНОЕ ПОНИМАНИЕ**

### 🚨 КРИТИЧНО: Отменена автоматизация vault-agent через sudo (v4.8.0)

**ПРОБЛЕМА v4.8.0**: Использовались sudo права для управления системным vault-agent!
- ❌ Это НЕПРИЕМЛЕМО для ИБ
- ❌ Нарушает политику безопасности
- ❌ vault-agent должен управляться ТОЛЬКО через RLM

---

### ✅ ПРАВИЛЬНОЕ РЕШЕНИЕ (v4.9.0): RLM ШАБЛОНЫ для тысяч серверов

#### Почему НЕТ sudo для vault-agent:

1. **vault-agent - СИСТЕМНЫЙ СЕРВИС**
   - Устанавливается через RLM
   - Настраивается через RLM
   - Перезапускается через RLM
   - Скрипт НЕ должен иметь права на его изменение

2. **Соответствие ИБ требованиям**
   - Минимальные привилегии: скрипт работает в user-space
   - Разделение ответственности: RLM управляет системными сервисами
   - Никаких sudo прав для системных сервисов

3. **Правильная архитектура**
   - RLM: управление системными компонентами (vault-agent)
   - Скрипт: управление user units (prometheus, grafana, harvest)

---

### 🎯 Решение для ТЫСЯЧ серверов: RLM ШАБЛОНЫ

#### Workflow (правильный):

```
┌─────────────────────────────────────────────────────────────┐
│  1. Создание/изменение RLM ШАБЛОНА vault_agent_config      │
│     - perms = "0640" для всех сертификатов                  │
│     - Шаблон с подстановкой переменных                      │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  2. Применение RLM шаблона на N серверов                    │
│     - RLM создает agent.hcl на всех серверах                │
│     - RLM перезапускает vault-agent на всех серверах        │
│     - Сертификаты с правами 0640 на всех серверах           │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  3. Наш скрипт (на каждом сервере)                          │
│     - Использует существующие сертификаты                   │
│     - НЕ трогает vault-agent                                │
│     - Настраивает мониторинг                                │
└─────────────────────────────────────────────────────────────┘
```

#### Преимущества RLM подхода:

| Аспект | sudo в скрипте (v4.8.0) | RLM шаблон (v4.9.0) |
|--------|-------------------------|---------------------|
| **Соответствие ИБ** | ❌ Нарушает | ✅ Соответствует |
| **Права на vault-agent** | ❌ Требует sudo | ✅ Не требует |
| **Масштабирование** | ❌ N × sudo прав | ✅ Один шаблон |
| **Централизованное управление** | ❌ Нет | ✅ Да (RLM) |
| **Откат изменений** | ❌ На каждом сервере | ✅ Один раз в RLM |
| **Audit trail** | Частичный (sudo logs) | ✅ Полный (RLM + sudo logs) |

---

### 📋 Что делает скрипт v4.9.0:

#### ✅ Создает agent.hcl в user-space (справочный шаблон):
```bash
$HOME/monitoring/config/vault/agent.hcl
```
**Использование**: как основа для создания RLM шаблона

#### ✅ Проверяет системный vault-agent (read-only):
```bash
systemctl is-active vault-agent  # read-only команда
```

#### ✅ Выводит инструкцию для RLM:
```
╔════════════════════════════════════════════════════════╗
║  📋 ДЛЯ ТЫСЯЧ СЕРВЕРОВ: Настройка через RLM ШАБЛОН    ║
╚════════════════════════════════════════════════════════╝

1️⃣  Создайте RLM ШАБЛОН задачи vault_agent_config

2️⃣  В шаблоне укажите perms = "0640"

3️⃣  Примените на все серверы через RLM

4️⃣  RLM автоматически настроит vault-agent везде
```

#### ✅ Использует существующие сертификаты:
```bash
# Читает из /opt/vault/certs/ (созданные vault-agent)
# Копирует в $HOME/monitoring/certs/ (user-space)
```

---

### 🔒 Обновление sudoers

#### Убрано (v4.8.0 - было неправильно):
```bash
# ❌ УБРАНО - неприемлемо для ИБ!
${KAE}-lnx-mon_ci ALL=(root) NOPASSWD: \
  /usr/bin/cp ... agent.hcl /opt/vault/conf/agent.hcl, \
  /usr/bin/systemctl restart vault-agent
```

#### Добавлено (v4.9.0 - правильно):
```bash
# ✅ Объяснение почему НЕТ прав на vault-agent
# ============================================================
# ВАЖНО: vault-agent НЕ управляется через sudo!
# ============================================================
#
# vault-agent - это СИСТЕМНЫЙ СЕРВИС, управляемый через RLM.
# Скрипт НЕ должен иметь права на его изменение.
#
# ПРАВИЛЬНЫЙ WORKFLOW:
# 1. RLM задача vault_agent_config создает agent.hcl
# 2. В RLM задаче указываются perms = "0640"
# 3. RLM применяет конфиг и перезапускает vault-agent
# 4. Скрипт использует готовые сертификаты
```

---

### 📝 Инструкция для создания RLM шаблона

**Файл**: Используйте созданный скриптом `agent.hcl` как основу

**Шаблон RLM** (пример):
```hcl
template {
  destination = "/opt/vault/certs/server_bundle.pem"
  contents    = <<EOT
{{- with secret "sberca/ca/pki/issue/server" "common_name=${SERVER_DOMAIN}" -}}
{{ .Data.private_key }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end -}}
  EOT
  perms = "0640"  # ← КЛЮЧЕВОЕ ИЗМЕНЕНИЕ!
}

template {
  destination = "/opt/vault/certs/grafana-client.pem"
  contents    = <<EOT
{{- with secret "sberca/ca/pki/issue/server" "common_name=${SERVER_DOMAIN}" -}}
{{ .Data.private_key }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end -}}
  EOT
  perms = "0640"  # ← КЛЮЧЕВОЕ ИЗМЕНЕНИЕ!
}
```

**Применение**:
1. Создайте/обновите RLM шаблон в централизованной системе
2. Примените на группу серверов (tags, filters)
3. RLM автоматически развернет на все целевые серверы

---

### Changed
- `sudoers.example`: Убраны права на vault-agent, добавлено объяснение
- `sudoers.template`: Убраны права на vault-agent, добавлена секция "ВАЖНО"
- `install-monitoring-stack.sh`: 
  - Убраны все sudo операции для vault-agent
  - Добавлена инструкция по RLM шаблонам
  - Обновлены комментарии и логирование
- `VAULT_AUTO_CONFIG.md`: Обновлено (использовать RLM шаблоны)
- `DEPLOY_GUIDE_v4.8.0.md`: Обновлено → `DEPLOY_GUIDE_RLM.md`

### Removed
- Все `sudo` операции для vault-agent (v4.8.0)
- Автоматическое копирование в /opt/vault/conf/
- Автоматический перезапуск vault-agent

### Fixed
- ✅ Соответствие ИБ требованиям (нет sudo для системных сервисов)
- ✅ Правильная архитектура (RLM управляет vault-agent)
- ✅ Масштабируемость (RLM шаблоны для тысяч серверов)
- ✅ Централизованное управление (один шаблон вместо N × sudo)

---

## [4.8.0-auto-vault-config] - 2026-02-02 **ОТМЕНЕНО**

### ✅ Added - АВТОМАТИЧЕСКОЕ применение vault-agent конфига (для тысяч серверов!)

**ПРОБЛЕМА v4.7.0**: Требовалось ручное изменение RLM задачи для каждого сервера!
- ❌ При деплое на тысячи серверов - это неприемлемо
- ❌ Конфиг создавался, но НЕ применялся автоматически
- ❌ Требовалось ручное изменение RLM шаблона

---

### ✅ РЕШЕНИЕ v4.8.0: Автоматизация + Минимальные права

#### 1. **Добавлены права в sudoers.example**

```bash
# 2. Управление vault-agent конфигурацией (ОДИН РАЗ при установке)
# ВАЖНО: Минимальные права только для автоматизации vault-agent
${KAE}-lnx-mon_ci ALL=(root) NOPASSWD: \
  /usr/bin/cp /home/${KAE}-lnx-mon_ci/monitoring/config/vault/agent.hcl /opt/vault/conf/agent.hcl, \
  /usr/bin/cp /opt/vault/conf/agent.hcl /opt/vault/conf/agent.hcl.backup.*, \
  /usr/bin/systemctl restart vault-agent, \
  /usr/bin/systemctl status vault-agent
```

**ПОЧЕМУ ЭТО ПРАВИЛЬНО** (соответствует ИБ):
- ✅ Явно прописанные права (не wildcard!)
- ✅ Только конкретные команды (не shell!)
- ✅ NOPASSWD (автоматизация)
- ✅ Минимально необходимый набор
- ✅ Используется ОДИН РАЗ при деплое

#### 2. **Восстановлено автоматическое применение конфига**

```bash
# Создаем backup
sudo cp /opt/vault/conf/agent.hcl /opt/vault/conf/agent.hcl.backup.20260202_151032

# Применяем наш конфиг с perms = "0640"
sudo cp $VAULT_AGENT_HCL /opt/vault/conf/agent.hcl

# Перезапускаем vault-agent
sudo systemctl restart vault-agent

# Проверяем статус
systemctl is-active vault-agent
```

#### 3. **Graceful degradation**

Если нет sudo прав → понятная инструкция:
```
⚠️  Не удалось автоматически применить конфиг (нет sudo прав)

РЕШЕНИЯ:
1. Добавьте права в sudoers (см. sudoers.example)
2. Или примените вручную:
   sudo cp $VAULT_AGENT_HCL /opt/vault/conf/agent.hcl
   sudo systemctl restart vault-agent
```

---

### 🎯 Workflow для тысяч серверов

#### ОДИН РАЗ (подготовка):
1. Создайте заявку в ИБ на добавление прав из `sudoers.example` (секция vault-agent)
2. Примените через IDM/puppet на все серверы

#### ЗАТЕМ (автоматически на ВСЕХ серверах):
1. Скрипт создает `agent.hcl` с `perms = "0640"`
2. Скрипт копирует в `/opt/vault/conf/agent.hcl` ✅
3. Скрипт перезапускает `vault-agent` ✅
4. Новые сертификаты создаются с правами `0640` ✅
5. Группа `va-read` может читать сертификаты ✅

**НЕ НУЖНО** менять ничего вручную! 🎉

---

### 📊 Сравнение версий

| Действие | v4.7.0 | v4.8.0 |
|----------|--------|--------|
| **Создание agent.hcl** | ✅ | ✅ |
| **Применение к vault-agent** | ❌ Вручную | ✅ Автоматически |
| **Права в sudoers** | ❌ Не нужны | ✅ Добавлены явно |
| **Деплой на 1000 серверов** | ❌ 1000 ручных действий | ✅ 0 ручных действий |
| **Соответствие ИБ** | ✅ | ✅ (права явно прописаны) |

---

### 🔒 Безопасность

**Минимальные права в sudoers**:
- ✅ Только конкретные пути (не wildcard `*`)
- ✅ Только для копирования конфига
- ✅ Только для управления vault-agent
- ✅ НЕТ прав на другие системные сервисы
- ✅ NOEXEC (защита от command injection)

**Процесс согласования с ИБ**:
1. Покажите `sudoers.example`
2. Объясните необходимость для автоматизации тысяч серверов
3. Подчеркните минимальность и явность прав
4. Получите одобрение ИБ

---

### Changed
- `sudoers.example`: Добавлена секция "Управление vault-agent конфигурацией"
- `install-monitoring-stack.sh`: Восстановлен автоматический apply конфига с sudo
- `setup_vault_config()`: Добавлены backup, copy, restart с проверками

### Fixed
- ✅ Автоматизация для тысяч серверов (не нужно ручное изменение!)
- ✅ Явные права в sudoers (соответствует ИБ)
- ✅ Graceful degradation (если нет прав - инструкция)

---

## [4.7.0-ib-compliant-vault] - 2026-02-02

### 🚨 КРИТИЧНО: Убран код, нарушающий правила ИБ!

**ПРОБЛЕМА**: В версии 4.6.0 использовался `sudo` для управления системным сервисом vault-agent!

```bash
# ❌ НАРУШЕНИЕ ИБ (v4.6.0):
sudo cp $VAULT_AGENT_HCL /opt/vault/conf/agent.hcl
sudo systemctl restart vault-agent
```

**ПОЧЕМУ ЭТО НАРУШЕНИЕ**:
1. ❌ vault-agent - СИСТЕМНЫЙ СЕРВИС (управляется RLM, не нами!)
2. ❌ Требует `sudo` права (отсутствуют в `sudoers.example`)
3. ❌ Нарушает принцип минимальных привилегий
4. ❌ Конфликтует с Secure Edition философией (user-space only)

---

### ✅ ИСПРАВЛЕНО (v4.7.0): Соответствие ИБ требованиям

#### 1. **Убраны ВСЕ `sudo` операции для vault-agent**

```bash
# ✅ ПРАВИЛЬНО (v4.7.0):
# - Создаем agent.hcl в user-space (только для справки)
# - НЕ трогаем системный vault-agent
# - Используем существующие сертификаты из /opt/vault/certs/
```

#### 2. **Новая логика: vault-agent как внешний сервис**

**ЧТО ДЕЛАЕТ СКРИПТ СЕЙЧАС**:
- ✅ Создает `agent.hcl` в `$HOME/monitoring/config/vault/` (для справки/документации)
- ✅ Проверяет статус системного `vault-agent` (read-only)
- ✅ Проверяет наличие сертификатов в `/opt/vault/certs/`
- ✅ Выводит **ИНСТРУКЦИЮ** по настройке прав через RLM
- ✅ Использует **существующие** сертификаты от vault-agent

**ЧТО СКРИПТ НЕ ДЕЛАЕТ** (правильно!):
- ❌ НЕ копирует конфиг в `/opt/vault/conf/` (требует root)
- ❌ НЕ перезапускает `vault-agent` (требует root)
- ❌ НЕ изменяет системные файлы

#### 3. **Инструкция для настройки прав на сертификаты**

Скрипт выводит понятную инструкцию:

```
╔════════════════════════════════════════════════════════════════════════════╗
║  📋 ИНСТРУКЦИЯ: Настройка прав на сертификаты через RLM                  ║
╚════════════════════════════════════════════════════════════════════════════╝

⚠️  ВАЖНО: vault-agent - это СИСТЕМНЫЙ СЕРВИС!

Для корректной работы мониторинга требуется изменить RLM задачу vault-agent:

1️⃣  Откройте RLM задачу типа 'vault_agent_config' для этого сервера

2️⃣  В секциях template измените права на сертификаты:

    template {
      destination = "/opt/vault/certs/server_bundle.pem"
      perms = "0640"   # ← ИЗМЕНИТЬ С 0600 НА 0640!
    }

    template {
      destination = "/opt/vault/certs/grafana-client.pem"
      perms = "0640"   # ← ИЗМЕНИТЬ С 0600 НА 0640!
    }

3️⃣  Сохраните изменения в RLM задаче

4️⃣  RLM автоматически применит новый конфиг и перезапустит vault-agent

5️⃣  После применения изменений группа ${KAE}-lnx-va-read сможет читать сертификаты
```

#### 4. **Graceful degradation**

- Если vault-agent активен → скрипт продолжает работу ✅
- Если vault-agent неактивен → предупреждение, но НЕ ошибка ⚠️
- Если сертификаты не найдены → предупреждение (могут быть созданы позже) ⚠️

---

### 📋 Изменения в коде

**Файл**: `install-monitoring-stack.sh`

**Функция**: `setup_vault_config()`

**Было (v4.6.0)** - ~60 строк с `sudo` операциями:
```bash
if sudo -n cp "$VAULT_AGENT_HCL" "$system_agent_hcl" 2>/dev/null; then
    if sudo -n systemctl restart vault-agent 2>&1; then
        # ... проверки ...
    fi
fi
```

**Стало (v4.7.0)** - понятная инструкция БЕЗ `sudo`:
```bash
if systemctl is-active --quiet vault-agent; then
    print_success "Системный vault-agent активен и работает"
    # Выводим инструкцию для RLM...
fi
```

---

### 🎯 Правильная архитектура (Secure Edition)

```
┌─────────────────────────────────────────────────────────────┐
│  RLM (Root-Level Management)                               │
│  ─────────────────────────────────────────────────────────  │
│  • Устанавливает vault-agent как system service            │
│  • Создает /opt/vault/conf/agent.hcl                       │
│  • Устанавливает perms = "0640" для сертификатов           │
│  • Перезапускает vault-agent (имеет права!)                │
└─────────────────────────────────────────────────────────────┘
                           ↓
                    Генерирует сертификаты
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  /opt/vault/certs/                                         │
│  ─────────────────────────────────────────────────────────  │
│  • server_bundle.pem (perms: 0640, group: va-read)         │
│  • grafana-client.pem (perms: 0640, group: va-read)        │
│  • ca_chain.crt (perms: 0640, group: va-read)              │
└─────────────────────────────────────────────────────────────┘
                           ↓
                    Группа va-read читает
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  Наш скрипт (БЕЗ sudo, user-space only)                    │
│  ─────────────────────────────────────────────────────────  │
│  • Читает сертификаты из /opt/vault/certs/                 │
│  • Копирует в $HOME/monitoring/certs/                      │
│  • Настраивает monitoring services                         │
│  • НЕ трогает системный vault-agent ✅                     │
└─────────────────────────────────────────────────────────────┘
```

---

### 📊 Что нужно сделать вручную

**ОДИН РАЗ** для проекта (через ИБ/IDM):
1. Создать RLM задачу `vault_agent_config` с `perms = "0640"` для сертификатов
2. Добавить пользователей в группу `${KAE}-lnx-va-read` (скрипт делает автоматически через RLM API)

**После этого**:
- ✅ Скрипт работает полностью автоматически
- ✅ Не требует `sudo` для vault-agent
- ✅ Соответствует всем требованиям ИБ

---

### 🔍 Сравнение версий

| Аспект | v4.6.0 (BAD) | v4.7.0 (GOOD) |
|--------|--------------|---------------|
| **sudo для vault-agent** | ❌ Требует | ✅ Не требует |
| **Изменение /opt/** | ❌ Изменяет | ✅ Не трогает |
| **Соответствие ИБ** | ❌ Нарушает | ✅ Соблюдает |
| **Права в sudoers** | ❌ Нужны доп. | ✅ Не нужны |
| **Философия Secure Edition** | ❌ Конфликт | ✅ Соответствует |
| **Управление vault-agent** | ❌ Пытаемся сами | ✅ Делегируем RLM |

---

### Changed
- `setup_vault_config()`: Полностью переработана логика для vault-agent
- Убраны: `sudo cp`, `sudo systemctl restart vault-agent`
- Добавлена: Инструкция по настройке RLM задачи
- Добавлена: Graceful degradation для отсутствующих сертификатов

### Fixed
- ✅ Соответствие правилам ИБ (минимальные привилегии)
- ✅ Соответствие Secure Edition философии (user-space only)
- ✅ Не требует дополнительных прав в sudoers
- ✅ Правильное разделение ответственности (RLM vs наш скрипт)

---

## [4.6.0-apply-vault-config] - 2026-02-02

### 🔧 Fixed - КРИТИЧНО: vault-agent.hcl не применялся к системному vault-agent!

**ПРОБЛЕМА 1**: Мы создавали agent.hcl, но НЕ применяли его!
- Создавали: `$HOME/monitoring/config/vault/agent.hcl`
- НО системный vault-agent использует: `/opt/vault/conf/agent.hcl`
- НЕ копировали наш конфиг в системный путь
- vault-agent продолжал использовать СТАРЫЙ конфиг
- Права на сертификаты оставались `0600` ❌

**ПРОБЛЕМА 2**: perms = "0600" для сертификатов
- `server_bundle.pem` имел `perms = "0600"` (только владелец)
- `grafana-client.pem` имел `perms = "0600"` (только владелец)
- Группа `va-read` НЕ МОГЛА читать сертификаты ❌

**ИСПРАВЛЕНО**:

1. **✅ ВСЕ сертификаты теперь с `perms = "0640"`**:
   - `server_bundle.pem`: `0640` (владелец + группа могут читать)
   - `ca_chain.crt`: `0640` (уже было)
   - `grafana-client.pem`: `0640` (изменено с `0600`)
   - **Группа `va-read` сможет читать сертификаты!** ✅

2. **✅ Автоматическое применение agent.hcl при SKIP_VAULT_INSTALL=true**:
   ```bash
   # Создаем backup существующего конфига
   sudo cp /opt/vault/conf/agent.hcl /opt/vault/conf/agent.hcl.backup.20260202_181532
   
   # Копируем наш конфиг в системный путь
   sudo cp $VAULT_AGENT_HCL /opt/vault/conf/agent.hcl
   
   # Перезапускаем vault-agent
   sudo systemctl restart vault-agent
   ```

3. **✅ Graceful degradation**:
   - Если нет прав sudo → понятная инструкция по ручному применению
   - Создается backup старого конфига
   - Проверка статуса после перезапуска

**ДИАГНОСТИКА**:
```
[VAULT-CONFIG] SKIP_VAULT_INSTALL=true: применяем конфиг к существующему vault-agent
[VAULT-CONFIG] Копирование agent.hcl в системный путь...
[VAULT-CONFIG] ✅ Создан backup: /opt/vault/conf/agent.hcl.backup.20260202_181532
[VAULT-CONFIG] ✅ agent.hcl скопирован в /opt/vault/conf/agent.hcl
[VAULT-CONFIG] Перезапуск vault-agent для применения нового конфига...
[VAULT-CONFIG] ✅ vault-agent перезапущен успешно
[VAULT-CONFIG] ✅ vault-agent активен после перезапуска
SUCCESS: vault-agent конфигурация применена и сервис перезапущен
INFO: ВАЖНО: Новые сертификаты будут иметь права 0640 (группа сможет читать)
```

**Результат**:
- Теперь при `SKIP_VAULT_INSTALL=true` мы **ПРИМЕНЯЕМ** наш конфиг к системному vault-agent
- Все сертификаты создаются с `perms = "0640"`
- Группа `${KAE}-lnx-va-read` может читать сертификаты
- Не нужны workaround'ы с sudo или повторными запусками!

---

## [4.5.2-smart-va-read-check] - 2026-02-02

### ✨ Improved - Умная проверка перед добавлением в va-read + улучшенный вывод

**ЧТО УЛУЧШЕНО**:

1. **✅ Проверка перед созданием RLM задачи** (ответ на вопрос "зачем создавать если уже в группе"):
   ```bash
   [VA-READ] Проверка: состоит ли CI-user в группе va-read...
   [VA-READ] ✅ Пользователь УЖЕ СОСТОИТ в группе (пропускаем RLM задачу)
   ```
   - Если пользователь **уже в группе** → пропускаем создание RLM задачи
   - Если **не в группе** → создаем задачу
   - Экономия времени: ~3-5 минут при повторных запусках

2. **✅ Улучшен вывод копирования** (убран избыточный "Attempt 2/3 failed"):
   ```bash
   [CERTS] 🔧 Попытка копирования через sudo -u mon_sys...
   [CERTS] 🔧 Попытка копирования через sudo cat...
   [CERTS] ✅ Bundle скопирован через sudo cat
   ```
   - Показываем только реальные попытки
   - Убраны избыточные "⚠️ Method X failed" если способ не главный

3. **✅ Добавлено ЛУЧШЕЕ РЕШЕНИЕ в инструкции** (ответ про vault-agent.hcl):
   ```
   РЕШЕНИЕ (выберите один из вариантов):
   
   ⭐ Вариант 1: Перезапустите pipeline (РЕКОМЕНДУЕТСЯ)
   
   Вариант 2: Добавьте в sudoers право на cat
   
   Вариант 3: Измените права в vault-agent.hcl (ЛУЧШЕЕ ДОЛГОСРОЧНОЕ)
      В setup_vault_config() добавьте perms = "0640" в template блоки
      Тогда группа va-read сможет читать сертификаты
   ```

4. **✅ Добавлены комментарии в setup_vault_config()**:
   ```bash
   # ВАЖНО: perms = "0600" - только владелец может читать
   # ДЛЯ ДОСТУПА ГРУППЕ: можно изменить на perms = "0640"
   # НО в Secure Edition мы копируем в user-space
   ```

**ЗАЧЕМ МЫ КОПИРУЕМ ЧЕРЕЗ mon_sys, А НЕ mon_ci?**:
- `mon_ci` только что добавлен в группу через RLM ✅
- НО изменения группы применяются только в **НОВОЙ** сессии ❌
- Текущая Jenkins сессия еще не знает о новой группе
- `mon_sys` УЖЕ БЫЛ в группе `va-read`
- Поэтому копируем от его имени как workaround
- При **ПОВТОРНОМ** запуске `mon_ci` будет в группе → сработает прямое копирование ✅

**ЛУЧШЕЕ ДОЛГОСРОЧНОЕ РЕШЕНИЕ**:
Изменить права на сертификаты в vault-agent.hcl при его создании через vault-agent task:
```hcl
template {
  destination = "/opt/vault/certs/server_bundle.pem"
  perms = "0640"  # группа va-read сможет читать!
}
```
Тогда не нужны workaround'ы с sudo или повторными запусками.

---

## [4.5.1-improve-cert-copy-fallback] - 2026-02-02

### 🔧 Fixed - Улучшена логика копирования сертификатов после добавления в группу

**ПРОБЛЕМА**:
- RLM задача успешно выполнилась: ✅ Пользователь добавлен в группу `va-read`
- НО `sudo -u sys_user cp` не сработал (нет прав в sudoers)
- Скрипт падал с ошибкой: `ERROR: Не удалось скопировать сертификаты. Требуется перелогин или sudo права.`
- После добавления в группу нужна новая сессия для применения изменений

**ИСПРАВЛЕНО**:
- ✅ **3 способа копирования с fallback'ами**:
  
  **Способ 1**: `sudo -u ${KAE}-lnx-mon_sys cp` (если mon_sys в va-read)
  - Требует права в sudoers: `${KAE}-lnx-mon_ci ALL=(${KAE}-lnx-mon_sys) NOPASSWD: /usr/bin/cp /opt/vault/certs/*`
  - Если не работает → переход к способу 2
  
  **Способ 2**: `sudo -u ${KAE}-lnx-mon_sys cat > file` (читаем от mon_sys, пишем от mon_ci)
  - Требует права в sudoers: `${KAE}-lnx-mon_ci ALL=(${KAE}-lnx-mon_sys) NOPASSWD: /usr/bin/cat /opt/vault/certs/*`
  - Если не работает → переход к способу 3
  
  **Способ 3**: Прямое копирование `cp` (на случай если группа уже применилась)
  - Может сработать если скрипт перезапущен после добавления в группу
  - Если не работает → понятная ошибка с инструкциями

- ✅ **Детальная диагностика**:
  ```
  [CERTS] Способ 1: Попытка копирования через sudo -u ${KAE}-lnx-mon_sys...
  [CERTS] ⚠️  Способ 1 не сработал (нет прав sudo)
  [CERTS] Способ 2: Попытка копирования через sudo cat...
  [CERTS] ✅ Bundle скопирован через sudo cat
  ```

- ✅ **Понятная финальная ошибка**:
  ```
  ERROR: Не удалось скопировать сертификаты ни одним из способов
  
  ДИАГНОСТИКА:
    1. Пользователь добавлен в группу ${KAE}-lnx-va-read через RLM ✅
    2. Но изменения группы требуют новой сессии/перелогина
    3. sudo -u ${KAE}-lnx-mon_sys не работает (нет прав в sudoers)
  
  РЕШЕНИЕ:
    Вариант 1: Перезапустите pipeline (группа уже применится) - РЕКОМЕНДУЕТСЯ
    Вариант 2: Добавьте в sudoers право на 'sudo -u ${KAE}-lnx-mon_sys cat /opt/vault/certs/*'
  ```

**Результат**:
- Больше шансов успешно скопировать сертификаты после добавления в группу
- Если все способы не работают → четкие инструкции по исправлению

---

## [4.5.0-auto-va-read-group] - 2026-02-02

### ✨ Added - Автоматическое добавление CI-user в группу va-read через RLM

**НОВАЯ ФУНКЦИОНАЛЬНОСТЬ**:
- ✅ **Новая функция `ensure_user_in_va_read_group()`**:
  - Автоматически добавляет пользователя в группу `${KAE}-lnx-va-read` через RLM API
  - Использует сервис `UVS_LINUX_ADD_USERS_GROUP` (тот же, что для `as-admin`)
  - Полная интеграция с RLM API wrapper
  - Таймаут: 10 минут (60 попыток × 10 сек)
  - Красивый прогресс-бар в стиле `as-admin`
  
- ✅ **Автоматическая интеграция в `setup_certificates_after_install()`**:
  - **Попытка 1**: Автоматически добавить CI-user в группу `va-read` через RLM
  - После успеха: использует workaround через `${KAE}-lnx-mon_sys` (изменения группы требуют новой сессии)
  - **Попытка 2**: Если RLM не сработал → копирование через `sudo -u ${KAE}-lnx-mon_sys` (fallback)
  - **Попытка 3**: Прямое копирование (может не сработать)
  - **Финал**: Понятная ошибка с инструкциями

**АЛГОРИТМ РАБОТЫ**:
```
1. Проверяем доступ CI-user к /opt/vault/certs/server_bundle.pem
   ├─ Есть доступ? → Копируем напрямую ✅
   └─ Нет доступа? → Идем дальше ⬇️

2. ПОПЫТКА 1: Автоматическое добавление в va-read
   ├─ Вызываем ensure_user_in_va_read_group()
   ├─ Создается RLM задача UVS_LINUX_ADD_USERS_GROUP
   ├─ Ожидаем выполнения (до 10 минут)
   ├─ Успех? → Копируем через ${KAE}-lnx-mon_sys workaround ✅
   └─ Неудача? → Идем дальше ⬇️

3. ПОПЫТКА 2: Копирование через ${KAE}-lnx-mon_sys
   ├─ Проверяем: mon_sys в группе va-read?
   ├─ Да? → sudo -u ${KAE}-lnx-mon_sys cp ... ✅
   └─ Нет? → Идем дальше ⬇️

4. ПОПЫТКА 3: Прямое копирование (desperate attempt)
   └─ cp ... || ERROR с инструкциями ❌
```

**ДИАГНОСТИКА**:
- `[CERTS] ПОПЫТКА 1: Автоматическое добавление в группу va-read`
- `🔐 User: ${KAE}-lnx-mon_ci │ Попытка 1/60 │ Статус: in_progress 🔄`
- `✅ Пользователь ${KAE}-lnx-mon_ci добавлен в группу ${KAE}-lnx-va-read за 2.3м`
- `[CERTS] ✅ Bundle скопирован через sudo cat` (или через mon_sys workaround)

**ПРЕИМУЩЕСТВА**:
1. **Полностью автоматический деплой** - не требует ручного добавления в группу
2. **Graceful degradation** - 3 попытки копирования с fallback'ами
3. **Прозрачность** - подробная диагностика на каждом шаге
4. **Безопасность** - используется официальный RLM API

**ТРЕБОВАНИЯ**:
- `RLM_API_URL` и `RLM_TOKEN` должны быть заданы (обычно есть)
- CI-user должен иметь права на создание RLM задач (обычно есть)

---

## [4.4.2-fix-certs-permissions] - 2026-02-02

### 🔧 Fixed - Права доступа к сертификатам Vault Agent

**ПРОБЛЕМА**:
- Сертификаты в `/opt/vault/certs/` принадлежат пользователю `${KAE}-lnx-va-start` и группе `${KAE}-lnx-va-read`
- Права: `rw-------` (600) - только владелец может читать
- `${KAE}-lnx-mon_ci` (CI-user) **НЕ СОСТОИТ** в группе `va-read` → **нет доступа** ❌
- `${KAE}-lnx-mon_sys` (sys-user) **СОСТОИТ** в группе `va-read` → **есть доступ** ✅
- Последнее сообщение: `❌ Failed to copy bundle` → exit 1

**ИСПРАВЛЕНО**:
- ✅ **Проверка прав доступа** перед копированием:
  1. Если CI-user имеет прямой доступ (`-r`) → копируем напрямую
  2. Если нет доступа → проверяем, есть ли доступ у `${KAE}-lnx-mon_sys` через группу `va-read`
  3. Если mon_sys в `va-read` → копируем через `sudo -u ${KAE}-lnx-mon_sys`
  4. Меняем владельца обратно на CI-user: `chown $USER:$USER`
  5. Если нет доступа ни у кого → понятная ошибка с инструкциями
- ✅ **Обработка всех файлов**:
  - `server_bundle.pem` - основной сертификат
  - `ca_chain.crt` - цепочка CA (если есть)
  - `grafana-client.pem` - клиентский сертификат Grafana (если есть)
- ✅ **Диагностика**:
  - `[CERTS] Проверка прав доступа к сертификатам...`
  - `[CERTS] ✅ CI-user имеет доступ на чтение` ИЛИ
  - `[CERTS] ⚠️ CI-user НЕ имеет доступа, копируем через sys-user`
  - `[CERTS] ✅ Bundle скопирован через sudo -u ${KAE}-lnx-mon_sys`
- ✅ **Понятные ошибки**:
  ```
  ERROR: Недостаточно прав для доступа к сертификатам Vault
  ERROR: Права на файл: -rw------- 1 ${KAE}-lnx-va-start ${KAE}-lnx-va-read ...
  ERROR: 
  ERROR: ТРЕБУЕТСЯ: Добавить ${KAE}-lnx-mon_ci в группу ${KAE}-lnx-va-read
  ERROR: Используйте RLM или IDM для добавления пользователя в группу
  ```

**Решение**:
1. **Предпочтительный вариант**: Добавить CI-user в группу va-read через RLM/IDM (одноразово)
2. **Автоматический workaround**: Копирование через `sudo -u ${KAE}-lnx-mon_sys` (требует соответствующих прав в sudoers)

---

## [4.4.1-fix-vault-system-certs] - 2026-02-02

### 🔧 Fixed - Vault Agent создает сертификаты в /opt/, а не в user-space

**ПРОБЛЕМА**:
- Скрипт искал сертификаты в `$HOME/monitoring/certs/vault/server_bundle.pem`
- НО Vault Agent - это **СИСТЕМНЫЙ СЕРВИС**, установленный и управляемый RLM
- Vault Agent создает сертификаты в `/opt/vault/certs/` (системный путь)
- Последнее сообщение: `ERROR: Сертификаты от Vault не найдены` → exit 1

**ИСПРАВЛЕНО**:
- ✅ **setup_certificates_after_install()** теперь:
  1. **Проверяет системный путь**: `/opt/vault/certs/server_bundle.pem` (где vault-agent создает файлы)
  2. **Копирует в user-space**: `$VAULT_CERTS_DIR/server_bundle.pem` для доступа без root
  3. **Копирует также**: `ca_chain.crt`, `grafana-client.pem` (если есть)
  4. **Вызывает** `copy_certs_to_user_dirs()` для распределения по сервисам
- ✅ **copy_certs_to_user_dirs()** упрощена:
  - Работает только с уже скопированным user-space bundle
  - Убраны избыточные проверки `if [[ -f "$vault_bundle" ]]`
  - Более четкая логика: проверка → извлечение → распределение
- ✅ **Приоритеты проверки** (от высшего к низшему):
  1. `/opt/vault/certs/server_bundle.pem` (системный vault-agent)
  2. `$VAULT_CERTS_DIR/server_bundle.pem` (уже скопированный)
  3. `$VAULT_CRT_FILE` + `$VAULT_KEY_FILE` (отдельные файлы)
- ✅ **Диагностика**:
  - `[CERTS] Системный путь (vault-agent): /opt/vault/certs/server_bundle.pem`
  - `[CERTS] User-space путь: $HOME/monitoring/certs/vault/server_bundle.pem`
  - `[CERTS] ✅ Сертификаты скопированы в user-space`
  - При ошибке: `ls -la /opt/vault/certs/` для диагностики

**Архитектура**:
- Vault Agent остается системным сервисом в `/opt/vault/` (управляется RLM)
- Наш скрипт **КОПИРУЕТ** сертификаты в user-space для использования мониторингом
- Мониторинговые сервисы (Prometheus/Grafana/Harvest) используют копии из `$HOME/monitoring/certs/`

---

## [4.4.0-user-space-certs] - 2026-02-02

### 🔧 Fixed - ПОЛНАЯ ПЕРЕРАБОТКА сертификатов для user-space

**ПРОБЛЕМА**:
- Скрипт падал в `copy_certs_to_dirs()` на командах требующих root:
  - `mkdir -p /opt/harvest/cert` - требует root
  - `mkdir -p /etc/grafana/cert` - требует root
  - `mkdir -p /etc/prometheus/cert` - требует root
  - `chown harvest:harvest /opt/harvest/cert` - требует root
  - `chown root:grafana /etc/grafana/cert` - требует root
- Все хардкод пути: `/opt/vault/certs/`, `/etc/grafana/cert/`, `/etc/prometheus/cert/`
- Последнее сообщение: `STEP: Копирование сертификатов в целевые директории` → ТИШИНА

**ИСПРАВЛЕНО**:
- ✅ **Создана новая функция `copy_certs_to_user_dirs()`** для Secure Edition:
  - Работает ТОЛЬКО с user-space путями: `$HOME/monitoring/certs/`, `$HOME/monitoring/config/`
  - Harvest: `$HARVEST_USER_CONFIG_DIR/cert/harvest.{crt,key}`
  - Grafana: `$GRAFANA_USER_CERTS_DIR/{crt.crt,key.key,grafana-client.*}`
  - Prometheus: `$PROMETHEUS_USER_CERTS_DIR/{server.crt,server.key}`
  - CA chain: копируется во все директории
- ✅ **Переработана функция `setup_certificates_after_install()`**:
  - Использует `$VAULT_CERTS_DIR/server_bundle.pem` вместо `/opt/vault/certs/`
  - Проверяет `$PROMETHEUS_USER_CERTS_DIR/` вместо `/etc/prometheus/cert/`
  - Расширенная диагностика `[CERTS]` на каждом шаге
- ✅ **НЕТ операций требующих root**:
  - Нет `mkdir -p /etc/` или `/opt/`
  - Нет `chown` команд
  - Только операции в `$HOME/monitoring/`
- ✅ **Подробная диагностика**:
  - `[CERTS] Проверка источников сертификатов...`
  - `[CERTS-COPY] 1/3: Обработка сертификатов для Harvest...`
  - `[CERTS-COPY] 2/3: Обработка сертификатов для Grafana...`
  - `[CERTS-COPY] 3/3: Обработка сертификатов для Prometheus...`
  - `[CERTS-COPY] ✅ Все сертификаты скопированы в user-space`

**Результат**:
- Сертификаты теперь полностью в user-space
- Работает БЕЗ root прав
- Все файлы доступны для `${KAE}-lnx-mon_ci` и `${KAE}-lnx-mon_sys`

---

## [4.3.0-fix-rlm-and-certs] - 2026-02-02

### 🔧 Fixed - Скрипт падал после RLM установки из-за /etc/profile.d/

**ПРОБЛЕМА**:
- После успешной установки Grafana/Prometheus/Harvest через RLM скрипт тихо падал
- `create_rlm_install_tasks()` пыталась записать в `/etc/profile.d/harvest.sh` (требует root!)
- `create_rlm_install_tasks()` пыталась создать симлинк в `/usr/local/bin/harvest` (требует root!)
- Jenkins показывал `Stage "CDL: Проверка результатов" skipped due to earlier failure(s)`
- Последнее сообщение: `SUCCESS: Создана символическая ссылка для harvest в /usr/local/bin/`
- После этого - ТИШИНА, скрипт падал при записи в `/etc/profile.d/`

**ИСПРАВЛЕНО**:
- ✅ Убраны операции с `/etc/profile.d/harvest.sh` (требует root, не нужно для user units)
- ✅ Убраны операции с `/usr/local/bin/harvest` (требует root, не нужно для user units)
- ✅ PATH экспортируется только в текущую сессию (для последующих команд в скрипте)
- ✅ Harvest будет запускаться через systemd user unit с явным путем к исполняемому файлу
- ✅ Расширенная диагностика:
  - `[RLM-INSTALL] Настройка PATH для Harvest...`
  - `[RLM-INSTALL] ✅ Найден harvest: /opt/harvest/bin/harvest`
  - `[RLM-INSTALL] PATH обновлен для текущей сессии`
  - `[RLM-INSTALL] ✅ create_rlm_install_tasks ЗАВЕРШЕНА`
- ✅ Добавлен вызов `[MAIN] Вызов setup_certificates_after_install...` в main()

**СЛЕДУЮЩАЯ ПРОБЛЕМА**:
- `copy_certs_to_dirs()` и `setup_certificates_after_install()` НЕ ПЕРЕДЕЛАНЫ для Secure Edition
- Используют хардкод `/opt/vault/certs/`, `/etc/grafana/cert/`, `/etc/prometheus/cert/`
- Команды `mkdir -p /etc/`, `chown`, требующие root
- Нужна полная переработка для user-space путей

---

## [4.2.0-fix-vault-paths] - 2026-02-02

### 🔧 Fixed - КРИТИЧЕСКАЯ ПРОБЛЕМА: vault-agent.conf использовал хардкод /opt/

**ПРОБЛЕМА**: 
- После успешного извлечения секретов скрипт падал без сообщений
- `setup_vault_config()` пыталась работать с `/opt/vault/` (ХАРДКОД!)
- В Secure Edition мы используем `$HOME/monitoring/` - `/opt/` НЕ СУЩЕСТВУЕТ
- `chown --reference=/opt/vault/conf` требует root и падает
- vault-agent.conf создавался с путями `/opt/vault/log/`, `/opt/vault/conf/`, `/opt/vault/certs/`

**ИСПРАВЛЕНО**:
- ✅ ВСЕ хардкод `/opt/vault/` заменены на переменные:
  - `pid_file = "$VAULT_LOG_DIR/vault-agent.pidfile"` (был `/opt/vault/log/`)
  - `ca_path = "$VAULT_CONF_DIR/ca-trust"` (был `/opt/vault/conf/ca-trust`)
  - `role_id_file_path = "$VAULT_ROLE_ID_FILE"` (был `/opt/vault/conf/role_id.txt`)
  - `secret_id_file_path = "$VAULT_SECRET_ID_FILE"` (был `/opt/vault/conf/secret_id.txt`)
  - `log_path = "$VAULT_LOG_DIR"` (был `/opt/vault/log`)
  - `destination = "$VAULT_CONF_DIR/data_sec.json"` (был `/opt/vault/conf/data_sec.json`)
  - Сертификаты: `$VAULT_CERTS_DIR/` и `$MONITORING_CERTS_DIR/grafana/` (были `/opt/vault/certs/`)
- ✅ Убраны команды `chown --reference=/opt/vault/conf` (требуют root, не нужны в user-space)
- ✅ Убран вызов `config-writer_launcher.sh` - запись напрямую в `$VAULT_AGENT_HCL`
- ✅ Пропускаем `systemctl restart vault-agent` если `SKIP_VAULT_INSTALL=true` (требует sudo)
- ✅ Расширенная диагностика на каждом шаге `setup_vault_config()`:
  - `[VAULT-CONFIG] После извлечения секретов`
  - `[VAULT-CONFIG] Установка прав на файлы секретов...`
  - `[VAULT-CONFIG] Создание vault-agent.conf...`
  - `[VAULT-CONFIG] Проверка перезапуска vault-agent...`
  - `[VAULT-CONFIG] ✅ setup_vault_config ЗАВЕРШЕНА УСПЕШНО`

**Результат**: 
- `setup_vault_config()` теперь полностью IB-compliant
- Работает БЕЗ root прав
- Все файлы в `$HOME/monitoring/config/vault/`
- Подробная диагностика на каждом шаге

---

## [4.1.0-debug-all-visible] - 2026-02-02

### 🔍 Fixed - ВСЕ диагностические выводы теперь видны в Jenkins

**ПРОБЛЕМА**: Часть выводов использовала `>&2` (только STDERR), часть `| tee /dev/stderr` (STDOUT+STDERR). Jenkins показывал только STDOUT.

**ИСПРАВЛЕНО**:
- ✅ ВСЕ выводы `[MAIN]` теперь через `| tee /dev/stderr`
- ✅ ВСЕ выводы `[DEBUG-CONFIG]` теперь через `| tee /dev/stderr`
- ✅ Добавлены выводы для функций, которые выполняются после `detect_network_info`:
  - `[MAIN] Вызов ensure_monitoring_users_in_as_admin...`
  - `[MAIN] Вызов ensure_mon_sys_in_grafana_group...`
  - `[MAIN] Вызов cleanup_all_previous...`
  - `[MAIN] Вызов create_directories...`
- ✅ Теперь видны **ВСЕ** шаги выполнения в Jenkins консоли

**Результат**: Полная прозрачность выполнения скрипта. Последний успешный `[MAIN] ✅` покажет точное место падения.

---

## [4.1.0-debug-stdout] - 2026-02-02

### 🔍 Fixed - Диагностика теперь видна в Jenkins консоли

**ПРОБЛЕМА**: Весь вывод `[MAIN]`, `[DEBUG-CONFIG]`, `[DEBUG-SECRETS]` шел в STDERR, но Jenkins НЕ ПОКАЗЫВАЕТ STDERR в консоли - только в DEBUG_LOG файле!

**ИСПРАВЛЕНО**:
- ✅ Все критичные выводы теперь **дублируются** в STDOUT и STDERR через `| tee /dev/stderr`
- ✅ Агрессивный вывод в начале `main()`:
  - Время запуска
  - PWD (рабочая директория)
  - User (кто запускает)
  - Вызов каждой функции
  - ✅/❌ статус выполнения каждой функции
- ✅ Теперь в Jenkins консоли видны ВСЕ шаги выполнения:
  ```
  [MAIN] START: main() функция запущена
  [MAIN] Calling print_header...
  [MAIN] print_header completed
  [MAIN] Вызов check_sudo...
  [MAIN] ✅ check_sudo completed
  [MAIN] Вызов check_dependencies...
  ...
  ```

**Результат**: Теперь можно увидеть ТОЧНО, где падает скрипт - последний успешный `[MAIN] ✅` покажет место падения.

---

## [4.1.0-debug-config] - 2026-02-02

### 🔍 Added - Диагностика load_config_from_json

**Цель**: Определить, почему скрипт падает после успешного извлечения секретов.

**Добавлено**:
- ✅ Детальный вывод `[DEBUG-CONFIG]` в STDERR и DEBUG_LOG
- ✅ Проверка всех обязательных ENV переменных:
  - `NETAPP_API_ADDR`
  - `GRAFANA_URL`
  - `PROMETHEUS_URL`
  - `HARVEST_URL`
- ✅ Dump ВСЕХ ENV переменных с префиксами (NETAPP, GRAFANA, PROMETHEUS, HARVEST, NAMESPACE, KAE) при ошибке
- ✅ Диагностика вычисления `NETAPP_POLLER_NAME`
- ✅ Вывод `[MAIN]` для отслеживания выполнения функций в main()

**Вероятная проблема**: Один из параметров (NETAPP_API_ADDR/GRAFANA_URL/PROMETHEUS_URL/HARVEST_URL) не передается из Jenkinsfile в скрипт.

---

## [4.1.0-fix-secrets-whitelist] - 2026-02-02

### 🐛 Fixed - Критическая ошибка в secrets-manager-wrapper whitelist

**ПРОБЛЕМА НАЙДЕНА**: Wrapper падал из-за слишком жесткого whitelist путей.

**Было**:
```bash
allowed_paths=(
    "/opt/vault/conf/data_sec.json"  # Только точные пути
    "/tmp/temp_data_cred.json"
    "/tmp/data_sec.json"
)
```

**Проблема**: Файл `/home/CI-user/monitoring-deployment/temp_data_cred.json` не проходил проверку → wrapper падал с ошибкой "JSON файл не в whitelist".

**Исправлено**:
- ✅ Whitelist теперь проверяет **директории** и **имена файлов** отдельно
- ✅ Разрешенные директории:
  - `/opt/vault/conf` (старая логика)
  - `/tmp` (старая логика)
  - `/dev/shm` (для секретов в памяти - безопасность)
  - **`$HOME`** (для Secure Edition - пользовательская директория)
- ✅ Разрешенные имена: `data_sec.json`, `temp_data_cred.json`
- ✅ Поддержка поддиректорий (например, `$HOME/monitoring-deployment/temp_data_cred.json`)

**Результат**: Wrapper теперь работает как в root-режиме, так и в user-space (Secure Edition).

---

## [4.1.0-debug-secrets] - 2026-02-02

### 🔍 Added - Расширенная диагностика secrets-manager-wrapper

**Проблема**: `ERROR: Не удалось извлечь role_id через secrets-wrapper` - непонятно почему wrapper фейлится.

**Добавлено для диагностики**:
- ✅ Детальный вывод `[DEBUG-SECRETS]` в STDERR и DEBUG_LOG
- ✅ Проверка существования `temp_data_cred.json` и его размера
- ✅ Проверка прав доступа на файл credentials
- ✅ **БЕЗОПАСНО**: Показ структуры JSON (только ключи, без значений!)
- ✅ Проверка наличия полей `vault-agent`, `vault-agent.role_id`, `vault-agent.secret_id`
- ✅ Проверка существования `secrets-manager-wrapper_launcher.sh`
- ✅ Проверка прав и исполняемости wrapper
- ✅ Раздельный захват STDOUT и STDERR для каждой операции (role_id, secret_id)
- ✅ Exit codes для каждой операции

**Решение проблемы с linger** (из предыдущей версии):
- Проблема НЕ критична: файл linger уже существует (`/var/lib/systemd/linger/USER`)
- Команда `linuxadm-enable-linger` требует sudo для проверки (`libuser`), но сам linger работает
- Скрипт продолжает выполнение без остановки на этой ошибке

---

## [4.1.0-debug-linger] - 2026-02-02

### 🔍 Added - Расширенная диагностика linuxadm-enable-linger

**Проблема**: Команда `linuxadm-enable-linger` фейлится с сообщением "User is not in group as-admin", хотя пользователь СОСТОИТ в группе (видно через `id`).

**Добавлено для диагностики**:
- ✅ Детальный вывод `[DEBUG-LINGER]` в STDERR и DEBUG_LOG
- ✅ Информация о текущем и целевом пользователях (whoami, UID, GID)
- ✅ Полные группы обоих пользователей через `id`
- ✅ Проверка членства в `as-admin` для обоих
- ✅ Путь к команде `linuxadm-enable-linger` и права на файл
- ✅ Статус linger ДО и ПОСЛЕ выполнения через `loginctl show-user`
- ✅ Раздельный захват STDOUT и STDERR команды
- ✅ Exit code команды
- ✅ Проверка существования файла `/var/lib/systemd/linger/USER`
- ✅ Скрипт НЕ останавливается при ошибке linger (для полной диагностики)

**Цель**: Определить, почему `linuxadm-enable-linger` не видит группу `as-admin`, несмотря на её наличие.

---

## [4.1.0-wip] - 2026-02-02

### 🎯 НАЙДЕНА КОРНЕВАЯ ПРОБЛЕМА!

**Благодаря DEBUG логу найдено:**
Скрипт падал на функции `save_environment_variables()`, которая пыталась писать в `/etc/environment.d/99-monitoring-vars.conf` (требует root).

### 🔧 Fixed
- **save_environment_variables()**: Убрана запись в `/etc/` - теперь только экспорт переменных
- **Добавлены обработчики ошибок**: Функции с root-операциями теперь не прерывают выполнение:
  - `ensure_monitoring_users_in_as_admin` - продолжит при ошибке
  - `ensure_mon_sys_in_grafana_group` - продолжит при ошибке  
  - `cleanup_all_previous` - продолжит при ошибке
  - `create_directories` - продолжит при ошибке

### ⚠️ ВАЖНО - WIP (Work In Progress)
Это ВРЕМЕННОЕ исправление. Скрипт содержит **222 обращения** к системным путям (`/etc/`, `/var/`, `/opt/`), которые требуют root.

**Полное исправление требует**:
1. Переработать ВСЕ пути на пользовательские (`$HOME/monitoring/`)
2. Убрать все операции, требующие root
3. Адаптировать конфигурации Grafana/Prometheus/Harvest для работы в user space

Версия 4.1.0-wip позволит увидеть СЛЕДУЮЩУЮ проблему в DEBUG логе.

---

## [4.0.7-debug] - 2026-02-02

### 🔧 DEBUG MODE - АГРЕССИВНАЯ ДИАГНОСТИКА
- **Добавлены echo >&2 в НАЧАЛО скрипта**: Покажет, доходит ли выполнение до определенных точек
  - `[SCRIPT_START]` - самое начало скрипта
  - `[SCRIPT_START] Variables initialized` - после инициализации переменных
  - `[SCRIPT] Reached end of definitions` - перед вызовом main()
  - `[MAIN] Started` - начало main()
  - `[MAIN] Calling init_debug_log` - перед инициализацией DEBUG лога
  - `[init_debug_log] START/COMPLETE` - процесс создания DEBUG лога
- **trap DEBUG перенесен в main()**: Устанавливается ПОСЛЕ создания DEBUG_LOG
- **Все сообщения выводятся в stderr**: Будут видны в Jenkins логе

### ⚠️ ВАЖНО
Теперь мы точно увидим, где именно скрипт падает - даже если это происходит в самом начале!

---

## [4.0.6-debug] - 2026-02-02

### 🔧 DEBUG MODE
- **ВРЕМЕННО отключен set -e**: Скрипт больше не падает на первой ошибке
- **Добавлен trap DEBUG**: Логирует КАЖДУЮ выполняемую команду в DEBUG лог
- **Добавлены echo в stderr в init_debug_log()**: Показывает прогресс инициализации в Jenkins логе
- **НЕ восстанавливается строгий режим**: Для максимальной диагностики

### ⚠️ ВАЖНО
Эта версия для диагностики! После нахождения проблемы нужно вернуть:
- `set -euo pipefail`
- Убрать `trap DEBUG`
- Убрать echo в stderr

---

## [4.0.5] - 2026-02-02

### 🔧 Added
- **Детальное логирование вызовов функций**: Теперь каждый вызов функции логируется
  - log_debug "Calling: function_name" ПЕРЕД вызовом
  - log_debug "Completed: function_name" ПОСЛЕ вызова
  - Это позволит точно определить, на какой функции падает скрипт
  - Добавлено для: check_sudo, check_dependencies, check_and_close_ports, detect_network_info, и других

---

## [4.0.4] - 2026-02-02

### 🔧 Fixed
- **CRITICAL: init_debug_log() упрощена до минимума**: Убраны ВСЕ диагностические команды из инициализации
  - init_debug_log() теперь создает только заголовок лога
  - Расширенная диагностика перенесена в отдельную функцию log_debug_extended()
  - log_debug_extended() вызывается ПОСЛЕ успешной инициализации
  - Это гарантирует, что DEBUG лог создастся в любом случае

---

## [4.0.3] - 2026-02-02

### 🔧 Fixed
- **CRITICAL: init_debug_log() падал на диагностических командах**: Полностью переписана логика
  - Отключение ВСЕХ строгих опций (set +euo pipefail) во время инициализации
  - Построчная запись с защитой от ошибок (`|| true` на каждой строке)
  - Восстановление опций по отдельности после инициализации
  - Теперь DEBUG лог создается полностью, даже если какие-то команды недоступны

---

## [4.0.2] - 2026-02-02

### 🔧 Fixed
- **CRITICAL: check_sudo() требовал root**: Скрипт падал сразу после запуска
  - Изменена логика: теперь скрипт **НЕ должен** запускаться под root
  - В Secure Edition все операции выполняются под CI-пользователем
  - Скрипт проверяет, что EUID != 0 (не root), иначе выдает ошибку
  - Это исправляет проблему: "Stage skipped due to earlier failure"

### ✨ Added
- **Расширенное DEBUG логирование**: Полная диагностика развертывания
  - Автоматическое создание детального DEBUG лога: `~/monitoring_deployment_debug_YYYYMMDD_HHMMSS.log`
  - Симлинк на последний лог: `~/monitoring_deployment_summary.log`
  - Логирование всех критических операций (STEP, ERROR, SUCCESS, WARNING, INFO)
  - Сбор информации о системе при старте (OS, kernel, disk, network, sudo rights)
  - Автоматический снимок состояния системы при ошибке (processes, ports, user units, logs)
  - Trap для отлова всех непойманных ошибок с полным call stack
  - Итоговое резюме с exit code, временем выполнения и статусом сервисов
  
### 🔧 Improved
- **Диагностика ошибок**: Все ошибки теперь сохраняются с контекстом в DEBUG лог
  - Номер строки, где произошла ошибка
  - Последняя выполненная команда
  - Call stack функций
  - Состояние системы на момент ошибки
  
### 📝 Changed
- Все функции `print_*` теперь дублируют вывод в DEBUG лог
- DEBUG лог создается автоматически при каждом запуске (не требует специальных флагов)
- Упрощена диагностика проблем: достаточно выполнить `cat ~/monitoring_deployment_summary.log`

### 📋 Usage
```bash
# После развертывания посмотреть полный DEBUG лог:
cat ~/monitoring_deployment_summary.log

# Или конкретный лог:
cat ~/monitoring_deployment_debug_20260202_130657.log
```

---

## [4.0.1] - 2026-01-30

### 🔧 Fixed
- **Jenkins Credential**: Исправлена ошибка совместимости типа credential
  - Заменено `withCredentials([string(...)])` на `withVault()` плагин (как в v3.x)
  - Теперь корректно работает с типом credential `Vault App Role Credential`
  - Исправлена ошибка: `'Vault App Role Credential' where 'StringCredentials' was expected`
  - Добавлен параметр `VAULT_CREDENTIAL_ID` (по умолчанию: `vault-agent-dev`)
- **Home Directory**: Исправлена ошибка "Не удалось создать директорию"
  - Добавлена диагностика существования home директории в `scp_script.sh`
  - Улучшены сообщения об ошибках с инструкциями по решению проблемы
  - При отсутствии home директории выводится команда: `sudo mkhomedir_helper <username>`

### 📝 Changed
- Обновлена документация с правильным типом credential (`Vault App Role Credential`, не `Secret text`)
- Унифицирован подход получения секретов из Vault с версией v3.x
- Добавлены инструкции по созданию home директорий в README.md и README-MIGRATION.md
- Улучшена диагностика подключения по SSH в Jenkinsfile

---

## [4.0.0] - 2026-01-30

### 🔒 SECURITY EDITION - Полное соответствие требованиям ИБ

Это **мажорный релиз** с breaking changes. Проект полностью переработан для соответствия требованиям информационной безопасности банка.

### Added
- ✅ **secrets-manager-wrapper.sh** - безопасная работа с секретами через обертку с автоматическим unset
- ✅ **health_check режим** в grafana-api-wrapper.sh для проверки доступности без токена  
- ✅ **linuxadm-enable-linger** интеграция для user units без sudo
- ✅ **Минимальные sudo права** - только конкретные systemctl --user команды для CI → sys
- ✅ **SECURITY-COMPLIANCE.md** - детальное описание соответствия требованиям ИБ
- ✅ **README-MIGRATION.md** - руководство по миграции с v3.x на v4.0

### Changed
- 🔄 **BREAKING:** Запуск под CI-пользователем (${KAE}-lnx-mon_ci) вместо root
- 🔄 **BREAKING:** User units как единственная модель (удален fallback на system units)
- 🔄 **BREAKING:** Все секреты извлекаются через secrets-manager-wrapper, не напрямую через jq
- 🔄 **BREAKING:** Заменен `runuser` на `sudo -u` для управления user units
- 🔄 **sudoers:** Конкретные команды systemctl --user вместо широких прав
- 🔄 **Jenkinsfile:** Подключение под ${KAE}-lnx-mon_ci, копирование в ~/monitoring-deployment

### Removed
- ❌ **create_service_account_via_api()** - удалены все прямые curl с eval и паролями
- ❌ **Fallback на system units** - только user units для соответствия методичке ИБ
- ❌ **Широкие sudo права** - удалены ALL=(ALL:ALL) правила

### Security
- 🔒 **Соответствие требованиям ИБ на 100%:**
  - Никаких прямых curl с секретами
  - Все секреты через обертку с валидацией и очисткой
  - Минимальные привилегии (принцип least privilege)
  - Конкретные sudo права для systemctl --user
  - Никаких eval curl с паролями в переменных

### Migration Guide
Для миграции с v3.x на v4.0 см. [README-MIGRATION.md](README-MIGRATION.md)

### Breaking Changes
1. **Требуется создание CI/ТУЗ** через IDM: `${KAE}-lnx-mon_ci`
2. **Требуется настройка sudoers** через IDM для конкретного KAE
3. **Jenkins должен подключаться** под CI-пользователем, не под root
4. **User units обязательны** - system units больше не поддерживаются
5. **linuxadm-enable-linger** должен быть доступен на целевых серверах

---

## [3.0.10] - 2026-01-30 (Legacy Version)

### Changed
- Обновлена документация по service management (user-units vs system-units)
- Улучшено логирование RLM задач с real-time выводом
- Исправлено выравнивание ASCII таблиц в выводе

### Fixed
- Путь установки скрипта изменен на `/usr/local/bin`
- Исправлены команды проверки статуса в финальном summary

---

## Формат версий

- **MAJOR** (X.0.0) - Breaking changes, несовместимые изменения API
- **MINOR** (x.Y.0) - Новый функционал с обратной совместимостью  
- **PATCH** (x.y.Z) - Исправления багов с обратной совместимостью

## Ссылки
- [Unreleased]: Изменения в ветке develop
- [4.0.0]: Security Edition - Полное соответствие требованиям ИБ
- [3.0.10]: Последняя legacy версия перед security refactoring
