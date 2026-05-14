// ============================================================================
// PCILeech BAR Controller — C-Media CMI8738/PCI-SX Null Endpoint
// ============================================================================
// Target: Artix-7 100T/75T Captain DMA
// BAR0: I/O space, 256 bytes — full CMI8738 register emulation
// Audio: null endpoint — position advances, interrupts fire, no real DMA
// PCILeech: completely unaffected, zero audio TLP overhead
// ============================================================================

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_tlps128_bar_controller(
    input                   rst,
    input                   clk,
    input                   bar_en,
    input [15:0]            pcie_id,
    IfAXIS128.sink_lite     tlps_in,
    IfAXIS128.source        tlps_out,
    output wire             intx_line,
    output wire             led_dma_debug,
    input [31:0]            base_address_register,
    input [31:0]            base_address_register_1,
    input [31:0]            base_address_register_2,
    input [31:0]            base_address_register_3,
    input [31:0]            base_address_register_4,
    input [31:0]            base_address_register_5,
    IfMemoryWrite.source     mem_wr_out,
    IfMemoryRead.source      mem_rd_out,
    // Step 4: expose CMI8738 channel state to fake DMA generator
    output wire              fake_ch0_running,
    output wire [31:0]       fake_ch0_dma_base,
    output wire [15:0]       fake_ch0_dma_size,
    output wire              fake_ch1_running,
    output wire [31:0]       fake_ch1_dma_base,
    output wire [15:0]       fake_ch1_dma_size,
    // Step 4 SAFETY: driver-programmed flags + global enable
    output wire              fake_ch0_frame1_written,
    output wire              fake_ch1_frame1_written,
    output wire              fake_dma_enable
);
    
    wire in_is_wr_ready;
    bit  in_is_wr_last;
    wire in_is_first    = tlps_in.tuser[0];
    wire in_is_bar      = bar_en && (tlps_in.tuser[8:2] != 0);
    wire in_is_rd       = (in_is_first && tlps_in.tlast && ((tlps_in.tdata[31:25] == 7'b0000000) || (tlps_in.tdata[31:25] == 7'b0010000) || (tlps_in.tdata[31:24] == 8'b00000010)));
    wire in_is_wr       = in_is_wr_last || (in_is_first && in_is_wr_ready && ((tlps_in.tdata[31:25] == 7'b0100000) || (tlps_in.tdata[31:25] == 7'b0110000) || (tlps_in.tdata[31:24] == 8'b01000010)));
    
    always @ ( posedge clk )
        if ( rst ) begin
            in_is_wr_last <= 0;
        end
        else if ( tlps_in.tvalid ) begin
            in_is_wr_last <= !tlps_in.tlast && in_is_wr;
        end
    
    wire [6:0]  wr_bar;
    wire [31:0] wr_addr;
    wire [3:0]  wr_be;
    wire [31:0] wr_data;
    wire        wr_valid;
    wire [87:0] rd_req_ctx;
    wire [6:0]  rd_req_bar;
    wire [31:0] rd_req_addr;
    wire        rd_req_valid;
    wire [87:0] rd_rsp_ctx;
    wire [31:0] rd_rsp_data;
    wire        rd_rsp_valid;
        
    pcileech_tlps128_bar_rdengine i_pcileech_tlps128_bar_rdengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .pcie_id        ( pcie_id                       ),
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_rd ),
        .tlps_out       ( tlps_out                      ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_bar     ( rd_req_bar                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid                  ),
        .rd_rsp_ctx     ( rd_rsp_ctx                    ),
        .rd_rsp_data    ( rd_rsp_data                   ),
        .rd_rsp_valid   ( rd_rsp_valid                  )
    );

    pcileech_tlps128_bar_wrengine i_pcileech_tlps128_bar_wrengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_wr ),
        .tlps_in_ready  ( in_is_wr_ready                ),
        .wr_bar         ( wr_bar                        ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid                      )
    );
    
    wire [87:0] bar_rsp_ctx[7];
    wire [31:0] bar_rsp_data[7];
    wire        bar_rsp_valid[7];
    
    assign rd_rsp_ctx = bar_rsp_valid[0] ? bar_rsp_ctx[0] :
                        bar_rsp_valid[1] ? bar_rsp_ctx[1] :
                        bar_rsp_valid[2] ? bar_rsp_ctx[2] :
                        bar_rsp_valid[3] ? bar_rsp_ctx[3] :
                        bar_rsp_valid[4] ? bar_rsp_ctx[4] :
                        bar_rsp_valid[5] ? bar_rsp_ctx[5] :
                        bar_rsp_valid[6] ? bar_rsp_ctx[6] : 0;
    assign rd_rsp_data = bar_rsp_valid[0] ? bar_rsp_data[0] :
                        bar_rsp_valid[1] ? bar_rsp_data[1] :
                        bar_rsp_valid[2] ? bar_rsp_data[2] :
                        bar_rsp_valid[3] ? bar_rsp_data[3] :
                        bar_rsp_valid[4] ? bar_rsp_data[4] :
                        bar_rsp_valid[5] ? bar_rsp_data[5] :
                        bar_rsp_valid[6] ? bar_rsp_data[6] : 0;
    assign rd_rsp_valid = bar_rsp_valid[0] || bar_rsp_valid[1] || bar_rsp_valid[2] || bar_rsp_valid[3] || bar_rsp_valid[4] || bar_rsp_valid[5] || bar_rsp_valid[6];
    
    // BAR0: CMI8738 null endpoint
    pcileech_bar_impl_CMI8738_null i_bar0(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[0]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[0] ),
        .base_address_register( base_address_register   ),
        .intx_line      ( intx_line                     ),
        .led_dma_debug  ( led_dma_debug                 ),
        .rd_rsp_ctx     ( bar_rsp_ctx[0]                ),
        .rd_rsp_data    ( bar_rsp_data[0]               ),
        .rd_rsp_valid   ( bar_rsp_valid[0]              ),
        .mem_wr_out     ( mem_wr_out                    ),
        .mem_rd_out     ( mem_rd_out                    ),
        // Step 4: fake DMA channel status
        .fake_ch0_running  ( fake_ch0_running              ),
        .fake_ch0_dma_base ( fake_ch0_dma_base             ),
        .fake_ch0_dma_size ( fake_ch0_dma_size             ),
        .fake_ch1_running  ( fake_ch1_running              ),
        .fake_ch1_dma_base ( fake_ch1_dma_base             ),
        .fake_ch1_dma_size ( fake_ch1_dma_size             ),
        // Step 4 SAFETY: driver-programmed flags + global enable
        .fake_ch0_frame1_written ( fake_ch0_frame1_written  ),
        .fake_ch1_frame1_written ( fake_ch1_frame1_written  ),
        .fake_dma_enable         ( fake_dma_enable          )
    );
    
    // BAR1-5 + OptROM: disabled
    pcileech_bar_impl_none i_bar1( .rst(rst), .clk(clk), .wr_addr(wr_addr), .wr_be(wr_be), .wr_data(wr_data), .wr_valid(wr_valid && wr_bar[1]), .rd_req_ctx(rd_req_ctx), .rd_req_addr(rd_req_addr), .rd_req_valid(rd_req_valid && rd_req_bar[1]), .rd_rsp_ctx(bar_rsp_ctx[1]), .rd_rsp_data(bar_rsp_data[1]), .rd_rsp_valid(bar_rsp_valid[1]) );
    pcileech_bar_impl_none i_bar2( .rst(rst), .clk(clk), .wr_addr(wr_addr), .wr_be(wr_be), .wr_data(wr_data), .wr_valid(wr_valid && wr_bar[2]), .rd_req_ctx(rd_req_ctx), .rd_req_addr(rd_req_addr), .rd_req_valid(rd_req_valid && rd_req_bar[2]), .rd_rsp_ctx(bar_rsp_ctx[2]), .rd_rsp_data(bar_rsp_data[2]), .rd_rsp_valid(bar_rsp_valid[2]) );
    pcileech_bar_impl_none i_bar3( .rst(rst), .clk(clk), .wr_addr(wr_addr), .wr_be(wr_be), .wr_data(wr_data), .wr_valid(wr_valid && wr_bar[3]), .rd_req_ctx(rd_req_ctx), .rd_req_addr(rd_req_addr), .rd_req_valid(rd_req_valid && rd_req_bar[3]), .rd_rsp_ctx(bar_rsp_ctx[3]), .rd_rsp_data(bar_rsp_data[3]), .rd_rsp_valid(bar_rsp_valid[3]) );
    pcileech_bar_impl_none i_bar4( .rst(rst), .clk(clk), .wr_addr(wr_addr), .wr_be(wr_be), .wr_data(wr_data), .wr_valid(wr_valid && wr_bar[4]), .rd_req_ctx(rd_req_ctx), .rd_req_addr(rd_req_addr), .rd_req_valid(rd_req_valid && rd_req_bar[4]), .rd_rsp_ctx(bar_rsp_ctx[4]), .rd_rsp_data(bar_rsp_data[4]), .rd_rsp_valid(bar_rsp_valid[4]) );
    pcileech_bar_impl_none i_bar5( .rst(rst), .clk(clk), .wr_addr(wr_addr), .wr_be(wr_be), .wr_data(wr_data), .wr_valid(wr_valid && wr_bar[5]), .rd_req_ctx(rd_req_ctx), .rd_req_addr(rd_req_addr), .rd_req_valid(rd_req_valid && rd_req_bar[5]), .rd_rsp_ctx(bar_rsp_ctx[5]), .rd_rsp_data(bar_rsp_data[5]), .rd_rsp_valid(bar_rsp_valid[5]) );
    pcileech_bar_impl_none i_bar6_optrom( .rst(rst), .clk(clk), .wr_addr(wr_addr), .wr_be(wr_be), .wr_data(wr_data), .wr_valid(wr_valid && wr_bar[6]), .rd_req_ctx(rd_req_ctx), .rd_req_addr(rd_req_addr), .rd_req_valid(rd_req_valid && rd_req_bar[6]), .rd_rsp_ctx(bar_rsp_ctx[6]), .rd_rsp_data(bar_rsp_data[6]), .rd_rsp_valid(bar_rsp_valid[6]) );

endmodule
module pcileech_tlps128_bar_wrengine(
    input                   rst,    
    input                   clk,
    IfAXIS128.sink_lite     tlps_in,
    input                   tlps_in_valid,
    output                  tlps_in_ready,
    output bit [6:0]        wr_bar,
    output bit [31:0]       wr_addr,
    output bit [3:0]        wr_be,
    output bit [31:0]       wr_data,
    output bit              wr_valid
);

    wire            f_rd_en;
    wire [127:0]    f_tdata;
    wire [3:0]      f_tkeepdw;
    wire [8:0]      f_tuser;
    wire            f_tvalid;
    
    bit [127:0]     tdata;
    bit [3:0]       tkeepdw;
    bit             tlast;
    
    bit [3:0]       be_first;
    bit [3:0]       be_last;
    bit             first_dw;
    bit [31:0]      addr;

    fifo_141_141_clk1_bar_wr i_fifo_141_141_clk1_bar_wr(
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( {tlps_in.tuser[8:0], tlps_in.tkeepdw, tlps_in.tdata} ),
        .full           (                               ),
        .prog_empty     ( tlps_in_ready                 ),
        .rd_en          ( f_rd_en                       ),
        .dout           ( {f_tuser, f_tkeepdw, f_tdata} ),    
        .empty          (                               ),
        .valid          ( f_tvalid                      )
    );
    
    `define S_ENGINE_IDLE        3'h0
    `define S_ENGINE_FIRST       3'h1
    `define S_ENGINE_4DW_REQDATA 3'h2
    `define S_ENGINE_TX0         3'h4
    `define S_ENGINE_TX1         3'h5
    `define S_ENGINE_TX2         3'h6
    `define S_ENGINE_TX3         3'h7
    (* KEEP = "TRUE" *) bit [3:0] state = `S_ENGINE_IDLE;
    
    assign f_rd_en = (state == `S_ENGINE_IDLE) ||
                     (state == `S_ENGINE_4DW_REQDATA) ||
                     (state == `S_ENGINE_TX3) ||
                     ((state == `S_ENGINE_TX2 && !tkeepdw[3])) ||
                     ((state == `S_ENGINE_TX1 && !tkeepdw[2])) ||
                     ((state == `S_ENGINE_TX0 && !f_tkeepdw[1]));

    always @ ( posedge clk ) begin
        wr_addr     <= addr;
        wr_valid    <= ((state == `S_ENGINE_TX0) && f_tvalid) || (state == `S_ENGINE_TX1) || (state == `S_ENGINE_TX2) || (state == `S_ENGINE_TX3);
    end

    always @ ( posedge clk )
        if ( rst ) begin
            state <= `S_ENGINE_IDLE;
        end
        else case ( state )
            `S_ENGINE_IDLE: begin
                state   <= `S_ENGINE_FIRST;
            end
            `S_ENGINE_FIRST: begin
                if ( f_tvalid && f_tuser[0] ) begin
                    wr_bar      <= f_tuser[8:2];
                    tdata       <= f_tdata;
                    tkeepdw     <= f_tkeepdw;
                    tlast       <= f_tuser[1];
                    first_dw    <= 1;
                    be_first    <= f_tdata[35:32];
                    be_last     <= f_tdata[39:36];
                    if ( f_tdata[31:29] == 8'b010 ) begin
                        addr    <= { f_tdata[95:66], 2'b00 };
                        state   <= `S_ENGINE_TX3;
                    end
                    else if ( f_tdata[31:29] == 8'b011 ) begin
                        addr    <= { f_tdata[127:98], 2'b00 };
                        state   <= `S_ENGINE_4DW_REQDATA;
                    end 
                end
                else begin
                    state   <= `S_ENGINE_IDLE;
                end
            end 
            `S_ENGINE_4DW_REQDATA: begin
                state   <= `S_ENGINE_TX0;
            end
            `S_ENGINE_TX0: begin
                tdata       <= f_tdata;
                tkeepdw     <= f_tkeepdw;
                tlast       <= f_tuser[1];
                addr        <= addr + 4;
                wr_data     <= { f_tdata[0+00+:8], f_tdata[0+08+:8], f_tdata[0+16+:8], f_tdata[0+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (f_tkeepdw[1] ? 4'hf : be_last);
                state       <= f_tvalid ? (f_tkeepdw[1] ? `S_ENGINE_TX1 : `S_ENGINE_FIRST) : `S_ENGINE_IDLE;
            end
            `S_ENGINE_TX1: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[32+00+:8], tdata[32+08+:8], tdata[32+16+:8], tdata[32+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (tkeepdw[2] ? 4'hf : be_last);
                state       <= tkeepdw[2] ? `S_ENGINE_TX2 : `S_ENGINE_FIRST;
            end
            `S_ENGINE_TX2: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[64+00+:8], tdata[64+08+:8], tdata[64+16+:8], tdata[64+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (tkeepdw[3] ? 4'hf : be_last);
                state       <= tkeepdw[3] ? `S_ENGINE_TX3 : `S_ENGINE_FIRST;
            end
            `S_ENGINE_TX3: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[96+00+:8], tdata[96+08+:8], tdata[96+16+:8], tdata[96+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (!tlast ? 4'hf : be_last);
                state       <= !tlast ? `S_ENGINE_TX0 : `S_ENGINE_FIRST;
            end
        endcase

endmodule


// ============================================================================
// BAR READ ENGINE — ORIGINAL FRAMEWORK (verbatim from core3d)
// ============================================================================
module pcileech_tlps128_bar_rdengine(
    input                   rst,    
    input                   clk,
    input [15:0]            pcie_id,
    IfAXIS128.sink_lite     tlps_in,
    input                   tlps_in_valid,
    IfAXIS128.source        tlps_out,
    output [87:0]           rd_req_ctx,
    output [6:0]            rd_req_bar,
    output [31:0]           rd_req_addr,
    output                  rd_req_valid,
    input  [87:0]           rd_rsp_ctx,
    input  [31:0]           rd_rsp_data,
    input                   rd_rsp_valid
);

    // 1: PROCESS AND QUEUE INCOMING READ TLPs:
    wire [10:0] rd1_in_dwlen    = (tlps_in.tdata[9:0] == 0) ? 11'd1024 : {1'b0, tlps_in.tdata[9:0]};
    wire [6:0]  rd1_in_bar      = tlps_in.tuser[8:2];
    wire [15:0] rd1_in_reqid    = tlps_in.tdata[63:48];
    wire [7:0]  rd1_in_tag      = tlps_in.tdata[47:40];
    wire [31:0] rd1_in_addr     = { ((tlps_in.tdata[31:29] == 3'b000) ? tlps_in.tdata[95:66] : tlps_in.tdata[127:98]), 2'b00 };
    wire [73:0] rd1_in_data;
    assign rd1_in_data[73:63]   = rd1_in_dwlen;
    assign rd1_in_data[62:56]   = rd1_in_bar;   
    assign rd1_in_data[55:48]   = rd1_in_tag;
    assign rd1_in_data[47:32]   = rd1_in_reqid;
    assign rd1_in_data[31:0]    = rd1_in_addr;
    
    wire        rd1_out_rden;
    wire [73:0] rd1_out_data;
    wire        rd1_out_valid;
    
    fifo_74_74_clk1_bar_rd1 i_fifo_74_74_clk1_bar_rd1(
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( rd1_in_data                   ),
        .full           (                               ),
        .rd_en          ( rd1_out_rden                  ),
        .dout           ( rd1_out_data                  ),    
        .empty          (                               ),
        .valid          ( rd1_out_valid                 )
    );
    
    // 2: SPLIT READ TLPs INTO RESPONSE TLP READ REQUESTS:
    wire [10:0] rd1_out_dwlen       = rd1_out_data[73:63];
    wire [4:0]  rd1_out_dwlen5      = rd1_out_data[67:63];
    wire [4:0]  rd1_out_addr5       = rd1_out_data[6:2];
    
    wire [4:0]  rd2_pkt1_dwlen_pre  = ((rd1_out_addr5 + rd1_out_dwlen5 > 6'h20) || ((rd1_out_addr5 != 0) && (rd1_out_dwlen5 == 0))) ? (6'h20 - rd1_out_addr5) : rd1_out_dwlen5;
    wire [5:0]  rd2_pkt1_dwlen      = (rd2_pkt1_dwlen_pre == 0) ? 6'h20 : rd2_pkt1_dwlen_pre;
    wire [10:0] rd2_pkt1_dwlen_next = rd1_out_dwlen - rd2_pkt1_dwlen;
    wire        rd2_pkt1_large      = (rd1_out_dwlen > 32) || (rd1_out_dwlen != rd2_pkt1_dwlen);
    wire        rd2_pkt1_tiny       = (rd1_out_dwlen == 1);
    wire [11:0] rd2_pkt1_bc         = rd1_out_dwlen << 2;
    wire [85:0] rd2_pkt1;
    assign      rd2_pkt1[85:74]     = rd2_pkt1_bc;
    assign      rd2_pkt1[73:63]     = rd2_pkt1_dwlen;
    assign      rd2_pkt1[62:0]      = rd1_out_data[62:0];
    
    bit  [10:0] rd2_total_dwlen;
    wire [10:0] rd2_total_dwlen_next = rd2_total_dwlen - 11'h20;
    
    bit  [85:0] rd2_pkt2;
    wire [10:0] rd2_pkt2_dwlen = rd2_pkt2[73:63];
    wire        rd2_pkt2_large = (rd2_total_dwlen > 11'h20);
    
    wire        rd2_out_rden;
    
    `define S2_ENGINE_REQDATA     1'h0
    `define S2_ENGINE_PROCESSING  1'h1
    (* KEEP = "TRUE" *) bit [0:0] state2 = `S2_ENGINE_REQDATA;
    
    always @ ( posedge clk )
        if ( rst ) begin
            state2 <= `S2_ENGINE_REQDATA;
        end
        else case ( state2 )
            `S2_ENGINE_REQDATA: begin
                if ( rd1_out_valid && rd2_pkt1_large ) begin
                    rd2_total_dwlen <= rd2_pkt1_dwlen_next;
                    rd2_pkt2[85:74] <= rd2_pkt1_dwlen_next << 2;
                    rd2_pkt2[73:63] <= (rd2_pkt1_dwlen_next > 11'h20) ? 11'h20 : rd2_pkt1_dwlen_next;
                    rd2_pkt2[62:12] <= rd1_out_data[62:12];
                    rd2_pkt2[11:0]  <= rd1_out_data[11:0] + (rd2_pkt1_dwlen << 2);
                    state2 <= `S2_ENGINE_PROCESSING;
                end
            end
            `S2_ENGINE_PROCESSING: begin
                if ( rd2_out_rden ) begin
                    rd2_total_dwlen <= rd2_total_dwlen_next;
                    rd2_pkt2[85:74] <= rd2_total_dwlen_next << 2;
                    rd2_pkt2[73:63] <= (rd2_total_dwlen_next > 11'h20) ? 11'h20 : rd2_total_dwlen_next;
                    rd2_pkt2[62:12] <= rd2_pkt2[62:12];
                    rd2_pkt2[11:0]  <= rd2_pkt2[11:0] + (rd2_pkt2_dwlen << 2);
                    if ( !rd2_pkt2_large ) begin
                        state2 <= `S2_ENGINE_REQDATA;
                    end
                end
            end
        endcase
    
    assign rd1_out_rden = rd2_out_rden && (((state2 == `S2_ENGINE_REQDATA) && (!rd1_out_valid || rd2_pkt1_tiny)) || ((state2 == `S2_ENGINE_PROCESSING) && !rd2_pkt2_large));

    wire [85:0] rd2_in_data  = (state2 == `S2_ENGINE_REQDATA) ? rd2_pkt1 : rd2_pkt2;
    wire        rd2_in_valid = rd1_out_valid || ((state2 == `S2_ENGINE_PROCESSING) && rd2_out_rden);

    bit  [85:0] rd2_out_data;
    bit         rd2_out_valid;
    always @ ( posedge clk ) begin
        rd2_out_data    <= rd2_in_valid ? rd2_in_data : rd2_out_data;
        rd2_out_valid   <= rd2_in_valid && !rst;
    end

    // 3: PROCESS EACH READ REQUEST PER INDIVIDUAL 32-bit DWORDS:
    wire [4:0]  rd2_out_dwlen   = rd2_out_data[67:63];
    wire        rd2_out_last    = (rd2_out_dwlen == 1);
    wire [9:0]  rd2_out_dwaddr  = rd2_out_data[11:2];
    
    wire        rd3_enable;
    
    bit         rd3_process_valid;
    bit         rd3_process_first;
    bit         rd3_process_last;
    bit [4:0]   rd3_process_dwlen;
    bit [9:0]   rd3_process_dwaddr;
    bit [85:0]  rd3_process_data;
    wire        rd3_process_next_last = (rd3_process_dwlen == 2);
    wire        rd3_process_nextnext_last = (rd3_process_dwlen <= 3);
    
    assign rd_req_ctx   = { rd3_process_first, rd3_process_last, rd3_process_data };
    assign rd_req_bar   = rd3_process_data[62:56];
    assign rd_req_addr  = { rd3_process_data[31:12], rd3_process_dwaddr, 2'b00 };
    assign rd_req_valid = rd3_process_valid;
    
    `define S3_ENGINE_REQDATA     1'h0
    `define S3_ENGINE_PROCESSING  1'h1
    (* KEEP = "TRUE" *) bit [0:0] state3 = `S3_ENGINE_REQDATA;
    
    always @ ( posedge clk )
        if ( rst ) begin
            rd3_process_valid   <= 1'b0;
            state3              <= `S3_ENGINE_REQDATA;
        end
        else case ( state3 )
            `S3_ENGINE_REQDATA: begin
                if ( rd2_out_valid ) begin
                    rd3_process_valid       <= 1'b1;
                    rd3_process_first       <= 1'b1;
                    rd3_process_last        <= rd2_out_last;
                    rd3_process_dwlen       <= rd2_out_dwlen;
                    rd3_process_dwaddr      <= rd2_out_dwaddr;
                    rd3_process_data[85:0]  <= rd2_out_data[85:0];
                    if ( !rd2_out_last ) begin
                        state3 <= `S3_ENGINE_PROCESSING;
                    end
                end
                else begin
                    rd3_process_valid       <= 1'b0;
                end
            end
            `S3_ENGINE_PROCESSING: begin
                rd3_process_first           <= 1'b0;
                rd3_process_last            <= rd3_process_next_last;
                rd3_process_dwlen           <= rd3_process_dwlen - 1;
                rd3_process_dwaddr          <= rd3_process_dwaddr + 1;
                if ( rd3_process_next_last ) begin
                    state3 <= `S3_ENGINE_REQDATA;
                end
            end
        endcase

    assign rd2_out_rden = rd3_enable && (
        ((state3 == `S3_ENGINE_REQDATA) && (!rd2_out_valid || rd2_out_last)) ||
        ((state3 == `S3_ENGINE_PROCESSING) && rd3_process_nextnext_last));
    
    // 4: PROCESS RESPONSES:
    wire        rd_rsp_first    = rd_rsp_ctx[87];
    wire        rd_rsp_last     = rd_rsp_ctx[86];
    
    wire [9:0]  rd_rsp_dwlen    = rd_rsp_ctx[72:63];
    wire [11:0] rd_rsp_bc       = rd_rsp_ctx[85:74];
    wire [15:0] rd_rsp_reqid    = rd_rsp_ctx[47:32];
    wire [7:0]  rd_rsp_tag      = rd_rsp_ctx[55:48];
    wire [6:0]  rd_rsp_lowaddr  = rd_rsp_ctx[6:0];
    wire [31:0] rd_rsp_addr     = rd_rsp_ctx[31:0];
    wire [31:0] rd_rsp_data_bs  = { rd_rsp_data[7:0], rd_rsp_data[15:8], rd_rsp_data[23:16], rd_rsp_data[31:24] };
    
    bit [127:0] tdata;
    bit [3:0]   tkeepdw = 0;
    bit         tlast;
    bit         first   = 1;
    wire        tvalid  = tlast || tkeepdw[3];
    
    always @ ( posedge clk )
        if ( rst ) begin
            tkeepdw <= 0;
            tlast   <= 0;
            first   <= 0;
        end
        else if ( rd_rsp_valid && rd_rsp_first ) begin
            tkeepdw         <= 4'b1111;
            tlast           <= rd_rsp_last;
            first           <= 1'b1;
            tdata[31:0]     <= { 22'b0100101000000000000000, rd_rsp_dwlen };
            tdata[63:32]    <= { pcie_id[7:0], pcie_id[15:8], 4'b0, rd_rsp_bc };
            tdata[95:64]    <= { rd_rsp_reqid, rd_rsp_tag, 1'b0, rd_rsp_lowaddr };
            tdata[127:96]   <= rd_rsp_data_bs;
        end
        else begin
            tlast   <= rd_rsp_valid && rd_rsp_last;
            tkeepdw <= tvalid ? (rd_rsp_valid ? 4'b0001 : 4'b0000) : (rd_rsp_valid ? ((tkeepdw << 1) | 1'b1) : tkeepdw);
            first   <= 0;
            if ( rd_rsp_valid ) begin
                if ( tvalid || !tkeepdw[0] )
                    tdata[31:0]   <= rd_rsp_data_bs;
                if ( !tkeepdw[1] )
                    tdata[63:32]  <= rd_rsp_data_bs;
                if ( !tkeepdw[2] )
                    tdata[95:64]  <= rd_rsp_data_bs;
                if ( !tkeepdw[3] )
                    tdata[127:96] <= rd_rsp_data_bs;   
            end
        end
    
    fifo_134_134_clk1_bar_rdrsp i_fifo_134_134_clk1_bar_rdrsp(
        .srst           ( rst                       ),
        .clk            ( clk                       ),
        .din            ( { first, tlast, tkeepdw, tdata } ),
        .wr_en          ( tvalid                    ),
        .rd_en          ( tlps_out.tready           ),
        .dout           ( { tlps_out.tuser[0], tlps_out.tlast, tlps_out.tkeepdw, tlps_out.tdata } ),
        .full           (                           ),
        .empty          (                           ),
        .prog_empty     ( rd3_enable                ),
        .valid          ( tlps_out.tvalid           )
    );
    
    assign tlps_out.tuser[1] = tlps_out.tlast;
    assign tlps_out.tuser[8:2] = 0;
    
    bit [10:0]  pkt_count       = 0;
    wire        pkt_count_dec   = tlps_out.tvalid && tlps_out.tlast;
    wire        pkt_count_inc   = tvalid && tlast;
    wire [10:0] pkt_count_next  = pkt_count + pkt_count_inc - pkt_count_dec;
    assign tlps_out.has_data    = (pkt_count_next > 0);
    
    always @ ( posedge clk ) begin
        pkt_count <= rst ? 0 : pkt_count_next;
    end

endmodule


// ============================================================================
// pcileech_bar_impl_none — empty BAR placeholder
// ============================================================================
module pcileech_bar_impl_none(
    input               rst,
    input               clk,
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);
    initial rd_rsp_ctx = 0;
    initial rd_rsp_data = 0;
    initial rd_rsp_valid = 0;
endmodule


// ============================================================================
// pcileech_bar_impl_CMI8738_null — NULL ENDPOINT AUDIO
// ============================================================================
//
// The driver programs DMA buffers and enables channels exactly as on real
// hardware. This module:
//   - Accepts all register writes (FRAME1, FRAME2, FUNCTRL0, etc.)
//   - Counts position down at the programmed sample rate
//   - Fires period interrupts (CHINT0/CHINT1) at the correct times
//   - Reports CH0BUSY/CH1BUSY and CM_INTR in INT_STATUS
//   - Generates ZERO PCIe TLPs (mem_rd and mem_wr fully tied off)
//
// From the driver's perspective the DMA is running perfectly.
// Audio samples are "consumed" but discarded — null endpoint.
//
// PCIe overhead: exactly zero. PCILeech performance: unaffected.
// ============================================================================
module pcileech_bar_impl_CMI8738_null(
    input                rst,
    input                clk,
    input  [31:0]        wr_addr,
    input  [3:0]         wr_be,
    input  [31:0]        wr_data,
    input                wr_valid,
    input  [87:0]        rd_req_ctx,
    input  [31:0]        rd_req_addr,
    input                rd_req_valid,
    input  [31:0]        base_address_register,
    IfMemoryWrite.source mem_wr_out,
    IfMemoryRead.source  mem_rd_out,
    output wire          intx_line,
    output reg [87:0]    rd_rsp_ctx,
    output reg [31:0]    rd_rsp_data,
    output reg           rd_rsp_valid,
    output wire          led_dma_debug,
    // Step 4: expose DMA channel state for fake_dma_gen
    output wire          fake_ch0_running,
    output wire [31:0]   fake_ch0_dma_base,
    output wire [15:0]   fake_ch0_dma_size,
    output wire          fake_ch1_running,
    output wire [31:0]   fake_ch1_dma_base,
    output wire [15:0]   fake_ch1_dma_size,
    // Step 4 SAFETY: driver-programmed flags + global enable
    output wire          fake_ch0_frame1_written,
    output wire          fake_ch1_frame1_written,
    output wire          fake_dma_enable
);

    // =====================================================================
    // TIE OFF DMA — no bus mastering, no TLPs, zero PCIe overhead
    // =====================================================================
    assign mem_rd_out.address     = '0;
    assign mem_rd_out.data_length = '0;
    assign mem_rd_out.has_request = 1'b0;
    assign mem_rd_out.rd_en       = 1'b0;
    assign mem_wr_out.address     = '0;
    assign mem_wr_out.data_length = '0;
    assign mem_wr_out.has_data    = 1'b0;
    assign mem_wr_out.din         = '0;
    assign mem_wr_out.wr_en       = 1'b0;
    assign mem_wr_out.wr_done     = 1'b0;

    // =====================================================================
    // SAMPLE RATE PRESCALER — 62.5 MHz / rate
    // =====================================================================
    function [15:0] rate_div; input [2:0] c;
        case(c)
            3'd0: rate_div = 16'd11338;   // 5512 Hz
            3'd1: rate_div = 16'd5669;    // 11025 Hz
            3'd2: rate_div = 16'd2834;    // 22050 Hz
            3'd3: rate_div = 16'd1417;    // 44100 Hz
            3'd4: rate_div = 16'd7812;    // 8000 Hz
            3'd5: rate_div = 16'd3906;    // 16000 Hz
            3'd6: rate_div = 16'd1953;    // 32000 Hz
            3'd7: rate_div = 16'd1302;    // 48000 Hz
        endcase
    endfunction

    // =====================================================================
    // CMI8738 REGISTER FILE
    // =====================================================================
    reg [31:0] reg_functrl0;        // 0x00
    reg [31:0] reg_functrl1;        // 0x04
    reg [31:0] reg_chformat;        // 0x08
    reg [31:0] reg_int_hldclr;      // 0x0C
    reg [31:0] reg_int_status;      // 0x10
    reg [31:0] reg_legacy_ctrl;     // 0x14
    reg [31:0] reg_misc_ctrl;       // 0x18
    reg [31:0] reg_tdma_pos;        // 0x1C
    reg [7:0]  reg_mixer0;          // 0x20
    reg [7:0]  reg_mixer21;         // 0x21
    reg [7:0]  reg_sb16_data;       // 0x22
    reg [7:0]  reg_sb16_addr;       // 0x23
    reg [7:0]  reg_mixer1;          // 0x24
    reg [7:0]  reg_mixer2;          // 0x25
    reg [7:0]  reg_aux_vol;         // 0x26
    reg [7:0]  reg_misc;            // 0x27
    reg [31:0] reg_ac97;            // 0x28
    reg [31:0] reg_mpu_pci;         // 0x40
    reg [31:0] reg_fm_pci;          // 0x50
    reg [31:0] reg_ch0_frame1;      // 0x80
    reg [31:0] reg_ch1_frame1;      // 0x88
    reg [15:0] ch0_buf_size;        // FRAME2[15:0]
    reg [15:0] ch0_period_size;     // FRAME2[31:16]
    reg [15:0] ch1_buf_size;
    reg [15:0] ch1_period_size;
    reg [31:0] reg_ext_misc;        // 0x90
    reg [31:0] reg_scratch_d0;      // 0xD0 — Step 4 SAFETY: fake DMA global enable
    reg [7:0]  reg_extent_ind;      // 0xF0
    reg [31:0] reg_pll;             // 0xF8

    // =====================================================================
    // STEP 4 SAFETY — Driver-must-program-FRAME1 flags
    // Reset defaults for reg_chX_frame1 come from a chip dump (0x0A2X0000)
    // which are VALID-looking addresses but garbage. Without this flag, the
    // fake DMA gen would fire MRd to those addresses as soon as CHENx=1,
    // causing WHEA AER faults -> BSOD. These flags gate the fake DMA until
    // the driver explicitly writes FRAME1 at least once post-reset.
    // =====================================================================
    reg        ch0_frame1_written;
    reg        ch1_frame1_written;
    reg        ch0_running_prev;
    reg        ch1_running_prev;

    // SB16 mixer RAM
    reg [7:0]  sb16_mixer [0:255];

    // =====================================================================
    // POSITION ENGINE — per channel countdown + period interrupt
    // =====================================================================
    reg [15:0] ch0_pos, ch0_period_cnt, ch0_prescaler;
    reg [15:0] ch1_pos, ch1_period_cnt, ch1_prescaler;

    // =====================================================================
    // STABILITY FIX — Fallback periodic INTx generator (CH0 playback)
    // Fires INT_STATUS[0] every ~46 ms (2048 samples @ 44.1 kHz semi-period)
    // regardless of sample-rate / period_size programming, preventing
    // driver hang when DMA bus-mastering is not yet implemented.
    // 62.5 MHz clk × 46.44 ms ≈ 2,902,494 cycles → 23-bit counter.
    // =====================================================================
    localparam [22:0] INTX_FALLBACK_PERIOD = 23'd2_902_494;
    reg [22:0] intx_fallback_cnt;

    // =====================================================================
    // DMA POINTER ANIMATION — emulates live FRAME1/FRAME2 movement
    // ch*_dma_pos    : sample-byte pointer, +4 per sample @ 44.1 kHz
    // ch*_period_sim : high counter, advances by CH_PERIOD_SIM_DELTA on wrap
    // Both are readback-only; driver writes reset them (spec behavior).
    // =====================================================================
    localparam [15:0] CH_PERIOD_SIM_DELTA = 16'h1000;  // ~1/4 of 16KB buffer
    reg [15:0] ch0_dma_pos, ch0_period_sim;
    reg [15:0] ch1_dma_pos, ch1_period_sim;

    // =====================================================================
    // LFSR (offset 0x1C / reg_tdma_pos) — 32-bit maximal-length Fibonacci
    // Taps: 32, 22, 2, 1 (1-indexed). Free-running independent of CHEN0/1.
    // =====================================================================
    wire lfsr_tdma_fb = reg_tdma_pos[31] ^ reg_tdma_pos[21]
                      ^ reg_tdma_pos[ 1] ^ reg_tdma_pos[ 0];

    wire ch0_running = reg_functrl0[16] & ~reg_functrl0[2];  // CHEN0 & !PAUSE0
    wire ch1_running = reg_functrl0[17] & ~reg_functrl0[3];  // CHEN1 & !PAUSE1

    wire [2:0] ch0_rate = reg_functrl1[12:10];  // ASFC
    wire [2:0] ch1_rate = reg_functrl1[15:13];  // DSFC

    // =====================================================================
    // INTERRUPT LOGIC
    // =====================================================================
    wire int_ch0 = reg_int_hldclr[16] & reg_int_status[0];
    wire int_ch1 = reg_int_hldclr[17] & reg_int_status[1];
    assign intx_line = int_ch0 | int_ch1;

    // Heartbeat
    reg [21:0] heartbeat_cnt;

    // LED — blink when DMA running
    reg [23:0] led_timer;
    assign led_dma_debug = (led_timer != 0);

    // =====================================================================
    // PIPELINE
    // =====================================================================
    reg [87:0]  drd_req_ctx;
    reg [31:0]  drd_req_addr;
    reg         drd_req_valid;
    reg [31:0]  dwr_addr, dwr_data;
    reg [3:0]   dwr_be;
    reg         dwr_valid;
    reg [7:0]   prd_offset, pwr_offset;

    wire [31:0] bar_base = base_address_register & 32'hFFFFFF00;

    integer idx;

    // =====================================================================
    // MAIN LOGIC
    // =====================================================================
    always @(posedge clk) begin
        if (rst) begin
            drd_req_ctx<=0; drd_req_addr<=0; drd_req_valid<=0;
            dwr_addr<=0; dwr_data<=0; dwr_be<=0; dwr_valid<=0;
            prd_offset<=0; pwr_offset<=0;
            rd_rsp_ctx<=0; rd_rsp_data<=0; rd_rsp_valid<=0;

            // CMI8738 defaults from REAL hardware dump (Linux 2a:00.0, post-BIOS pre-driver)
            reg_functrl0    <= 32'h00000000;
            reg_functrl1    <= 32'h00000000;
            reg_chformat    <= 32'h0102000F;  // dump: was 0x00200000
            reg_int_hldclr  <= 32'h00000000;  // dump: was 0x00010000
            reg_int_status  <= 32'h00000040;
            reg_legacy_ctrl <= 32'h000000C0;  // dump: was 0x00000000
            reg_misc_ctrl   <= 32'h0D808000;  // dump @ 0x18: was 0x00000000
            reg_tdma_pos    <= 32'hFFFFBFFF;  // dump @ 0x1C: was 0xFEBFBFFF (LFSR seed phase2)
            // 0x20 bank (mixer0/21/sb16_data/sb16_addr) = 0xFFFFFFFF from dump
            reg_mixer0<=8'hFF; reg_mixer21<=8'hFF;
            reg_sb16_data<=8'hFF; reg_sb16_addr<=8'hFF;
            // 0x24 bank (mixer1/mixer2/aux_vol/misc) = 0xFFFFFFFF from dump
            reg_mixer1<=8'hFF; reg_mixer2<=8'hFF;
            reg_aux_vol<=8'hFF; reg_misc<=8'hFF;
            reg_ac97<=0;
            // 0x40-0x6C bank = 0xFFFFFFFF from dump
            reg_mpu_pci<=32'hFFFFFFFF; reg_fm_pci<=32'hFFFFFFFF;
            // CH0/CH1 FRAME1 = 0x0A22/0x0A23 0000 (chip default buffer pointers from dump)
            reg_ch0_frame1<=32'h0A220000;
            reg_ch1_frame1<=32'h0A230000;
            // FRAME2 = 0x00003FFF (buf_size=0x3FFF=16KB-1, period_size=0)
            ch0_buf_size<=16'h3FFF; ch0_period_size<=16'h0000;
            ch1_buf_size<=16'h3FFF; ch1_period_size<=16'h0000;
            reg_ext_misc<=0; reg_extent_ind<=0; reg_pll<=0;
            // Step 4 safety: fake DMA disarmed until driver programs FRAME1.
            // Global enable (scratch D0 bit 0) defaults to 0 = fake DMA OFF
            // out-of-box. Real hardware deployments saw ~11k PCIe Correctable
            // Errors/h on host root port AER (WHEA-Logger ID 17, Hdr Log
            // Overflow / Corrected Internal) attributed to completions of
            // the fake MRd traffic not being explicitly drained by
            // host_mem_read_2 (which checks request_id range 0x00-0xFB while
            // fake DMA uses tags 0xFC-0xFF → completions flow through tlps_rx
            // without explicit consumer). The errors are correctable, not
            // fatal, but the kernel WHEA logging path was lagging the host
            // OS post-login. Host can write 1 to BAR0+0xD0 to re-enable.
            ch0_frame1_written <= 1'b0;
            ch1_frame1_written <= 1'b0;
            ch0_running_prev   <= 1'b0;
            ch1_running_prev   <= 1'b0;
            reg_scratch_d0     <= 32'h00000000;

            ch0_pos<=16'h3FFF; ch0_period_cnt<=16'h0000; ch0_prescaler<=0;
            ch1_pos<=16'h3FFF; ch1_period_cnt<=16'h0000; ch1_prescaler<=0;
            ch0_dma_pos<=16'h0000; ch0_period_sim<=16'h3FFF;
            ch1_dma_pos<=16'h0000; ch1_period_sim<=16'h3FFF;
            intx_fallback_cnt<=INTX_FALLBACK_PERIOD;
            heartbeat_cnt<=0; led_timer<=0;

            for (idx=0; idx<256; idx=idx+1) sb16_mixer[idx]<=0;
            sb16_mixer[8'h30]<=8'hF8; sb16_mixer[8'h31]<=8'hF8;
            sb16_mixer[8'h32]<=8'hF8; sb16_mixer[8'h33]<=8'hF8;

        end else begin

            // =============================================================
            // POSITION ENGINE — CH0 (playback)
            // Prescaler counts down from rate_div to 0.
            // On each sample tick: pos counts down, wraps at 0→buf_size.
            // On period boundary: CHINT0 fires.
            // =============================================================
            if (ch0_running) begin
                if (ch0_prescaler == 0) begin
                    ch0_prescaler <= rate_div(ch0_rate);
                    ch0_pos <= (ch0_pos == 0) ? ch0_buf_size : ch0_pos - 1;
                    if (ch0_period_cnt == 0) begin
                        ch0_period_cnt <= ch0_period_size;
                        reg_int_status[0] <= 1'b1;  // CHINT0
                    end else
                        ch0_period_cnt <= ch0_period_cnt - 1;
                    // DMA pointer: +4 bytes per sample (stereo 16-bit);
                    // on wrap, bump the period-sim high counter.
                    if (ch0_dma_pos + 16'd4 >= ch0_buf_size) begin
                        ch0_dma_pos    <= 16'd0;
                        ch0_period_sim <= ch0_period_sim + CH_PERIOD_SIM_DELTA;
                    end else begin
                        ch0_dma_pos <= ch0_dma_pos + 16'd4;
                    end
                end else
                    ch0_prescaler <= ch0_prescaler - 1;
            end

            // POSITION ENGINE — CH1 (capture / second DAC)
            if (ch1_running) begin
                if (ch1_prescaler == 0) begin
                    ch1_prescaler <= rate_div(ch1_rate);
                    ch1_pos <= (ch1_pos == 0) ? ch1_buf_size : ch1_pos - 1;
                    if (ch1_period_cnt == 0) begin
                        ch1_period_cnt <= ch1_period_size;
                        reg_int_status[1] <= 1'b1;  // CHINT1
                    end else
                        ch1_period_cnt <= ch1_period_cnt - 1;
                    // DMA pointer CH1 — identical logic to CH0
                    if (ch1_dma_pos + 16'd4 >= ch1_buf_size) begin
                        ch1_dma_pos    <= 16'd0;
                        ch1_period_sim <= ch1_period_sim + CH_PERIOD_SIM_DELTA;
                    end else begin
                        ch1_dma_pos <= ch1_dma_pos + 16'd4;
                    end
                end else
                    ch1_prescaler <= ch1_prescaler - 1;
            end

            // =============================================================
            // LFSR shift — free-running reg_tdma_pos @ 0x1C
            // Placed before write path so driver write wins when reseeding.
            // =============================================================
            reg_tdma_pos <= {reg_tdma_pos[30:0], lfsr_tdma_fb};

            // =============================================================
            // STABILITY FIX — Fallback periodic INTx for CH0
            // While CHEN0 (FUNCTRL0[16]) = 1, fire CH0 period-done interrupt
            // every ~46 ms. When interrupt is pending (INT_STATUS[0]=1), hold
            // counter loaded until the driver W1C-clears it via INT_HLDCLR[0]
            // (handled in the write path below). When CHEN0=0, disarm.
            // =============================================================
            if (reg_functrl0[16]) begin
                if (reg_int_status[0]) begin
                    // Int pending — wait for driver ack (W1C clears status[0])
                    intx_fallback_cnt <= INTX_FALLBACK_PERIOD;
                end else if (intx_fallback_cnt == 23'd0) begin
                    // 46 ms elapsed — raise INTx (write path is after this,
                    // so a concurrent W1C ack in the same cycle still wins)
                    reg_int_status[0] <= 1'b1;
                    intx_fallback_cnt <= INTX_FALLBACK_PERIOD;
                end else begin
                    intx_fallback_cnt <= intx_fallback_cnt - 1'b1;
                end
            end else begin
                intx_fallback_cnt <= INTX_FALLBACK_PERIOD;
            end

            // INT_STATUS dynamic bits
            reg_int_status[2]  <= ch0_running;      // CH0BUSY
            reg_int_status[3]  <= ch1_running;      // CH1BUSY
            reg_int_status[31] <= int_ch0 | int_ch1; // CM_INTR

            // Heartbeat toggle (~15 Hz)
            heartbeat_cnt <= heartbeat_cnt + 1;
            if (heartbeat_cnt == 0) reg_int_status[6] <= ~reg_int_status[6];

            // LED
            if (ch0_running || ch1_running) led_timer <= 24'hFFFFFF;
            else if (led_timer != 0) led_timer <= led_timer - 1;

            // =============================================================
            // PIPELINE
            // =============================================================
            drd_req_ctx<=rd_req_ctx; drd_req_addr<=rd_req_addr;
            drd_req_valid<=rd_req_valid;
            prd_offset<=(rd_req_addr - bar_base) & 8'hFC;
            dwr_addr<=wr_addr; dwr_data<=wr_data; dwr_be<=wr_be;
            dwr_valid<=wr_valid;
            pwr_offset<=(wr_addr - bar_base) & 8'hFC;
            rd_rsp_ctx<=drd_req_ctx; rd_rsp_valid<=drd_req_valid;

            // =============================================================
            // READ PATH
            // =============================================================
            if (drd_req_valid) begin
                case (prd_offset)
                    8'h00: rd_rsp_data <= reg_functrl0;
                    8'h04: rd_rsp_data <= reg_functrl1;
                    8'h08: rd_rsp_data <= reg_chformat;
                    8'h0C: rd_rsp_data <= reg_int_hldclr;
                    8'h10: rd_rsp_data <= reg_int_status;
                    8'h14: rd_rsp_data <= reg_legacy_ctrl;
                    8'h18: rd_rsp_data <= reg_misc_ctrl;
                    8'h1C: rd_rsp_data <= reg_tdma_pos;
                    // SB16 mixer indexed read: byte 2 returns sb16_mixer[reg_sb16_addr],
                    // not last-written reg_sb16_data. This is the spec-correct behavior
                    // for the SB16 indexed mixer protocol (write index@0x23, read value@0x22).
                    8'h20: rd_rsp_data <= {reg_sb16_addr, sb16_mixer[reg_sb16_addr], reg_mixer21, reg_mixer0};
                    8'h24: rd_rsp_data <= {reg_misc, reg_aux_vol, reg_mixer2, reg_mixer1};
                    8'h28: rd_rsp_data <= reg_ac97;
                    8'h30: rd_rsp_data <= 32'hFFFFFFFF;  // dump: was 0xFF3FFBED
                    // 0x40-0x6C bank: all 0xFFFFFFFF per dump (idle state)
                    8'h40: rd_rsp_data <= reg_mpu_pci;
                    8'h44: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h48: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h4C: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h50: rd_rsp_data <= reg_fm_pci;
                    8'h54: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h58: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h5C: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h60: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h64: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h68: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h6C: rd_rsp_data <= 32'hFFFFFFFF;
                    8'h7C: rd_rsp_data <= 32'h01000000;
                    8'h80: rd_rsp_data <= {reg_ch0_frame1[31:16], ch0_dma_pos};
                    8'h84: rd_rsp_data <= {ch0_period_sim, ch0_dma_pos};
                    8'h88: rd_rsp_data <= {reg_ch1_frame1[31:16], ch1_dma_pos};
                    8'h8C: rd_rsp_data <= {ch1_period_sim, ch1_dma_pos};
                    8'h90: rd_rsp_data <= reg_ext_misc;
                    8'hD0: rd_rsp_data <= reg_scratch_d0;    // Step 4 safety scratch
                    8'hF0: rd_rsp_data <= {24'd0, reg_extent_ind};
                    8'hF8: rd_rsp_data <= reg_pll;
                    default: rd_rsp_data <= 32'h00000000;
                endcase
            end

            // =============================================================
            // WRITE PATH
            // =============================================================
            if (dwr_valid) begin
                case (pwr_offset)

                    8'h00: begin // FUNCTRL0 — channel enable/reset/pause
                        if (dwr_be[0]) reg_functrl0[7:0]  <= dwr_data[7:0];
                        if (dwr_be[1]) reg_functrl0[15:8] <= dwr_data[15:8];
                        if (dwr_be[2]) begin
                            reg_functrl0[23:16] <= dwr_data[23:16];
                            // CH0 enable rising edge → reload counters
                            if (dwr_data[16] && !reg_functrl0[16]) begin
                                ch0_pos        <= ch0_buf_size;
                                ch0_period_cnt <= ch0_period_size;
                                ch0_prescaler  <= rate_div(ch0_rate);
                                intx_fallback_cnt <= INTX_FALLBACK_PERIOD;
                                // Stability-fix: ensure HLDCLR mask bit is set
                                // so fallback INTx actually reaches the wire
                                reg_int_hldclr[16] <= 1'b1;
                            end
                            // CH1 enable rising edge
                            if (dwr_data[17] && !reg_functrl0[17]) begin
                                ch1_pos        <= ch1_buf_size;
                                ch1_period_cnt <= ch1_period_size;
                                ch1_prescaler  <= rate_div(ch1_rate);
                            end
                            // RST_CH0 — self-clearing
                            if (dwr_data[18]) begin
                                reg_functrl0[18] <= 0;
                                reg_functrl0[16] <= 0;
                                ch0_pos <= ch0_buf_size;
                                ch0_period_cnt <= ch0_period_size;
                                ch0_prescaler <= 0;
                                reg_int_status[0] <= 0;
                                ch0_dma_pos    <= 16'd0;
                                ch0_period_sim <= 16'h3FFF;
                            end
                            // RST_CH1 — self-clearing
                            if (dwr_data[19]) begin
                                reg_functrl0[19] <= 0;
                                reg_functrl0[17] <= 0;
                                ch1_pos <= ch1_buf_size;
                                ch1_period_cnt <= ch1_period_size;
                                ch1_prescaler <= 0;
                                reg_int_status[1] <= 0;
                                ch1_dma_pos    <= 16'd0;
                                ch1_period_sim <= 16'h3FFF;
                            end
                        end
                        if (dwr_be[3]) reg_functrl0[31:24] <= dwr_data[31:24];
                    end

                    8'h04: begin // FUNCTRL1 — sample rate, features
                        if (dwr_be[0]) reg_functrl1[7:0]   <= dwr_data[7:0];
                        if (dwr_be[1]) reg_functrl1[15:8]  <= dwr_data[15:8];
                        if (dwr_be[2]) reg_functrl1[23:16] <= dwr_data[23:16];
                        if (dwr_be[3]) reg_functrl1[31:24] <= dwr_data[31:24];
                    end

                    8'h08: begin // CHFORMAT — chip mask[28:24] read-only
                        if (dwr_be[0]) reg_chformat[7:0]   <= dwr_data[7:0];
                        if (dwr_be[1]) reg_chformat[15:8]  <= dwr_data[15:8];
                        if (dwr_be[2]) reg_chformat[23:16] <= dwr_data[23:16];
                        if (dwr_be[3]) reg_chformat[31:24] <= (dwr_data[31:24] & 8'hE0) | (reg_chformat[31:24] & 8'h1F);
                    end

                    8'h0C: begin // INT_HLDCLR — W1C interrupt clear + HLDCLR mask
                        // Path 1: explicit W1C via bit 0/1 of byte 0 (CHIRQ0/1_CLR)
                        if (dwr_be[0]) begin
                            if (dwr_data[0]) reg_int_status[0] <= 0;
                            if (dwr_data[1]) reg_int_status[1] <= 0;
                        end
                        // Path 2: snd_cmipci driver IRQ-ack convention.
                        // Driver does clear_bit(HLDCLR_CHx) then set_bit(HLDCLR_CHx).
                        // Real chip clears INT_STATUS on HLDCLR_CHx falling edge,
                        // otherwise the re-enable in step 5 would fire intx_line
                        // again on the SAME stale status bit → IRQ storm / driver
                        // infinite loop. Detect 1→0 edge here and auto-ack.
                        if (dwr_be[2]) begin
                            if (reg_int_hldclr[16] && !dwr_data[16]) reg_int_status[0] <= 1'b0;
                            if (reg_int_hldclr[17] && !dwr_data[17]) reg_int_status[1] <= 1'b0;
                            reg_int_hldclr[23:16] <= dwr_data[23:16];
                        end
                    end

                    8'h14: begin if(dwr_be[0])reg_legacy_ctrl[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_legacy_ctrl[15:8]<=dwr_data[15:8]; if(dwr_be[2])reg_legacy_ctrl[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_legacy_ctrl[31:24]<=dwr_data[31:24]; end

                    8'h18: begin // MISC_CTRL — CM_RESET
                        if (dwr_be[0]) reg_misc_ctrl[7:0]   <= dwr_data[7:0];
                        if (dwr_be[1]) reg_misc_ctrl[15:8]  <= dwr_data[15:8];
                        if (dwr_be[2]) reg_misc_ctrl[23:16] <= dwr_data[23:16];
                        if (dwr_be[3]) begin
                            reg_misc_ctrl[31:24] <= dwr_data[31:24];
                            if (dwr_data[30]) begin // soft reset
                                reg_functrl0 <= 0; reg_functrl1 <= 0;
                                reg_int_status <= 32'h00000040;
                                ch0_pos<=16'hFFFF; ch0_period_cnt<=16'hFFFF; ch0_prescaler<=0;
                                ch1_pos<=16'hFFFF; ch1_period_cnt<=16'hFFFF; ch1_prescaler<=0;
                                ch0_dma_pos<=16'd0; ch0_period_sim<=16'h3FFF;
                                ch1_dma_pos<=16'd0; ch1_period_sim<=16'h3FFF;
                            end
                        end
                    end

                    8'h1C: begin if(dwr_be[0])reg_tdma_pos[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_tdma_pos[15:8]<=dwr_data[15:8]; end

                    8'h20: begin // Mixer byte regs
                        if (dwr_be[0]) reg_mixer0    <= dwr_data[7:0];
                        if (dwr_be[1]) reg_mixer21   <= dwr_data[15:8];
                        if (dwr_be[2]) begin reg_sb16_data <= dwr_data[23:16]; sb16_mixer[reg_sb16_addr] <= dwr_data[23:16]; end
                        if (dwr_be[3]) reg_sb16_addr <= dwr_data[31:24];
                    end

                    8'h24: begin
                        if (dwr_be[0]) reg_mixer1  <= dwr_data[7:0];
                        if (dwr_be[1]) reg_mixer2  <= dwr_data[15:8];
                        if (dwr_be[2]) reg_aux_vol <= dwr_data[23:16];
                        if (dwr_be[3]) reg_misc    <= dwr_data[31:24];
                    end

                    8'h28: begin if(dwr_be[0])reg_ac97[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_ac97[15:8]<=dwr_data[15:8]; if(dwr_be[2])reg_ac97[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_ac97[31:24]<=dwr_data[31:24]; end
                    8'h40: begin if(dwr_be[0])reg_mpu_pci[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_mpu_pci[15:8]<=dwr_data[15:8]; if(dwr_be[2])reg_mpu_pci[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_mpu_pci[31:24]<=dwr_data[31:24]; end
                    8'h50: begin if(dwr_be[0])reg_fm_pci[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_fm_pci[15:8]<=dwr_data[15:8]; if(dwr_be[2])reg_fm_pci[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_fm_pci[31:24]<=dwr_data[31:24]; end

                    8'h80: begin // CH0_FRAME1 — DMA base address; spec: reset ch0_dma_pos on write
                        if(dwr_be[0])reg_ch0_frame1[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_ch0_frame1[15:8]<=dwr_data[15:8];
                        if(dwr_be[2])reg_ch0_frame1[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_ch0_frame1[31:24]<=dwr_data[31:24];
                        ch0_dma_pos <= 16'd0;
                        ch0_frame1_written <= 1'b1;     // Step 4 safety: arm fake DMA
                    end

                    8'h84: begin // CH0_FRAME2 — spec: only buf_size[13:0] writable; reset anim counters
                        if(dwr_be[0]) ch0_buf_size[7:0]    <= dwr_data[7:0];
                        if(dwr_be[1]) ch0_buf_size[13:8]   <= dwr_data[13:8];
                        if(dwr_be[2]) ch0_period_size[7:0] <= dwr_data[23:16];
                        if(dwr_be[3]) ch0_period_size[15:8]<= dwr_data[31:24];
                        ch0_pos        <= {dwr_data[15:8], dwr_data[7:0]};
                        ch0_period_cnt <= {dwr_data[31:24], dwr_data[23:16]};
                        // Reset animation counters per task 2 spec
                        ch0_dma_pos    <= 16'd0;
                        ch0_period_sim <= 16'h3FFF;
                    end

                    8'h88: begin // CH1_FRAME1
                        if(dwr_be[0])reg_ch1_frame1[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_ch1_frame1[15:8]<=dwr_data[15:8];
                        if(dwr_be[2])reg_ch1_frame1[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_ch1_frame1[31:24]<=dwr_data[31:24];
                        ch1_dma_pos <= 16'd0;
                        ch1_frame1_written <= 1'b1;     // Step 4 safety: arm fake DMA
                    end

                    8'h8C: begin // CH1_FRAME2
                        if(dwr_be[0]) ch1_buf_size[7:0]    <= dwr_data[7:0];
                        if(dwr_be[1]) ch1_buf_size[13:8]   <= dwr_data[13:8];
                        if(dwr_be[2]) ch1_period_size[7:0] <= dwr_data[23:16];
                        if(dwr_be[3]) ch1_period_size[15:8]<= dwr_data[31:24];
                        ch1_pos        <= {dwr_data[15:8], dwr_data[7:0]};
                        ch1_period_cnt <= {dwr_data[31:24], dwr_data[23:16]};
                        ch1_dma_pos    <= 16'd0;
                        ch1_period_sim <= 16'h3FFF;
                    end

                    8'h90: begin if(dwr_be[0])reg_ext_misc[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_ext_misc[15:8]<=dwr_data[15:8]; if(dwr_be[2])reg_ext_misc[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_ext_misc[31:24]<=dwr_data[31:24]; end
                    // Step 4 safety: runtime kill-switch for fake DMA (bit 0).
                    // Default 0x00000001 at reset = fake DMA enabled. Host app
                    // can write 0 here to globally disable fake MRd generation.
                    8'hD0: begin if(dwr_be[0])reg_scratch_d0[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_scratch_d0[15:8]<=dwr_data[15:8]; if(dwr_be[2])reg_scratch_d0[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_scratch_d0[31:24]<=dwr_data[31:24]; end
                    8'hF0: begin if(dwr_be[0]) reg_extent_ind <= dwr_data[7:0]; end
                    8'hF8: begin if(dwr_be[0])reg_pll[7:0]<=dwr_data[7:0]; if(dwr_be[1])reg_pll[15:8]<=dwr_data[15:8]; if(dwr_be[2])reg_pll[23:16]<=dwr_data[23:16]; if(dwr_be[3])reg_pll[31:24]<=dwr_data[31:24]; end

                    default: ;
                endcase
            end

            // =============================================================
            // STEP 4 SAFETY — auto-disarm fake DMA on CHENx falling edge.
            // If driver stops the channel, require it to re-program FRAME1
            // before the fake DMA can arm again. Placed AFTER write path so
            // a simultaneous FRAME1-write + channel-stop resolves to DISARMED
            // (safer default).
            // =============================================================
            ch0_running_prev <= ch0_running;
            ch1_running_prev <= ch1_running;
            if (ch0_running_prev && !ch0_running) ch0_frame1_written <= 1'b0;
            if (ch1_running_prev && !ch1_running) ch1_frame1_written <= 1'b0;

        end // !rst
    end // always

    // =========================================================================
    // Step 4: export DMA channel state for fake_dma_gen (bus-master emulation).
    // ch0_running / ch1_running are already defined at lines ~686-687 as:
    //   ch0_running = reg_functrl0[16] & ~reg_functrl0[2];  // CHEN0 & !PAUSE0
    //   ch1_running = reg_functrl0[17] & ~reg_functrl0[3];  // CHEN1 & !PAUSE1
    // reg_chX_frame1 = DMA buffer base address written by driver.
    // chX_buf_size   = buffer size in bytes (bytes count, DW-aligned expected).
    // =========================================================================
    assign fake_ch0_running  = ch0_running;
    assign fake_ch0_dma_base = reg_ch0_frame1;
    assign fake_ch0_dma_size = ch0_buf_size;
    assign fake_ch1_running  = ch1_running;
    assign fake_ch1_dma_base = reg_ch1_frame1;
    assign fake_ch1_dma_size = ch1_buf_size;
    // Step 4 SAFETY exports
    assign fake_ch0_frame1_written = ch0_frame1_written;
    assign fake_ch1_frame1_written = ch1_frame1_written;
    assign fake_dma_enable         = reg_scratch_d0[0];

endmodule
