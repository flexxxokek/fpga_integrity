# Архитектура

## 1. Слои проекта

```mermaid
flowchart TB
    subgraph cores["rtl/cores — вычислительные ядра"]
        P[parity] --- C[checksum] --- F[fletcher] --- A[adler32] --- CR[crc_engine generic] --- S[sha256]
    end
    subgraph wrap["rtl/wrappers — единый интерфейс"]
        TX["integrity_tx: расчёт + вставка тега"]
        RX["integrity_rx: извлечение + проверка + tag_error"]
    end
    subgraph harness["rtl/harness — измерительный стенд"]
        STIM[stimulus_gen] --> BC["broadcast register"]
        BC --> LANES["N lanes: TX → error_injector → RX → counters"]
        LANES --> CTRL[experiment_ctrl]
        CTRL --> UART[uart_tx / uart_rx]
    end
    subgraph board["boards/<name> — board-зависимый слой"]
        BT["board_top: клоки, сброс, пины, UART-физика"]
    end
    cores --> wrap --> harness --> board
```

Принцип: всё, кроме `boards/`, не зависит от вендора и кристалла.
При получении платы добавляется только тонкая обёртка и constraints.

## 2. Ядра (`rtl/cores`)

Один параметризуемый движок на класс алгоритмов:

| Модуль | Параметры | Покрывает |
|--------|-----------|-----------|
| `parity_core` | `MODE` (even/odd) | бит чётности |
| `checksum_core` | `SUM_WIDTH`, `ONES_COMPLEMENT` | checksum-8/16/32, Internet |
| `fletcher_core` | `BLOCK_WIDTH` | Fletcher-16/32 |
| `adler32_core` | — | Adler-32 |
| `crc_engine` | `CRC_WIDTH`, `POLY`, `INIT`, `REFIN`, `REFOUT`, `XOROUT` | все CRC из спецификации |
| `sha256_core` | — | SHA-256 (расширенный трек) |

CRC реализован одним последовательным MSB-first LFSR-движком; для
REFIN/REFOUT входные байты и итоговый остаток переворачиваются. Отдельного
скрипта генерации параллельных уравнений нет — `scripts/gen_crc.py` был
удалён как неиспользуемый: в репозитории не осталось мёртвых скриптов.

## 3. Обёртки (`rtl/wrappers`)

`integrity_tx` и `integrity_rx` параметризуются шириной тега и ссылкой
на ядро (через интерфейс/инстанс). Обеспечивают единые правила вставки/извлечения
тега, буферизацию хвоста, `busy`, `tag_value/tag_valid/tag_error`
согласно [spec.md](spec.md).

## 4. Стенд (`rtl/harness`)

| Блок | Назначение |
|------|------------|
| `stimulus_gen` | PRNG-генератор пакетов: seed, диапазон длин, детерминированное воспроизведение |
| `broadcast register` | удерживает beat, пока его не примут все lanes; гарантирует одинаковый поток и отсутствие повторного приёма |
| `error_injector` | режимы: clean, single-bit, burst (длина L), byte-swap, zero-insert; вставляется после TX каждого lane и искажает только payload, поэтому тег считается по чистым данным, а искажение одинаково для всех lanes |
| `lane[N]` | TX → error_injector → RX одного алгоритма + счётчики (см. measurement_plan) |
| `experiment_ctrl` | FSM: приём команды, запуск кампании, сбор счётчиков, выдача отчёта |
| `uart_tx/rx` | обмен с хостом; 115200 8N1, подтверждено на DE2-115 |

Топ стенда `exp_harness_top` имеет board-независимые порты:
`clk`, `rst`, `uart_txd`, `uart_rxd`, опционально `leds` для bring-up.

## 5. Board-абстракция (`boards/`)

Для DE2-115 каталог заполнен:

```
boards/de2_115/
├── de2_115.qpf / .qsf / .sdc  # проект Quartus, пины, 50 МГц → 12.5 МГц
├── de2_115_top.sv             # инстанс exp_harness_top + POR/клок/HEX/LED
└── output_files/              # .sof и отчёты (игнорируются git)
```

Отдельная прошивка [`boards/de2_115_interactive/`](../boards/de2_115_interactive/)
использует тот же UART-протокол для интерактивной демонстрации хешей.

Выбор САПР, кристалла и целевой частоты зафиксирован в [board.md](board.md)
и [decisions.md](decisions.md) (D-11).

## 6. Хост-часть (`scripts/`)

- `collect.py` — приём отчётов по UART (pyserial), сохранение в `data/*.csv`.
- `parse_reports.py` — извлечение LUT/FF/Fmax из отчётов САПР.
- `analyze.py` — таблицы и графики (только stdlib + опциональный matplotlib),
  экспорт в `docs/results/`.
- `synth.py` / `synth_table.py` — синтез Yosys и таблица статических метрик.
- `cov_report.py` — слияние покрытия всех конфигураций.
