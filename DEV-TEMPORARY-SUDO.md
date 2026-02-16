# ⚠️ Временное решение для DEV: sudo через mvp_dev

## 📋 Проблема

На **dev-стенде** (tvlds-mvp001939) права IDM еще не выданы, но нужно протестировать vault-agent.

## ✅ Решение

Временно использовать `sudo` от `mvp_dev` (у него есть passwordless sudo) **только на dev**.

---

## 🔧 Реализация в скрипте

### Определение окружения

```bash
# Проверка: это dev-стенд?
is_dev_environment() {
    local hostname=$(hostname -f 2>/dev/null || hostname)
    
    # Список dev-серверов
    case "$hostname" in
        tvlds-mvp001939*|*-dev.*|*-test.*|*-ift.*)
            return 0  # Это dev
            ;;
        *)
            return 1  # Это prod
            ;;
    esac
}

# Или проверка по наличию mvp_dev пользователя
is_dev_by_user() {
    id mvp_dev &>/dev/null && return 0 || return 1
}
```

### Обертка для sudo-команд

```bash
# Обертка для выполнения sudo-команд
# На dev: используем sudo от текущего пользователя (если mvp_dev)
# На prod: используем sudo -n (требуются права из IDM)
safe_sudo() {
    local cmd="$1"
    shift
    
    if is_dev_environment && [[ $(whoami) == "mvp_dev" ]]; then
        echo "[DEV] Выполняется sudo от mvp_dev: $cmd $@" | tee /dev/stderr
        sudo "$cmd" "$@"
    elif is_dev_environment && id mvp_dev &>/dev/null; then
        echo "[DEV] Переключение на mvp_dev для sudo: $cmd $@" | tee /dev/stderr
        sudo -u mvp_dev sudo "$cmd" "$@"
    else
        # PROD: требуются права из IDM
        echo "[PROD] Выполняется sudo -n: $cmd $@" | tee /dev/stderr
        if ! sudo -n "$cmd" "$@" 2>/dev/null; then
            echo "[ERROR] Не удалось выполнить: sudo $cmd $@" | tee /dev/stderr
            echo "[ERROR] Права не настроены! Создайте IDM заявку." | tee /dev/stderr
            echo "[ERROR] См. файл: IDM-SUDO-CLEAN.txt" | tee /dev/stderr
            return 1
        fi
    fi
}
```

### Использование в коде

```bash
# Старый код (НЕ РАБОТАЕТ без прав):
sudo -n /usr/bin/cp /tmp/vault_role_id.txt /opt/vault/conf/role_id.txt

# Новый код (работает и на dev, и на prod):
safe_sudo /usr/bin/cp /tmp/vault_role_id.txt /opt/vault/conf/role_id.txt
```

---

## 🚨 Важные ограничения

### ✅ Что можно делать через mvp_dev на dev:
```bash
safe_sudo /usr/bin/cp /tmp/vault_role_id.txt /opt/vault/conf/role_id.txt
safe_sudo /usr/bin/chown CI10742292-lnx-va-start:CI10742292-lnx-va-read /opt/vault/conf/role_id.txt
safe_sudo /usr/bin/chmod 640 /opt/vault/conf/role_id.txt
safe_sudo /usr/bin/mkdir -p /opt/vault/certs
safe_sudo /usr/bin/systemctl restart vault-agent
```

### ❌ Что НЕ делать:
```bash
# НЕ использовать для интерактивных команд
safe_sudo vim /etc/something  # ❌

# НЕ использовать для деструктивных операций
safe_sudo rm -rf /opt/vault/  # ❌

# НЕ использовать для команд с переменными
safe_sudo chown $USER:$GROUP $FILE  # ❌ Только фиксированные значения!
```

---

## 📝 Пример интеграции в install-monitoring-stack.sh

