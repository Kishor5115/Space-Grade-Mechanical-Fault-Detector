//============================================================================
// Module : goertzel_core.v
// Project: Space-Grade Vibration Pattern Anomaly Detector (GF180, 180nm)
//----------------------------------------------------------------------------
// Function:
//   INTERLEAVED TRI-AXIS Goertzel (ITAG) recursive IIR engine in Q8.15
//   fixed-point. A single incoming sensor burst carries X, Y and Z samples
//   simultaneously; this core runs THREE independent frequency bins (bin 0 /
//   bin 1 / bin 2) for ALL THREE axes within one sample period, each computing
//
//       v_k[n] = x[n] + C_k * v_k[n-1] - v_k[n-2]
//
//   All 9 (axis,bin) resonators SHARE the single chip-wide hardware
//   multiplier (rtl/multiplier.v, instanced in magnitude_compute.v) by
//   time-multiplexing it across the 9 recurrences, one at a time.
//
//----------------------------------------------------------------------------
// Why ITAG (vs. the legacy axis-sequential core):
//   The legacy core processed ONE axis per 512-sample block, rotating
//   X->Y->Z across blocks, so a given axis was only observed once every 3
//   blocks (up to 38.4 ms worst-case inter-axis latency; a simultaneous
//   multi-axis fault could be smeared across blocks and missed). The sensor
//   burst already delivers X/Y/Z together every sample -- the legacy core
//   simply discarded Y and Z. ITAG exploits the ~98% idle window to process
//   all three axes every sample, giving ZERO inter-axis latency and
//   cycle-accurate per-axis fault attribution, at the cost of 12 extra 24-bit
//   state flops (v1/v2 x 3 bins x 2 extra axes). See
//   docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md for the full timing/area/power/RHBD
//   analysis.
//
//----------------------------------------------------------------------------
// Microarchitecture (ULTRA-LOW-POWER / AREA-OPTIMIZED, 18 active cycles/sample):
//
//   Per (axis,bin) we need exactly TWO cycles because of the 1-cycle
//   multiplier latency, NOT three. The classic add-then-sub is FUSED into one
//   update:
//
//     *_MUL : request shared multiplier -> C_k * v1  (operands driven
//             combinationally; magnitude_compute's latch captures them this
//             edge).
//     *_UPD : product mult_q (= C_k*v1) is valid this cycle, so compute the
//             FULL recurrence in a single fused 3-input saturating add:
//                 v1(new) = sat( x[axis] + mult_q - v2 )
//                 v2(new) = v1(old)
//
//   FSM sequence for one sample (19 states, interleaved by axis):
//     S_IDLE
//       -> XB0_MUL -> XB0_UPD -> XB1_MUL -> XB1_UPD -> XB2_MUL -> XB2_UPD  [X]
//       -> YB0_MUL -> YB0_UPD -> YB1_MUL -> YB1_UPD -> YB2_MUL -> YB2_UPD  [Y]
//       -> ZB0_MUL -> ZB0_UPD -> ZB1_MUL -> ZB1_UPD -> ZB2_MUL -> ZB2_UPD  [Z]
//       -> S_IDLE
//     => 18 active cycles per sample (6 per axis). 375 clk/sample @ 10 MHz,
//        26.667 kHz -> 357 idle cycles remain (~95.2% idle). The magnitude
//        engine steals that idle window for its 9-pair mag computation using
//        the SAME shared multiplier (no contention: this core holds
//        mult_req=0 for the whole idle window).
//
//   Why this is the lowest-PPA choice:
//     * NO acc register(s). The intermediate (x + C*v1) is never stored; it is
//       consumed the same cycle by the fused adder -> zero scratch flops.
//     * The fused add is "(x - v2) + mult_q". (x - v2) is a parallel SHORT
//       path (register->register); mult_q is the only operand on the long
//       (post-multiplier) path -> critical path == multiplier + 1 add,
//       identical to the legacy core. No timing penalty at 10 MHz.
//     * The expensive multiplier is SHARED across all 9 recurrences AND the
//       magnitude engine: full 3-axis x 3-bin spectral coverage on ONE
//       multiplier.
//
//----------------------------------------------------------------------------
// Fixed-point handling:
//   * Each ADC sample is 16-bit Q1.15 (+-1.0). All three axes are registered
//     once per sample (x_q15_r/y_q15_r/z_q15_r) and sign-extended into the
//     24-bit Q8.15 datapath (binary point fixed at bit 15 -> no shift needed).
//   * C_k * v1 is performed by the shared multiplier, returning an
//     ALREADY-truncated/saturated Q8.15 result (mult_q).
//   * The fused add uses TWO guard bits (3-input sum) and saturates back to
//     Q8.15 once, at the end -> a single, clean overflow clamp.
//
// Radiation hardening (Rule C):
//   The control FSM state register is TRIPLICATED (5-bit, 19 states) with a
//   self-scrubbing bitwise majority voter (vote5). Next-state logic reads ONLY
//   the voted state, so a flipped copy is corrected on the next clock. The
//   next-state default maps to S_IDLE so any of the 13 illegal 5-bit codes
//   (SEU-induced) recovers to a safe state in one clock. The 18 datapath
//   v-registers are intentionally NOT triplicated (area/power) -- an upset
//   corrupts at most one (axis,bin) magnitude for one block, after which
//   block_clear zeroes all state (effective 512-sample scrub).
//
// Correctness contracts preserved from the legacy core:
//   1. block_clear is an explicit PRIORITY override of the v1/v2 writes
//      (clears ALL 18 state regs; v-updates are skipped that cycle).
//   2. Samples are REGISTERED on data_ready -> the arithmetic pipeline is
//      decoupled from how long the upstream module holds x_n/y_n/z_n.
//   3. NO acc register (fused update) -> zero scratch flops.
//   4. sample_done pulses exactly ONCE per sample, at ZB2_UPD (end of all
//      three axes) -> fault_flagger's block counter stays correct.
//
// Multiplier protocol (1-cycle latency, operand-isolated):
//   In each *_MUL state we drive mult_a/mult_b and assert mult_req. The shared
//   multiplier latches the operands on that clk edge; mult_q is valid in the
//   following (*_UPD) state. In every other state mult_req=0 and the operands
//   are driven to 0, so the shared unit's inputs freeze -> no toggling -> no
//   dynamic power.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module goertzel_core #(
    parameter integer DATA_W   = 24,  // Q8.15 datapath width (1.8.15)
    parameter integer SAMPLE_W = 16,  // ADC sample width (Q1.15)
    parameter integer N_BINS   = 3    // number of frequency bins (fixed at 3)
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       enable,       // global detector enable
    input  wire                       data_ready,   // new sample strobe (1 clk)
    input  wire signed [SAMPLE_W-1:0] x_n,          // Q1.15 X-axis sample
    input  wire signed [SAMPLE_W-1:0] y_n,          // Q1.15 Y-axis sample
    input  wire signed [SAMPLE_W-1:0] z_n,          // Q1.15 Z-axis sample
    input  wire signed [DATA_W-1:0]   coeff_c0,     // Q8.15 coeff, bin 0 (fundamental)
    input  wire signed [DATA_W-1:0]   coeff_c1,     // Q8.15 coeff, bin 1 (harmonic)
    input  wire signed [DATA_W-1:0]   coeff_c2,     // Q8.15 coeff, bin 2 (resonance)
    input  wire                       block_clear,  // reset all v1/v2 for new block

    // Shared-multiplier request interface (result pre-truncated to Q8.15)
    output reg                        mult_req,     // assert to use the mult
    output reg  signed [DATA_W-1:0]   mult_a,
    output reg  signed [DATA_W-1:0]   mult_b,
    input  wire signed [DATA_W-1:0]   mult_q,       // C*v1 truncated to Q8.15

    // Per-axis, per-bin Goertzel state outputs (consumed by magnitude_compute
    // each block). 18 total: 3 axes (x/y/z) x 3 bins (0/1/2) x {v1,v2}.
    output reg  signed [DATA_W-1:0]   v1x_0, v2x_0, v1x_1, v2x_1, v1x_2, v2x_2,
    output reg  signed [DATA_W-1:0]   v1y_0, v2y_0, v1y_1, v2y_1, v1y_2, v2y_2,
    output reg  signed [DATA_W-1:0]   v1z_0, v2z_0, v1z_1, v2z_1, v1z_2, v2z_2,
    output reg                        sample_done   // 1-clk pulse per sample
);

    //------------------------------------------------------------------------
    // Saturation limits for Q8.15 (DATA_W bits).
    //------------------------------------------------------------------------
    localparam signed [DATA_W-1:0] Q_MAX = {1'b0, {(DATA_W-1){1'b1}}}; // +max
    localparam signed [DATA_W-1:0] Q_MIN = {1'b1, {(DATA_W-1){1'b0}}}; // -min

    // 2 guard bits: the fused update is a 3-input signed sum (x + C*v1 - v2).
    localparam signed [DATA_W+1:0] Q_MAX_EXT2 = {{2{Q_MAX[DATA_W-1]}}, Q_MAX};
    localparam signed [DATA_W+1:0] Q_MIN_EXT2 = {{2{Q_MIN[DATA_W-1]}}, Q_MIN};

    //------------------------------------------------------------------------
    // FSM state encoding (19 states -> 5 bits). default -> S_IDLE (SEU-safe).
    //   X axis: XB0_MUL..XB2_UPD, Y axis: YB0_MUL..YB2_UPD, Z: ZB0_MUL..ZB2_UPD
    //------------------------------------------------------------------------
    localparam [4:0]
        S_IDLE  = 5'd0,
        XB0_MUL = 5'd1,  XB0_UPD = 5'd2,
        XB1_MUL = 5'd3,  XB1_UPD = 5'd4,
        XB2_MUL = 5'd5,  XB2_UPD = 5'd6,
        YB0_MUL = 5'd7,  YB0_UPD = 5'd8,
        YB1_MUL = 5'd9,  YB1_UPD = 5'd10,
        YB2_MUL = 5'd11, YB2_UPD = 5'd12,
        ZB0_MUL = 5'd13, ZB0_UPD = 5'd14,
        ZB1_MUL = 5'd15, ZB1_UPD = 5'd16,
        ZB2_MUL = 5'd17, ZB2_UPD = 5'd18;

    // Bitwise 5-bit majority voter for the triplicated FSM state.
    function automatic [4:0] vote5;
        input [4:0] a;
        input [4:0] b;
        input [4:0] c;
        begin
            vote5 = (a & b) | (b & c) | (a & c);
        end
    endfunction

    // Triple Modular Redundancy: three physical copies of the state register.
    reg  [4:0] state_a, state_b, state_c;
    wire [4:0] state_v = vote5(state_a, state_b, state_c); // voted (SEU-scrubbed)
    reg  [4:0] next_state;

    //------------------------------------------------------------------------
    // Input registration: latch all three Q1.15 samples once when data_ready
    // fires, sign-extended into the Q8.15 datapath. Decouples the core from
    // how long the upstream module holds x_n/y_n/z_n stable.
    //------------------------------------------------------------------------
    reg signed [DATA_W-1:0] x_q15_r, y_q15_r, z_q15_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_q15_r <= {DATA_W{1'b0}};
            y_q15_r <= {DATA_W{1'b0}};
            z_q15_r <= {DATA_W{1'b0}};
        end else if (data_ready && enable && (state_v == S_IDLE)) begin
            x_q15_r <= {{(DATA_W-SAMPLE_W){x_n[SAMPLE_W-1]}}, x_n};
            y_q15_r <= {{(DATA_W-SAMPLE_W){y_n[SAMPLE_W-1]}}, y_n};
            z_q15_r <= {{(DATA_W-SAMPLE_W){z_n[SAMPLE_W-1]}}, z_n};
        end
    end

    //------------------------------------------------------------------------
    // Fused saturating update networks: 9 total (3 axes x 3 bins).
    //   v1(new) = sat( x[axis] + mult_q - v2 )
    // The (x - v2) part is a parallel short path; mult_q is the only operand
    // on the long (post-multiplier) path -> critical path == multiplier + 1
    // add. Only the network whose mult_q is valid in the current *_UPD state
    // is actually consumed; synthesis prunes the dead replicas.
    //------------------------------------------------------------------------
    // ---- X axis ----
    wire signed [DATA_W+1:0] upd_ext_x0 =
        $signed({{2{x_q15_r[DATA_W-1]}}, x_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2x_0  [DATA_W-1]}}, v2x_0  });
    wire signed [DATA_W-1:0] upd_sat_x0 = (upd_ext_x0 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_x0 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_x0[DATA_W-1:0];

    wire signed [DATA_W+1:0] upd_ext_x1 =
        $signed({{2{x_q15_r[DATA_W-1]}}, x_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2x_1  [DATA_W-1]}}, v2x_1  });
    wire signed [DATA_W-1:0] upd_sat_x1 = (upd_ext_x1 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_x1 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_x1[DATA_W-1:0];

    wire signed [DATA_W+1:0] upd_ext_x2 =
        $signed({{2{x_q15_r[DATA_W-1]}}, x_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2x_2  [DATA_W-1]}}, v2x_2  });
    wire signed [DATA_W-1:0] upd_sat_x2 = (upd_ext_x2 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_x2 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_x2[DATA_W-1:0];

    // ---- Y axis ----
    wire signed [DATA_W+1:0] upd_ext_y0 =
        $signed({{2{y_q15_r[DATA_W-1]}}, y_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2y_0  [DATA_W-1]}}, v2y_0  });
    wire signed [DATA_W-1:0] upd_sat_y0 = (upd_ext_y0 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_y0 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_y0[DATA_W-1:0];

    wire signed [DATA_W+1:0] upd_ext_y1 =
        $signed({{2{y_q15_r[DATA_W-1]}}, y_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2y_1  [DATA_W-1]}}, v2y_1  });
    wire signed [DATA_W-1:0] upd_sat_y1 = (upd_ext_y1 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_y1 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_y1[DATA_W-1:0];

    wire signed [DATA_W+1:0] upd_ext_y2 =
        $signed({{2{y_q15_r[DATA_W-1]}}, y_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2y_2  [DATA_W-1]}}, v2y_2  });
    wire signed [DATA_W-1:0] upd_sat_y2 = (upd_ext_y2 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_y2 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_y2[DATA_W-1:0];

    // ---- Z axis ----
    wire signed [DATA_W+1:0] upd_ext_z0 =
        $signed({{2{z_q15_r[DATA_W-1]}}, z_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2z_0  [DATA_W-1]}}, v2z_0  });
    wire signed [DATA_W-1:0] upd_sat_z0 = (upd_ext_z0 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_z0 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_z0[DATA_W-1:0];

    wire signed [DATA_W+1:0] upd_ext_z1 =
        $signed({{2{z_q15_r[DATA_W-1]}}, z_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2z_1  [DATA_W-1]}}, v2z_1  });
    wire signed [DATA_W-1:0] upd_sat_z1 = (upd_ext_z1 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_z1 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_z1[DATA_W-1:0];

    wire signed [DATA_W+1:0] upd_ext_z2 =
        $signed({{2{z_q15_r[DATA_W-1]}}, z_q15_r}) +
        $signed({{2{mult_q [DATA_W-1]}}, mult_q }) -
        $signed({{2{v2z_2  [DATA_W-1]}}, v2z_2  });
    wire signed [DATA_W-1:0] upd_sat_z2 = (upd_ext_z2 > Q_MAX_EXT2) ? Q_MAX :
                                          (upd_ext_z2 < Q_MIN_EXT2) ? Q_MIN :
                                          upd_ext_z2[DATA_W-1:0];

    //------------------------------------------------------------------------
    // Next-state logic (operates on the VOTED current state). Linear walk
    // through the 18 active states, interleaving X then Y then Z.
    //------------------------------------------------------------------------
    always @(*) begin
        next_state = state_v;
        case (state_v)
            S_IDLE : if (enable && data_ready) next_state = XB0_MUL;
            XB0_MUL:                            next_state = XB0_UPD;
            XB0_UPD:                            next_state = XB1_MUL;
            XB1_MUL:                            next_state = XB1_UPD;
            XB1_UPD:                            next_state = XB2_MUL;
            XB2_MUL:                            next_state = XB2_UPD;
            XB2_UPD:                            next_state = YB0_MUL;
            YB0_MUL:                            next_state = YB0_UPD;
            YB0_UPD:                            next_state = YB1_MUL;
            YB1_MUL:                            next_state = YB1_UPD;
            YB1_UPD:                            next_state = YB2_MUL;
            YB2_MUL:                            next_state = YB2_UPD;
            YB2_UPD:                            next_state = ZB0_MUL;
            ZB0_MUL:                            next_state = ZB0_UPD;
            ZB0_UPD:                            next_state = ZB1_MUL;
            ZB1_MUL:                            next_state = ZB1_UPD;
            ZB1_UPD:                            next_state = ZB2_MUL;
            ZB2_MUL:                            next_state = ZB2_UPD;
            ZB2_UPD:                            next_state = S_IDLE;
            default:                            next_state = S_IDLE; // SEU-safe
        endcase
    end

    //------------------------------------------------------------------------
    // Shared-multiplier request: COMBINATIONAL operand drive. Only the *_MUL
    // states drive operands; every other state holds mult_req low and operands
    // at 0 so the shared multiplier's inputs freeze. Coefficients are shared
    // across axes (all three axes monitor the same three frequencies).
    //------------------------------------------------------------------------
    always @(*) begin
        mult_req = 1'b0;
        mult_a   = {DATA_W{1'b0}};
        mult_b   = {DATA_W{1'b0}};
        case (state_v)
            XB0_MUL: begin mult_req = 1'b1; mult_a = coeff_c0; mult_b = v1x_0; end
            XB1_MUL: begin mult_req = 1'b1; mult_a = coeff_c1; mult_b = v1x_1; end
            XB2_MUL: begin mult_req = 1'b1; mult_a = coeff_c2; mult_b = v1x_2; end
            YB0_MUL: begin mult_req = 1'b1; mult_a = coeff_c0; mult_b = v1y_0; end
            YB1_MUL: begin mult_req = 1'b1; mult_a = coeff_c1; mult_b = v1y_1; end
            YB2_MUL: begin mult_req = 1'b1; mult_a = coeff_c2; mult_b = v1y_2; end
            ZB0_MUL: begin mult_req = 1'b1; mult_a = coeff_c0; mult_b = v1z_0; end
            ZB1_MUL: begin mult_req = 1'b1; mult_a = coeff_c1; mult_b = v1z_1; end
            ZB2_MUL: begin mult_req = 1'b1; mult_a = coeff_c2; mult_b = v1z_2; end
            default: ; // inputs stay 0 -> multiplier frozen -> no toggling
        endcase
    end

    //------------------------------------------------------------------------
    // Sequential datapath + triplicated state update.
    //------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_a <= S_IDLE;
            state_b <= S_IDLE;
            state_c <= S_IDLE;
            v1x_0 <= {DATA_W{1'b0}}; v2x_0 <= {DATA_W{1'b0}};
            v1x_1 <= {DATA_W{1'b0}}; v2x_1 <= {DATA_W{1'b0}};
            v1x_2 <= {DATA_W{1'b0}}; v2x_2 <= {DATA_W{1'b0}};
            v1y_0 <= {DATA_W{1'b0}}; v2y_0 <= {DATA_W{1'b0}};
            v1y_1 <= {DATA_W{1'b0}}; v2y_1 <= {DATA_W{1'b0}};
            v1y_2 <= {DATA_W{1'b0}}; v2y_2 <= {DATA_W{1'b0}};
            v1z_0 <= {DATA_W{1'b0}}; v2z_0 <= {DATA_W{1'b0}};
            v1z_1 <= {DATA_W{1'b0}}; v2z_1 <= {DATA_W{1'b0}};
            v1z_2 <= {DATA_W{1'b0}}; v2z_2 <= {DATA_W{1'b0}};
            sample_done <= 1'b0;
        end else begin
            // Self-scrubbing TMR: all three copies driven from the voted next.
            state_a <= next_state;
            state_b <= next_state;
            state_c <= next_state;

            // block_clear is a PRIORITY override of all 18 per-(axis,bin) v
            // updates -> the whole state matrix zeroes for the new block.
            if (block_clear) begin
                v1x_0 <= {DATA_W{1'b0}}; v2x_0 <= {DATA_W{1'b0}};
                v1x_1 <= {DATA_W{1'b0}}; v2x_1 <= {DATA_W{1'b0}};
                v1x_2 <= {DATA_W{1'b0}}; v2x_2 <= {DATA_W{1'b0}};
                v1y_0 <= {DATA_W{1'b0}}; v2y_0 <= {DATA_W{1'b0}};
                v1y_1 <= {DATA_W{1'b0}}; v2y_1 <= {DATA_W{1'b0}};
                v1y_2 <= {DATA_W{1'b0}}; v2y_2 <= {DATA_W{1'b0}};
                v1z_0 <= {DATA_W{1'b0}}; v2z_0 <= {DATA_W{1'b0}};
                v1z_1 <= {DATA_W{1'b0}}; v2z_1 <= {DATA_W{1'b0}};
                v1z_2 <= {DATA_W{1'b0}}; v2z_2 <= {DATA_W{1'b0}};
            end else begin
                case (state_v)
                    // Fused recurrence: v2<=v1(old); v1<=sat(x[axis]+C*v1-v2).
                    XB0_UPD: begin v2x_0 <= v1x_0; v1x_0 <= upd_sat_x0; end
                    XB1_UPD: begin v2x_1 <= v1x_1; v1x_1 <= upd_sat_x1; end
                    XB2_UPD: begin v2x_2 <= v1x_2; v1x_2 <= upd_sat_x2; end
                    YB0_UPD: begin v2y_0 <= v1y_0; v1y_0 <= upd_sat_y0; end
                    YB1_UPD: begin v2y_1 <= v1y_1; v1y_1 <= upd_sat_y1; end
                    YB2_UPD: begin v2y_2 <= v1y_2; v1y_2 <= upd_sat_y2; end
                    ZB0_UPD: begin v2z_0 <= v1z_0; v1z_0 <= upd_sat_z0; end
                    ZB1_UPD: begin v2z_1 <= v1z_1; v1z_1 <= upd_sat_z1; end
                    ZB2_UPD: begin v2z_2 <= v1z_2; v1z_2 <= upd_sat_z2; end
                    default: ; // MUL/IDLE states: no state-register write
                endcase
            end

            // Exactly one sample_done pulse per sample, at the very last state
            // (all three axes done), regardless of block_clear -> fault_flagger
            // block counter safety.
            sample_done <= (state_v == ZB2_UPD);
        end
    end

endmodule

`default_nettype wire
