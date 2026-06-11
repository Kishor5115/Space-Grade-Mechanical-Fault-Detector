//============================================================================
// Module : vibration_top.v
// Project: Space-Grade Vibration Pattern Anomaly Detector (GF180, 180nm)
//----------------------------------------------------------------------------
// Function:
//   Top-level ASIC wrapper. Integrates spi_master, config_regs, goertzel_core
//   and fault_flagger, and instantiates the ONE and ONLY hardware multiplier
//   in the entire design.
//
// Shared multiplier + operand isolation (Rules A & B):
//   * Exactly ONE signed multiplier exists (the `prod = op_a * op_b` line).
//   * Its inputs come from an operand-isolation LATCH (op_a/op_b registers)
//     that only updates when a requester asserts mult_req. While idle the
//     inputs are frozen -> the large GF180 multiplier does not toggle ->
//     dynamic power is minimized.
//   * Goertzel and fault_flagger are time-sequenced (per-sample vs once per
//     512-sample block, with the sample period >> the ~7-cycle fault math),
//     so a simple priority mux (fault has priority) resolves the request.
//   * The wide 48-bit Q16.30 product is realigned (>>>15) and SATURATED back
//     to a 24-bit Q8.15 result HERE; only the 24-bit mult_q bus is routed to
//     the cores (no 48-bit datapath crosses module boundaries).
//
//   Multiplier latency = 1 cycle: requesters drive operands combinationally;
//   the latch captures them on the clk edge; mult_q is valid the next cycle.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module vibration_top #(
    parameter integer DATA_W     = 24,   // Q8.15 datapath width
    parameter integer FRAC_W     = 15,   // fractional bits
    parameter integer SAMPLE_W   = 16,   // ADC sample width
    parameter integer MAG_W      = 24,   // squared-magnitude / threshold width
    parameter integer APB_AW     = 8,
    parameter integer APB_DW     = 32,
    parameter integer BLOCK_N    = 512,
    parameter integer DEB_W      = 4,
    parameter integer DEB_TARGET = 5,
    parameter integer SCLK_DIV   = 4,
    parameter integer SAMPLE_DIV = 1000
)(
    // Clock / reset (single domain for this implementation)
    input  wire                clk,
    input  wire                rst_n,

    // SPI to external ADC
    input  wire                miso,
    output wire                sclk,
    output wire                cs_n,

    // APB configuration slave
    input  wire                PSEL,
    input  wire                PENABLE,
    input  wire                PWRITE,
    input  wire [APB_AW-1:0]   PADDR,
    input  wire [APB_DW-1:0]   PWDATA,
    output wire [APB_DW-1:0]   PRDATA,
    output wire                PREADY,

    // Fault output to spacecraft fault-management bus
    output wire                hw_interrupt
);

    //========================================================================
    // Internal nets
    //========================================================================
    // SPI -> Goertzel
    wire                       data_ready;
    wire signed [SAMPLE_W-1:0] x_n;

    // Config -> datapath
    wire signed [DATA_W-1:0]   cfg_coeff_c;
    wire        [MAG_W-1:0]    cfg_thresh_sq;
    wire                       cfg_enable;
    wire                       cfg_rst_alarm;

    // Goertzel <-> fault flagger
    wire signed [DATA_W-1:0]   v1, v2;
    wire                       sample_done;
    wire                       block_clear;
    wire                       alarm_active;

    // Shared-multiplier request buses
    wire                       g_mreq;
    wire signed [DATA_W-1:0]   g_ma, g_mb;
    wire                       f_mreq;
    wire signed [DATA_W-1:0]   f_ma, f_mb;
    wire signed [DATA_W-1:0]   mult_q;   // truncated Q8.15 result (shared)

    //========================================================================
    // THE single shared hardware multiplier + operand-isolation latch
    //========================================================================
    // Priority mux: fault_flagger wins (it only runs between samples, when
    // Goertzel is guaranteed idle). Operand isolation freezes inputs at idle.
    wire                     mult_en = g_mreq | f_mreq;
    wire signed [DATA_W-1:0] sel_a   = f_mreq ? f_ma : g_ma;
    wire signed [DATA_W-1:0] sel_b   = f_mreq ? f_mb : g_mb;

    reg signed [DATA_W-1:0] op_a, op_b;  // <-- operand isolation registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_a <= {DATA_W{1'b0}};
            op_b <= {DATA_W{1'b0}};
        end else if (mult_en) begin
            op_a <= sel_a;   // update ONLY when a multiply is requested
            op_b <= sel_b;   // otherwise hold -> multiplier inputs do not toggle
        end
    end

    // ---- The ONE multiplier instance for the whole chip ----
    // Q8.15 * Q8.15 = Q16.30 captured in 2*DATA_W bits.
    wire signed [2*DATA_W-1:0] prod    = op_a * op_b;
    // Realign Q16.30 -> Q8.15 by arithmetic right shift of FRAC_W (15).
    wire signed [2*DATA_W-1:0] prod_sh = prod >>> FRAC_W;

    // Saturate the realigned product back into the 24-bit Q8.15 range so the
    // wide product never propagates and fixed-point overflow can't wrap.
    localparam signed [DATA_W-1:0] Q_MAX = {1'b0, {(DATA_W-1){1'b1}}};
    localparam signed [DATA_W-1:0] Q_MIN = {1'b1, {(DATA_W-1){1'b0}}};

    localparam signed [2*DATA_W-1:0] Q_MAX_EXT = {{(DATA_W){Q_MAX[DATA_W-1]}}, Q_MAX};
    localparam signed [2*DATA_W-1:0] Q_MIN_EXT = {{(DATA_W){Q_MIN[DATA_W-1]}}, Q_MIN};

    assign mult_q = (prod_sh > Q_MAX_EXT) ? Q_MAX :
                    (prod_sh < Q_MIN_EXT) ? Q_MIN :
                    prod_sh[DATA_W-1:0];

    //========================================================================
    // Module 1: SPI master
    //========================================================================
    spi_master #(
        .SAMPLE_W   (SAMPLE_W),
        .SCLK_DIV   (SCLK_DIV),
        .SAMPLE_DIV (SAMPLE_DIV)
    ) u_spi (
        .clk        (clk),
        .rst_n      (rst_n),
        .miso       (miso),
        .sclk       (sclk),
        .cs_n       (cs_n),
        .data_ready (data_ready),
        .x_n        (x_n)
    );

    //========================================================================
    // Module 2: APB configuration registers
    //========================================================================
    config_regs #(
        .APB_AW (APB_AW),
        .APB_DW (APB_DW),
        .DATA_W (DATA_W),
        .MAG_W  (MAG_W)
    ) u_cfg (
        .PCLK          (clk),
        .PRESETn       (rst_n),
        .PSEL          (PSEL),
        .PENABLE       (PENABLE),
        .PWRITE        (PWRITE),
        .PADDR         (PADDR),
        .PWDATA        (PWDATA),
        .PRDATA        (PRDATA),
        .PREADY        (PREADY),
        .alarm_active  (alarm_active),
        .cfg_coeff_c   (cfg_coeff_c),
        .cfg_thresh_sq (cfg_thresh_sq),
        .cfg_enable    (cfg_enable),
        .cfg_rst_alarm (cfg_rst_alarm)
    );

    //========================================================================
    // Module 3: Goertzel core (shared-mult requester #1)
    //========================================================================
    goertzel_core #(
        .DATA_W   (DATA_W),
        .SAMPLE_W (SAMPLE_W)
    ) u_goertzel (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (cfg_enable),
        .data_ready  (data_ready),
        .x_n         (x_n),
        .coeff_c     (cfg_coeff_c),
        .block_clear (block_clear),
        .mult_req    (g_mreq),
        .mult_a      (g_ma),
        .mult_b      (g_mb),
        .mult_q      (mult_q),
        .v1          (v1),
        .v2          (v2),
        .sample_done (sample_done)
    );

    //========================================================================
    // Module 4: Fault flagger (shared-mult requester #2, TMR-hardened)
    //========================================================================
    fault_flagger #(
        .DATA_W     (DATA_W),
        .MAG_W      (MAG_W),
        .BLOCK_N    (BLOCK_N),
        .DEB_W      (DEB_W),
        .DEB_TARGET (DEB_TARGET)
    ) u_fault (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (cfg_enable),
        .rst_alarm    (cfg_rst_alarm),
        .sample_done  (sample_done),
        .v1           (v1),
        .v2           (v2),
        .coeff_c      (cfg_coeff_c),
        .thresh_sq    (cfg_thresh_sq),
        .mult_req     (f_mreq),
        .mult_a       (f_ma),
        .mult_b       (f_mb),
        .mult_q       (mult_q),
        .block_clear  (block_clear),
        .hw_interrupt (hw_interrupt),
        .alarm_active (alarm_active)
    );

endmodule

`default_nettype wire
