# Апстрим и наши правки

## Источники

| Файл в `vendor/` | Откуда | Версия | Дата |
|---|---|---|---|
| `install_amneziawg_en.sh` | [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) | 5.23.0 | 2026-07-31 |
| `awg_common_en.sh` | там же, тег `v5.23.0` | 5.23.0 | 2026-07-31 |
| `awg3-apply.sh` | локальный одноразовый скрипт переноса конфигов на 3.0 | — | 2026-08-04 |

`awg3.sh` в корне — собственный скрипт (версия 1.1.0 на момент форка),
исторически вобравший генератор параметров из
[Vadim-Khristenko/AmneziaWG-Architect](https://github.com/Vadim-Khristenko/AmneziaWG-Architect)
(`awg-gen.sh`). Кодовой зависимости от Architect нет.

`vendor/` в работе не участвует. Он нужен, чтобы при выходе новой версии
апстрима увидеть через `git diff`, что изменилось у bivlked, и решить,
переносить ли это к себе.

## Как обновлять апстрим

```bash
curl -fsSL -o vendor/install_amneziawg_en.sh \
    https://raw.githubusercontent.com/bivlked/amneziawg-installer/vX.Y.Z/install_amneziawg_en.sh
curl -fsSL -o vendor/awg_common_en.sh \
    https://raw.githubusercontent.com/bivlked/amneziawg-installer/vX.Y.Z/awg_common_en.sh
git diff vendor/
```

Дальше вручную решить, что из изменений переносить в `install-awg3.sh`.

## Список наших отличий от апстрима

Заполняется по мере реализации. Планируемые (см. спеку
`docs/superpowers/specs/2026-08-05-awg3-deploy-design.md`):

### Удаляется

- `step5_download_scripts` — скачивание `awg_common.sh` и
  `manage_amneziawg.sh` с GitHub; больше не требуется сеть к репозиторию
  bivlked;
- `step6_generate_configs` — заменяется вызовом `awg3.sh server-init`;
- `generate_awg_params`, `generate_awg_h_ranges` — параметры 2.0; для 3.0 их
  генерирует `awg3.sh`;
- `safe_load_config`, `safe_read_config_key`, `warn_awg_init_drift`,
  `_awg_drift_dump`, `guard_subnet_change_with_peers` — работа с
  `awgsetup_cfg.init`, который больше не создаётся.

### Меняется

- `AWG_DIR` — вместо константы `/root/awg` вычисляется: домашний каталог
  целевого пользователя либо `/root/awg` в чисто-root установке;
- дефолт изоляции клиентов — с `on` на `off`;
- источник истины — только `/etc/amnezia/amneziawg/awg0.conf`.

### Добавляется

- `bootstrap.sh` — подготовка системы, которой в апстриме нет вовсе;
- меню сценариев развёртывания;
- `awg3.sh server-init` — создание 3.0-сервера с нуля.
