# Monitoring Stack Automation - Secure Edition

![Version](https://img.shields.io/badge/version-4.0.0-blue)
![Security](https://img.shields.io/badge/security-compliant-green)
![License](https://img.shields.io/badge/license-proprietary-red)

**Автоматизированное развертывание мониторинговой системы** (Prometheus + Grafana + Harvest) с **полным соответствием требованиям Информационной Безопасности**.

---

## 🔒 Secure Edition - Что изменилось?

**Версия 4.0.0** - это **полностью переработанная архитектура** для соответствия требованиям ИБ банка:

| Аспект | Legacy (v3.x) | Secure Edition (v4.0) |
|--------|---------------|----------------------|
| **Запуск скрипта** | `sudo /bin/bash script.sh` | `./script.sh` (под CI-user) |
| **Sudoers** | 4 широких правила | Конкретные systemctl для CI→sys |
| **Секреты** | `jq` напрямую | `secrets-manager-wrapper` + unset |
| **Curl** | `eval curl` с паролем | ТОЛЬКО через wrapper |
| **Service Units** | System + fallback | ТОЛЬКО user units |
| **Linger** | ❌ Отсутствует | ✅ linuxadm-enable-linger |

**Подробнее**: [SECURITY-COMPLIANCE.md](SECURITY-COMPLIANCE.md), [README-MIGRATION.md](README-MIGRATION.md)

---

## 📋 Быстрый старт

### 1. Предварительные требования

**Инфраструктура**:
- ✅ SBEL 8+ или RHEL 8+ (systemd 239+)
- ✅ Jenkins CI/CD
- ✅ HashiCorp Vault (SecMan)
- ✅ RLM API для управления пакетами/группами
- ✅ Linuxadm tools (`linuxadm-enable-linger`)

**Учётные записи через IDM**:
```
CI-пользователь:  ${KAE}-lnx-mon_ci   (интерактивная ПУЗ/ТУЗ)
Sys-пользователь: ${KAE}-lnx-mon_sys  (nologin сервисная УЗ)
```

**Sudoers через ИБ**:
```bash
# Конкретные systemctl --user команды для CI → sys
# См. sudoers.example для полного списка
```

### 2. Архитектура

```
┌─────────────────────────────────────────┐
│  Jenkins                                │
│  └─ Pipeline (Jenkinsfile)              │
│     ↓ SSH as CI-user                    │
└─────────────────────────────────────────┘
          ↓
┌─────────────────────────────────────────┐
│  Target Server                          │
│  ┌───────────────────────────────────┐  │
│  │  CI-user: CI84324523-lnx-mon_ci   │  │
│  │  Home: ~/monitoring-deployment/   │  │
│  │  ├─ install-monitoring-stack.sh   │  │
│  │  ├─ wrappers/ (security)          │  │
│  │  └─ temp_data_cred.json            │  │
│  └───────────────────────────────────┘  │
│         ↓ sudo -u sys-user               │
│  ┌───────────────────────────────────┐  │
│  │  Sys-user: CI84324523-lnx-mon_sys │  │
│  │  User Units:                       │  │
│  │  └─ ~/.config/systemd/user/        │  │
│  │     ├─ monitoring-prometheus.serv  │  │
│  │     ├─ monitoring-grafana.service  │  │
│  │     └─ monitoring-harvest.service  │  │
│  │  Linger: ENABLED ✅                 │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

### 3. Развертывание

#### Шаг 1: Подготовка (одноразово)

```bash
# 1. Создать УЗ через IDM
#    - CI-user: ${KAE}-lnx-mon_ci
#    - Sys-user: ${KAE}-lnx-mon_sys

# 2. Подать заявку в ИБ на sudoers правила
#    Использовать: sudoers.template

# 3. Настроить Jenkins credentials
#    ID: monitoring-stack-ci-user-ssh
#    Type: SSH Username with private key
#    Username: ${KAE}-lnx-mon_ci
```

#### Шаг 2: Запуск Pipeline

```groovy
// Jenkins → monitoring-stack-secure → Build with Parameters

SERVER_ADDRESS: target-server.domain.ru
SSH_CREDENTIALS_ID: monitoring-stack-ci-user-ssh
NAMESPACE_CI: kvSec_CI84324523     // ВАЖНО: для вычисления KAE
VAULT_CREDENTIAL_ID: vault-agent-dev  // Jenkins Credential ID для Vault токена
SKIP_VAULT_INSTALL: true           // Если vault-agent уже настроен
SKIP_RPM_INSTALL: false            // Установить RPM пакеты
```

**Примечание**: Если credential `vault-agent-dev` не существует в Jenkins, создайте его:
1. Jenkins → Manage Jenkins → Credentials
2. Add Credentials → Kind: Secret text
3. ID: `vault-agent-dev` (или другой, указанный в параметре)
4. Secret: [Ваш Vault токен]

#### Шаг 3: Проверка

```bash
ssh CI84324523-lnx-mon_ci@target-server

# 1. Проверка linger
loginctl show-user CI84324523-lnx-mon_sys | grep Linger
# Output: Linger=yes

# 2. Проверка user units
sudo -u CI84324523-lnx-mon_sys \
  env XDG_RUNTIME_DIR="/run/user/$(id -u CI84324523-lnx-mon_sys)" \
  systemctl --user list-units 'monitoring-*'
# Все 3 сервиса должны быть active

# 3. Проверка портов
ss -tln | grep -E ':(3000|9090|12990|12991)'
# Все 4 порта должны быть открыты

# 4. Проверка доступности
curl -k https://localhost:3000/api/health
curl -k https://localhost:9090/-/healthy
```

---

## 📂 Структура проекта

```
monitoring-stack-automation-secure/
├── Jenkinsfile                    # CI/CD pipeline (v4.0 - запуск под CI-user)
├── install-monitoring-stack.sh    # Основной скрипт развертывания
├── wrappers/                      # Security wrappers
│   ├── secrets-manager-wrapper.sh # НОВОЕ: Безопасная работа с секретами
│   ├── grafana-api-wrapper.sh     # Grafana API (добавлен health_check)
│   ├── rlm-api-wrapper.sh        # RLM API integration
│   ├── firewall-manager.sh       # Firewall management
│   ├── config-writer.sh          # Безопасная запись конфигов
│   └── build-integrity-checkers.sh # Генерация SHA256 launchers
├── tools/
│   ├── get-version.sh            # Версионирование
│   └── update-version-in-docs.sh # Обновление версии в документах
├── VERSION                        # 4.0.0
├── CHANGELOG.md                   # История изменений
├── README.md                      # Этот файл
├── README-MIGRATION.md            # Руководство по миграции v3→v4
├── SECURITY-COMPLIANCE.md         # Соответствие требованиям ИБ
├── sudoers.example                # Пример sudoers правил
└── sudoers.template               # Шаблон для заявки в ИБ
```

---

## 🔐 Безопасность

### Принципы безопасности (Security by Design)

1. **Минимальные привилегии**: Только необходимые sudo права
2. **User Units Only**: БЕЗ root привилегий для сервисов
3. **Secrets через Wrappers**: Автоматическая очистка переменных
4. **Валидация всех входных данных**: Whitelist разрешенных значений
5. **SHA256 Integrity Checks**: Для всех security wrappers
6. **NOEXEC в sudoers**: Защита от выполнения команд

### Соответствие требованиям ИБ

✅ **Таблица 2** (Секреты): Все через `secrets-manager-wrapper.sh` + unset  
✅ **Таблица 3** (Запрещенные команды): Curl ТОЛЬКО через обертки, нет bash в sudoers  
✅ **Методичка SberInfra**: ТОЛЬКО user units, никаких system units  
✅ **Принцип минимальных привилегий**: Конкретные systemctl команды  

**Подробнее**: [SECURITY-COMPLIANCE.md](SECURITY-COMPLIANCE.md)

---

## 🚀 Основные возможности

### 1. Автоматическое развертывание

- ✅ Prometheus (метрики, alerting)
- ✅ Grafana (визуализация, dashboards)
- ✅ Harvest (NetApp metrics collector)
- ✅ Vault-agent (secrets management)
- ✅ RLM интеграция (package installation)

### 2. Безопасность

- ✅ HashiCorp Vault интеграция
- ✅ Secrets через validated wrappers
- ✅ SHA256 integrity checks
- ✅ Минимальные sudo привилегии
- ✅ User units (БЕЗ root)
- ✅ Linger для 24/7 работы

### 3. Управление

- ✅ Запуск под CI-пользователем (БЕЗ sudo для main script)
- ✅ Sudo ТОЛЬКО для systemctl --user (управление сервисами sys-user)
- ✅ Централизованное логирование
- ✅ Real-time мониторинг RLM задач
- ✅ Идемпотентность (можно запускать многократно)

### 4. Масштабируемость

- ✅ KAE-based модель (автоматическое определение пользователей)
- ✅ Массовое развертывание через Jenkins
- ✅ Подходит для 1000+ серверов
- ✅ Минимальные требования к sudoers (простота управления)

---

## 📖 Документация

### Основные документы

1. **[SECURITY-COMPLIANCE.md](SECURITY-COMPLIANCE.md)** - Соответствие требованиям ИБ
2. **[README-MIGRATION.md](README-MIGRATION.md)** - Миграция с v3.x на v4.0
3. **[CHANGELOG.md](CHANGELOG.md)** - История изменений
4. **[sudoers.template](sudoers.template)** - Шаблон sudoers правил

### Дополнительные ресурсы

- 📋 **Troubleshooting**: См. раздел "Troubleshooting" ниже
- 🔧 **Конфигурация Jenkins**: См. раздел "Настройка Jenkins"
- 🐛 **Известные проблемы**: См. Issues в Git

---

## 🛠️ Управление сервисами

### Проверка статуса (User Units)

```bash
# Автоматически определяем KAE из NAMESPACE_CI
KAE=$(echo "$NAMESPACE_CI" | cut -d'_' -f2)
SYS_USER="${KAE}-lnx-mon_sys"
SYS_UID=$(id -u "$SYS_USER")

# Проверка всех сервисов
sudo -u "$SYS_USER" \
  env XDG_RUNTIME_DIR="/run/user/$SYS_UID" \
  systemctl --user status monitoring-prometheus
  
sudo -u "$SYS_USER" \
  env XDG_RUNTIME_DIR="/run/user/$SYS_UID" \
  systemctl --user status monitoring-grafana
  
sudo -u "$SYS_USER" \
  env XDG_RUNTIME_DIR="/run/user/$SYS_UID" \
  systemctl --user status monitoring-harvest
```

### Перезапуск сервисов

```bash
# Prometheus
sudo -u "$SYS_USER" \
  env XDG_RUNTIME_DIR="/run/user/$SYS_UID" \
  systemctl --user restart monitoring-prometheus

# Grafana
sudo -u "$SYS_USER" \
  env XDG_RUNTIME_DIR="/run/user/$SYS_UID" \
  systemctl --user restart monitoring-grafana

# Harvest
sudo -u "$SYS_USER" \
  env XDG_RUNTIME_DIR="/run/user/$SYS_UID" \
  systemctl --user restart monitoring-harvest
```

### Проверка Linger

```bash
# Проверить, включен ли linger
loginctl show-user "$SYS_USER" | grep Linger
# Output: Linger=yes

# Если linger отключен, включить (требуется as-admin)
linuxadm-enable-linger "$SYS_USER"
```

---

## 🔧 Troubleshooting

### Проблема: User unit не запускается

**Симптомы**:
```bash
sudo -u sys-user systemctl --user status service
# Error: Failed to connect to bus
```

**Причина**: Linger не включен

**Решение**:
```bash
# Проверить linger
loginctl show-user ${KAE}-lnx-mon_sys | grep Linger

# Включить linger (требуется as-admin)
linuxadm-enable-linger ${KAE}-lnx-mon_sys

# Проверить снова
loginctl show-user ${KAE}-lnx-mon_sys | grep Linger
# Output: Linger=yes
```

### Проблема: Permission denied для systemctl --user

**Симптомы**:
```bash
sudo -u sys-user systemctl --user restart service
# Error: Permission denied
```

**Причина**: Sudoers правила не настроены

**Решение**:
```bash
# Проверить sudoers для CI-пользователя
sudo -l -U ${KAE}-lnx-mon_ci

# Должны быть правила для systemctl --user
# Если нет - подать заявку в ИБ (sudoers.template)
```

### Проблема: linuxadm-enable-linger not found

**Симптомы**:
```bash
linuxadm-enable-linger user
# Command not found
```

**Причина**: Пакет linuxadm не установлен

**Решение**:
```bash
# Установить пакет (требуется root)
sudo yum install linuxadm  # или аналог для вашей ОС
```

### Проблема: Сервисы останавливаются после logout

**Симптомы**: После logout CI-пользователя, сервисы останавливаются

**Причина**: Linger не включен

**Решение**: См. "User unit не запускается" выше

---

## 🆚 Сравнение версий

### Когда использовать v4.0 Secure Edition?

✅ **Используйте v4.0** если:
- Требуется полное соответствие требованиям ИБ
- Есть возможность создать CI/ТУЗ через IDM
- Есть доступ к linuxadm-enable-linger
- Целевые серверы: SBEL 8+ или RHEL 8+
- Массовое развертывание (100+ серверов)

❌ **Оставайтесь на v3.x** если:
- Требования ИБ не критичны
- Нет возможности создать CI-пользователя
- Целевые серверы: RHEL 7 (ограниченная поддержка user units)
- Единичные развертывания (< 10 серверов)

**Миграция**: [README-MIGRATION.md](README-MIGRATION.md)

---

## 📞 Поддержка

**Для вопросов и предложений**:
- 📋 Техническая поддержка: [ссылка на канал/email]
- 🔒 Вопросы по безопасности: ИБ отдел
- 🐛 Сообщить об ошибке: [Git Issues](...)

**Версионирование**:
- Текущая версия: **4.0.0 - Secure Edition**
- История изменений: [CHANGELOG.md](CHANGELOG.md)

---

## 📜 Лицензия

Проприетарный софт. Все права защищены.

---

**Дата создания:** 2026-01-30  
**Версия документа:** 1.0  
**Авторы:** Monitoring Team + ИБ консультация
