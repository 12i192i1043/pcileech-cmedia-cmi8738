//
// Step 4 — Fake DMA Master MRd generator
// ------------------------------------------------------------------------
// Emits periodic MRd TLPs when the emulated CMI8738 DMA channels are
// running, so that PCIe bus traffic matches a real audio endpoint during
// playback (~1378 MRd/s per active channel @ 176.4 KB/s).
//
// Key properties:
//   - Tag range 0xFC..0xFF reserved (host_mem_read_2 limited to 0x00..0xFB)
//   - Single-beat 3DW MRd (32-bit addressing, matches PCI 2.x legacy)
//   - Round-robin arbitration when both channels are active (fair)
//   - Priority: pcileech real traffic always preempts (via wrap mux)
//   - Safety gates: dma_base != 0, != 0xFFFFFFFF, size != 0, running
//   - 100-cycle watchdog on tready
//
// (c) 2026 — Step 4 extension
//
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_fake_dma_gen (
    input              rst,
    input              clk_pcie,
    input  [15:0]      pcie_id,

    // Channel 0 status
    input              ch0_running,
    input  [31:0]      ch0_dma_base,
    input  [15:0]      ch0_dma_size,

    // Channel 1 status
    input              ch1_running,
    input  [31:0]      ch1_dma_base,
    input  [15:0]      ch1_dma_size,

    // Step 4 SAFETY: driver-programmed flags + global runtime enable
    input              ch0_frame1_written,
    input              ch1_frame1_written,
    input              fake_dma_enable,

    // TLP AXIS source
    IfAXIS128.source   tlps_out
);

    // ---- Parameters --------------------------------------------------------
    // 62.5 MHz / (44100 * 2ch * 2B / 128B) = 62.5e6 / 1378.125 ≈ 45352.94
    localparam [15:0] TIMER_PERIOD  = 16'd45352;
    localparam [9:0]  MRD_LEN_DW    = 10'd32;     // 128 B burst
    localparam [6:0]  WDOG_LIMIT    = 7'd100;     // tready-wait timeout

    // ---- State encoding ----------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0,
                     S_WAIT  = 3'd1,
                     S_ISSUE = 3'd2,
                     S_DONE  = 3'd3,
                     S_WDOG  = 3'd4;

    reg [2:0]  state;
    reg [15:0] ch0_timer, ch1_timer;
    reg [15:0] ch0_offset, ch1_offset;
    reg [1:0]  tag_cnt;
    reg        last_served;   // 0 = CH0 last served, 1 = CH1 last served
    reg        served_ch;     // current transaction target
    reg [6:0]  wdog_cnt;

    // ---- Gate signals ------------------------------------------------------
    wire ch0_base_valid = (ch0_dma_base != 32'h00000000) &&
                          (ch0_dma_base != 32'hFFFFFFFF);
    wire ch1_base_valid = (ch1_dma_base != 32'h00000000) &&
                          (ch1_dma_base != 32'hFFFFFFFF);
    // Step 4 SAFETY: gate now REQUIRES driver to have explicitly written
    // FRAME1 post-reset (ch_frame1_written) AND global enable (fake_dma_enable).
    // This prevents the generator from firing MRd to the non-zero/non-FFFF
    // default reset values (0x0A22/0x0A23 0000) which would otherwise pass
    // the base_valid guard and cause WHEA AER faults on the host.
    wire ch0_gate = ch0_running && ch0_base_valid && (ch0_dma_size != 16'd0)
                 && ch0_frame1_written && fake_dma_enable;
    wire ch1_gate = ch1_running && ch1_base_valid && (ch1_dma_size != 16'd0)
                 && ch1_frame1_written && fake_dma_enable;
    wire any_gate = ch0_gate || ch1_gate;

    wire ch0_ready = ch0_gate && (ch0_timer == 16'd0);
    wire ch1_ready = ch1_gate && (ch1_timer == 16'd0);

    // Round-robin arbiter:
    //   - If only one channel ready, serve it
    //   - If both ready, serve the one opposite to last_served (fairness)
    wire pick_ch1 =  ch1_ready && (!ch0_ready || (last_served == 1'b0));
    wire pick_ch0 =  ch0_ready && !pick_ch1;
    wire any_ready = ch0_ready || ch1_ready;

    // ---- TLP header construction (combinational) ---------------------------
    wire [31:0] sel_base   = served_ch ? ch1_dma_base : ch0_dma_base;
    wire [15:0] sel_offset = served_ch ? ch1_offset   : ch0_offset;
    wire [7:0]  current_tag = {6'b111111, tag_cnt};   // 0xFC..0xFF

    // DW0 layout (PCIe Base 3.0 §2.2, MRd 3DW 32-bit addr):
    //   [31:29] Fmt = 000 (3DW header, no data)
    //   [28:24] Type = 00000 (MRd)
    //   [23]    R
    //   [22:20] TC = 000
    //   [19:16] R / Attr[2] / LN / TH = 0
    //   [15]    TD = 0
    //   [14]    EP = 0
    //   [13:12] Attr[1:0] = 00
    //   [11:10] AT[1:0]   = 00
    //   [9:0]   Length    = 32 DW
    wire [31:0] hdr_dw0 = {
        1'b0, 2'b00, 5'b00000,       // [31:24] Fmt[2:0] + Type[4:0]
        1'b0, 3'b000, 4'b0000,       // [23:16] R + TC[2:0] + R[3:0]
        1'b0, 1'b0, 2'b00, 2'b00,    // [15:10] TD + EP + Attr[1:0] + AT[1:0]
        MRD_LEN_DW                    // [ 9:0] Length
    };

    // DW1 layout:
    //   [31:16] RequesterID (bus/dev/func, byteswapped for PCIe wire format)
    //   [15:8]  Tag
    //   [7:4]   LastDW BE
    //   [3:0]   FirstDW BE
    wire [31:0] hdr_dw1 = {`_bs16(pcie_id), current_tag, 4'hF, 4'hF};

    // DW2 layout (3DW addressing):
    //   [31:2]  Address[31:2]  = (base + offset), DW-aligned
    //   [ 1:0]  R              = 00
    wire [31:0] hdr_dw2 = (sel_base + {16'h0, sel_offset}) & 32'hFFFFFFFC;

    // Full 128-bit AXIS beat: DW3 unused (tkeepdw[3]=0)
    wire [127:0] mrd_tlp = {32'h00000000, hdr_dw2, hdr_dw1, hdr_dw0};

    // ---- AXIS source drive (registered to keep timing clean) --------------
    reg         r_tvalid;
    reg         r_has_data;
    reg [127:0] r_tdata;

    assign tlps_out.tvalid   = r_tvalid;
    assign tlps_out.tlast    = 1'b1;             // single-beat packet
    assign tlps_out.tkeepdw  = 4'b0111;          // DW0..DW2 valid, DW3 skip
    assign tlps_out.tuser    = 9'b000000001;     // tuser[0] = first
    assign tlps_out.has_data = r_has_data;
    assign tlps_out.tdata    = r_tdata;

    // ---- Main FSM ----------------------------------------------------------
    always @(posedge clk_pcie) begin
        if (rst) begin
            state        <= S_IDLE;
            ch0_timer    <= TIMER_PERIOD;
            ch1_timer    <= TIMER_PERIOD;
            ch0_offset   <= 16'd0;
            ch1_offset   <= 16'd0;
            tag_cnt      <= 2'd0;
            last_served  <= 1'b0;
            served_ch    <= 1'b0;
            wdog_cnt     <= 7'd0;
            r_tvalid     <= 1'b0;
            r_has_data   <= 1'b0;
            r_tdata      <= 128'd0;
        end
        else begin
            // ---- Timer management (independent per channel, RELOAD mode) --
            // CH0
            if (!ch0_gate)
                ch0_timer <= TIMER_PERIOD;
            else if (state == S_DONE && served_ch == 1'b0)
                ch0_timer <= TIMER_PERIOD;
            else if (ch0_timer != 16'd0)
                ch0_timer <= ch0_timer - 16'd1;
            // CH1
            if (!ch1_gate)
                ch1_timer <= TIMER_PERIOD;
            else if (state == S_DONE && served_ch == 1'b1)
                ch1_timer <= TIMER_PERIOD;
            else if (ch1_timer != 16'd0)
                ch1_timer <= ch1_timer - 16'd1;

            // ---- FSM ---------------------------------------------------------
            case (state)
                // -----------------------------------------------------------
                // S_IDLE: all channels disabled; wait for any gate to open
                // -----------------------------------------------------------
                S_IDLE: begin
                    r_tvalid   <= 1'b0;
                    r_has_data <= 1'b0;
                    if (any_gate) state <= S_WAIT;
                end

                // -----------------------------------------------------------
                // S_WAIT: at least one gate open, waiting for timer expiry
                // -----------------------------------------------------------
                S_WAIT: begin
                    r_tvalid   <= 1'b0;
                    r_has_data <= 1'b0;
                    if (!any_gate) begin
                        state <= S_IDLE;
                    end
                    else if (any_ready) begin
                        served_ch  <= pick_ch1;       // latch chosen channel
                        r_tdata    <= mrd_tlp;        // latch header
                        r_has_data <= 1'b1;           // advertise to mux
                        r_tvalid   <= 1'b1;
                        wdog_cnt   <= 7'd0;
                        state      <= S_ISSUE;
                    end
                end

                // -----------------------------------------------------------
                // S_ISSUE: drive tvalid until wrap mux consumes (tready=1)
                //          or watchdog fires, or gate drops mid-flight
                // -----------------------------------------------------------
                S_ISSUE: begin
                    // Preemption: channel disabled while in flight → abort
                    if (!(served_ch ? ch1_gate : ch0_gate)) begin
                        r_tvalid   <= 1'b0;
                        r_has_data <= 1'b0;
                        state      <= S_WAIT;
                    end
                    else if (tlps_out.tready) begin
                        // TLP consumed by arbiter
                        r_tvalid   <= 1'b0;
                        r_has_data <= 1'b0;
                        state      <= S_DONE;
                    end
                    else if (wdog_cnt == WDOG_LIMIT) begin
                        // 100 cycles without tready → abort, do not advance
                        r_tvalid   <= 1'b0;
                        r_has_data <= 1'b0;
                        state      <= S_WDOG;
                    end
                    else begin
                        wdog_cnt   <= wdog_cnt + 7'd1;
                    end
                end

                // -----------------------------------------------------------
                // S_DONE: MRd committed → advance offset + tag + last_served
                // -----------------------------------------------------------
                S_DONE: begin
                    if (served_ch == 1'b0) begin
                        if (ch0_offset + 16'd128 >= ch0_dma_size)
                            ch0_offset <= 16'd0;
                        else
                            ch0_offset <= ch0_offset + 16'd128;
                    end else begin
                        if (ch1_offset + 16'd128 >= ch1_dma_size)
                            ch1_offset <= 16'd0;
                        else
                            ch1_offset <= ch1_offset + 16'd128;
                    end
                    tag_cnt     <= tag_cnt + 2'd1;
                    last_served <= served_ch;
                    state       <= S_WAIT;
                end

                // -----------------------------------------------------------
                // S_WDOG: recovery cycle, no side-effects (tag/offset frozen)
                // -----------------------------------------------------------
                S_WDOG: begin
                    state <= S_WAIT;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
