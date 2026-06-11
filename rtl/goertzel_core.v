//============================================================================
// Module : goertzel_core.v
// Project: Space-Grade Vibration Pattern Anomaly Detector (GF180, 180nm)
//----------------------------------------------------------------------------
// Function:
//   Single-bin Goertzel recursive IIR stage in Q8.15 fixed-point.
//       v[n] = x[n] + C * v[n-1] - v[n-2]
//
// Microarchitecture (strict 3-state datapath FSM, ONE op per cycle):
//   S_MUL : request shared multiplier -> C * v1   (uses the ONE design mult)
//   S_ADD : acc = x[n] + (C*v1)                    (single adder)
//   S_SUB : v0  = acc - v2 ; shift state v2<=v1, v1<=v0  (single subtractor)
//   One arithmetic operator fires per state -> shallow logic, short timing
//   paths, minimal combinational area on the large GF180 standard cells.
//
// Fixed-point handling:
//   * ADC sample x[n] is a 16-bit Q1.15 fractional code (+-1.0 full scale).
//     It is sign-extended into the 24-bit Q8.15 datapath (binary point fixed
//     at bit 15 for both operands -> no shift needed on the add).
//   * The C*v1 product is performed by the shared multiplier, which returns
//     an ALREADY-truncated Q8.15 result (the wide 48-bit Q16.30 intermediate
//     never leaves that block, per the "no wide buses" rule).
//   * Add/Sub use a 1-bit guard and saturate back to Q8.15.
//
// Radiation hardening (Rule C):
//   The control FSM state register is TRIPLICATED with a self-scrubbing
//   bitwise majority voter (datapath is intentionally NOT triplicated).
//
// Multiplier protocol (1-cycle latency):
//   In S_MUL we drive mult_a/mult_b and assert mult_req. The shared multiplier
//   latches the operands on that clk edge; the truncated result mult_q is
//   therefore valid in the following state (S_ADD).
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module goertzel_core #(
    parameter integer DATA_W   = 24,  // Q8.15 datapath width (1.8.15)
    parameter integer SAMPLE_W = 16   // ADC sample width (Q1.15)
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       enable,       // global detector enable
    input  wire                       data_ready,   // new sample strobe (1 clk)
    input  wire signed [SAMPLE_W-1:0] x_n,          // Q1.15 ADC sample
    input  wire signed [DATA_W-1:0]   coeff_c,      // Q8.15 coefficient C
    input  wire                       block_clear,  // reset v1/v2 for new block

    // Shared-multiplier request interface (result pre-truncated to Q8.15)
    output reg                        mult_req,     // assert to use the mult
    output reg  signed [DATA_W-1:0]   mult_a,
    output reg  signed [DATA_W-1:0]   mult_b,
    input  wire signed [DATA_W-1:0]   mult_q,       // C*v1 truncated to Q8.15

    // Goertzel state outputs (consumed by fault_flagger each block)
    output reg  signed [DATA_W-1:0]   v1,           // v[n-1]
    output reg  signed [DATA_W-1:0]   v2,           // v[n-2]
    output reg                        sample_done   // 1-clk pulse per sample
);

    //------------------------------------------------------------------------
    // Saturating round-trip helper: clamp a (DATA_W+1)-bit signed value back
    // into a DATA_W-bit Q8.15 register to prevent fixed-point wrap-around.
    //------------------------------------------------------------------------
    localparam signed [DATA_W-1:0] Q_MAX =  {1'b0, {(DATA_W-1){1'b1}}}; // +max
    localparam signed [DATA_W-1:0] Q_MIN =  {1'b1, {(DATA_W-1){1'b0}}}; // -min

    localparam signed [DATA_W:0] Q_MAX_EXT = {Q_MAX[DATA_W-1], Q_MAX};
    localparam signed [DATA_W:0] Q_MIN_EXT = {Q_MIN[DATA_W-1], Q_MIN};

    // Bitwise 2-bit majority voter for the triplicated FSM state.
    function automatic [1:0] vote2;
        input [1:0] a;
        input [1:0] b;
        input [1:0] c;
        begin
            vote2 = (a & b) | (b & c) | (a & c);
        end
    endfunction

    //------------------------------------------------------------------------
    // FSM state encoding
    //------------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0,
                     S_MUL  = 2'd1,
                     S_ADD  = 2'd2,
                     S_SUB  = 2'd3;

    // Triple Modular Redundancy: three physical copies of the state register.
    reg [1:0] state_a, state_b, state_c;
    wire [1:0] state_v = vote2(state_a, state_b, state_c); // voted (SEU-scrubbed)
    reg  [1:0] next_state;

    // Sign-extend Q1.15 sample into the Q8.15 datapath (binary point aligned).
    wire signed [DATA_W-1:0] x_q15 = {{(DATA_W-SAMPLE_W){x_n[SAMPLE_W-1]}}, x_n};

    // Datapath working register for the intermediate sum (x + C*v1).
    reg signed [DATA_W-1:0] acc;

    // Combinational add/sub with one guard bit, then saturate.
    wire signed [DATA_W:0] add_ext = $signed({x_q15[DATA_W-1],  x_q15}) +
                                     $signed({mult_q[DATA_W-1],  mult_q});
    wire signed [DATA_W-1:0] add_sat = (add_ext > Q_MAX_EXT) ? Q_MAX :
                                       (add_ext < Q_MIN_EXT) ? Q_MIN :
                                       add_ext[DATA_W-1:0];

    wire signed [DATA_W:0] sub_ext = $signed({acc[DATA_W-1],     acc})   -
                                     $signed({v2[DATA_W-1],      v2});
    wire signed [DATA_W-1:0] sub_sat = (sub_ext > Q_MAX_EXT) ? Q_MAX :
                                       (sub_ext < Q_MIN_EXT) ? Q_MIN :
                                       sub_ext[DATA_W-1:0];

    //------------------------------------------------------------------------
    // Next-state logic (operates on the VOTED current state)
    //------------------------------------------------------------------------
    always @(*) begin
        next_state = state_v;
        case (state_v)
            S_IDLE: if (enable && data_ready) next_state = S_MUL;
            S_MUL :                            next_state = S_ADD;
            S_ADD :                            next_state = S_SUB;
            S_SUB :                            next_state = S_IDLE;
            default:                           next_state = S_IDLE;
        endcase
    end

    //------------------------------------------------------------------------
    // Shared-multiplier request: COMBINATIONAL operand drive (operand isolation
    // and the single register stage live in the top-level shared multiplier).
    // Only S_MUL drives the operands; all other states hold request low so the
    // top latch freezes the multiplier inputs -> no toggling, no dynamic power.
    //------------------------------------------------------------------------
    always @(*) begin
        mult_req = 1'b0;
        mult_a   = {DATA_W{1'b0}};
        mult_b   = {DATA_W{1'b0}};
        if (state_v == S_MUL) begin
            mult_req = 1'b1;
            mult_a   = coeff_c;   // Q8.15
            mult_b   = v1;        // Q8.15  ->  product = C * v[n-1]
        end
    end

    //------------------------------------------------------------------------
    // Sequential datapath + triplicated state update
    //------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_a    <= S_IDLE;
            state_b    <= S_IDLE;
            state_c    <= S_IDLE;
            v1         <= {DATA_W{1'b0}};
            v2         <= {DATA_W{1'b0}};
            acc        <= {DATA_W{1'b0}};
            sample_done<= 1'b0;
        end else begin
            // Update all three state copies from the voted next-state
            // (self-scrubbing: any single upset copy is corrected next clk).
            state_a <= next_state;
            state_b <= next_state;
            state_c <= next_state;

            // Default
            sample_done <= 1'b0;

            // Block boundary: clear recursive history for the next 512-block.
            if (block_clear) begin
                v1 <= {DATA_W{1'b0}};
                v2 <= {DATA_W{1'b0}};
            end

            case (state_v)
                //------------------------------------------------------------
                S_IDLE: begin
                    // Resting: no multiplier activity, datapath quiet.
                end
                //------------------------------------------------------------
                // Cycle 1: MULTIPLY  ->  C * v1  (shared multiplier)
                //   Operands are driven COMBINATIONALLY (see mult-request
                //   block below); the top-level operand-isolation latch
                //   captures them this edge, product valid next state.
                //------------------------------------------------------------
                S_MUL: begin
                    // no datapath register update this cycle
                end
                //------------------------------------------------------------
                // Cycle 2: ADD  ->  acc = x[n] + (C*v1)
                //   mult_q is the truncated Q8.15 product, valid this cycle.
                //------------------------------------------------------------
                S_ADD: begin
                    acc <= add_sat;
                end
                //------------------------------------------------------------
                // Cycle 3: SUBTRACT -> v0 = acc - v2 ; shift the delay line.
                //------------------------------------------------------------
                S_SUB: begin
                    v2          <= v1;          // v[n-2] <= v[n-1]
                    v1          <= sub_sat;
                    sample_done <= 1'b1;        // signal sample complete
                end
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
