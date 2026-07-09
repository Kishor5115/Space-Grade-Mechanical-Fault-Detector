//============================================================================
// tmr_reg_bank.v  -- APB slave, triplicated+scrubbed config registers
// Register map (byte addr):
//   0x00 CTRL        bit0=cfg_start(W1P), bit1=cfg_fault_clear(W1P), bit2=cfg_stop(W1P)
//   0x04 CFG_C0      [23:0] Q8.15 coeff bin 0
//   0x08 CFG_C1      [23:0] Q8.15 coeff bin 1
//   0x0C CFG_C2      [23:0] Q8.15 coeff bin 2
//   0x10 CFG_THRESHOLD [31:0]
//   0x14 STATUS      [0]=fault_flag (R)
//   0x18 FAULT_MAG   [31:0] (R)
//   0x1C FAULT_BIN   [1:0]=bin idx (R), [3:2]=axis idx 0=X/1=Y/2=Z (R)
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tmr_reg_bank (
    input  wire        clk,
    input  wire        rst_n,

    // APB slave
    input  wire [31:0] p_addr,
    input  wire [31:0] pwdata,
    input  wire        psel,
    input  wire        pwrite,
    input  wire        penable,
    output reg  [31:0] prdata,
    output reg         pready,

    // config outputs
    output wire signed [23:0] cfg_c0,
    output wire signed [23:0] cfg_c1,
    output wire signed [23:0] cfg_c2,
    output wire [31:0] cfg_threshold,
    output reg         cfg_start,
    output reg         cfg_stop,
    output reg         cfg_fault_clear,
    output reg         run_enable,

    // status inputs
    input  wire        fault_flag,
    input  wire [31:0] fault_mag_latched,
    input  wire [1:0]  fault_bin_latched,
    input  wire [1:0]  fault_axis_latched
);

    function automatic [31:0] vote32;
        input [31:0] a,b,c; begin vote32=(a&b)|(b&c)|(a&c); end
    endfunction

    wire apb_write = psel & penable & pwrite;
    wire [7:0] waddr = p_addr[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pready<=0;
        else        pready<=psel & penable;
    end

    // ---- scrub timer ----
    localparam SCRUB_P = 1024;
    localparam SCRUB_W = $clog2(SCRUB_P);
    reg [SCRUB_W-1:0] scrub_cnt;
    reg scrub;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scrub_cnt<=0; scrub<=0; end
        else begin
            scrub <= (scrub_cnt == SCRUB_P-1);
            scrub_cnt <= (scrub_cnt==SCRUB_P-1) ? 0 : scrub_cnt+1'b1;
        end
    end

    // ---- triplicated config registers ----
    reg [23:0] c0_a,c0_b,c0_c;
    reg [23:0] c1_a,c1_b,c1_c;
    reg [23:0] c2_a,c2_b,c2_c;
    reg [31:0] th_a,th_b,th_c;

    assign cfg_c0        = vote32({8'd0,c0_a},{8'd0,c0_b},{8'd0,c0_c});
    assign cfg_c1        = vote32({8'd0,c1_a},{8'd0,c1_b},{8'd0,c1_c});
    assign cfg_c2        = vote32({8'd0,c2_a},{8'd0,c2_b},{8'd0,c2_c});
    assign cfg_threshold = vote32(th_a,th_b,th_c);

    // write + scrub, real write wins
    `define TMR_FIELD(NAME_A,NAME_B,NAME_C,VOTED,ADDR,SLICE) \
    always @(posedge clk or negedge rst_n) begin \
        if (!rst_n) begin NAME_A<=0; NAME_B<=0; NAME_C<=0; end \
        else if (apb_write && waddr==ADDR) begin \
            NAME_A<=pwdata[SLICE]; NAME_B<=pwdata[SLICE]; NAME_C<=pwdata[SLICE]; end \
        else if (scrub) begin NAME_A<=VOTED[SLICE]; NAME_B<=VOTED[SLICE]; NAME_C<=VOTED[SLICE]; end \
    end

    `TMR_FIELD(c0_a,c0_b,c0_c,cfg_c0,8'h04,23:0)
    `TMR_FIELD(c1_a,c1_b,c1_c,cfg_c1,8'h08,23:0)
    `TMR_FIELD(c2_a,c2_b,c2_c,cfg_c2,8'h0C,23:0)
    `TMR_FIELD(th_a,th_b,th_c,cfg_threshold,8'h10,31:0)

    // ---- CTRL pulses + run_enable latch ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_start<=0; cfg_fault_clear<=0; cfg_stop<=0; run_enable<=0;
        end else begin
            cfg_start       <= apb_write && waddr==8'h00 && pwdata[0];
            cfg_fault_clear <= apb_write && waddr==8'h00 && pwdata[1];
            cfg_stop        <= apb_write && waddr==8'h00 && pwdata[2];
            if      (apb_write && waddr==8'h00 && pwdata[0]) run_enable<=1'b1;
            else if (apb_write && waddr==8'h00 && pwdata[2]) run_enable<=1'b0;
        end
    end

    // ---- read mux (pre-fetched in SETUP phase) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prdata<=0;
        else if (psel && !penable) begin
            case (waddr)
                8'h04: prdata <= {8'd0, cfg_c0};
                8'h08: prdata <= {8'd0, cfg_c1};
                8'h0C: prdata <= {8'd0, cfg_c2};
                8'h10: prdata <= cfg_threshold;
                8'h14: prdata <= {31'd0, fault_flag};
                8'h18: prdata <= fault_mag_latched;
                8'h1C: prdata <= {28'd0, fault_axis_latched, fault_bin_latched};
                default: prdata <= 32'd0;
            endcase
        end
    end

endmodule
`default_nettype wire