# Interactive demo: 50 MHz input, 12.5 MHz stand clock.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
create_generated_clock -name CLK_12M5 -source [get_ports CLOCK_50] \
    -divide_by 4 [get_registers {div_q[1]}]
