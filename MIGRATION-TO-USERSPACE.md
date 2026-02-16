# 🚀 Миграция на User-Space архитектуру (согласно требованиям ИБ)

## 📋 Текущая проблема

Vault-agent требует:
- ❌ Системные пути: `/opt/vault/conf/`, `/opt/vault/certs/`
- ❌ Root права: `sudo cp`, `sudo chown`, `sudo chmod`, `sudo mkdir`, `sudo systemctl`
- ❌ 19+ sudo-команд для работы с `/opt/vault/`

**Это противоречит требованиям ИБ!**

---

## ✅ Целевая архитектура (User-Space)

### Принципы (из документации ИБ):
1. ✅ **Все файлы в user-space**: `$HOME/monitoring/`
2. ✅ **User units**: `systemctl --user` вместо системных
3. ✅ **Разделение ролей**:
   - `CI10742292-lnx-mon_ci` — деплой (ТУЗ)
   - `CI10742292-lnx-mon_sys` — запуск сервисов (СУЗ, nologin)
   - Опционально: `CI10742292-lnx-mon_ro` — read-only
4. ✅ **Минимум sudo**: только для управления user-юнитами sys-пользователя

---

## 🏗️ Новая структура каталогов

```
/home/CI10742292-lnx-mon_sys/          # Домашний каталог sys-пользователя
├── .config/
│   └── systemd/user/                  # User units
│       ├── vault-agent.service        # ⬅️ НОВОЕ: vault-agent как user unit
│       ├── monitoring-prometheus.service
│       ├── monitoring-grafana.service
│       └── monitoring-harvest.service
├── monitoring/
│   ├── vault-agent/                   # ⬅️ НОВОЕ: vault-agent в user-space
│   │   ├── bin/                       # Бинарь vault (если нужен отдельный)
│   │   ├── config/
│   │   │   ├── agent.hcl              # Конфигурация vault-agent
│   │   │   ├── role_id.txt            # Credentials (640)
│   │   │   └── secret_id.txt          # Credentials (640)
│   │   ├── certs/                     # ⬅️ Сертификаты генерируются здесь!
│   │   │   ├── server_bundle.pem
│   │   │   ├── ca_chain.crt
│   │   │   └── grafana-client.pem
│   │   └── log/                       # Логи vault-agent
│   │       └── agent.log
│   ├── bin/                           # Бинари сервисов (Prometheus, Grafana, Harvest)
│   ├── config/                        # Конфиги сервисов
│   ├── data/                          # Данные сервисов
│   └── log/                           # Логи сервисов
```

---

## 🔧 Vault-agent в user-space: agent.hcl

```hcl
# User-space vault-agent configuration
pid_file = "/home/CI10742292-lnx-mon_sys/monitoring/vault-agent/log/vault-agent.pidfile"

vault {
  address = "https://secman.sigma.sbrf.ru:8200"
  tls_skip_verify = "false"
  ca_path = "/etc/pki/ca-trust/extracted/pem/"  # Системные CA
}

auto_auth {
  method "approle" {
    namespace = "CI10742292"
    mount_path = "auth/approle"
    
    config = {
      # ⬅️ User-space credentials!
      role_id_file_path = "/home/CI10742292-lnx-mon_sys/monitoring/vault-agent/config/role_id.txt"
      secret_id_file_path = "/home/CI10742292-lnx-mon_sys/monitoring/vault-agent/config/secret_id.txt"
      remove_secret_id_file_after_reading = false
    }
  }
}

log_destination "Tengry" {
  log_format = "json"
  log_path = "/home/CI10742292-lnx-mon_sys/monitoring/vault-agent/log"
  log_rotate = "5"
  log_max_size = "5mb"
  log_level = "trace"
  log_file = "agent.log"
}

# Шаблон для сертификатов (генерируются в user-space!)
template {
  destination = "/home/CI10742292-lnx-mon_sys/monitoring/vault-agent/certs/server_bundle.pem"
  contents = <<EOT
{{- with secret "pki/CI10742292/sberca/fetch/..." -}}
{{ .Data.private_key }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end -}}
EOT
  perms = "0600"
}

template {
  destination = "/home/CI10742292-lnx-mon_sys/monitoring/vault-agent/certs/ca_chain.crt"
  contents = <<EOT
{{- with secret "pki/CI10742292/sberca/fetch/..." -}}
{{ .Data.issuing_ca }}
{{- end -}}
EOT
  perms = "0600"
}

template {
  destination = "/home/CI10742292-lnx-mon_sys/monitoring/vault-agent/certs/grafana-client.pem"
  contents = <<EOT
{{- with secret "pki/CI10742292/sberca/fetch/..." -}}
{{ .Data.private_key }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end -}}
EOT
  perms = "0600"
}
```

