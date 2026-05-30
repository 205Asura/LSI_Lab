current_design cubic_solver

create_clock -name "clk" -add -period 100.0 -waveform {0.0 50.0} [get_ports clk]

set_input_delay  -clock [get_clocks clk] -add_delay 1.0 [get_ports rst_n]
set_input_delay  -clock [get_clocks clk] -add_delay 1.0 [get_ports start]
set_input_delay  -clock [get_clocks clk] -add_delay 1.0 [get_ports a]
set_input_delay  -clock [get_clocks clk] -add_delay 1.0 [get_ports b]
set_input_delay  -clock [get_clocks clk] -add_delay 1.0 [get_ports c]
set_input_delay  -clock [get_clocks clk] -add_delay 1.0 [get_ports d]

set_output_delay -clock [get_clocks clk] -add_delay 1.0 [get_ports done]
set_output_delay -clock [get_clocks clk] -add_delay 1.0 [get_ports x0_re]
set_output_delay -clock [get_clocks clk] -add_delay 1.0 [get_ports x0_im]
set_output_delay -clock [get_clocks clk] -add_delay 1.0 [get_ports x1_re]
set_output_delay -clock [get_clocks clk] -add_delay 1.0 [get_ports x1_im]
set_output_delay -clock [get_clocks clk] -add_delay 1.0 [get_ports x2_re]
set_output_delay -clock [get_clocks clk] -add_delay 1.0 [get_ports x2_im]

set_max_fanout    15.000 [current_design]
set_max_transition 1.2   [current_design]
