//
// Step 4 — TLP TX pre-inject wrap mux
// ------------------------------------------------------------------------
// 2-to-1 combinational priority mux inserted between the pcileech_pcie_tlp_a7
// sink_mux1 and the tlps_in6 (tlps_static) port. Lets the fake DMA generator
// share that slot with the static TLP injector without modifying sink_mux1.
//
// Priority:
//   orig_in (tlps_static from pcileech_pcie_cfg_a7) > fake_in (fake_dma_gen)
//
// Why combinational:
//   sink_mux1 relies on `has_data` look-ahead to pre-select the source before
//   tvalid rises. Registering here would race with that look-ahead. We propagate
//   all signals combinationally and only register `sel_fake` (safe, toggles on
//   packet boundary: tlast or when both sides are idle).
//
// (c) 2026 — Step 4 extension
//
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_tlp_tx_wrap (
    input              rst,
    input              clk_pcie,
    IfAXIS128.sink     orig_in,    // from tlps_static
    IfAXIS128.sink     fake_in,    // from pcileech_fake_dma_gen
    IfAXIS128.source   tlps_out    // to sink_mux1.tlps_in6
);

    // ---- Selection latch ---------------------------------------------------
    // Switch selection only at packet boundaries. Orig always wins ties.
    bit  sel_fake = 0;     // 0 = orig, 1 = fake
    wire orig_active  = orig_in.has_data || orig_in.tvalid;
    wire pkt_boundary = !tlps_out.tvalid || (tlps_out.tvalid && tlps_out.tlast);
    wire select_next  = !orig_active;   // fake only if orig idle

    always @(posedge clk_pcie) begin
        if (rst)               sel_fake <= 1'b0;
        else if (pkt_boundary) sel_fake <= select_next;
    end

    // Re-gate: even once fake was selected, if orig becomes active between
    // packets, switch back immediately (orig preempts). Safe because fake
    // TLPs are single-beat so packet boundary is every cycle for fake.
    wire use_fake = sel_fake && !orig_active;

    // ---- Combinational pass-through ---------------------------------------
    assign tlps_out.has_data = orig_in.has_data || fake_in.has_data;
    assign tlps_out.tdata    = use_fake ? fake_in.tdata   : orig_in.tdata;
    assign tlps_out.tkeepdw  = use_fake ? fake_in.tkeepdw : orig_in.tkeepdw;
    assign tlps_out.tlast    = use_fake ? fake_in.tlast   : orig_in.tlast;
    assign tlps_out.tuser    = use_fake ? fake_in.tuser   : orig_in.tuser;
    assign tlps_out.tvalid   = use_fake ? fake_in.tvalid  : orig_in.tvalid;

    // Backpressure: only the selected source gets tready=1
    assign orig_in.tready = tlps_out.tready && !use_fake;
    assign fake_in.tready = tlps_out.tready &&  use_fake;

endmodule
