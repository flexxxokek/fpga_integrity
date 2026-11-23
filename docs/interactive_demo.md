# Интерактивная демонстрация хешей на DE2-115

Отдельная прошивка `boards/de2_115_interactive/` позволяет ввести пакет на
компьютере, передать его по UART на FPGA, получить все 6 тегов и время их
вычисления в тактах, затем свериться с эталоном на Python.

Это **не** измерительный стенд: это демонстрация работы алгоритмов. Для
кампаний искажений остаётся обычная прошивка `boards/de2_115/`.

## Протокол

**PC → FPGA** (115200 8N1):

```
A5 5A LEN <LEN байт> XOR
```

`XOR` — побитовое XOR всех предыдущих байт кадра, `LEN` = 1…64. Хост шлёт
байты с небольшой паузой: приёмник FPGA обрабатывает по одному байту за раз.

**FPGA → PC** (фиксированный бинарный ответ):

```
для lane 0..5:  32 байта тега (MSB first) + 4 байта ticks (little endian)
затем:          "DONE" (4 байта)
```

`TICKS` — реальное число тактов стенда (12.5 МГц) от первого принятого байта
пакета до `tag_valid` соответствующего ядра. Это позволяет сравнивать
алгоритмы по скорости **в железе**, а не только в симуляции.

## Сборка и запуск

```bash
make interactive-build      # Quartus-проект de2_115_interactive
make interactive-program    # прошить DEMO-прошивку (JTAG должен быть подключён)
make hash-demo PORT=/dev/ttyUSB0 TEXT=123456789
make hash-demo PORT=/dev/ttyUSB0 HEX=00010203...
make hash-demo PORT=/dev/ttyUSB0 FILE=packet.bin
```

Возврат к измерительному стенду:

```bash
make board-program          # прошить обычную прошивку boards/de2_115/
```

## Пример результата

```
| lane | algorithm  | ticks | ticks/byte | FPGA tag | Python tag | match |
|-----:|------------|------:|-----------:|----------|------------|:-----:|
| 0 | parity     |    11 |       1.22 | 1 | 1 | OK |
| 5 | sha256     |   109 |      12.11 | 25B28E44... | 25B28E44... | OK |

PASS: all 6 FPGA tags match the Python reference
```

Эталон считается функциями `tb/model.py` (zlib/hashlib/CRC-модель), тот же
код используется в регрессии cocotb.

## Верификация RTL demо

```bash
.venv/bin/python scripts/sim_uart_rx.py       # cocotb: приёмник UART
.venv/bin/python scripts/sim_interactive_top.py  # cocotb: полный проход кадра
```

Оба теста запускаются без платы.
