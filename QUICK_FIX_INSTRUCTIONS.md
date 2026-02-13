# Быстрое исправление проблемы с vault-agent

## Проблема
1. `secrets-manager-wrapper` не извлекает секреты из `temp_data_cred.json`
2. Файлы `role_id.txt` и `secret_id.txt` остаются пустыми
3. Vault-agent получает шаблонный `agent.hcl` с `%your_role_id_file_path%`

## Решение (уже в коде)
Я добавил fallback механизм: если `secrets-manager-wrapper` не работает, секреты извлекаются напрямую через `jq`.

## Что нужно сделать на сервере:

### 1. Запустить диагностический скрипт
```bash
cd /home/CI10742292-lnx-mon_ci/monitoring-deployment
chmod +x debug_secrets.sh
./debug_secrets.sh
```

### 2. Проверить вручную извлечение секретов
```bash
# Проверить наличие секретов в файле
sudo cat /home/CI10742292-lnx-mon_ci/monitoring-deployment/temp_data_cred.json | jq '.vault-agent'

# Извлечь вручную через jq
sudo jq -r '.vault-agent.role_id' /home/CI10742292-lnx-mon_ci/monitoring-deployment/temp_data_cred.json
sudo jq -r '.vault-agent.secret_id' /home/CI10742292-lnx-mon_ci/monitoring-deployment/temp_data_cred.json
```

### 3. Запустить исправленный скрипт
```bash
cd /home/CI10742292-lnx-mon_ci/monitoring-deployment
./install-monitoring-stack.sh
```

### 4. Проверить результат
```bash
# Проверить созданные файлы
sudo ls -la /opt/vault/conf/
sudo cat /opt/vault/conf/agent.hcl | grep -A2 -B2 "role_id_file_path"

# Проверить vault-agent
sudo systemctl status vault-agent
```

## Если проблема осталась:

### Вариант A: Вручную создать файлы
```bash
# Извлечь секреты вручную
ROLE_ID=$(sudo jq -r '.vault-agent.role_id' /home/CI10742292-lnx-mon_ci/monitoring-deployment/temp_data_cred.json)
SECRET_ID=$(sudo jq -r '.vault-agent.secret_id' /home/CI10742292-lnx-mon_ci/monitoring-deployment/temp_data_cred.json)

# Записать в системные файлы
echo "$ROLE_ID" | sudo tee /opt/vault/conf/role_id.txt
echo "$SECRET_ID" | sudo tee /opt/vault/conf/secret_id.txt

# Установить права
sudo chmod 640 /opt/vault/conf/role_id.txt /opt/vault/conf/secret_id.txt
sudo chown CI10742292-lnx-va-start:CI10742292-lnx-va-read /opt/vault/conf/role_id.txt /opt/vault/conf/secret_id.txt

# Перезапустить vault-agent
sudo systemctl restart vault-agent
```

### Вариант B: Проверить и исправить wrapper
```bash
# Проверить wrapper
ls -la /home/CI10742292-lnx-mon_ci/monitoring-deployment/wrappers/
chmod +x /home/CI10742292-lnx-mon_ci/monitoring-deployment/wrappers/secrets-manager-wrapper_launcher.sh

# Проверить работу wrapper
/home/CI10742292-lnx-mon_ci/monitoring-deployment/wrappers/secrets-manager-wrapper_launcher.sh extract_secret \
  /home/CI10742292-lnx-mon_ci/monitoring-deployment/temp_data_cred.json \
  "vault-agent.role_id"
```

## Ожидаемый результат
После исправлений должны появиться:
- `/opt/vault/conf/role_id.txt` с реальным role_id
- `/opt/vault/conf/secret_id.txt` с реальным secret_id  
- `/opt/vault/conf/agent.hcl` с правильными путями (без шаблонов)
- Vault-agent должен перезапуститься и начать генерировать сертификаты