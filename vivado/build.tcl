# Regenerates the Vivado project from RTL + constraints + IP.
#
# Usage (from project root):
#   vivado -mode batch -source vivado/build.tcl              # batch
#   vivado -source vivado/build.tcl                          # GUI
#
# The .xpr is intentionally NOT committed to git — each developer regenerates
# it locally from this script. This avoids the merge conflicts that come from
# having the project file under version control.

set proj_name  "basys3_face_detect"
set proj_dir   [file dirname [file normalize [info script]]]
set repo_root  [file dirname $proj_dir]
set part       "xc7a35tcpg236-1"

# camera_vga_top now integrates the detector + bounding-box overlay.
set top_module "camera_vga_top"

# Wipe any existing project so the script is idempotent.
if {[file exists $proj_dir/$proj_name.xpr]} {
    file delete -force $proj_dir/$proj_name.xpr
    foreach d {.cache .gen .hw .ip_user_files .runs .sim .srcs} {
        catch {file delete -force $proj_dir/$proj_name$d}
    }
}

create_project $proj_name $proj_dir -part $part -force
set_property board_part digilentinc.com:basys3:part0:1.2 [current_project]

# ---------- Add Verilog sources from every subsystem ----------
foreach sub {camera filter detector overlay top} {
    set files [glob -nocomplain $repo_root/rtl/$sub/*.v]
    if {[llength $files] > 0} {
        add_files -norecurse $files
    }
}

# ---------- Add constraints ----------
set xdc_files [glob -nocomplain $repo_root/constraints/*.xdc]
if {[llength $xdc_files] > 0} {
    add_files -fileset constrs_1 -norecurse $xdc_files
}

# ---------- Add detector weight hex files ----------
# weight_rom.v uses $readmemh(MEM_FILE, mem). Vivado looks for MEM_FILE in the
# synthesis run directory, so we register each .hex as a project source and tag
# it as a Memory Initialization File. The detector_top instantiation in
# camera_vga_top.v passes the basenames, e.g. "conv1_w.hex".
foreach hex [glob -nocomplain $repo_root/weights/*.hex] {
    add_files -norecurse $hex
    set_property file_type "Memory Initialization Files" [get_files [file tail $hex]]
}

# ---------- Add Xilinx IP cores ----------
# Each IP lives in its own folder under vivado/ip/<name>/<name>.xci.
foreach xci [glob -nocomplain $repo_root/vivado/ip/*/*.xci] {
    read_ip $xci
}
if {[llength [get_ips]] > 0} {
    upgrade_ip [get_ips]
    generate_target all [get_ips]
}

# ---------- Set top module ----------
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

puts "==> Project created at $proj_dir/$proj_name.xpr"
puts "==> Top module: $top_module"
puts "==> Run synthesis with: launch_runs synth_1"