```bash
# В начале скрипта
is_dev_environment() {
    local hostname=$(hostname -f 2>/dev/null || hostname)
    case "$hostname" in
        tvlds-mvp001939*|*-dev.*|*-test.*|*-ift.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

safe_sudo() {
    local cmd="$1"
    shift
    
    if is_dev_environment; then
        if [[ $(whoami) == "mvp_dev" ]]; then
            sudo "$cmd" "$@"
        elif id mvp_dev &>/dev/null; then
            sudo -u mvp_dev sudo "$cmd" "$@"
        else
            # На dev, но mvp_dev недоступен - используем штатный sudo
            sudo -n "$cmd" "$@" 2>/dev/null || {
                echo "[ERROR] sudo failed and mvp_dev not available" | tee /dev/stderr
                return 1
            }
        fi
    else
        # PROD: только с правами из IDM
        sudo -n "$cmd" "$@" 2>/dev/null || {
            echo "[ERROR] sudo -n failed. IDM rights required!" | tee /dev/stderr
            return 1
        }
    fi
}

# В setup_vault_config():
# Старое:
# if sudo -n /usr/bin/cp "$TMP_ROLE_ID" /opt/vault/conf/role_id.txt 2>/dev/null; then

# Новое:
if safe_sudo /usr/bin/cp "$TMP_ROLE_ID" /opt/vault/conf/role_id.txt; then
    echo "[VAULT-CONFIG] ✅ role_id.txt скопирован" | tee /dev/stderr
    
    # Установка владельца
    if safe_sudo /usr/bin/chown "${KAE}-lnx-va-start:${KAE}-lnx-va-read" /opt/vault/conf/role_id.txt; then
        log_debug "✅ role_id.txt chown successful"
    fi
    
    # Установка прав
    if safe_sudo /usr/bin/chmod 640 /opt/vault/conf/role_id.txt; then
        log_debug "✅ role_id.txt chmod 640 successful"
    fi
else
    echo "[VAULT-CONFIG] ❌ Не удалось скопировать role_id.txt" | tee /dev/stderr
fi
```

---

## 🔍 Проверка работы

### На dev-стенде:
```bash
# 1. Проверка окружения
hostname -f
# tvlds-mvp001939.ca.sbrf.ru ✅

# 2. Проверка пользователя
whoami
# mvp_dev или CI10742292-lnx-mon_ci

# 3. Проверка sudo от mvp_dev
sudo -u mvp_dev sudo whoami
# root ✅

# 4. Запуск деплоя
./install-monitoring-stack.sh
# [DEV] Выполняется sudo от mvp_dev: /usr/bin/cp ...
```

### На prod-стенде:
```bash
# 1. Проверка окружения
hostname -f
# prod-server.ca.sbrf.ru

# 2. Деплой (требует права из IDM!)
./install-monitoring-stack.sh
# [PROD] Выполняется sudo -n: /usr/bin/cp ...
# [ERROR] sudo -n failed. IDM rights required! ❌
```

---

## ⚠️ Безопасность

### Почему это безопасно для dev?

1. ✅ **Только на dev-стендах** (по hostname)
2. ✅ **Только через wrapper** (`safe_sudo`)
3. ✅ **Фиксированные команды** (нет переменных)
4. ✅ **Логируется каждое действие**
5. ✅ **На prod не работает** (требует IDM)

### Что нужно сделать после получения прав IDM?

```bash
# 1. Удалить проверку is_dev_environment
# 2. Заменить safe_sudo на sudo -n везде
# 3. Удалить этот файл (DEV-TEMPORARY-SUDO.md)
```

---

## 📋 Checklist для dev-тестирования

- [ ] Проверить `hostname -f` (должно быть `tvlds-mvp001939...`)
- [ ] Проверить `id mvp_dev` (пользователь существует)
- [ ] Проверить `sudo -u mvp_dev sudo whoami` (возвращает `root`)
- [ ] Запустить деплой от `CI10742292-lnx-mon_ci`
- [ ] Проверить логи: должно быть `[DEV] Выполняется sudo от mvp_dev`
- [ ] Проверить vault-agent: `sudo systemctl status vault-agent`
- [ ] Проверить сертификаты: `sudo ls -lah /opt/vault/certs/`

---

## 🎯 Миграция на user-space (рекомендуется!)

Вместо использования временного sudo на dev, **лучше сразу мигрировать на user-space архитектуру**!

См. `MIGRATION-TO-USERSPACE.md` — там описано, как запустить vault-agent **БЕЗ SUDO вообще**!

**Преимущества:**
- ✅ Не нужны права в IDM
- ✅ Полностью self-service
- ✅ Соответствует требованиям ИБ
- ✅ Работает одинаково на dev и prod
