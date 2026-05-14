// ============================================================================
// PCIe TLP Debug Probes — ILA-ready signal taps
// ============================================================================
//
// Instantiate this module inside pcileech_pcie_a7.sv to expose key signals
// for Vivado ILA capture. All outputs have (* mark_debug *) so Vivado's
// "Set Up Debug" wizard finds them automatically.
//
// CLOCK DOMAIN: clk_pcie (62.5 MHz for Gen1 x1)
//
// WHAT YOU CAN OBSERVE:
//   - Every TLP received from the host (config reads/writes, BAR accesses)
//   - Every TLP transmitted back (completions, interrupt asserts)
//   - BAR controller register read/write activity
//   - PCIe link state, device ID, BAR addresses
//   - Interrupt assert/deassert timing
//
// RESOURCE USAGE: ~0 LUTs (wires only), ILA core uses ~2-4 BRAM
// ============================================================================

`timescale 1ns / 1ps

module pcileech_tlp_debug_probes(
    input           clk_pcie,
    input           rst,
    
    // --- TLP RX: packets FROM host TO device (128-bit AXI stream) ---
    input [127:0]   tlps_rx_tdata,
    input [3:0]     tlps_rx_tkeepdw,
    input           tlps_rx_tvalid,
    input           tlps_rx_tlast,
    input [8:0]     tlps_rx_tuser,

    // --- TLP TX: packets FROM device TO host (128-bit AXI stream) ---
    input [127:0]   tlps_tx_tdata,
    input [3:0]     tlps_tx_tkeepdw,
    input           tlps_tx_tvalid,
    input           tlps_tx_tlast,
    
    // --- BAR controller activity ---
    input           bar_wr_valid,
    input [31:0]    bar_wr_addr,
    input [31:0]    bar_wr_data,
    input           bar_rd_req_valid,
    input [31:0]    bar_rd_req_addr,
    input           bar_rd_rsp_valid,
    input [31:0]    bar_rd_rsp_data,
    
    // --- PCIe state ---
    input           user_lnk_up,
    input [15:0]    pcie_id,
    input [31:0]    base_address_register,
    input [15:0]    cfg_command,
    input [5:0]     pl_ltssm_state,
    input           intx_line
);

    // =====================================================================
    // TLP RX DECODER — extract fields from first DWORD of received TLP
    // =====================================================================
    // PCIe TLP header format (first 128 bits, little-endian on AXI):
    //   DW0 [31:0]  = tdata[31:0]   = Fmt[31:29] Type[28:24] TC[22:20] Len[9:0]
    //   DW1 [31:0]  = tdata[63:32]  = ReqID[31:16] Tag[15:8] LastBE[7:4] FirstBE[3:0]
    //   DW2 [31:0]  = tdata[95:64]  = Address[31:0] (3DW) or AddrHi[31:0] (4DW)
    //   DW3 [31:0]  = tdata[127:96] = Data[31:0] (3DW) or AddrLo[31:0] (4DW)

    wire        rx_is_first = tlps_rx_tuser[0];
    wire        rx_valid_hdr = tlps_rx_tvalid & rx_is_first;

    // Decode TLP type from Fmt+Type fields
    wire [7:0]  rx_fmttype = tlps_rx_tdata[31:24];
    
    // Common TLP types:
    //   0x00 = MRd   3DW (Memory Read, no data)
    //   0x20 = MRd   4DW
    //   0x40 = MWr   3DW (Memory Write, with data)
    //   0x60 = MWr   4DW
    //   0x04 = CfgRd0 (Config Read Type 0)
    //   0x44 = CfgWr0 (Config Write Type 0)
    //   0x4A = CplD   (Completion with Data)
    //   0x0A = Cpl    (Completion without Data)
    //   0x30 = Msg
    //   0x34 = MsgD

    (* mark_debug = "TRUE" *) reg        dbg_rx_valid;
    (* mark_debug = "TRUE" *) reg [7:0]  dbg_rx_fmttype;
    (* mark_debug = "TRUE" *) reg [9:0]  dbg_rx_length;     // DW count
    (* mark_debug = "TRUE" *) reg [15:0] dbg_rx_requester;  // Requester ID
    (* mark_debug = "TRUE" *) reg [7:0]  dbg_rx_tag;
    (* mark_debug = "TRUE" *) reg [3:0]  dbg_rx_firstbe;
    (* mark_debug = "TRUE" *) reg [3:0]  dbg_rx_lastbe;
    (* mark_debug = "TRUE" *) reg [31:0] dbg_rx_address;    // target address
    (* mark_debug = "TRUE" *) reg [31:0] dbg_rx_data_dw0;   // first data DW (for writes)
    (* mark_debug = "TRUE" *) reg [6:0]  dbg_rx_bar_hit;    // which BAR was hit

    always @(posedge clk_pcie) begin
        dbg_rx_valid <= rx_valid_hdr;
        if (rx_valid_hdr) begin
            dbg_rx_fmttype  <= rx_fmttype;
            dbg_rx_length   <= tlps_rx_tdata[9:0];
            dbg_rx_requester<= tlps_rx_tdata[63:48];
            dbg_rx_tag      <= tlps_rx_tdata[47:40];
            dbg_rx_firstbe  <= tlps_rx_tdata[35:32];
            dbg_rx_lastbe   <= tlps_rx_tdata[39:36];
            dbg_rx_address  <= tlps_rx_tdata[95:64];
            dbg_rx_data_dw0 <= tlps_rx_tdata[127:96];
            dbg_rx_bar_hit  <= tlps_rx_tuser[8:2];
        end
    end

    // =====================================================================
    // TLP TX DECODER — extract fields from transmitted completions
    // =====================================================================
    wire        tx_is_first = (tlps_tx_tkeepdw != 0); // simplified
    wire        tx_valid_hdr = tlps_tx_tvalid;

    (* mark_debug = "TRUE" *) reg        dbg_tx_valid;
    (* mark_debug = "TRUE" *) reg [7:0]  dbg_tx_fmttype;
    (* mark_debug = "TRUE" *) reg [9:0]  dbg_tx_length;
    (* mark_debug = "TRUE" *) reg [15:0] dbg_tx_completer;  // Completer ID (our device)
    (* mark_debug = "TRUE" *) reg [31:0] dbg_tx_data_dw0;   // completion data

    always @(posedge clk_pcie) begin
        dbg_tx_valid <= tx_valid_hdr;
        if (tx_valid_hdr) begin
            dbg_tx_fmttype  <= tlps_tx_tdata[31:24];
            dbg_tx_length   <= tlps_tx_tdata[9:0];
            dbg_tx_completer<= tlps_tx_tdata[63:48];
            dbg_tx_data_dw0 <= tlps_tx_tdata[127:96];
        end
    end

    // =====================================================================
    // BAR ACTIVITY PROBES
    // =====================================================================
    (* mark_debug = "TRUE" *) reg        dbg_bar_wr;
    (* mark_debug = "TRUE" *) reg [7:0]  dbg_bar_wr_offset;
    (* mark_debug = "TRUE" *) reg [31:0] dbg_bar_wr_val;
    (* mark_debug = "TRUE" *) reg        dbg_bar_rd_req;
    (* mark_debug = "TRUE" *) reg [7:0]  dbg_bar_rd_offset;
    (* mark_debug = "TRUE" *) reg        dbg_bar_rd_rsp;
    (* mark_debug = "TRUE" *) reg [31:0] dbg_bar_rd_val;

    always @(posedge clk_pcie) begin
        dbg_bar_wr       <= bar_wr_valid;
        dbg_bar_wr_offset<= bar_wr_addr[7:0];
        dbg_bar_wr_val   <= bar_wr_data;
        dbg_bar_rd_req   <= bar_rd_req_valid;
        dbg_bar_rd_offset<= bar_rd_req_addr[7:0];
        dbg_bar_rd_rsp   <= bar_rd_rsp_valid;
        dbg_bar_rd_val   <= bar_rd_rsp_data;
    end

    // =====================================================================
    // PCIe STATE PROBES
    // =====================================================================
    (* mark_debug = "TRUE" *) reg        dbg_link_up;
    (* mark_debug = "TRUE" *) reg [15:0] dbg_pcie_id;
    (* mark_debug = "TRUE" *) reg [15:0] dbg_bar0_base;
    (* mark_debug = "TRUE" *) reg [15:0] dbg_cfg_cmd;
    (* mark_debug = "TRUE" *) reg [5:0]  dbg_ltssm;
    (* mark_debug = "TRUE" *) reg        dbg_intx;

    always @(posedge clk_pcie) begin
        dbg_link_up   <= user_lnk_up;
        dbg_pcie_id   <= pcie_id;
        dbg_bar0_base <= base_address_register[15:0];
        dbg_cfg_cmd   <= cfg_command;
        dbg_ltssm     <= pl_ltssm_state;
        dbg_intx      <= intx_line;
    end

    // =====================================================================
    // TLP STATISTICS COUNTERS (visible in ILA and useful for analysis)
    // =====================================================================
    (* mark_debug = "TRUE" *) reg [15:0] cnt_rx_tlp;      // total RX TLPs
    (* mark_debug = "TRUE" *) reg [15:0] cnt_tx_tlp;      // total TX TLPs
    (* mark_debug = "TRUE" *) reg [15:0] cnt_bar_rd;      // BAR read count
    (* mark_debug = "TRUE" *) reg [15:0] cnt_bar_wr;      // BAR write count
    (* mark_debug = "TRUE" *) reg [15:0] cnt_intx_assert; // interrupt count

    reg intx_prev;

    always @(posedge clk_pcie) begin
        if (rst) begin
            cnt_rx_tlp <= 0; cnt_tx_tlp <= 0;
            cnt_bar_rd <= 0; cnt_bar_wr <= 0;
            cnt_intx_assert <= 0; intx_prev <= 0;
        end else begin
            if (rx_valid_hdr)    cnt_rx_tlp <= cnt_rx_tlp + 1;
            if (tx_valid_hdr)    cnt_tx_tlp <= cnt_tx_tlp + 1;
            if (bar_rd_req_valid) cnt_bar_rd <= cnt_bar_rd + 1;
            if (bar_wr_valid)     cnt_bar_wr <= cnt_bar_wr + 1;
            intx_prev <= intx_line;
            if (intx_line && !intx_prev) cnt_intx_assert <= cnt_intx_assert + 1;
        end
    end

endmodule
