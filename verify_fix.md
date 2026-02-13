# Проверка исправлений для vault-config

## Проблема
Vault-agent установлен через RLM, но конфигурационный файл `agent.hcl` содержит шаблонные значения вместо реальных путей к `role_id` и `secret_id`.

## Причина
1. Скрипт создавал `agent.hcl` только в user-space (`$HOME/monitoring/config/vault/agent.hcl`)
2. Копирование в системный путь `/opt/vault/conf/agent.hcl` происходило ТОЛЬКО если `SKIP_VAULT_INSTALL=true`
3. Vault-agent (системный сервис) ожидает конфигурацию в `/opt/vault/conf/agent.hcl`

## Решение
Исправлена функция `setup_vault_config()`:

### 1. Создание двух версий agent.hcl
- **Системная версия**: `/opt/vault/conf/agent.hcl` - с системными путями для vault-agent
- **User-space версия**: `$HOME/monitoring/config/vault/agent.hcl` - для справки/шаблона

### 2. Копирование role_id и secret_id
- Файлы `role_id.txt` и `secret_id.txt` копируются из user-space в системные пути:
  - `/opt/vault/conf/role_id.txt`
  - `/opt/vault/conf/secret_id.txt`

### 3. Применение конфигурации
- Проверка прав на запись в `/opt/vault/conf/`
- Автоматическое добавление пользователя в группу `va-start` при необходимости
- Попытка перезапуска vault-agent с новым конфигом

### 4. Соответствие SECURITY-COMPLIANCE.md
- Сохранены user-space пути для других компонентов
- Использование `secrets-manager-wrapper` для безопасного извлечения секретов
- Автоматическая очистка секретов после использования

## Ключевые изменения в коде

### До исправления:
```bash
# Создавался только user-space agent.hcl
} > "$VAULT_AGENT_HCL"

# Копирование в системный путь только при SKIP_VAULT_INSTALL=true
if [[ "${SKIP_VAULT_INSTALL:-false}" == "true" ]]; then
    # ... код копирования ...
fi
```

### После исправления:
```bash
# 1. Системная версия (для vault-agent)
local SYSTEM_VAULT_AGENT_HCL="/opt/vault/conf/agent.hcl"
{
    # Конфиг с системными путями /opt/vault/
} > "$SYSTEM_VAULT_AGENT_HCL"

# 2. User-space версия (для справки)
{
    # Конфиг с user-space путями $HOME/monitoring/
} > "$VAULT_AGENT_HCL"

# 3. Копирование role_id/secret_id в системные пути
cp "$VAULT_ROLE_ID_FILE" "/opt/vault/conf/role_id.txt"
cp "$VAULT_SECRET_ID_FILE" "/opt/vault/conf/secret_id.txt"

# 4. Применение конфигурации к vault-agent
systemctl restart vault-agent
```

## Ожидаемый результат
1. Vault-agent получает правильный `agent.hcl` с реальными путями к `role_id` и `secret_id`
2. Создаются блоки `template` для генерации сертификатов и `data_sec.json`
3. Сертификаты создаются с правами `0640` (доступны группе `va-read`)
4. User-space версия сохраняется для справки и аудита

## Проверка на сервере
После применения исправлений на сервере должны появиться:

```
/opt/vault/conf/agent.hcl          # С реальными путями, без шаблонов
/opt/vault/conf/role_id.txt        # С реальным role_id
/opt/vault/conf/secret_id.txt      # С реальным secret_id
/home/CIxxxx-lnx-mon_ci/monitoring/config/vault/agent.hcl  # User-space версия
```

## Безопасность
- Все секреты извлекаются через `secrets-manager-wrapper`
- Автоматический `unset` секретов после использования
- Минимальные права на файлы (`chmod 640`)
- Изоляция user-space и системных компонентов