---

## 🔄 User Unit для vault-agent

Файл: `~/.config/systemd/user/vault-agent.service`

```ini
[Unit]
Description=HashiCorp Vault Agent (User-Space)
Documentation=https://www.vaultproject.io/docs/agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
# Бинарь vault из системного пакета или user-space
ExecStart=/opt/vault/bin/vault agent -config=%h/monitoring/vault-agent/config/agent.hcl
Restart=on-failure
RestartSec=5s

# Ограничения безопасности
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/monitoring/vault-agent/certs %h/monitoring/vault-agent/log

[Install]
WantedBy=default.target
```

---

## 🚀 Управление vault-agent (user-space)

### От CI10742292-lnx-mon_ci (через sudo):
```bash
# Запуск
sudo -u CI10742292-lnx-mon_sys systemctl --user start vault-agent

# Статус
sudo -u CI10742292-lnx-mon_sys systemctl --user status vault-agent

# Перезапуск
sudo -u CI10742292-lnx-mon_sys systemctl --user restart vault-agent

# Логи
sudo -u CI10742292-lnx-mon_sys journalctl --user -u vault-agent -n 50
```

### Права sudo (ТОЛЬКО ЭТИ!)
```
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user start vault-agent.service
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user stop vault-agent.service
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user restart vault-agent.service
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user status vault-agent.service
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user is-active vault-agent.service
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user enable vault-agent.service
ALL=(CI10742292-lnx-mon_sys) NOEXEC: NOPASSWD: /usr/bin/systemctl --user daemon-reload
```

**ИТОГО: 7 команд вместо 37!** ✅

---

## 📦 Установка vault binary (опционально)

Если vault не установлен системно, можно использовать user-space установку:

```bash
# 1. Скачать vault binary из Nexus
curl -o ~/monitoring/vault-agent/bin/vault https://infra.nexus.sigma.sbrf.ru/path/to/vault

# 2. Права
chmod 700 ~/monitoring/vault-agent/bin/vault

# 3. Обновить ExecStart в vault-agent.service:
ExecStart=%h/monitoring/vault-agent/bin/vault agent -config=%h/monitoring/vault-agent/config/agent.hcl
```

---

## 🔄 Миграция с /opt/vault/ на user-space

### Шаг 1: Подготовка структуры (mon_ci)
```bash
# Создание структуры в home-каталоге sys-пользователя
SYSUSER_HOME="/home/CI10742292-lnx-mon_sys"

mkdir -p "$SYSUSER_HOME/monitoring/vault-agent/"{config,certs,log,bin}
mkdir -p "$SYSUSER_HOME/.config/systemd/user"

# Права (все принадлежит sys-пользователю!)
# Это делается через RLM или через sudo -u
sudo -u CI10742292-lnx-mon_sys bash << 'EOF'
chmod 700 ~/monitoring/vault-agent/config
chmod 700 ~/monitoring/vault-agent/certs
chmod 755 ~/monitoring/vault-agent/log
EOF
```

### Шаг 2: Копирование credentials (mon_ci)
```bash
# Credentials создаются mon_ci, копируются в sys
cp role_id.txt secret_id.txt "$SYSUSER_HOME/monitoring/vault-agent/config/"
chown CI10742292-lnx-mon_sys:CI10742292-lnx-mon_sys "$SYSUSER_HOME/monitoring/vault-agent/config/"*.txt
chmod 600 "$SYSUSER_HOME/monitoring/vault-agent/config/"*.txt
```

### Шаг 3: Создание agent.hcl (mon_ci)
```bash
# Генерация agent.hcl с правильными путями
cat > "$SYSUSER_HOME/monitoring/vault-agent/config/agent.hcl" << 'EOF'
# ... (см. выше)
EOF

chown CI10742292-lnx-mon_sys:CI10742292-lnx-mon_sys "$SYSUSER_HOME/monitoring/vault-agent/config/agent.hcl"
chmod 640 "$SYSUSER_HOME/monitoring/vault-agent/config/agent.hcl"
```

