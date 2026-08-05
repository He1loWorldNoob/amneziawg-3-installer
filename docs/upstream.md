# Апстрим и наши правки

## Источники

| Файл в `vendor/` | Откуда | Версия | Дата |
|---|---|---|---|
| `install_amneziawg_en.sh` | [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) | 5.23.0 | 2026-07-31 |
| `awg_common_en.sh` | там же, тег `v5.23.0` | 5.23.0 | 2026-07-31 |
| `awg3-apply.sh` | локальный одноразовый скрипт переноса конфигов на 3.0 | — | 2026-08-04 |

`awg3.sh` в корне — собственный скрипт, исторически вобравший генератор
параметров из
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

## Отличия `install-awg3.sh` от апстрима

Объём: 3993 → 3283 строки.

### Удалено

| Что | Почему |
|---|---|
| `step5_download_scripts`, `_secure_download`, `verify_sha256` | скачивание `awg_common.sh` и `manage_amneziawg.sh` с GitHub; сеть к репозиторию bivlked больше не нужна |
| `step6_generate_configs` | заменён вызовом `awg3.sh server-init` |
| `generate_awg_params`, `generate_awg_h_ranges`, `generate_cps_i1`, `rand_range` | параметры 2.0; для 3.0 их генерирует `awg3.sh` |
| `safe_load_config`, `safe_read_config_key` | чтение `awgsetup_cfg.init`, которого больше нет |
| `guard_subnet_change_with_peers` | опиралась на сохранённую подсеть из файла настроек |
| `configure_server_name`, `validate_server_name`, `resolve_mobile_flag`, `_trim_ws` | нужны были для `vpn://` URI в `manage_amneziawg.sh` |
| `initialize_setup` (403 строки) | опрос и запись файла настроек; заменён на `parse_args` + `ask_params` |
| `show_help` | переписан под наши флаги |
| разбор аргументов на верхнем уровне | перенесён в `parse_args()`, иначе скрипт нельзя подключить как библиотеку для тестов |
| `exit 0` в конце файла | обрывал подключение через `source` |

### Изменено

| Что | Как |
|---|---|
| `AWG_DIR` | вместо константы `/root/awg` — функция `resolve_awg_dir()`: домашний каталог целевого пользователя (`SUDO_USER`), либо `/root/awg`; перекрывается `--awg-dir` и `AWG3_DIR` |
| источник истины | только `/etc/amnezia/amneziawg/awg0.conf`; порт для проверок и удаления правил UFW читается из него же |
| `secure_files` | вместо `keys/` и файла настроек — каталоги клиентов (700) и файлы `.private`/`.public` (600) |
| `create_diagnostic_report` | в отчёте дополнительно скрываются `HeaderProtectionKey` и `PresharedKey` — по ним восстанавливается доступ к туннелю, а отчёт часто уходит в issue |
| `step_uninstall` | прежний `--no-tweaks` не читается из файла настроек, берётся текущий флаг; правила снимаются идемпотентно |
| хвост скрипта | вместо state-машины `while (( current_step < 99 ))` — `main()` с пятью сценариями |

### Добавлено

| Что | Зачем |
|---|---|
| `bootstrap.sh` | подготовка системы, которой в апстриме нет вовсе |
| меню сценариев + `--mode` | пять сценариев: `full`, `awg-only`, `upgrade`, `reinstall`, `uninstall` |
| `ask_params` / `validate_params` | опрос параметров сервера с дефолтами и проверкой |
| `install_awg3_script` | установка `awg3.sh` в каталог данных + симлинк `/usr/local/sbin/awg3` |
| `run_server_init`, `create_initial_clients` | стык с `awg3.sh` |
| source-guard | подключение как библиотеки для юнит-тестов |

## Отличия `awg3.sh` от прежней версии (1.1.0 → 1.2.0)

- **Добавлена команда `server-init`** — создание сервера AWG 3.0 с нуля:
  `guard_existing_server`, `enable_forwarding`, `cmd_server_init`,
  `_rollback_server_init`, `generate_server_keys`, `derive_ipv6_server_addr`,
  `extract_peers`, `render_server_conf`, `build_postup`, `build_postdown`,
  `validate_awg_port`, `validate_subnet`, `validate_mtu`, `port_is_free`,
  `get_main_nic`.
- **Удалено чтение `awgsetup_cfg.init`** в `resolve_endpoint` и его бэкап в
  `cmd_backup`.
- **`cmd_list` показывает состояние сервера**: порт, подсеть, MTU, изоляция
  клиентов и IPv6 — всё вычисляется из `awg0.conf`, включая изоляцию по
  наличию правила `FORWARD -i %i -o %i -j DROP` в `PostUp`.
- **`check_dependencies`** дополнен `ip` и `iptables`.
- **source-guard** в конце файла — для юнит-тестов.
- Исправлено маскирование кода возврата в `_backup_file`
  (`local bak=$(date ...)` → объявление отдельно от присваивания).

## Что осознанно НЕ переносилось

- ARM-сборки (`_try_install_prebuilt_arm`) оставлены как есть — не тестировались;
- пин модуля на 2.0 (`AWG2_PIN_TAG`, `_install_pinned_awg2_module`) сохранён:
  на ядрах старше 6.7 сборка 3.0-модуля не проходит, и запасной путь нужен;
- проверка Secure Boot сохранена — она даёт внятное сообщение вместо
  «Key was rejected by service».
