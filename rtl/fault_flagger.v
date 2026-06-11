//============================================================================
// Module : fault_flagger.v
// Project: Space-Grade Vibration Pattern Anomaly Detector (GF180, 180nm)
//----------------------------------------------------------------------------
// Function:
//   Per-block (N = 512 samples) spectral magnitude evaluation and debounced
//   fault decision.
//
//   Magnitude-squared (NO square root, per Rule A):
//       Mag^2 = v1^2 + v2^2 - (C * v1 * v2)
//   evaluated with the ONE shared multiplier (4 sequential products):
//       t1 = v1*v1 ; t2 = v2*v2 ; t3 = C*v1 ; t4 = t3*v2
//       Mag^2 = t1 + t2 - t4
//   Each product is returned ALREADY truncated to Q8.15 by the shared mult,
//   so only 24-bit buses are routed (no 48-bit datapath leaves the mult).
//
//   Decision: if Mag^2 > THRESH_SQ -> increment debounce counter, else reset.
//   When the debounce counter reaches DEB_TARGET (5) the hw_interrupt latch
//   is asserted (cleared via cfg_rst_alarm).
//
// Radiation hardening (Rule C):
//   The block (sample) counter AND the debounce counter are TRIPLICATED with
//   self-scrubbing bitwise majority voters: voted = (a&b)|(b&c)|(a&c).
//   The arithmetic datapath itself is intentionally NOT triplicated (area).
//
// Multiplier protocol: 1-cycle latency (operands latched when mult_req high;
// result mult_q valid the following state).
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module fault_flagger #(
    parameter integer DATA_W     = 24,   // Q8.15 datapath width
    parameter integer MAG_W      = 24,   // squared-magnitude / threshold width
    parameter integer BLOCK_N    = 512,  // samples per analysis block
    parameter integer DEB_W      = 4,    // debounce counter width
    parameter integer DEB_TARGET = 5     // consecutive bad blocks -> interrupt
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     enable,
    input  wire                     rst_alarm,    // clear interrupt latch (1 clk)

    input  wire                     sample_done,  // 1-clk pulse per Goertzel sample
    input  wire signed [DATA_W-1:0] v1,           // Goertzel state v[n-1]
    input  wire signed [DATA_W-1:0] v2,           // Goertzel state v[n-2]
    input  wire signed [DATA_W-1:0] coeff_c,      // Q8.15 coefficient C
    input  wire        [MAG_W-1:0]  thresh_sq,    // squared threshold

    // Shared-multiplier request interface (result pre-truncated to Q8.15)
    output reg                      mult_req,
    output reg  signed [DATA_W-1:0] mult_a,
    output reg  signed [DATA_W-1:0] mult_b,
    input  wire signed [DATA_W-1:0] mult_q,

    output reg                      block_clear,  // reset Goertzel v1/v2 (1 clk)
    output wire                     hw_interrupt, // persistent fault asserted
    output wire                     alarm_active  // status mirror
);

    //------------------------------------------------------------------------
    // Local params
    //------------------------------------------------------------------------
    localparam integer CNT_W = $clog2(BLOCK_N) + 1;

    localparam [2:0] F_IDLE = 3'd0,
                     F0     = 3'd1,  // load v1*v1
                     F1     = 3'd2,  // cap t1, load v2*v2
                     F2     = 3'd3,  // cap t2, load C*v1
                     F3     = 3'd4,  // load (C*v1)*v2  [chained from mult_q]
                     F4     = 3'd5,  // cap t4 = C*v1*v2
                     F5     = 3'd6;  // compute Mag^2, compare, debounce

    reg [2:0] fstate;

    // Product capture registers (all Q8.15)
    reg signed [DATA_W-1:0] t1;  // v1^2
    reg signed [DATA_W-1:0] t2;  // v2^2
    reg signed [DATA_W-1:0] t4;  // C*v1*v2

    //------------------------------------------------------------------------
    // TMR block (sample) counter : three copies + bitwise majority vote
    //------------------------------------------------------------------------
    reg [CNT_W-1:0] bcnt_a, bcnt_b, bcnt_c;
    wire [CNT_W-1:0] bcnt_v = (bcnt_a & bcnt_b) | (bcnt_b & bcnt_c) | (bcnt_a & bcnt_c);
    reg [CNT_W-1:0] bcnt_nxt;

    reg block_trig;  // latched: a full block of N samples is ready

    //------------------------------------------------------------------------
    // TMR debounce counter : three copies + bitwise majority vote
    //------------------------------------------------------------------------
    reg [DEB_W-1:0] deb_a, deb_b, deb_c;
    wire [DEB_W-1:0] deb_v = (deb_a & deb_b) | (deb_b & deb_c) | (deb_a & deb_c);
    reg [DEB_W-1:0] deb_nxt;

    // Interrupt latch
    reg alarm_reg;
    assign hw_interrupt = alarm_reg;
    assign alarm_active = alarm_reg;

    //------------------------------------------------------------------------
    // Magnitude-squared combinational sum: t1 + t2 - t4 with 2 guard bits.
    //------------------------------------------------------------------------
    wire signed [DATA_W+1:0] mag2_ext =
            $signed({{2{t1[DATA_W-1]}}, t1}) +
            $signed({{2{t2[DATA_W-1]}}, t2}) -
            $signed({{2{t4[DATA_W-1]}}, t4});

    // Clamp negative (truncation noise) to 0, saturate high, present as MAG_W.
    localparam [MAG_W-1:0] MAG_MAX = {MAG_W{1'b1}};
    wire [MAG_W-1:0] mag2_clamped =
            (mag2_ext[DATA_W+1])                       ? {MAG_W{1'b0}} : // negative -> 0
            (|mag2_ext[DATA_W:MAG_W])                  ? MAG_MAX        : // overflow -> max
                                                         mag2_ext[MAG_W-1:0];

    wire over_thresh = (mag2_clamped > thresh_sq);

    //------------------------------------------------------------------------
    // Shared-multiplier request: COMBINATIONAL operand drive (the single
    // register stage / operand isolation is in the top-level multiplier).
    //   F0: v1*v1   F1: v2*v2   F2: C*v1   F3: (C*v1)*v2  [chained via mult_q]
    //------------------------------------------------------------------------
    always @(*) begin
        mult_req = 1'b0;
        mult_a   = {DATA_W{1'b0}};
        mult_b   = {DATA_W{1'b0}};
        case (fstate)
            F0: begin mult_req = 1'b1; mult_a = v1;     mult_b = v1; end
            F1: begin mult_req = 1'b1; mult_a = v2;     mult_b = v2; end
            F2: begin mult_req = 1'b1; mult_a = coeff_c;mult_b = v1; end
            // chain: feed the just-produced C*v1 (mult_q) back as operand A
            F3: begin mult_req = 1'b1; mult_a = mult_q; mult_b = v2; end
            default: ; // isolated
        endcase
    end

    //------------------------------------------------------------------------
    // Block-counter accumulation (TMR). Counts Goertzel sample_done pulses.
    //------------------------------------------------------------------------
    always @(*) begin
        bcnt_nxt = bcnt_v;
        if (sample_done) begin
            if (bcnt_v == BLOCK_N[CNT_W-1:0] - 1'b1)
                bcnt_nxt = {CNT_W{1'b0}};   // block complete -> wrap
            else
                bcnt_nxt = bcnt_v + 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // Debounce next-value (TMR), evaluated at F5.
    //------------------------------------------------------------------------
    always @(*) begin
        if (over_thresh) begin
            // saturate at DEB_TARGET so we never wrap past the trip point
            if (deb_v >= DEB_TARGET[DEB_W-1:0])
                deb_nxt = DEB_TARGET[DEB_W-1:0];
            else
                deb_nxt = deb_v + 1'b1;
        end else begin
            deb_nxt = {DEB_W{1'b0}};         // healthy block resets debounce
        end
    end

    //------------------------------------------------------------------------
    // Main sequential process
    //------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate      <= F_IDLE;
            t1          <= {DATA_W{1'b0}};
            t2          <= {DATA_W{1'b0}};
            t4          <= {DATA_W{1'b0}};
            bcnt_a      <= {CNT_W{1'b0}};
            bcnt_b      <= {CNT_W{1'b0}};
            bcnt_c      <= {CNT_W{1'b0}};
            block_trig  <= 1'b0;
            deb_a       <= {DEB_W{1'b0}};
            deb_b       <= {DEB_W{1'b0}};
            deb_c       <= {DEB_W{1'b0}};
            alarm_reg   <= 1'b0;
            block_clear <= 1'b0;
        end else begin
            // Defaults
            block_clear <= 1'b0;

            // ---- TMR block counter update (write all three copies) ----
            if (enable) begin
                bcnt_a <= bcnt_nxt;
                bcnt_b <= bcnt_nxt;
                bcnt_c <= bcnt_nxt;
                // Latch "block ready" on the Nth sample
                if (sample_done && (bcnt_v == BLOCK_N[CNT_W-1:0] - 1'b1))
                    block_trig <= 1'b1;
            end

            // ---- Interrupt clear ----
            if (rst_alarm)
                alarm_reg <= 1'b0;

            //----------------------------------------------------------------
            // Magnitude-squared evaluation FSM (uses the shared multiplier)
            //----------------------------------------------------------------
            case (fstate)
                F_IDLE: begin
                    if (enable && block_trig) begin
                        block_trig <= 1'b0;
                        fstate     <= F0;
                    end
                end
                // Cycle: load v1*v1 (operands driven combinationally)
                F0: begin
                    fstate <= F1;
                end
                // Capture t1 = v1^2 ; (load v2*v2 combinationally)
                F1: begin
                    t1     <= mult_q;
                    fstate <= F2;
                end
                // Capture t2 = v2^2 ; (load C*v1 combinationally)
                F2: begin
                    t2     <= mult_q;
                    fstate <= F3;
                end
                // (chained (C*v1)*v2 driven combinationally from mult_q)
                F3: begin
                    fstate <= F4;
                end
                // Capture t4 = C*v1*v2
                F4: begin
                    t4     <= mult_q;
                    fstate <= F5;
                end
                // Compute Mag^2 = t1+t2-t4, compare, update debounce (TMR).
                F5: begin
                    deb_a <= deb_nxt;
                    deb_b <= deb_nxt;
                    deb_c <= deb_nxt;
                    if (deb_nxt >= DEB_TARGET[DEB_W-1:0])
                        alarm_reg <= 1'b1;       // persistent fault -> interrupt
                    block_clear <= 1'b1;         // start fresh Goertzel block
                    fstate      <= F_IDLE;
                end
                default: fstate <= F_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
