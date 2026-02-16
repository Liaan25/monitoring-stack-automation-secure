# IDM Заявка: Sudo-правила для vault-agent

## 📋 Общая информация

**Цель:** Настройка passwordless sudo-прав для автоматизации развертывания monitoring stack с vault-agent

**Пользователь:** `${KAE}-lnx-mon_ci` (например: `CI10742292-lnx-mon_ci`)

**Сервер:** tvlds-mvp001939.ca.sbrf.ru (или ваш сервер)

---

## ✅ Необходимые sudo-правила

### 1️⃣ Управление user-юнитами мониторинга (от имени sys-пользователя)

```
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

---

### 2️⃣ Копирование credentials и agent.hcl из временных путей в /opt/vault/conf/

```
# Копирование role_id и secret_id из /tmp/
# ВАЖНО: Используются фиксированные имена (без wildcards) согласно требованиям ИБ
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp /tmp/vault_role_id.txt /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp /tmp/vault_secret_id.txt /opt/vault/conf/secret_id.txt

# Копирование agent.hcl из user-space
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp /home/${KAE}-lnx-mon_ci/monitoring/config/vault/agent.hcl /opt/vault/conf/agent.hcl
```

---

### 3️⃣ Установка владельца для файлов vault-agent

```
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/conf/secret_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/conf/agent.hcl
```

---

### 4️⃣ Установка прав для файлов vault-agent

```
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 640 /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 640 /opt/vault/conf/secret_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 640 /opt/vault/conf/agent.hcl
```

---

### 5️⃣ Создание и настройка /opt/vault/certs/

```
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/mkdir -p /opt/vault/certs
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown ${KAE}-lnx-va-start:${KAE}-lnx-va-read /opt/vault/certs
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 750 /opt/vault/certs
```

---

### 6️⃣ Управление системным сервисом vault-agent

```
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl restart vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl status vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl is-active vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl start vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl stop vault-agent
```

---

## 🔒 Обоснование безопасности

### ✅ NOEXEC флаг
- Предотвращает выполнение произвольных команд через shell escapes
- Команды выполняются напрямую без возможности инъекции

### ✅ NOPASSWD флаг
- Не требует ввода пароля
- Критично для автоматизации CI/CD pipeline

### ✅ Явные пути (без wildcards)
- Все пути явно указаны **БЕЗ wildcards** согласно требованиям ИБ
- Используются фиксированные имена файлов: `/tmp/vault_role_id.txt`, `/tmp/vault_secret_id.txt`
- Файлы создаются с правами 600 и удаляются сразу после копирования
- Предотвращает злоупотребления и race conditions

### ✅ Минимальные привилегии
- Пользователь может выполнять **только** указанные команды
- Не может выполнять другие системные операции
- Соответствует принципу least privilege

---

## 📝 Пример для конкретного KAE

Для `CI10742292` (ваш KAE):

```sudoers
# User-юниты мониторинга
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user daemon-reload
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart monitoring-prometheus.service
... (остальные команды systemctl --user)

# Vault-agent credentials и config (фиксированные пути без wildcards)
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp /tmp/vault_role_id.txt /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp /tmp/vault_secret_id.txt /opt/vault/conf/secret_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/cp /home/CI10742292-lnx-mon_ci/monitoring/config/vault/agent.hcl /opt/vault/conf/agent.hcl

# Chown для vault-agent файлов
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown CI10742292-lnx-va-start:CI10742292-lnx-va-read /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown CI10742292-lnx-va-start:CI10742292-lnx-va-read /opt/vault/conf/secret_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown CI10742292-lnx-va-start:CI10742292-lnx-va-read /opt/vault/conf/agent.hcl

# Chmod для vault-agent файлов
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 640 /opt/vault/conf/role_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 640 /opt/vault/conf/secret_id.txt
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 640 /opt/vault/conf/agent.hcl

# Создание /opt/vault/certs/
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/mkdir -p /opt/vault/certs
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chown CI10742292-lnx-va-start:CI10742292-lnx-va-read /opt/vault/certs
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/chmod 750 /opt/vault/certs

# Управление vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl restart vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl status vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl is-active vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl start vault-agent
ALL=(root) NOEXEC: NOPASSWD: /usr/bin/systemctl stop vault-agent
```

---

## ✅ Проверка после применения

После одобрения IDM заявки, проверьте на сервере:

```bash
# 1. Проверка sudo для копирования (создайте тестовый файл)
echo "test" > /tmp/vault_role_id.txt
sudo -n /usr/bin/cp /tmp/vault_role_id.txt /opt/vault/conf/role_id.txt
rm /tmp/vault_role_id.txt

# 2. Проверка sudo для vault-agent
sudo -n /usr/bin/systemctl status vault-agent

# 3. Проверка sudo для user-юнитов
sudo -u CI10742292-lnx-mon_sys /usr/bin/systemctl --user status monitoring-prometheus.service
```

Если все команды выполняются **без запроса пароля**, значит права настроены правильно! ✅

---

## 📚 Дополнительно

- Полный пример sudo-правил: `sudoers.example` (строки 16-87)
- Документация по откату: `HOW-TO-REVERT.md`
- История изменений: `CHANGELOG.md`
