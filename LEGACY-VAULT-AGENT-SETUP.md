# ⚠️ LEGACY: Автоматизация Vault и Credentials (vault-agent подход)

**СТАТУС:** 🔴 **ЗАКОММЕНТИРОВАН / НЕ ИСПОЛЬЗУЕТСЯ ПО УМОЛЧАНИЮ**  
**Дата закомментирования:** 15.02.2026  
**Версия:** 4.0 (LEGACY)  

---

## ⚠️ ВНИМАНИЕ: Это LEGACY документация

Начиная с **версии 4.1**, проект использует **упрощенный подход без vault-agent**, где:
- ✅ Все файлы хранятся в `$HOME/monitoring/` (user-space)
- ✅ Сертификаты получаются из Jenkins или создаются self-signed
- ✅ НЕ требуется sudo для файловых операций
- ✅ НЕ используются системные пути `/opt/vault/`

**Этот документ описывает LEGACY подход с vault-agent**, который был закомментирован в коде, но может быть восстановлен при необходимости.

### 📌 Для возврата к vault-agent подходу:

1. См. документацию: **`HOW-TO-REVERT.md`**
2. Раскомментируйте функцию `setup_vault_config()` в `install-monitoring-stack.sh`
3. Раскомментируйте System-level sudo-правила в `sudoers.example`
4. Создайте IDM заявку с sudo-правилами

---

## 🎯 Что было автоматизировано (в LEGACY подходе)

В соответствии с требованиями ИБ, весь процесс настройки Vault и credentials был полностью автоматизирован в Jenkins Pipeline.

### ✅ Что делает скрипт автоматически (LEGACY):

1. **Извлекает secrets из `temp_data_cred.json`**
   - Использует `jq` для безопасного парсинга JSON
   - Извлекает `role_id` и `secret_id` для vault-agent
   - Сохраняет во временные файлы в `/tmp/` с правами `600`

2. **Копирует credentials в `/opt/vault/conf/`**
   - Использует `sudo -n` для копирования из `/tmp/` в системные пути
   - Устанавливает владельца: `${KAE}-lnx-va-start:${KAE}-lnx-va-read`
   - Устанавливает права: `640`
   - Автоматически удаляет временные файлы после копирования

3. **Создает `/opt/vault/certs/`**
   - Создает директорию если не существует
   - Устанавливает владельца и права (750)

4. **Перезапускает vault-agent**
   - Применяет новый конфигурационный файл `agent.hcl`
   - Ждет стабилизации (5 сек)
   - Проверяет статус и активность
   - Ожидает генерации сертификатов (еще 5 сек)

5. **Управляет user-юнитами мониторинга**
   - Использует `sudo -u ${KAE}-lnx-mon_sys` для запуска команд от имени sys-пользователя
   - Использует `/usr/bin/systemctl --user` согласно требованиям ИБ
   - Управляет Prometheus, Grafana, Harvest через user units

---

## 📋 Необходимые sudo-права (для LEGACY подхода)

### 1. System-level операции (требуют root)

Добавьте эти правила в **IDM заявку** для пользователя `${KAE}-lnx-mon_ci`:

```sudoers
# Копирование credentials из /tmp/ в /opt/vault/conf/
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp /tmp/role_id_*.txt /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp /tmp/secret_id_*.txt /opt/vault/conf/secret_id.txt

# Установка владельца для credentials
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/conf/secret_id.txt

# Установка прав для credentials
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 640 /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 640 /opt/vault/conf/secret_id.txt

# Создание и настройка /opt/vault/certs/
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/mkdir -p /opt/vault/certs
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/certs
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 750 /opt/vault/certs

# Управление системным сервисом vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl restart vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl status vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl is-active vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl start vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl stop vault-agent
```

### 2. User-space операции (от имени mon_sys)

Добавьте эти правила в **IDM заявку** для пользователя `${KAE}-lnx-mon_ci`:

```sudoers
# Управление user-юнитами мониторинга
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user daemon-reload
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user reset-failed monitoring-prometheus.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user reset-failed monitoring-grafana.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user reset-failed monitoring-harvest.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user enable monitoring-prometheus.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user enable monitoring-grafana.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user enable monitoring-harvest.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-prometheus.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-grafana.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-harvest.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user stop monitoring-prometheus.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user stop monitoring-grafana.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user stop monitoring-harvest.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user status monitoring-prometheus.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user status monitoring-grafana.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user status monitoring-harvest.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user is-active monitoring-prometheus.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user is-active monitoring-grafana.service
ALL=(${KAE}-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user is-active monitoring-harvest.service
```

**ВАЖНО:** Замените `${KAE}` на ваш реальный KAE (например, `CI10742292`).

---

## 🚀 Запуск через Jenkins (LEGACY подход)

После добавления sudo-прав в IDM, просто запустите Jenkins Pipeline:

```bash
# Jenkins автоматически (в LEGACY подходе):
1. Извлечет secrets из temp_data_cred.json
2. Скопирует их в /opt/vault/conf/
3. Создаст /opt/vault/certs/
4. Перезапустит vault-agent
5. Дождется генерации сертификатов
6. Запустит user-юниты мониторинга
```

---

## 🔍 Проверка работы (LEGACY подход)

### 1. Проверьте что credentials установлены:

