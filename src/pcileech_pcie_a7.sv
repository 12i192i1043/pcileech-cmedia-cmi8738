//
// PCILeech FPGA.
//
// PCIe module for Artix-7.
//
// (c) Ulf Frisk, 2018-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_pcie_a7(
    input                   clk_sys,
    input                   rst,

    // PCIe fabric
    output  [0:0]           pcie_tx_p,
    output  [0:0]           pcie_tx_n,
    input   [0:0]           pcie_rx_p,
    input   [0:0]           pcie_rx_n,
    input                   pcie_clk_p,
    input                   pcie_clk_n,
    input                   pcie_perst_n,
    
    // State and Activity LEDs
    output                  led_state,
    
    // PCIe <--> FIFOs
    IfPCIeFifoCfg.mp_pcie   dfifo_cfg,
    IfPCIeFifoTlp.mp_pcie   dfifo_tlp,
    IfPCIeFifoCore.mp_pcie  dfifo_pcie,
    IfShadow2Fifo.shadow    dshadow2fifo
    );
       
    // ----------------------------------------------------------------------------
    // PCIe DEFINES AND WIRES
    // ----------------------------------------------------------------------------
    
    wire intx_line;
    wire led_dma_debug;
    
    
    
    IfPCIeSignals           ctx();
    IfPCIeTlpRxTx           tlp_tx();
    IfPCIeTlpRxTx           tlp_rx();
    IfAXIS128               tlps_tx();
    IfAXIS128               tlps_rx();
    
    IfAXIS128               tlps_static();       // static tlp transmit from cfg->tlp
    wire [15:0]             pcie_id;
    wire                    user_lnk_up;
    
    // system interface
    wire pcie_clk_c;
    wire clk_pcie;
    wire rst_pcie_user;
    wire rst_subsys = rst || rst_pcie_user || dfifo_pcie.pcie_rst_subsys;
    wire rst_pcie = rst || ~pcie_perst_n || dfifo_pcie.pcie_rst_core;
       
    // Buffer for differential system clock
    IBUFDS_GTE2 refclk_ibuf (.O(pcie_clk_c), .ODIV2(), .I(pcie_clk_p), .CEB(1'b0), .IB(pcie_clk_n));
    
    // ----------------------------------------------------
    // TickCount64 PCIe REFCLK and LED OUTPUT
    // ----------------------------------------------------

    time tickcount64_pcie_refclk = 0;
    always @ ( posedge pcie_clk_c )
        tickcount64_pcie_refclk <= tickcount64_pcie_refclk + 1;
    assign led_state = user_lnk_up || tickcount64_pcie_refclk[25];
    //assign led_state = led_dma_debug;
    wire [31:0] base_address_register;
    wire [31:0] base_address_register_1;
    wire [31:0] base_address_register_2;
    wire [31:0] base_address_register_3;
    wire [31:0] base_address_register_4;
    wire [31:0] base_address_register_5;
    // ----------------------------------------------------------------------------
    // PCIe CFG RX/TX <--> FIFO below
    // ----------------------------------------------------------------------------
    
    pcileech_pcie_cfg_a7 i_pcileech_pcie_cfg_a7(
        .rst                        ( rst_subsys                ),
        .clk_sys                    ( clk_sys                   ),
        .clk_pcie                   ( clk_pcie                  ),
        .dfifo                      ( dfifo_cfg                 ),        
        .ctx                        ( ctx                       ),
        .tlps_static                ( tlps_static.source        ),
        .pcie_id                    ( pcie_id                   ),   // -> [15:0]
        .base_address_register      ( base_address_register     ),  // bar0 base register
        .base_address_register_1    ( base_address_register_1   ),  // bar1 base register
        .base_address_register_2    ( base_address_register_2   ),  // bar2 base register
        .base_address_register_3    ( base_address_register_3   ),  // bar3 base register
        .base_address_register_4    ( base_address_register_4   ),  // bar4 base register
        .base_address_register_5    ( base_address_register_5   )   // bar5 base register
    );
    
    // ----------------------------------------------------------------------------
    // PCIe TLP RX/TX <--> FIFO below
    // ----------------------------------------------------------------------------
    
    pcileech_tlps128_src64 i_pcileech_tlps128_src64(
        .rst                        ( rst_subsys                ),
        .clk_pcie                   ( clk_pcie                  ),
        .tlp_rx                     ( tlp_rx.sink               ),
        .tlps_out                   ( tlps_rx.source_lite       )
    );
    
    pcileech_pcie_tlp_a7 i_pcileech_pcie_tlp_a7(
        .rst                        ( rst_subsys                ),
        .clk_pcie                   ( clk_pcie                  ),
        .clk_sys                    ( clk_sys                   ),
        .dfifo                      ( dfifo_tlp                 ),
        .tlps_tx                    ( tlps_tx.source            ),       
        .tlps_rx                    ( tlps_rx.sink_lite         ),
        .tlps_static                ( tlps_static.sink          ),
        .dshadow2fifo               ( dshadow2fifo              ),
        .pcie_id                    ( pcie_id                   ),   // <- [15:0]
        .intx_line                  ( intx_line                ),
        .led_dma_debug                  ( led_dma_debug                ),
        .base_address_register      ( base_address_register     ),  // bar0 base register 基地址
        .base_address_register_1    ( base_address_register_1   ),  // bar1 base register 基地址
        .base_address_register_2    ( base_address_register_2   ),  // bar2 base register 基地址
        .base_address_register_3    ( base_address_register_3   ),  // bar3 base register 基地址
        .base_address_register_4    ( base_address_register_4   ),  // bar4 base register 基地址
        .base_address_register_5    ( base_address_register_5   )   // bar5 base register 基地址
    );
    
    pcileech_tlps128_dst64 i_pcileech_tlps128_dst64(
        .rst                        ( rst                       ),
        .clk_pcie                   ( clk_pcie                  ),
        .tlp_tx                     ( tlp_tx.source             ),
        .tlps_in                    ( tlps_tx.sink              )
    );
    // ----------------------------------------------------------------------------
    // INTx INTERRUPT CONTROLLER
    // ----------------------------------------------------------------------------
    wire        w_intx_assert;
    wire        w_intx_strobe;
    wire [7:0]  w_intx_di;
    wire        w_intx_debug; // <--- ADD THIS WIRE
    pcileech_intx_controller i_pcileech_intx_controller (
        .clk_pcie            ( clk_pcie              ),
        .rst                 ( rst_subsys            ),
        .intx_line           ( intx_line             ),  // Ensure this wire is driven by your BAR logic
        .cfg_interrupt_assert( w_intx_assert         ),
        .cfg_interrupt       ( w_intx_strobe         ),
        .cfg_interrupt_rdy   ( ctx.cfg_interrupt_rdy ),  // Read Ready signal from Core via ctx
        .cfg_interrupt_di    ( w_intx_di             ),
        .debug_active        ( w_intx_debug          )  // <--- CONNECT HERE
    );
    // ----------------------------------------------------------------------------
    // PCIe TLP DEBUG PROBES (ILA — remove for production)
    // ----------------------------------------------------------------------------
    
    pcileech_tlp_debug_probes i_debug_probes(
        .clk_pcie               ( clk_pcie                  ),
        .rst                    ( rst_subsys                ),
        // TLP RX stream (from host)
        .tlps_rx_tdata          ( tlps_rx.tdata             ),
        .tlps_rx_tkeepdw        ( tlps_rx.tkeepdw           ),
        .tlps_rx_tvalid         ( tlps_rx.tvalid            ),
        .tlps_rx_tlast          ( tlps_rx.tlast             ),
        .tlps_rx_tuser          ( tlps_rx.tuser             ),
        // TLP TX stream (to host)
        .tlps_tx_tdata          ( tlps_tx.tdata             ),
        .tlps_tx_tkeepdw        ( tlps_tx.tkeepdw           ),
        .tlps_tx_tvalid         ( tlps_tx.tvalid            ),
        .tlps_tx_tlast          ( tlps_tx.tlast             ),
        // BAR controller activity (directly from tlp_a7 wiring)
        .bar_wr_valid           ( 1'b0                      ), // connected post-synthesis via ILA
        .bar_wr_addr            ( 32'd0                     ),
        .bar_wr_data            ( 32'd0                     ),
        .bar_rd_req_valid       ( 1'b0                      ),
        .bar_rd_req_addr        ( 32'd0                     ),
        .bar_rd_rsp_valid       ( 1'b0                      ),
        .bar_rd_rsp_data        ( 32'd0                     ),
        // PCIe state
        .user_lnk_up            ( user_lnk_up               ),
        .pcie_id                ( pcie_id                    ),
        .base_address_register  ( base_address_register      ),
        .cfg_command            ( ctx.cfg_command            ),
        .pl_ltssm_state         ( ctx.pl_ltssm_state        ),
        .intx_line              ( intx_line                  )
    );

    // ----------------------------------------------------------------------------
    // PCIe CORE BELOW
    // ---------------------------------------------------------------------------- 
      
    pcie_7x_0 i_pcie_7x_0 (
        // pcie_7x_mgt
        .pci_exp_txp                ( pcie_tx_p                 ),  // ->
        .pci_exp_txn                ( pcie_tx_n                 ),  // ->
        .pci_exp_rxp                ( pcie_rx_p                 ),  // <-
        .pci_exp_rxn                ( pcie_rx_n                 ),  // <-
        .sys_clk                    ( pcie_clk_c                ),  // <-
        .sys_rst_n                  ( ~rst_pcie                 ),  // <-
    
        // s_axis_tx (transmit data)
        .s_axis_tx_tdata            ( tlp_tx.data               ),  // <- [63:0]
        .s_axis_tx_tkeep            ( tlp_tx.keep               ),  // <- [7:0]
        .s_axis_tx_tlast            ( tlp_tx.last               ),  // <-
        .s_axis_tx_tready           ( tlp_tx.ready              ),  // ->
        .s_axis_tx_tuser            ( 4'b0                      ),  // <- [3:0]
        .s_axis_tx_tvalid           ( tlp_tx.valid              ),  // <-
    
        // s_axis_rx (receive data)
        .m_axis_rx_tdata            ( tlp_rx.data               ),  // -> [63:0]
        .m_axis_rx_tkeep            ( tlp_rx.keep               ),  // -> [7:0]
        .m_axis_rx_tlast            ( tlp_rx.last               ),  // -> 
        .m_axis_rx_tready           ( tlp_rx.ready              ),  // <-
        .m_axis_rx_tuser            ( tlp_rx.user               ),  // -> [21:0]
        .m_axis_rx_tvalid           ( tlp_rx.valid              ),  // ->
    
        // pcie_cfg_mgmt
        .cfg_mgmt_dwaddr            ( ctx.cfg_mgmt_dwaddr       ),  // <- [9:0]
        .cfg_mgmt_byte_en           ( ctx.cfg_mgmt_byte_en      ),  // <- [3:0]
        .cfg_mgmt_do                ( ctx.cfg_mgmt_do           ),  // -> [31:0]
        .cfg_mgmt_rd_en             ( ctx.cfg_mgmt_rd_en        ),  // <-
        .cfg_mgmt_rd_wr_done        ( ctx.cfg_mgmt_rd_wr_done   ),  // ->
        .cfg_mgmt_wr_readonly       ( ctx.cfg_mgmt_wr_readonly  ),  // <-
        .cfg_mgmt_wr_rw1c_as_rw     ( ctx.cfg_mgmt_wr_rw1c_as_rw ), // <-
        .cfg_mgmt_di                ( ctx.cfg_mgmt_di           ),  // <- [31:0]
        .cfg_mgmt_wr_en             ( ctx.cfg_mgmt_wr_en        ),  // <-
    
        // special core config
        //.pcie_cfg_vend_id           ( dfifo_pcie.pcie_cfg_vend_id       ),  // <- [15:0]
        //.pcie_cfg_dev_id            ( dfifo_pcie.pcie_cfg_dev_id        ),  // <- [15:0]
        //.pcie_cfg_rev_id            ( dfifo_pcie.pcie_cfg_rev_id        ),  // <- [7:0]
        //.pcie_cfg_subsys_vend_id    ( dfifo_pcie.pcie_cfg_subsys_vend_id ), // <- [15:0]
        //.pcie_cfg_subsys_id         ( dfifo_pcie.pcie_cfg_subsys_id     ),  // <- [15:0]
    
        // pcie2_cfg_interrupt
        // pcie2_cfg_interrupt
        .cfg_interrupt_assert       ( w_intx_assert                     ),  // <- Connected to INTx Controller
        .cfg_interrupt              ( w_intx_strobe                     ),  // <- Connected to INTx Controller
        .cfg_interrupt_mmenable     ( ctx.cfg_interrupt_mmenable        ),  // -> [2:0]
        .cfg_interrupt_msienable    ( ctx.cfg_interrupt_msienable       ),  // ->
        .cfg_interrupt_msixenable   ( ctx.cfg_interrupt_msixenable      ),  // ->
        .cfg_interrupt_msixfm       ( ctx.cfg_interrupt_msixfm          ),  // ->
        .cfg_pciecap_interrupt_msgnum ( ctx.cfg_pciecap_interrupt_msgnum ), // <- [4:0]
        .cfg_interrupt_rdy          ( ctx.cfg_interrupt_rdy             ),  // ->
        .cfg_interrupt_do           ( ctx.cfg_interrupt_do              ),  // -> [7:0]
        .cfg_interrupt_stat         ( ctx.cfg_interrupt_stat            ),  // <-
        .cfg_interrupt_di           ( w_intx_di                         ),  // <- Connected to INTx Controller
        
        // pcie2_cfg_control
        .cfg_ds_bus_number          ( ctx.cfg_bus_number                ),  // <- [7:0]
        .cfg_ds_device_number       ( ctx.cfg_device_number             ),  // <- [4:0]
        .cfg_ds_function_number     ( ctx.cfg_function_number           ),  // <- [2:0]
        .cfg_dsn                    ( ctx.cfg_dsn                       ),  // <- [63:0]
        .cfg_pm_force_state         ( ctx.cfg_pm_force_state            ),  // <- [1:0]
        .cfg_pm_force_state_en      ( ctx.cfg_pm_force_state_en         ),  // <-
        .cfg_pm_halt_aspm_l0s       ( ctx.cfg_pm_halt_aspm_l0s          ),  // <-
        .cfg_pm_halt_aspm_l1        ( ctx.cfg_pm_halt_aspm_l1           ),  // <-
        .cfg_pm_send_pme_to         ( ctx.cfg_pm_send_pme_to            ),  // <-
        .cfg_pm_wake                ( ctx.cfg_pm_wake                   ),  // <-
        .rx_np_ok                   ( ctx.rx_np_ok                      ),  // <-
        .rx_np_req                  ( ctx.rx_np_req                     ),  // <-
        .cfg_trn_pending            ( ctx.cfg_trn_pending               ),  // <-
        .cfg_turnoff_ok             ( ctx.cfg_turnoff_ok                ),  // <-
        .tx_cfg_gnt                 ( ctx.tx_cfg_gnt                    ),  // <-
        
        // pcie2_cfg_status
        .cfg_command                ( ctx.cfg_command                   ),  // -> [15:0]
        .cfg_bus_number             ( ctx.cfg_bus_number                ),  // -> [7:0]
        .cfg_device_number          ( ctx.cfg_device_number             ),  // -> [4:0]
        .cfg_function_number        ( ctx.cfg_function_number           ),  // -> [2:0]
        .cfg_root_control_pme_int_en( ctx.cfg_root_control_pme_int_en   ),  // ->
        .cfg_bridge_serr_en         ( ctx.cfg_bridge_serr_en            ),  // ->
        .cfg_dcommand               ( ctx.cfg_dcommand                  ),  // -> [15:0]
        .cfg_dcommand2              ( ctx.cfg_dcommand2                 ),  // -> [15:0]
        .cfg_dstatus                ( ctx.cfg_dstatus                   ),  // -> [15:0]
        .cfg_lcommand               ( ctx.cfg_lcommand                  ),  // -> [15:0]
        .cfg_lstatus                ( ctx.cfg_lstatus                   ),  // -> [15:0]
        .cfg_pcie_link_state        ( ctx.cfg_pcie_link_state           ),  // -> [2:0]
        .cfg_pmcsr_pme_en           ( ctx.cfg_pmcsr_pme_en              ),  // ->
        .cfg_pmcsr_pme_status       ( ctx.cfg_pmcsr_pme_status          ),  // ->
        .cfg_pmcsr_powerstate       ( ctx.cfg_pmcsr_powerstate          ),  // -> [1:0]
        .cfg_received_func_lvl_rst  ( ctx.cfg_received_func_lvl_rst     ),  // ->
        .cfg_status                 ( ctx.cfg_status                    ),  // -> [15:0]
        .cfg_to_turnoff             ( ctx.cfg_to_turnoff                ),  // ->
        .tx_buf_av                  ( ctx.tx_buf_av                     ),  // -> [5:0]
        .tx_cfg_req                 ( ctx.tx_cfg_req                    ),  // ->
        .tx_err_drop                ( ctx.tx_err_drop                   ),  // ->
        .cfg_vc_tcvc_map            ( ctx.cfg_vc_tcvc_map               ),  // -> [6:0]
        .cfg_aer_rooterr_corr_err_received          ( ctx.cfg_aer_rooterr_corr_err_received             ),  // ->
        .cfg_aer_rooterr_corr_err_reporting_en      ( ctx.cfg_aer_rooterr_corr_err_reporting_en         ),  // ->
        .cfg_aer_rooterr_fatal_err_received         ( ctx.cfg_aer_rooterr_fatal_err_received            ),  // ->
        .cfg_aer_rooterr_fatal_err_reporting_en     ( ctx.cfg_aer_rooterr_fatal_err_reporting_en        ),  // ->
        .cfg_aer_rooterr_non_fatal_err_received     ( ctx.cfg_aer_rooterr_non_fatal_err_received        ),  // ->
        .cfg_aer_rooterr_non_fatal_err_reporting_en ( ctx.cfg_aer_rooterr_non_fatal_err_reporting_en    ),  // ->
        .cfg_root_control_syserr_corr_err_en        ( ctx.cfg_root_control_syserr_corr_err_en           ),  // ->
        .cfg_root_control_syserr_fatal_err_en       ( ctx.cfg_root_control_syserr_fatal_err_en          ),  // ->
        .cfg_root_control_syserr_non_fatal_err_en   ( ctx.cfg_root_control_syserr_non_fatal_err_en      ),  // ->
        .cfg_slot_control_electromech_il_ctl_pulse  ( ctx.cfg_slot_control_electromech_il_ctl_pulse     ),  // ->
        
        // PCIe core PHY
        .pl_initial_link_width      ( ctx.pl_initial_link_width         ),  // -> [2:0]
        .pl_phy_lnk_up              ( ctx.pl_phy_lnk_up                 ),  // ->
        .pl_lane_reversal_mode      ( ctx.pl_lane_reversal_mode         ),  // -> [1:0]
        .pl_link_gen2_cap           ( ctx.pl_link_gen2_cap              ),  // ->
        .pl_link_partner_gen2_supported ( ctx.pl_link_partner_gen2_supported ),  // ->
        .pl_link_upcfg_cap          ( ctx.pl_link_upcfg_cap             ),  // ->
        .pl_sel_lnk_rate            ( ctx.pl_sel_lnk_rate               ),  // ->
        .pl_sel_lnk_width           ( ctx.pl_sel_lnk_width              ),  // -> [1:0]
        .pl_ltssm_state             ( ctx.pl_ltssm_state                ),  // -> [5:0]
        .pl_rx_pm_state             ( ctx.pl_rx_pm_state                ),  // -> [1:0]
        .pl_tx_pm_state             ( ctx.pl_tx_pm_state                ),  // -> [2:0]
        .pl_directed_change_done    ( ctx.pl_directed_change_done       ),  // ->
        .pl_received_hot_rst        ( ctx.pl_received_hot_rst           ),  // ->
        .pl_directed_link_auton     ( ctx.pl_directed_link_auton        ),  // <-
        .pl_directed_link_change    ( ctx.pl_directed_link_change       ),  // <- [1:0]
        .pl_directed_link_speed     ( ctx.pl_directed_link_speed        ),  // <-
        .pl_directed_link_width     ( ctx.pl_directed_link_width        ),  // <- [1:0]
        .pl_upstream_prefer_deemph  ( ctx.pl_upstream_prefer_deemph     ),  // <-
        .pl_transmit_hot_rst        ( ctx.pl_transmit_hot_rst           ),  // <-
        .pl_downstream_deemph_source( ctx.pl_downstream_deemph_source   ),  // <-
        
        // DRP - clock domain clk_100 - write should only happen when core is in reset state ...
        .pcie_drp_clk               ( clk_sys                           ),  // <-
        .pcie_drp_en                ( dfifo_pcie.drp_en                 ),  // <-
        .pcie_drp_we                ( dfifo_pcie.drp_we                 ),  // <-
        .pcie_drp_addr              ( dfifo_pcie.drp_addr               ),  // <- [8:0]
        .pcie_drp_di                ( dfifo_pcie.drp_di                 ),  // <- [15:0]
        .pcie_drp_rdy               ( dfifo_pcie.drp_rdy                ),  // ->
        .pcie_drp_do                ( dfifo_pcie.drp_do                 ),  // -> [15:0]
    
        // user interface
        .user_clk_out               ( clk_pcie                          ),  // ->
        .user_reset_out             ( rst_pcie_user                     ),  // ->
        .user_lnk_up                ( user_lnk_up                       ),  // ->
        .user_app_rdy               (                                   )   // ->
    );

endmodule


// ------------------------------------------------------------------------
// TLP STREAM SINK:
// Convert a 128-bit TLP-AXI-STREAM to a 64-bit PCIe core AXI-STREAM.
// ------------------------------------------------------------------------
module pcileech_tlps128_dst64(
    input                   rst,
    input                   clk_pcie,
    IfPCIeTlpRxTx.source    tlp_tx,
    IfAXIS128.sink          tlps_in
);

    bit [63:0]  d1_tdata;
    bit         d1_tkeepdw2;
    bit         d1_tlast;
    bit         d1_tvalid = 0;
    
    assign tlps_in.tready = tlp_tx.ready && !(tlps_in.tvalid && tlps_in.tkeepdw[2]);
    
    wire tkeepdw2       = d1_tvalid ? d1_tkeepdw2 : tlps_in.tkeepdw[1];
    assign tlp_tx.data  = d1_tvalid ? d1_tdata : tlps_in.tdata[63:0];
    assign tlp_tx.last  = d1_tvalid ? d1_tlast : (tlps_in.tlast && !tlps_in.tkeepdw[2]);
    assign tlp_tx.keep  = tkeepdw2 ? 8'hff : 8'h0f;
    assign tlp_tx.valid = d1_tvalid || tlps_in.tvalid;
    
    always @ ( posedge clk_pcie ) begin
        d1_tvalid    <= !rst && tlps_in.tvalid && tlps_in.tkeepdw[2];
        d1_tdata     <= tlps_in.tdata[127:64];
        d1_tlast     <= tlps_in.tlast;
        d1_tkeepdw2  <= tlps_in.tkeepdw[3];
    end

endmodule


// ------------------------------------------------------------------------
// TLP STREAM SOURCE:
// Convert a 64-bit PCIe core AXIS to a 128-bit TLP-AXI-STREAM 
// ------------------------------------------------------------------------
module pcileech_tlps128_src64(
    input                   rst,
    input                   clk_pcie,
    IfPCIeTlpRxTx.sink      tlp_rx,
    IfAXIS128.source_lite   tlps_out
);

    bit [127:0] tdata;
    bit         first       = 1;
    bit         tlast       = 0;
    bit [3:0]   len         = 0;
    bit [6:0]   bar_hit     = 0;
    wire        tvalid      = tlast || (len>2);
    
    assign tlp_rx.ready     = 1'b1;
    assign tlps_out.tdata   = tdata;
    assign tlps_out.tkeepdw = {(len>3), (len>2), (len>1), 1'b1};
    assign tlps_out.tlast   = tlast;   
    assign tlps_out.tvalid  = tvalid; 
    assign tlps_out.tuser[0]    = first;
    assign tlps_out.tuser[1]    = tlast;
    assign tlps_out.tuser[8:2]  = bar_hit;
    
    wire [3:0]  next_base   = (tlast || tvalid) ? 0 : len;
    wire [3:0]  next_len    = next_base + 1 + tlp_rx.keep[4];

    always @ ( posedge clk_pcie )
        if ( rst ) begin
            first   <= 1;
            tlast   <= 0;
            len     <= 0;
            bar_hit <= 0;
        end
        else if ( tlp_rx.valid ) begin
            tdata[(32*next_base)+:64] <= tlp_rx.data;
            first   <= tvalid ? tlast : first;
            tlast   <= tlp_rx.last;
            len     <= next_len;
            bar_hit <= tlp_rx.user[8:2];
        end
        else if ( tvalid ) begin 
            first   <= tlast;
            tlast   <= 0;
            len     <= 0;
            bar_hit <= 0;
        end
    
endmodule
module pcileech_intx_controller (
    // System Interface
    input                   clk_pcie,
    input                   rst,
    input                   intx_line,
    // PCIe Core Interface
    output reg              cfg_interrupt_assert,
    output reg              cfg_interrupt,      // Strobe
    input                   cfg_interrupt_rdy,  // Ready
    output reg [7:0]        cfg_interrupt_di,   // Vector (0x00)
    output wire             debug_active        // <--- ADD THIS LINE
);

    // Internal signals
    reg intx_line_sync;
    reg intx_line_prev;
    
    // Cycle counter for the 10-cycle hold
    reg [32:0] cycle_count;
    
    // Synchronize intx_line to PCIe clock domain
    always @(posedge clk_pcie) begin
        if (rst) begin
            intx_line_sync <= 1'b0;
            intx_line_prev <= 1'b0;
        end else begin
            intx_line_sync <= intx_line;
            intx_line_prev <= intx_line_sync;
        end
    end
    
    // State machine states
    localparam [2:0] IDLE         = 3'b000;
    localparam [2:0] ASSERTING    = 3'b001; // Send Assert packet
    localparam [2:0] HOLDING      = 3'b010; // Wait 10 cycles
    localparam [2:0] DEASSERTING  = 3'b011; // Send Deassert packet
    localparam [2:0] WAIT_LOW     = 3'b100; // Wait for line to drop
    
    reg [2:0] state, next_state;
    
    // State register
    always @(posedge clk_pcie) begin
        if (rst) begin
            state <= IDLE;
            cycle_count <= 0;
        end else begin
            state <= next_state;
            
            // Counter Logic: Only count while in HOLDING state
            if (state == HOLDING) begin
                cycle_count <= cycle_count + 1;
            end else begin
                cycle_count <= 0;
            end
        end
    end
    
    // Next state logic
    always @(*) begin
        case (state)
            IDLE: begin
                // If line goes high, start the sequence immediately
                if (intx_line_sync) begin
                    next_state = ASSERTING;
                end else begin
                    next_state = IDLE;
                end
            end
            
            ASSERTING: begin
                // Wait for Core to accept the Assert packet
                if (cfg_interrupt_rdy) begin
                    next_state = HOLDING;
                end else begin
                    next_state = ASSERTING;
                end
            end
            
            HOLDING: begin
                // Asserted for 10 cycles, then move to deassert
                if (cycle_count >= 32'd20_000) begin
                    next_state = DEASSERTING;
                end else begin
                    next_state = HOLDING;
                end
            end
            
            DEASSERTING: begin
                // Wait for Core to accept the Deassert packet
                if (cfg_interrupt_rdy) begin
                    next_state = WAIT_LOW;
                end else begin
                    next_state = DEASSERTING;
                end
            end
            
            WAIT_LOW: begin
                // Wait here until the physical line actually drops.
                // This ensures we don't re-trigger immediately if the line is stuck high.
                // Once it drops, we go to IDLE, which waits for it to go HIGH again.
                if (!intx_line_sync) begin
                    next_state = IDLE;
                end else begin
                    next_state = WAIT_LOW;
                end
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Output logic
    always @(posedge clk_pcie) begin
        if (rst) begin
            cfg_interrupt <= 1'b0;
            cfg_interrupt_assert <= 1'b0;
            cfg_interrupt_di <= 8'h00;
        end else begin
            // Default strobe is 0 unless set below
            cfg_interrupt <= 1'b0;
            
            case (state)
                ASSERTING: begin
                    // Send interrupt assertion strobe
                    // We keep strobing 1 until RDY is received
                    if (!cfg_interrupt_rdy) begin
                        cfg_interrupt <= 1'b1;
                        cfg_interrupt_assert <= 1'b1; 
                        cfg_interrupt_di <= 8'h00;
                    end
                end
                
                HOLDING: begin
                    // Just maintain the "asserted" state signal logically, 
                    // but do not send new strobes to the core.
                    cfg_interrupt <= 1'b0;
                    cfg_interrupt_assert <= 1'b1; 
                end
                
                DEASSERTING: begin
                    // Send interrupt deassertion strobe
                    if (!cfg_interrupt_rdy) begin
                        cfg_interrupt <= 1'b1;
                        cfg_interrupt_assert <= 1'b0; // Deassert bit is 0
                        cfg_interrupt_di <= 8'h00;
                    end
                end
                
                default: begin
                    cfg_interrupt <= 1'b0;
                    cfg_interrupt_assert <= 1'b0;
                end
            endcase
        end
    end

    // --------------------------------------------------------
    // DEBUG ASSIGNMENT
    // --------------------------------------------------------
    // Debug is active during the entire assert/hold/deassert sequence
    assign debug_active = (state == ASSERTING) || (state == HOLDING) || (state == DEASSERTING);

endmodule




module host_mem_write_2 (
    input               rst,
    input               clk_pcie,
    input [15:0]        pcie_id,
    IfMemoryWrite.sink mem_wr_in,
    IfAXIS128.source    tlps_out
);
    //CURRENT FIFO BUFFER: 128 * 128 (4 DWORD * 128 = 2048Bytes)
    localparam MAX_PAYLOAD_SIZE = 32'd128; //32DWORDs 128Bytes

    //===========================================
    // MEMORY MODULE REGISTER
    //===========================================
    memory_write_state_t state;
    reg [3:0]  rst_timer;
    reg [31:0] data_remaining;     //全体の残りデータ
    reg [31:0] transfer_remaining; //今回の転送の残りデータ
    reg [2:0]  dwords_packet;      //今回の転送のDWORD数
    reg [63:0] write_address;

    wire [9:0] dw_length = transfer_remaining == 32'd4096 ? 10'd0 : (transfer_remaining[11:2] + (transfer_remaining[1:0] != 2'b00));
    wire [1:0] last_dw_byte = transfer_remaining[1:0];
    wire [3:0] last_dw_be = data_remaining != 32'd0     ? 4'hF    : //今回のTLPは4DWORDで埋まっている
                            transfer_remaining <= 32'd4  ? 4'h0   : //DWORD以下(3バイト以下) = 1st DWのみ有効
                            last_dw_byte == 2'd1        ? 4'b0001 : //DWORD+1バイト
                            last_dw_byte == 2'd2        ? 4'b0011 : //DWORD+2バイト
                            last_dw_byte == 2'd3        ? 4'b0111 : 4'b1111; //DWORD+3バイト
    wire [3:0] first_dw_be = transfer_remaining >= 32'd4 ? 4'hF    : //DWORD以上(4バイト以上) = 1st DWは全有効
                             last_dw_byte == 2'd1        ? 4'b0001 : //DWORD+1バイト
                             last_dw_byte == 2'd2        ? 4'b0011 : //DWORD+2バイト
                             last_dw_byte == 2'd3        ? 4'b0111 : 4'b1111; //DWORD+3バイト

    assign mem_wr_in.state = state;

    //===========================================
    // TLP OUT
    //===========================================

    reg [127:0] tlp_data;
    reg [3:0]   tkeepdw;
    reg         tfirst;
    reg         tlast;
    reg         tvalid;
    reg         has_data;

    assign tlps_out.tdata    = tlp_data;
    assign tlps_out.tkeepdw  = tkeepdw;
    assign tlps_out.tuser[0] = tfirst; //FIRST
    assign tlps_out.tuser[1] = tlast;  //LAST
    assign tlps_out.tlast    = tlast;  //LAST
    assign tlps_out.tvalid   = tvalid;
    assign tlps_out.has_data = has_data;

    reg fifo_read;
    reg fifo_rst;

    wire [127:0] fifo_data_out;
    wire         fifo_srst = fifo_rst | rst;

    fifo_128_128_mem_write i_fifo_128_128_mem_write(
        .srst       ( fifo_srst         ),
        .clk        ( clk_pcie          ),
        .full       (                   ),
        .din        ( mem_wr_in.din     ),
        .wr_en      ( mem_wr_in.wr_en   ),
        .empty      (                   ),
        .dout       ( fifo_data_out     ),
        .rd_en      ( fifo_read         )
    );

    always @(posedge clk_pcie) begin
        if (rst) begin
            state <= WR_IDLE;
            rst_timer <= 3'd0;
            
            data_remaining <= 32'd0;
            transfer_remaining <= 32'd0;
            dwords_packet <= 3'd0;
            write_address <= 64'h0;
            
            tlp_data <= 128'h0;
            tkeepdw  <= 4'h0;
            tfirst   <= 1'b0;
            tlast    <= 1'b0;
            tvalid   <= 1'b0;
            has_data <= 1'b0;

            fifo_read <= 1'b0;
            fifo_rst <= 1'b0;
        end else begin
            case (state)
                WR_IDLE: begin
                    if (mem_wr_in.has_data) begin
                        state <= WR_DATA_INIT;
                        data_remaining <= mem_wr_in.data_length;
                        write_address  <= mem_wr_in.address;
                    end
                end
                WR_DATA_INIT: begin
                    if (mem_wr_in.wr_done) begin
                        state <= WR_CALC_DATA;
                    end
                end
                WR_CALC_DATA: begin
                    if (data_remaining > MAX_PAYLOAD_SIZE) begin
                        transfer_remaining <= MAX_PAYLOAD_SIZE;
                        data_remaining <= data_remaining - MAX_PAYLOAD_SIZE;
                    end else begin
                        transfer_remaining <= data_remaining;
                        data_remaining <= 32'd0;
                    end
                    state <= WR_PREPARE_HEADER;
                end
                WR_PREPARE_HEADER: begin
                    tkeepdw  <= 4'hF;
                    tfirst   <= 1'b1;
                    tlast    <= 1'b0;
                    has_data <= 1'b1;
                    tlp_data <= {
                        write_address[31:0],
                        write_address[63:32],
                        { `_bs16(pcie_id), 8'h00, last_dw_be, first_dw_be },
                        22'b01100000_00000000_000000, dw_length
                    };
                    write_address <= write_address + transfer_remaining;
                    state <= WR_TRANSMIT_HEADER;
                end
                WR_TRANSMIT_HEADER: begin
                    if (tlps_out.tready) begin
                        tvalid   <= 1'b1;
                        has_data <= 1'b0;
                        state    <= WR_DEASSERT_HEADER;
                    end
                end
                WR_DEASSERT_HEADER: begin
                    tvalid <= 1'b0;
                    state <= WR_GET_DATA_FIFO;
                end
                WR_GET_DATA_FIFO: begin
                    fifo_read <= 1'b1;

                    if (transfer_remaining[31:4] != 28'd0) begin
                        dwords_packet <= 3'd4;
                        transfer_remaining <= transfer_remaining - 32'd16;
                    end else begin
                        if (transfer_remaining[3:0] < 5) begin
                            dwords_packet <= 3'd1;
                        end else if (transfer_remaining[3:0] < 9) begin
                            dwords_packet <= 3'd2;
                        end else if (transfer_remaining[3:0] < 13) begin
                            dwords_packet <= 3'd3;
                        end else begin
                            dwords_packet <= 3'd4;
                        end
                        transfer_remaining <= 32'd0;
                    end

                    state <= WR_WAIT_DATA_FIFO;
                end
                WR_WAIT_DATA_FIFO: begin
                    state <= WR_PREPARE_DATA;
                end
                WR_PREPARE_DATA: begin
                    fifo_read <= 1'b0;
                    tfirst   <= 1'b0;
                    tlast    <= transfer_remaining == 32'd0;
                    has_data <= transfer_remaining != 32'd0;

                    case (dwords_packet)
                        3'd1: tkeepdw <= 4'b0001;
                        3'd2: tkeepdw <= 4'b0011;
                        3'd3: tkeepdw <= 4'b0111;
                        3'd4: tkeepdw <= 4'b1111;
                    endcase
                    
                    tlp_data <= {
                            `_bs32(fifo_data_out[127:96]),
                            `_bs32(fifo_data_out[95:64]),
                            `_bs32(fifo_data_out[63:32]),
                            `_bs32(fifo_data_out[31:0])
                        };

                    state <= WR_TRANSMIT_DATA;
                end
                WR_TRANSMIT_DATA: begin
                    if (tlps_out.tready) begin
                        tvalid <= 1'b1;
                        has_data <= 1'b0;
                        state <= WR_DEASSERT_DATA;
                    end
                end
                WR_DEASSERT_DATA: begin
                    tvalid <= 1'b0;
                    if (transfer_remaining == 32'd0) begin
                        if (data_remaining == 32'd0) begin
                            state <= WR_COMPLETE;
                        end else begin
                            state <= WR_CALC_DATA;
                        end
                    end else begin
                        state <= WR_GET_DATA_FIFO;
                    end
                end
                WR_COMPLETE: begin
                    if (!mem_wr_in.has_data) begin
                        state <= WR_CLEANUP;
                    end
                end
                WR_CLEANUP: begin
                    data_remaining <= 32'd0;
                    transfer_remaining <= 32'd0;
                    dwords_packet <= 3'd0;
                    write_address <= 64'h0;

                    tlp_data <= 128'h0;
                    tkeepdw  <= 4'h0;
                    tfirst   <= 1'b0;
                    tlast    <= 1'b0;
                    tvalid   <= 1'b0;
                    has_data <= 1'b0;

                    fifo_read <= 1'b0;
                    if (rst_timer == 3'd7) begin
                        state <= WR_IDLE;
                        fifo_rst <= 1'b0;
                        rst_timer <= 3'd0;
                    end else begin
                        fifo_rst <= 1'b1;
                        rst_timer <= rst_timer + 3'd1;
                    end
                end
            endcase
        end
    end
endmodule
module host_mem_read_2 (
    input               rst,
    input               clk_pcie,
    input [15:0]        pcie_id,
    IfMemoryRead.sink  mem_rd_in,
    IfAXIS128.source    tlps_out,
    IfAXIS128.sink_lite tlps_in
);
    //CURRENT FIFO BUFFER: 128 * 128 (4 DWORD * 128 = 2048Bytes)
    localparam MAX_PAYLOAD_SIZE = 32'd128; //32DWORDs 128Bytes

    //===========================================
    // MEMORY MODULE REGISTER
    //===========================================
    memory_read_state_t state;
    reg [3:0]  rst_timer;
    reg [31:0] data_remaining;     //全体の残りデータ
    reg [31:0] transfer_remaining; //今回の転送の残りデータ
    reg [2:0]  dwords_packet;      //今回の転送のDWORD数
    reg [63:0] read_address;
    reg [9:0]  dw_received;

    wire [9:0] dw_length = transfer_remaining == 32'd4096 ? 10'd0 : (transfer_remaining[11:2] + (transfer_remaining[1:0] != 2'b00));
    wire [1:0] last_dw_byte = transfer_remaining[1:0];
    wire [3:0] last_dw_be = data_remaining != 32'd0     ? 4'hF    : //今回のTLPは4DWORDで埋まっている
                            transfer_remaining <= 32'd4  ? 4'h0   : //DWORD以下(3バイト以下) = 1st DWのみ有効
                            last_dw_byte == 2'd1        ? 4'b0001 : //DWORD+1バイト
                            last_dw_byte == 2'd2        ? 4'b0011 : //DWORD+2バイト
                            last_dw_byte == 2'd3        ? 4'b0111 : 4'b1111; //DWORD+3バイト
    wire [3:0] first_dw_be = transfer_remaining >= 32'd4 ? 4'hF    : //DWORD以上(4バイト以上) = 1st DWは全有効
                             last_dw_byte == 2'd1        ? 4'b0001 : //DWORD+1バイト
                             last_dw_byte == 2'd2        ? 4'b0011 : //DWORD+2バイト
                             last_dw_byte == 2'd3        ? 4'b0111 : 4'b1111; //DWORD+3バイト

    assign mem_rd_in.state = state;

    //===========================================
    // TLP OUT
    //===========================================
    reg [7:0] request_id;

    reg [127:0] tlp_data;
    reg [3:0]   tkeepdw;
    reg         tfirst;
    reg         tlast;
    reg         tvalid;
    reg         has_data;

    assign tlps_out.tdata    = tlp_data;
    assign tlps_out.tkeepdw  = tkeepdw;
    assign tlps_out.tuser[0] = tfirst; //FIRST
    assign tlps_out.tuser[1] = tlast;  //LAST
    assign tlps_out.tlast    = tlast;  //LAST
    assign tlps_out.tvalid   = tvalid;
    assign tlps_out.has_data = has_data;

    //===========================================
    // TLP IN
    //===========================================
    reg [31:0] first_dword;

    wire first = tlps_in.tuser[0];
    wire is_cpld = first && (tlps_in.tdata[31:25] == 7'b0100101);
    wire our_tag = (tlps_in.tdata[79:72] == request_id);

    //===========================================
    // FIFO
    //===========================================
    reg [127:0] fifo_wr_in;
    reg         fifo_wr_en;
    reg         fifo_rst;

    wire        fifo_srst = fifo_rst | rst;

    fifo_128_128_mem_read i_fifo_128_128_mem_read(
        .srst       ( fifo_srst         ),
        .clk        ( clk_pcie          ),
        .full       (                   ),
        .din        ( fifo_wr_in        ),
        .wr_en      ( fifo_wr_en        ),
        .empty      (                   ),
        .dout       ( mem_rd_in.dout    ),
        .rd_en      ( mem_rd_in.rd_en   )
    );
    
    always @(posedge clk_pcie) begin
        if (rst) begin
            state <= RD_IDLE;
            rst_timer <= 3'd0;

            data_remaining <= 32'd0;
            transfer_remaining <= 32'd0;
            dwords_packet <= 3'd0;
            read_address  <= 64'h0;
            dw_received   <= 10'h0;
            
            // Step 4: reset into safe range (0x00-0xFB). Tags 0xFC-0xFF
            //         reserved for pcileech_fake_dma_gen (bus-master emulation).
            request_id <= 8'h00;

            tlp_data <= 128'h0;
            tkeepdw  <= 4'h0;
            tfirst   <= 1'b0;
            tlast    <= 1'b0;
            tvalid   <= 1'b0;
            has_data <= 1'b0;

            first_dword <= 32'h0;

            fifo_wr_in <= 128'h0;
            fifo_wr_en <= 1'b0;
            fifo_rst   <= 1'b0;
        end else begin
            case (state)
                RD_IDLE: begin
                    if (mem_rd_in.has_request) begin
                        state <= RD_CALC_DATA;
                        read_address   <= mem_rd_in.address;
                        data_remaining <= mem_rd_in.data_length;
                    end
                end
                RD_CALC_DATA: begin
                    if (data_remaining > MAX_PAYLOAD_SIZE) begin
                        transfer_remaining <= MAX_PAYLOAD_SIZE;
                        data_remaining <= data_remaining - MAX_PAYLOAD_SIZE;
                    end else begin
                        transfer_remaining <= data_remaining;
                        data_remaining <= 32'd0;
                    end
                    state <= RD_PREPARE_HEADER;
                end
                RD_PREPARE_HEADER: begin
                    tkeepdw  <= 4'hF;
                    tfirst   <= 1'b1;
                    tlast    <= 1'b1;
                    has_data <= 1'b1;
                    tlp_data <= {
                        read_address[31:0],
                        read_address[63:32],
                        { `_bs16(pcie_id), request_id, last_dw_be, first_dw_be },
                        22'b00100000_00000000_000000, dw_length
                    };
                    read_address <= read_address + transfer_remaining;
                    state <= RD_TRANSMIT_HEADER;
                end
                RD_TRANSMIT_HEADER: begin
                    if (tlps_out.tready) begin
                        tvalid <= 1'b1;
                        has_data <= 1'b0;
                        state <=  RD_WAIT_CPLT;
                    end
                end
                RD_WAIT_CPLT: begin
                    tvalid <= 1'b0;
                    if (tlps_in.tvalid && is_cpld && our_tag) begin
                        first_dword <= `_bs32(tlps_in.tdata[127:96]); //4st DW of CPLT packet
                        dw_received <= dw_received + 1;
                        if (dw_length <= 10'd1) begin
                            //complete read with only 1DW -> push to fifo
                            state <= RD_PACK_LAST;
                        end else begin
                            state <= RD_GET_DATA;
                        end
                    end
                end
                RD_GET_DATA: begin
                    if (tlps_in.tvalid) begin
                        fifo_wr_en <= 1'b1;
                        first_dword <= `_bs32(tlps_in.tdata[127:96]); //new 1st dword
                        fifo_wr_in[31:0]   <= first_dword; //old 1st dword
                        fifo_wr_in[63:32]  <= (dw_length - dw_received >= 1) ? `_bs32(tlps_in.tdata[31:0]) : 32'h0;
                        fifo_wr_in[95:64]  <= (dw_length - dw_received >= 2) ? `_bs32(tlps_in.tdata[63:32]) : 32'h0;
                        fifo_wr_in[127:96] <= (dw_length - dw_received >= 3) ? `_bs32(tlps_in.tdata[95:64]) : 32'h0;

                        if (dw_length - dw_received == 10'd4) begin
                            state <= RD_PACK_LAST;
                        end else if (dw_length - dw_received < 10'd4) begin
                            state <= RD_COMPLETE;
                        end else begin
                            dw_received <= dw_received + 10'd4;
                        end
                    end else begin
                        fifo_wr_en <= 1'b0;
                    end
                end
                RD_PACK_LAST: begin
                    fifo_wr_en <= 1'b1;
                    fifo_wr_in <= { 96'h0, first_dword };
                    state <= RD_COMPLETE;
                end
                RD_COMPLETE: begin
                    fifo_wr_en <= 1'b0;
                    if (!mem_rd_in.has_request) begin
                        state <= RD_CLEANUP;
                    end
                end
                RD_CLEANUP: begin
                    data_remaining <= 32'd0;
                    transfer_remaining <= 32'd0;
                    dwords_packet <= 3'd0;
                    read_address  <= 64'h0;
                    dw_received   <= 10'h0;
            
                    // Step 4: wrap at 0xFB. Skip 0xFC-0xFF (fake DMA reserved).
                    request_id <= (request_id == 8'hFB) ? 8'h00 : request_id + 8'd1;

                    tlp_data <= 128'h0;
                    tkeepdw  <= 4'h0;
                    tfirst   <= 1'b0;
                    tlast    <= 1'b0;
                    tvalid   <= 1'b0;
                    has_data <= 1'b0;

                    first_dword <= 32'h0;

                    fifo_wr_in <= 128'h0;
                    fifo_wr_en <= 1'b0;

                    if (rst_timer == 3'd7) begin
                        state <= RD_IDLE;
                        fifo_rst <= 1'b0;
                        rst_timer <= 3'd0;
                    end else begin
                        fifo_rst <= 1'b1;
                        rst_timer <= rst_timer + 3'd1;
                    end
                end
            endcase
        end
    end
endmodule