### Шаг 4: Создание user unit (mon_ci)
```bash
cat > "$SYSUSER_HOME/.config/systemd/user/vault-agent.service" << 'EOF'
# ... (см. выше)
EOF

chown CI10742292-lnx-mon_sys:CI10742292-lnx-mon_sys "$SYSUSER_HOME/.config/systemd/user/vault-agent.service"
chmod 644 "$SYSUSER_HOME/.config/systemd/user/vault-agent.service"
```

### Шаг 5: Enable linger (один раз!)
```bash
# Это позволяет user units работать после logout
sudo linuxadm-enable-linger CI10742292-lnx-mon_sys
```

### Шаг 6: Запуск vault-agent (mon_ci через sudo)
```bash
# Reload user daemon
sudo -u CI10742292-lnx-mon_sys systemctl --user daemon-reload

# Enable autostart
sudo -u CI10742292-lnx-mon_sys systemctl --user enable vault-agent.service

# Start
sudo -u CI10742292-lnx-mon_sys systemctl --user start vault-agent.service

# Проверка
sudo -u CI10742292-lnx-mon_sys systemctl --user status vault-agent.service
```

### Шаг 7: Проверка сертификатов
```bash
# Подождать 10-30 секунд для генерации
sleep 15

# Проверить
ls -lah "$SYSUSER_HOME/monitoring/vault-agent/certs/"
# Должны быть: server_bundle.pem, ca_chain.crt, grafana-client.pem
```

---

## ✅ Преимущества user-space подхода

| Аспект | `/opt/vault/` (старый) | User-space (новый) | Выигрыш |
|--------|------------------------|-------------------|---------|
| **Sudo-команд** | 37 | 7 | ✅ 81% меньше |
| **Системные пути** | `/opt/vault/` | `~/monitoring/` | ✅ Соответствует ИБ |
| **Права root** | Да | Нет | ✅ Безопаснее |
| **Разделение ролей** | Нет | Да (CI/SYS/RO) | ✅ Best practice |
| **Восстановление** | Сложно | Просто (в home) | ✅ Удобнее |
| **Автономность** | Требует админа | Полная | ✅ Self-service |

---

## 🛠️ Временное решение для dev (до IDM)

Если права в IDM еще не выданы, можно временно использовать wrapper-скрипт:

```bash
#!/bin/bash
# /tmp/dev-vault-wrapper.sh
# ТОЛЬКО ДЛЯ DEV! УДАЛИТЬ НА PROD!

SYSUSER="CI10742292-lnx-mon_sys"

case "$1" in
    start|stop|restart|status|enable)
        sudo -u "$SYSUSER" systemctl --user "$1" vault-agent.service
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|enable}"
        exit 1
        ;;
esac
```

Права для dev:
```
CI10742292-lnx-mon_ci ALL=(CI10742292-lnx-mon_sys) NOPASSWD: /usr/bin/systemctl --user * vault-agent.service
```
(После получения прав в IDM заменить на конкретные команды!)

---

## 📋 Checklist миграции

- [ ] Создать структуру каталогов в `~/monitoring/vault-agent/`
- [ ] Скопировать credentials (role_id.txt, secret_id.txt)
- [ ] Создать agent.hcl с user-space путями
- [ ] Создать user unit: `~/.config/systemd/user/vault-agent.service`
- [ ] Enable linger: `sudo linuxadm-enable-linger CI10742292-lnx-mon_sys`
- [ ] Запросить 7 sudo-команд в IDM (вместо 37!)
- [ ] Запустить vault-agent: `systemctl --user start vault-agent`
- [ ] Проверить сертификаты в `~/monitoring/vault-agent/certs/`
- [ ] Обновить мониторинг-сервисы для чтения из user-space
- [ ] Удалить старые файлы из `/opt/vault/` (если были)

---

## 🎯 Финальная архитектура (полностью user-space)

```
CI10742292-lnx-mon_ci (деплой)
    ↓ sudo -u mon_sys systemctl --user ...
CI10742292-lnx-mon_sys (запуск сервисов)
    ├── vault-agent.service (user unit)
    │   └── Генерирует сертификаты в ~/monitoring/vault-agent/certs/
    ├── monitoring-prometheus.service (user unit)
    ├── monitoring-grafana.service (user unit)
    └── monitoring-harvest.service (user unit)
```

**✅ Полное соответствие требованиям ИБ!**
**✅ Минимум sudo-прав!**
**✅ Self-service архитектура!**