```bash
# Должны существовать и не быть пустыми
ls -lah /opt/vault/conf/role_id.txt /opt/vault/conf/secret_id.txt

# Ожидаемый вывод:
# -rw-r----- 1 CI10742292-lnx-va-start CI10742292-lnx-va-read 37 Feb 15 17:14 /opt/vault/conf/role_id.txt
# -rw-r----- 1 CI10742292-lnx-va-start CI10742292-lnx-va-read 37 Feb 15 17:14 /opt/vault/conf/secret_id.txt
```

### 2. Проверьте что vault-agent активен:

```bash
sudo systemctl status vault-agent --no-pager
```

### 3. Проверьте что сертификаты сгенерированы:

```bash
ls -lah /opt/vault/certs/

# Должны быть:
# - server_bundle.pem (5-10 KB)
# - ca_chain.crt (2-5 KB)
# - grafana-client.pem (5-10 KB)
```

### 4. Проверьте user-юниты мониторинга:

```bash
# Переключитесь на mon_sys пользователя
sudo -u ${KAE}-lnx-mon_sys bash

# Установите XDG_RUNTIME_DIR
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# Проверьте статус
systemctl --user status monitoring-prometheus.service
systemctl --user status monitoring-grafana.service
systemctl --user status monitoring-harvest.service
```

---

## ⚠️ Troubleshooting (LEGACY подход)

### Проблема: "sudo: a password is required"

**Причина:** sudo-права еще не применились из IDM заявки.

**Решение:**
1. Проверьте что IDM заявка **approved** и **deployed**
2. Дождитесь синхронизации (может занять 10-30 минут)
3. Перелогиньтесь на сервере
4. Проверьте: `sudo -l` (должны быть видны новые правила)

---

### Проблема: vault-agent не запускается

**Причина:** DNS не может резолвить `secman.sigma.sbrf.ru`

**Решение:**
```bash
# Проверьте DNS
nslookup secman.sigma.sbrf.ru

# Если не работает - обратитесь к администратору сети
# или добавьте IP в /etc/hosts:
echo "10.X.X.X secman.sigma.sbrf.ru" | sudo tee -a /etc/hosts
```

---

### Проблема: Сертификаты не генерируются

**Причина 1:** vault-agent не может аутентифицироваться

**Решение:**
```bash
# Проверьте логи vault-agent
sudo journalctl -u vault-agent -n 100 --no-pager | grep -i error

# Частые ошибки:
# - "no such host" → DNS проблема (см. выше)
# - "permission denied" → неправильные права на role_id/secret_id
# - "invalid role_id" → неправильные credentials из temp_data_cred.json
```

**Причина 2:** agent.hcl содержит placeholder'ы

**Решение:**
```bash
# Проверьте agent.hcl
sudo grep "role_id_file_path" /opt/vault/conf/agent.hcl

# Должно быть:
# role_id_file_path = "/opt/vault/conf/role_id.txt"
# secret_id_file_path = "/opt/vault/conf/secret_id.txt"

# НЕ должно быть:
# %your_role_id_file_path%
```

---

## 📚 Дополнительная информация

- **Актуальный подход:** `CERTIFICATE-RENEWAL.md` — упрощенный подход без vault-agent
- **Как вернуться к LEGACY:** `HOW-TO-REVERT.md` — пошаговая инструкция
- **Файл с sudo-правилами (LEGACY):** `sudoers.example` (строки 36-68, закомментированы)
- **Требования ИБ:** `SECURITY-COMPLIANCE.md`

---

## ✅ Соответствие требованиям ИБ (для LEGACY подхода)

### Что было реализовано:

- ✅ **NOEXEC** на всех sudo-правилах
- ✅ **Явные пути** в командах (`/usr/bin/systemctl`, `/usr/bin/cp`)
- ✅ **Временное хранение** секретов в `/tmp/` с правами `600`
- ✅ **Автоматическая очистка** временных файлов через `trap`
- ✅ **User-space deployment** через `systemctl --user`
- ✅ **Privilege separation** между `mon_ci` и `mon_sys`
- ✅ **No plain-text passwords** в переменных окружения или логах
- ✅ **Minimal sudo rights** - только конкретные команды с явными путями
- ✅ **Forbidden commands** (`awk`, `sed`) используются с полными путями

### Что было улучшено в Simplified подходе (версия 4.1):

- ✅ **Еще меньше sudo** — только для `systemctl --user`, НЕТ sudo для файловых операций
- ✅ **Полностью user-space** — все в `$HOME/monitoring/`
- ✅ **Проще troubleshooting** — нет системных сервисов
- ✅ **Быстрее деплой** — режим Certificate Renewal Only

---

## 🔄 Сравнение подходов

| Характеристика | LEGACY (vault-agent) | Simplified (текущий) |
|----------------|----------------------|----------------------|
| Сертификаты | Автоматическая ротация | Из Jenkins / self-signed |
| Sudo-права | System + User level | Только User level |
| Сложность | Средняя | Низкая |
| Зависимости | vault-agent (системный) | Нет системных сервисов |
| Ротация сертификатов | Автоматическая | Ручная (через Jenkins) |
| Пути хранения | `/opt/vault/` | `$HOME/monitoring/` |
| Пользователи | mon_ci, mon_sys, va-start, va-read | mon_ci, mon_sys |

---

**Версия:** 4.0 (LEGACY)  
**Статус:** 🔴 Закомментировано / Не используется  
**Дата:** 15.02.2026  
**Автор:** Monitoring Team + AI Assistant

**Для актуального подхода см.:** `CERTIFICATE-RENEWAL.md`
