# Board layer

## Terasic DE2-115 (Cyclone IV E EP4CE115F29C7)

Плата получена 2026-11-23. Board-пакет лежит в [`de2_115/`](de2_115/):

```
de2_115/
├── de2_115.qpf       # Quartus project
├── de2_115.qsf       # device, sources, pin assignments, IO standards
├── de2_115.sdc       # 50 MHz input + generated 12.5 MHz stand clock
├── de2_115_top.sv    # board top: KEY/LED/UART -> exp_harness_top
└── output_files/     # .sof и отчёты (игнорируются git)
```

Характеристики и чеклист bring-up: [docs/board.md](../docs/board.md).

### Быстрый старт

```bash
make board-build    # Quartus compile + TimeQuest + docs/results/board.md
# подключить USB-Blaster / JTAG
make board-program  # прошивка .sof
make board-capture PORT=/dev/ttyUSB0  # приём RESULT/DONE + сверка с референсом
```

Отчёт отправляется **сразу после конфигурации** ПЛИС (POR → кампания → UART),
поэтому надёжнее сначала запустить приём, а затем выполнить `make board-program`.
Повторно отчёт можно вызвать нажатием KEY[0] (короткий reset-импульс по фронту).
Скрипт сравнивает все 6 lane с `data/sim_clean_w32.csv`.

Стенд работает на 12.5 МГц (`CLOCK_50 / 4`): Fmax полного стенда 20.45 МГц
(TimeQuest, worst slack +10.939 нс), поэтому прямая работа на 50 МГц не
закрывает тайминг.

`make board-build` использует `QUARTUS_SH` (по умолчанию
`/opt/intelFPGA/21.1/quartus/bin/quartus_sh`). Параметры кампании
(`NUM_PACKETS`, `LEN_MAX`, `MODE`, `SEED`) заданы в `de2_115_top.sv` и
совпадают с симуляционным референсом `data/sim_clean_w32.csv`.

## Обязательные проверки bring-up

1. Смок-тест тактовой сети и сброса: `LEDR[0]` мигает с периодом ~1.3 с.
   Визуализация: HEX7 — номер lane (KEY[1] переключает), HEX6…4 — пакеты (live),
   HEX3…0 — байты (live); LEDG[5:0] — успех по lane, LEDG[8] — done.
2. UART: после сброса приходят 6 строк `RESULT,...` и `DONE` на 115200 8N1.
3. Прогон `MODE=0` на 64 пакетах; побайтовая сверка с референсом из симуляции.
4. Только после этого — кампании `MODE=1..9`.

Метрики в `docs/results/` — симуляционные (Yosys gate-equivalent) или вендорные
статические из Quartus. Данные со всех кампаний на плате (`MODE=0..9`) —
`data/board_*_2026-11-25.log`; сравнение с симуляцией и тайминг по режимам —
[docs/results/board_campaigns.md](../docs/results/board_campaigns.md).
