# Bundled sing-box

Сюда `scripts/fetch-singbox.sh` кладёт бинарник перед сборкой.
В git не коммитится — только `.gitkeep`.

```bash
# пример: перед go build под macOS arm64
../../scripts/fetch-singbox.sh darwin arm64 .
```

Лицензия sing-box: GPL-3.0-or-later (файл `sing-box-LICENSE` после fetch).
