# awg3-deploy

Развёртывание AmneziaWG 3.0 на сервере с полного нуля: подготовка системы,
установка AmneziaWG, создание 3.0-конфигурации и управление клиентами.

**Статус: дизайн согласован, реализация не начата.**
Спека — [`docs/superpowers/specs/2026-08-05-awg3-deploy-design.md`](docs/superpowers/specs/2026-08-05-awg3-deploy-design.md).

## Что здесь будет

| Файл | Назначение |
|---|---|
| `bootstrap.sh` | подготовка свежего сервера: обновление, `sudo`, новый sudo-пользователь, SSH-порт, отключение root по SSH, фаервол |
| `install-awg3.sh` | установка AmneziaWG и запуск `server-init` |
| `awg3.sh` | управление: `server-init`, `add`, `remove`, `list`, `stats`, `backup` |

## Требования

- Debian 12/13 или Ubuntu 22.04/24.04
- root-доступ на старте
- поддержка DKMS (обычная ВМ; LXC-контейнер не подойдёт — модуль ядра
  собирается на хосте)

## Быстрый старт (после реализации)

```bash
# на сервере, под root
./bootstrap.sh                 # система, пользователь, SSH
# переподключиться под новым пользователем на новом порту
sudo ./install-awg3.sh         # AmneziaWG 3.0
sudo awg3 add my_phone         # первый клиент, QR рядом с конфигом
```

## Происхождение

Форк [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer)
v5.23.0. Что именно изменено и как обновлять апстрим —
[`docs/upstream.md`](docs/upstream.md).
