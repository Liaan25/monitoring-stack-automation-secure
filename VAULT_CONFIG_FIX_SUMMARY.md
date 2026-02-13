# Исправление проблемы с vault-agent конфигурацией

## Проблема
На сервере `tvlds-mvp001939.cloud.delta.sbrf.ru` обнаружены следующие проблемы:

1. **Файлы `role_id.txt` и `secret_id.txt` пустые (0 байт)** в user-space:
   ```
   /home/CI10742292-lnx-mon_ci/monitoring/config/vault/role_id.txt
   /home/CI10742292-lnx-mon_ci/monitoring/config/vault/secret_id.txt
   ```

2. **Системный `agent.hcl` содержит шаблонные значения** вместо реальных путей:
   ```
   /opt/vault/conf/agent.hcl
   Содержит: role_id_file_path = "%your_role_id_file_path%"
   Содержит: secret_id_file_path = "%your_secret_id_file_path%"
   ```

3. **User-space `agent.hcl` создан, но содержит user-space пути**, а не системные.

## Причина
1. **`secrets-manager-wrapper` не смог извлечь секреты** из `temp_data_cred.json`
2. **Скрипт создавал конфигурацию только в user-space**, но не копировал в системный путь
3. **Копирование в `/opt/vault/conf/` происходило только при `SKIP_VAULT_INSTALL=true`**

## Решение
Исправлена функция `setup_vault_config()` в `install-monitoring-stack.sh`:

### 1. **Улучшено извлечение секретов**
- Добавлена проверка на пустые результаты
- Не прерываем выполнение при ошибке извлечения (только предупреждение)
- Более детальное логирование

### 2. **Создание двух версий agent.hcl**
- **Системная версия**: `/opt/vault/conf/agent.hcl` - с системными путями `/opt/vault/`
- **User-space версия**: `$HOME/monitoring/config/vault/agent.hcl` - упрощенная для справки

### 3. **Копирование role_id и secret_id**
- Файлы копируются из user-space в системные пути:
  - `/opt/vault/conf/role_id.txt`
  - `/opt/vault/conf/secret_id.txt`
- Проверка на пустые файлы перед копированием

### 4. **Применение конфигурации**
- Проверка прав на запись в `/opt/vault/conf/`
- Автоматическое добавление пользователя в группу `va-start` при необходимости
- Попытка перезапуска vault-agent с новым конфигом

### 5. **Соответствие SECURITY-COMPLIANCE.md**
- Сохранены user-space пути для других компонентов
- Использование `secrets-manager-wrapper` для безопасного извлечения секретов
- Автоматическая очистка секретов после использования

## Ключевые изменения в коде

### Извлечение секретов (более устойчивое):
```bash
if [[ $role_id_exit -eq 0 && -s "$role_id_stdout" ]]; then
    echo "[DEBUG-SECRETS] ✅ role_id успешно извлечен"
    cat "$role_id_stdout" > "$VAULT_ROLE_ID_FILE"
    secrets_extracted=true
else
    echo "[DEBUG-SECRETS] ⚠️  Не удалось извлечь role_id или результат пустой"
    # Не выходим с ошибкой, продолжаем с пустыми файлами
fi
```

### Создание системной версии agent.hcl:
```bash
local SYSTEM_VAULT_AGENT_HCL="/opt/vault/conf/agent.hcl"
cat > "$SYSTEM_VAULT_AGENT_HCL" << SYS_EOF
pid_file = "/opt/vault/log/vault-agent.pidfile"
vault {
 address = "https://$SEC_MAN_ADDR"
 tls_skip_verify = "false"
 ca_path = "/opt/vault/conf/ca-trust"
}
auto_auth {
 method "approle" {
 namespace = "$NAMESPACE_CI"
 mount_path = "auth/approle"

 config = {
 role_id_file_path = "/opt/vault/conf/role_id.txt"
 secret_id_file_path = "/opt/vault/conf/secret_id.txt"
 remove_secret_id_file_after_reading = false
}
}
}
# ... остальная конфигурация ...
SYS_EOF
```

### Копирование с проверкой на пустые файлы:
```bash
if [[ -f "$VAULT_ROLE_ID_FILE" && -s "$VAULT_ROLE_ID_FILE" ]]; then
    cp "$VAULT_ROLE_ID_FILE" "/opt/vault/conf/role_id.txt"
    echo "[VAULT-CONFIG] ✅ role_id.txt скопирован"
else
    echo "[VAULT-CONFIG] ⚠️  role_id.txt пустой или не существует"
    print_warning "role_id.txt пустой - vault-agent не сможет аутентифицироваться!"
fi
```

## Ожидаемый результат после применения исправлений

### На сервере должны появиться:
```
/opt/vault/conf/agent.hcl          # С реальными путями, без шаблонов
/opt/vault/conf/role_id.txt        # С реальным role_id (если извлечен)
/opt/vault/conf/secret_id.txt      # С реальным secret_id (если извлечен)
/home/CIxxxx-lnx-mon_ci/monitoring/config/vault/agent.hcl  # User-space версия
```

### Vault-agent должен:
1. Получить правильный `agent.hcl` с реальными путями
2. Иметь блоки `template` для генерации сертификатов и `data_sec.json`
3. Создавать сертификаты с правами `0640` (доступны группе `va-read`)
4. Быть перезапущен с новой конфигурацией

## Диагностика проблем

### Если секреты не извлекаются:
1. Проверить наличие поля `vault-agent.role_id` и `vault-agent.secret_id` в `temp_data_cred.json`
2. Проверить работоспособность `secrets-manager-wrapper`
3. Проверить права на чтение `temp_data_cred.json`

### Если нет прав на запись в `/opt/vault/conf/`:
1. Пользователь должен быть в группе `${KAE}-lnx-va-start`
2. Можно добавить вручную через IDM
3. Или скопировать файлы вручную: `cp $VAULT_AGENT_HCL /opt/vault/conf/agent.hcl`

## Безопасность
- Все секреты извлекаются через `secrets-manager-wrapper`
- Автоматический `unset` секретов после использования
- Минимальные права на файлы (`chmod 640`)
- Изоляция user-space и системных компонентов

## Следующие шаги
1. Применить исправленный скрипт на сервере
2. Проверить создание файлов в `/opt/vault/conf/`
3. Проверить работу vault-agent
4. Проверить генерацию сертификатов в `/opt/vault/certs/`