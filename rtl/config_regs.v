//============================================================================
// Module : config_regs.v
// Project: Space-Grade Vibration Pattern Anomaly Detector (GF180, 180nm)
//----------------------------------------------------------------------------
// Function:
//   Lightweight APB (AMBA Advanced Peripheral Bus) slave providing runtime
//   programmable configuration for the detector.
//
// Register Map (byte addresses, 32-bit APB data bus):
//   0x00  COEFF_C    [DATA_W-1:0]  Goertzel coefficient C, Q8.15 signed.
//                                  C = 2*cos(2*pi*k/N).
//   0x04  THRESH_SQ  [MAG_W-1:0]   Squared magnitude threshold (no sqrt in HW).
//   0x08  CONTROL    bit0 = enable (run detector)
//                    bit1 = reset_alarm (W1-pulse: clears hw_interrupt latch)
//         STATUS     (read-back of 0x08) bit8 = alarm_active (from fault logic)
//
// GF180 notes:
//   * Tiny register file (3 words) -> minimal flop area.
//   * Synchronous active-low reset. Zero-wait-state APB (PREADY tied high).
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module config_regs #(
    parameter integer APB_AW = 8,    // APB address width (bytes addressable)
    parameter integer APB_DW = 32,   // APB data width
    parameter integer DATA_W = 24,   // Q8.15 datapath width
    parameter integer MAG_W  = 24    // squared-magnitude / threshold width
)(
    // APB interface (clocked by PCLK, reset by PRESETn)
    input  wire                   PCLK,
    input  wire                   PRESETn,
    input  wire                   PSEL,
    input  wire                   PENABLE,
    input  wire                   PWRITE,
    input  wire [APB_AW-1:0]      PADDR,
    input  wire [APB_DW-1:0]      PWDATA,
    output reg  [APB_DW-1:0]      PRDATA,
    output wire                   PREADY,

    // Status input from fault logic
    input  wire                   alarm_active,

    // Configuration outputs to the datapath
    output wire signed [DATA_W-1:0] cfg_coeff_c,   // Q8.15 coefficient C
    output wire        [MAG_W-1:0]  cfg_thresh_sq, // squared threshold
    output wire                     cfg_enable,    // detector enable
    output wire                     cfg_rst_alarm  // 1-cycle clear-alarm pulse
);

    //------------------------------------------------------------------------
    // Address decode (word-aligned)
    //------------------------------------------------------------------------
    localparam [APB_AW-1:0] ADDR_COEFF   = 8'h00,
                            ADDR_THRESH  = 8'h04,
                            ADDR_CONTROL = 8'h08;

    // Zero-wait-state slave
    assign PREADY = 1'b1;

    // APB write occurs in ACCESS phase: PSEL & PENABLE & PWRITE
    wire apb_write = PSEL & PENABLE & PWRITE;
    wire apb_read  = PSEL & ~PWRITE;

    //------------------------------------------------------------------------
    // Configuration registers
    //------------------------------------------------------------------------
    reg signed [DATA_W-1:0] coeff_c_reg;
    reg        [MAG_W-1:0]  thresh_sq_reg;
    reg                     enable_reg;
    reg                     rst_alarm_reg;  // auto-clearing 1-cycle pulse

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            coeff_c_reg   <= {DATA_W{1'b0}};
            thresh_sq_reg <= {MAG_W{1'b0}};
            enable_reg    <= 1'b0;
            rst_alarm_reg <= 1'b0;
        end else begin
            // reset_alarm is a self-clearing strobe -> default low each cycle
            rst_alarm_reg <= 1'b0;
            if (apb_write) begin
                case (PADDR)
                    ADDR_COEFF:   coeff_c_reg   <= PWDATA[DATA_W-1:0];
                    ADDR_THRESH:  thresh_sq_reg <= PWDATA[MAG_W-1:0];
                    ADDR_CONTROL: begin
                        enable_reg    <= PWDATA[0];
                        rst_alarm_reg <= PWDATA[1]; // W1 strobe to clear alarm
                    end
                    default: ; // no-op
                endcase
            end
        end
    end

    //------------------------------------------------------------------------
    // APB read mux (registered read data)
    //------------------------------------------------------------------------
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            PRDATA <= {APB_DW{1'b0}};
        end else if (apb_read) begin
            case (PADDR)
                ADDR_COEFF:   PRDATA <= {{(APB_DW-DATA_W){coeff_c_reg[DATA_W-1]}}, coeff_c_reg};
                ADDR_THRESH:  PRDATA <= {{(APB_DW-MAG_W){1'b0}}, thresh_sq_reg};
                ADDR_CONTROL: begin
                    PRDATA          <= {APB_DW{1'b0}};
                    PRDATA[0]       <= enable_reg;
                    PRDATA[8]       <= alarm_active; // STATUS: live alarm flag
                end
                default:      PRDATA <= {APB_DW{1'b0}};
            endcase
        end
    end

    //------------------------------------------------------------------------
    // Drive configuration outputs
    //------------------------------------------------------------------------
    assign cfg_coeff_c   = coeff_c_reg;
    assign cfg_thresh_sq = thresh_sq_reg;
    assign cfg_enable    = enable_reg;
    assign cfg_rst_alarm = rst_alarm_reg;

    //------------------------------------------------------------------------
    // The upper APB write-data bits above DATA_W/MAG_W are intentionally
    // unused (registers are narrower than the 32-bit bus). Tie them off so
    // lint does not flag them as dangling.
    //------------------------------------------------------------------------
    // verilator lint_off UNUSEDSIGNAL
    wire _unused_ok = &{1'b0, PWDATA[APB_DW-1:DATA_W]};
    // verilator lint_on UNUSEDSIGNAL

endmodule

`default_nettype wire
