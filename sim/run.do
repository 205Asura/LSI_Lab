if {[file exist work]} { vdel -lib work -all }

vlib work

if {[llength [glob -nocomplain ../rtl/*.v]] > 0} { vlog -work work ../rtl/*.v }
if {[llength [glob -nocomplain ../rtl/*.vh]] > 0} { vlog -work work ../rtl/*.vh }
if {[llength [glob -nocomplain ../rtl/*.sv]] > 0} { vlog -work work ../rtl/*.sv }

if {[llength [glob -nocomplain ../tb/*.v]] > 0} { vlog -work work ../tb/*.v }
if {[llength [glob -nocomplain ../tb/*.sv]] > 0} { vlog -work work ../tb/*.sv }

vsim -voptargs="+acc -debugdb" -debugDB work.tb_SPI_Communication

log -r /*

add wave -position insertpoint sim:/tb_SPI_Communication/dut/*
run -all