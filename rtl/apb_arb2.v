//============================================================================
// apb_arb2.v -- minimal 2-master : 1-slave APB arbiter (registered grant)
//----------------------------------------------------------------------------
// tmr_reg_bank has a single APB slave port but two possible masters:
//   m1 = cmd_spi_slave's config path (coefficients / threshold / control)
//   m0 = spi_apb_interface's Option-B sample forwarder (only active when
//        tmr_forward_en=1)
// They almost never contend (config is host-driven, forwarding is sensor-
// driven), but a proper arbiter guarantees they can never collide on the bus.
//
// Scheme: a registered grant. In IDLE the slave is deselected for one cycle;
// when a master asserts psel the grant latches to it and stays until that
// master drops psel (APB masters hold psel until pready, so a granted transfer
// always completes). Command config (m1) has priority over sample forwarding.
// The one-cycle grant latency is immaterial -- the requesting master simply
// waits, exactly as it would for a slave wait-state.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module apb_arb2 (
    input  wire        clk,
    input  wire        rst_n,

    // ---- master 0 (sample forwarder) ----
    input  wire        m0_psel,
    input  wire        m0_penable,
    input  wire        m0_pwrite,
    input  wire [31:0] m0_paddr,
    input  wire [31:0] m0_pwdata,
    output wire        m0_pready,
    output wire [31:0] m0_prdata,

    // ---- master 1 (command-SPI config) ----
    input  wire        m1_psel,
    input  wire        m1_penable,
    input  wire        m1_pwrite,
    input  wire [31:0] m1_paddr,
    input  wire [31:0] m1_pwdata,
    output wire        m1_pready,
    output wire [31:0] m1_prdata,

    // ---- slave (tmr_reg_bank) ----
    output wire        s_psel,
    output wire        s_penable,
    output wire        s_pwrite,
    output wire [31:0] s_paddr,
    output wire [31:0] s_pwdata,
    input  wire        s_pready,
    input  wire [31:0] s_prdata
);

    localparam [1:0] IDLE = 2'd0, G0 = 2'd1, G1 = 2'd2;
    reg [1:0] grant;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) grant <= IDLE;
        else case (grant)
            IDLE: if      (m1_psel) grant <= G1;   // config priority
                  else if (m0_psel) grant <= G0;
            G0:   if (!m0_psel) grant <= IDLE;
            G1:   if (!m1_psel) grant <= IDLE;
            default: grant <= IDLE;
        endcase
    end

    // slave driven from the granted master (deselected in IDLE)
    assign s_psel    = (grant==G0) ? m0_psel    : (grant==G1) ? m1_psel    : 1'b0;
    assign s_penable = (grant==G0) ? m0_penable : (grant==G1) ? m1_penable : 1'b0;
    assign s_pwrite  = (grant==G0) ? m0_pwrite  : (grant==G1) ? m1_pwrite  : 1'b0;
    assign s_paddr   = (grant==G0) ? m0_paddr   : (grant==G1) ? m1_paddr   : 32'd0;
    assign s_pwdata  = (grant==G0) ? m0_pwdata  : (grant==G1) ? m1_pwdata  : 32'd0;

    // ready/read-data steered back to the granted master only
    assign m0_pready = (grant==G0) & s_pready;
    assign m1_pready = (grant==G1) & s_pready;
    assign m0_prdata = s_prdata;
    assign m1_prdata = s_prdata;

endmodule

`default_nettype wire
