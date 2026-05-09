####################################################################################
# Basys 3 Constraints File for OV7670 Camera to VGA System
####################################################################################

# Clock signal (100 MHz)
set_property PACKAGE_PIN W5 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} -add [get_ports clk]

# Reset button (BTNC - Center button)
set_property PACKAGE_PIN U18 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]

####################################################################################
# OV7670 Camera Interface
####################################################################################

# Camera Data Lines D0-D7
set_property PACKAGE_PIN P17 [get_ports {camera_data[0]}]
set_property PACKAGE_PIN N17 [get_ports {camera_data[1]}]
set_property PACKAGE_PIN M19 [get_ports {camera_data[2]}]
set_property PACKAGE_PIN M18 [get_ports {camera_data[3]}]
set_property PACKAGE_PIN L17 [get_ports {camera_data[4]}]
set_property PACKAGE_PIN K17 [get_ports {camera_data[5]}]
set_property PACKAGE_PIN C16 [get_ports {camera_data[6]}]
set_property PACKAGE_PIN B16 [get_ports {camera_data[7]}]

set_property IOSTANDARD LVCMOS33 [get_ports {camera_data[*]}]

# Camera Control Signals
set_property PACKAGE_PIN A17 [get_ports camera_href]
set_property PACKAGE_PIN A16 [get_ports camera_pclk]
set_property PACKAGE_PIN R18 [get_ports camera_pwdn]
set_property PACKAGE_PIN P18 [get_ports camera_reset]
set_property PACKAGE_PIN B15 [get_ports camera_vsync]
set_property PACKAGE_PIN C15 [get_ports camera_xclk]

set_property IOSTANDARD LVCMOS33 [get_ports camera_href]
set_property IOSTANDARD LVCMOS33 [get_ports camera_pclk]
set_property IOSTANDARD LVCMOS33 [get_ports camera_pwdn]
set_property IOSTANDARD LVCMOS33 [get_ports camera_reset]
set_property IOSTANDARD LVCMOS33 [get_ports camera_vsync]
set_property IOSTANDARD LVCMOS33 [get_ports camera_xclk]

# SCCB (I2C) Interface
set_property PACKAGE_PIN A14 [get_ports camera_sioc]
set_property PACKAGE_PIN A15 [get_ports camera_siod]
set_property IOSTANDARD LVCMOS33 [get_ports camera_sioc]
set_property IOSTANDARD LVCMOS33 [get_ports camera_siod]
set_property PULLUP true [get_ports camera_siod]

# Camera clock constraint (pixel clock from camera)
# The actual frequency depends on camera configuration, typically ~24MHz
create_clock -period 41.666 -name camera_pclk -waveform {0.000 20.833} [get_ports camera_pclk]
set_clock_groups -asynchronous -group [get_clocks camera_pclk] -group [get_clocks sys_clk_pin]

####################################################################################
# VGA Output
####################################################################################

# VGA Red
set_property PACKAGE_PIN G19 [get_ports {vga_red[0]}]
set_property PACKAGE_PIN H19 [get_ports {vga_red[1]}]
set_property PACKAGE_PIN J19 [get_ports {vga_red[2]}]
set_property PACKAGE_PIN N19 [get_ports {vga_red[3]}]

# VGA Green
set_property PACKAGE_PIN J17 [get_ports {vga_green[0]}]
set_property PACKAGE_PIN H17 [get_ports {vga_green[1]}]
set_property PACKAGE_PIN G17 [get_ports {vga_green[2]}]
set_property PACKAGE_PIN D17 [get_ports {vga_green[3]}]

# VGA Blue
set_property PACKAGE_PIN N18 [get_ports {vga_blue[0]}]
set_property PACKAGE_PIN L18 [get_ports {vga_blue[1]}]
set_property PACKAGE_PIN K18 [get_ports {vga_blue[2]}]
set_property PACKAGE_PIN J18 [get_ports {vga_blue[3]}]

# VGA Sync
set_property PACKAGE_PIN P19 [get_ports vga_hsync]
set_property PACKAGE_PIN R19 [get_ports vga_vsync]

set_property IOSTANDARD LVCMOS33 [get_ports {vga_red[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_green[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {vga_blue[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports vga_hsync]
set_property IOSTANDARD LVCMOS33 [get_ports vga_vsync]

####################################################################################
# Filter Selection Switches (SW0-SW2)
####################################################################################

set_property PACKAGE_PIN V17 [get_ports {filter_sel[0]}]
set_property PACKAGE_PIN V16 [get_ports {filter_sel[1]}]
set_property PACKAGE_PIN W16 [get_ports {filter_sel[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {filter_sel[*]}]

####################################################################################
# Debug LEDs (LD0-LD3)
####################################################################################

set_property PACKAGE_PIN U16 [get_ports {led[0]}]
set_property PACKAGE_PIN E19 [get_ports {led[1]}]
set_property PACKAGE_PIN U19 [get_ports {led[2]}]
set_property PACKAGE_PIN V19 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

####################################################################################
# Configuration and Bitstream Settings
####################################################################################

set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]

####################################################################################
# Timing Constraints
####################################################################################

# Relax timing on cross-clock domain paths
set_false_path -from [get_clocks camera_pclk] -to [get_clocks clk_out1_clk_wiz_0]
set_false_path -from [get_clocks clk_out1_clk_wiz_0] -to [get_clocks camera_pclk]
