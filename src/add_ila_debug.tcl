# ============================================================================
# add_ila_debug.tcl — Add ILA cores to CMI8738 project
# ============================================================================
#
# Run AFTER opening the Vivado project and AFTER synthesis:
#   1. source vivado_generate_project_captaindma_100t.tcl
#   2. Run Synthesis
#   3. Open Synthesized Design
#   4. source add_ila_debug.tcl
#   5. Run Implementation → Generate Bitstream
#
# This creates ILA cores connected to the mark_debug signals in
# pcileech_tlp_debug_probes.sv. After programming the FPGA,
# use Hardware Manager → ILA Dashboard to capture TLP traffic.
#
# ILA SETTINGS:
#   - 4096 samples deep (captures ~65µs at 62.5 MHz)
#   - Trigger on any valid TLP RX or TX
#   - All mark_debug signals auto-connected
# ============================================================================

# Method 1: Use "Set Up Debug" wizard (recommended, automatic)
# This finds all (* mark_debug = "TRUE" *) signals and creates ILA cores.

puts "============================================"
puts " Setting up ILA debug cores..."
puts "============================================"

# Create debug core
create_debug_core u_ila_0 ila

# Configure: 4096 samples, 1 trigger comparator per probe
set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]

# Connect clock — must be clk_pcie (62.5 MHz PCIe user clock)
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets {i_pcileech_pcie_a7/clk_pcie}]

# Find all mark_debug nets and connect them
set dbg_nets [get_nets -hierarchical -filter {MARK_DEBUG == TRUE}]
set num_nets [llength $dbg_nets]
puts "Found $num_nets mark_debug signals"

if {$num_nets > 0} {
    # Create probe port with correct width
    set_property port_width $num_nets [get_debug_ports u_ila_0/probe0]
    connect_debug_port u_ila_0/probe0 $dbg_nets
    puts "Connected $num_nets signals to ILA probe0"
} else {
    puts "WARNING: No mark_debug signals found. Did you synthesize first?"
    puts "         Make sure pcileech_tlp_debug_probes.sv is in the project."
}

# Save constraints
puts ""
puts "ILA setup complete. Now run:"
puts "  1. Implementation"
puts "  2. Generate Bitstream"
puts "  3. Open Hardware Manager"
puts "  4. Program device"
puts "  5. ILA Dashboard appears automatically"
puts ""
puts "TRIGGER TIPS:"
puts "  - Trigger on dbg_rx_valid == 1 to capture incoming TLPs"
puts "  - Trigger on dbg_tx_valid == 1 to capture outgoing completions"  
puts "  - Trigger on dbg_bar_wr == 1 to capture BAR register writes"
puts "  - Trigger on dbg_intx == 1 to capture interrupt timing"
puts "  - Use cnt_rx_tlp as a running counter to see total traffic rate"
puts "============================================"
