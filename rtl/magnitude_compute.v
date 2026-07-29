//============================================================================
// magnitude_compute.v  (ITAG variant)
// Owns the design's SINGLE shared multiplier (rtl/multiplier.v, instanced
// exactly once below) and services two clients on it:
//   1. goertzel_core -- the primary user, requesting C_k*v1 during its 18
//      active cycles (core_mult_req has priority);
//   2. this module's own magnitude engine, which steals the ~357-cycle idle
//      window each block to compute, for ALL 9 (axis,bin) pairs,
//          mag_sq = v1^2 + v2^2 - C_k*v1*v2.
//
// Under the Interleaved Tri-Axis Goertzel (ITAG) architecture, goertzel_core
// exposes v1/v2 for 3 axes x 3 bins = 18 registers, all valid at block
// boundary. This module snapshots them on block_clear_in (before goertzel
// zeros them that same edge) and emits 9 mag_out pulses per block (one per
// axis,bin pair), each tagged with its frequency bin (mag_bin_idx) AND the
// physical axis (mag_axis_idx). Axis attribution is now STRUCTURAL -- driven
// by the engine's own active_axis counter -- so it no longer depends on a
// separately-advancing axis index elsewhere.
//
//----------------------------------------------------------------------------
// SINGLE-MULTIPLIER GUARANTEE:
//   Every product in the chip flows through the ONE `multiplier` instance
//   below. In particular the final cross term C_k*v1*v2 is now computed on the
//   shared multiplier in a dedicated M_CV1V2 state (operand cv1_r, sv2),
//   instead of the previous inline `cv1_r * sv2` expression which synthesised
//   a SECOND hardware multiplier (violating Design Invariant #2). Routing it
//   through the shared unit additionally fixes a latent one-bin-stale bug in
//   the old code: there, mag_out was registered on the same edge cv1_r was
//   updated, so the cross term used the PREVIOUS bin's cv1. Here cv1_r is
//   captured in M_CV1_W and consumed one state later in M_CV1V2, so the term
//   is always for the current (axis,bin) pair.
//
// Radiation hardening (Rule C):
//   The magnitude FSM is triplicated (4-bit now: 9 states) with a bitwise
//   majority voter and a default -> M_IDLE recovery. Snapshot/scratch
//   registers are datapath (not triplicated), per design policy. The
//   multiplier holds no state.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module magnitude_compute #(
    parameter integer DATA_W = 24
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // shared multiplier: goertzel_core is the primary user; this module owns
    // the multiplier instance and services it, stealing idle cycles for mag.
    input  wire                       core_mult_req,
    input  wire signed [DATA_W-1:0]   core_mult_a,
    input  wire signed [DATA_W-1:0]   core_mult_b,
    output reg  signed [DATA_W-1:0]   core_mult_q,

    // goertzel_core state (sampled on block_clear_in): 3 axes x 3 bins.
    input  wire signed [DATA_W-1:0]   v1x_0, v2x_0, v1x_1, v2x_1, v1x_2, v2x_2,
    input  wire signed [DATA_W-1:0]   v1y_0, v2y_0, v1y_1, v2y_1, v1y_2, v2y_2,
    input  wire signed [DATA_W-1:0]   v1z_0, v2z_0, v1z_1, v2z_1, v1z_2, v2z_2,
    input  wire signed [DATA_W-1:0]   coeff_c0, coeff_c1, coeff_c2,

    // block boundary from fault_flagger (same cycle it drives block_clear)
    input  wire                       block_clear_in,

    // magnitude result stream to fault_flagger (9 pulses per block)
    output reg  [31:0]                mag_out,
    output reg  [1:0]                 mag_bin_idx,
    output reg  [1:0]                 mag_axis_idx,
    output reg                        mag_out_valid
);

    // ===================================================================
    // THE single shared multiplier (only `*` in the design lives inside it)
    // ===================================================================
    reg                     mag_mult_req;
    reg signed [DATA_W-1:0] mag_mult_a, mag_mult_b;

    // Arbitration: goertzel_core has priority; otherwise the mag engine drives.
    wire                      mult_req_w = core_mult_req | mag_mult_req;
    wire signed [DATA_W-1:0]  mult_a_w   = core_mult_req ? core_mult_a : mag_mult_a;
    wire signed [DATA_W-1:0]  mult_b_w   = core_mult_req ? core_mult_b : mag_mult_b;

    wire signed [2*DATA_W-1:0] mult_full;

    multiplier #(.DATA_W(DATA_W)) u_mult (
        .a (mult_a_w),
        .b (mult_b_w),
        .p (mult_full)
    );

    // ---- Q8.15 shift + saturate path (for C*v1, v1^2, v2^2, C*v1) ----
    wire signed [DATA_W+1:0]   mult_shifted = mult_full[2*DATA_W-1:DATA_W-2]; // >>15, keep DATA_W+2 bits

    localparam signed [DATA_W-1:0] MQ_MAX = {1'b0, {(DATA_W-1){1'b1}}};
    localparam signed [DATA_W-1:0] MQ_MIN = {1'b1, {(DATA_W-1){1'b0}}};

    wire ovf_pos = (mult_shifted > $signed({{2{1'b0}}, MQ_MAX}));
    wire ovf_neg = (mult_shifted < $signed({{2{MQ_MIN[DATA_W-1]}}, MQ_MIN}));
    wire signed [DATA_W-1:0] mult_sat = ovf_pos ? MQ_MAX : ovf_neg ? MQ_MIN : mult_shifted[DATA_W-1:0];

    // Same-cycle capture of the saturated product (bug history: capturing one
    // cycle late reads mult_sat after the requesting FSM's operands have fallen
    // back to 0, silently losing every magnitude multiply -- see CHANGELOG).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_mult_q <= {DATA_W{1'b0}};
        end else if (mult_req_w) begin
            core_mult_q <= mult_sat;
        end
    end

    // ===================================================================
    // Snapshot on block_clear_in: 3 axes x 3 bins of v1/v2, plus the 3
    // (axis-shared) coefficients. Captured before goertzel_core zeros them.
    // ===================================================================
    reg signed [DATA_W-1:0] sv1 [0:2][0:2]; // sv1[axis][bin]
    reg signed [DATA_W-1:0] sv2 [0:2][0:2]; // sv2[axis][bin]
    reg signed [DATA_W-1:0] sc  [0:2];       // coefficient per bin (shared by all axes)

    integer ai, bi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ai=0; ai<3; ai=ai+1)
                for (bi=0; bi<3; bi=bi+1) begin
                    sv1[ai][bi] <= {DATA_W{1'b0}};
                    sv2[ai][bi] <= {DATA_W{1'b0}};
                end
            sc[0] <= {DATA_W{1'b0}}; sc[1] <= {DATA_W{1'b0}}; sc[2] <= {DATA_W{1'b0}};
        end else if (block_clear_in) begin
            // X axis
            sv1[0][0]<=v1x_0; sv1[0][1]<=v1x_1; sv1[0][2]<=v1x_2;
            sv2[0][0]<=v2x_0; sv2[0][1]<=v2x_1; sv2[0][2]<=v2x_2;
            // Y axis
            sv1[1][0]<=v1y_0; sv1[1][1]<=v1y_1; sv1[1][2]<=v1y_2;
            sv2[1][0]<=v2y_0; sv2[1][1]<=v2y_1; sv2[1][2]<=v2y_2;
            // Z axis
            sv1[2][0]<=v1z_0; sv1[2][1]<=v1z_1; sv1[2][2]<=v1z_2;
            sv2[2][0]<=v2z_0; sv2[2][1]<=v2z_1; sv2[2][2]<=v2z_2;
            // shared coefficients
            sc[0]<=coeff_c0; sc[1]<=coeff_c1; sc[2]<=coeff_c2;
        end
    end

    // ===================================================================
    // Magnitude FSM: 9 (axis,bin) pairs x {v1^2, v2^2, C*v1, C*v1*v2}.
    // 9 states -> 4-bit encoding, triplicated per Rule C (a hung mag FSM
    // would hold the shared multiplier indefinitely).
    // ===================================================================
    localparam [3:0]
        M_IDLE  = 4'd0, M_ARM    = 4'd1,
        M_SQV1  = 4'd2, M_SQV1_W = 4'd3,
        M_SQV2  = 4'd4, M_SQV2_W = 4'd5,
        M_CV1   = 4'd6, M_CV1_W  = 4'd7,
        M_CV1V2 = 4'd8;

    function automatic [3:0] vote4;
        input [3:0] a,b,c;
        begin vote4=(a&b)|(b&c)|(a&c); end
    endfunction

    (* keep = "true" *) reg [3:0] ms_a, ms_b, ms_c;
    wire [3:0] ms_v = vote4(ms_a, ms_b, ms_c);
    reg [3:0] ms_next;

    reg [1:0] active_axis;  // 0=X,1=Y,2=Z
    reg [1:0] active_bin;   // 0..2

    wire last_pair = (active_axis==2'd2) && (active_bin==2'd2);

    always @(*) begin
        ms_next = ms_v;
        case (ms_v)
            M_IDLE  : ms_next = block_clear_in ? M_ARM : M_IDLE;
            M_ARM   : ms_next = M_SQV1;
            M_SQV1  : ms_next = M_SQV1_W;
            M_SQV1_W: ms_next = M_SQV2;
            M_SQV2  : ms_next = M_SQV2_W;
            M_SQV2_W: ms_next = M_CV1;
            M_CV1   : ms_next = M_CV1_W;
            M_CV1_W : ms_next = M_CV1V2;
            M_CV1V2 : ms_next = last_pair ? M_IDLE : M_SQV1;
            default : ms_next = M_IDLE; // SEU-safe
        endcase
    end

    reg signed [DATA_W-1:0] sq_v1_r, sq_v2_r, cv1_r;

    // Drive the shared multiplier from the mag FSM. Operands isolated to 0
    // in all non-MUL states so the shared unit stays frozen.
    always @(*) begin
        mag_mult_req = 1'b0; mag_mult_a = {DATA_W{1'b0}}; mag_mult_b = {DATA_W{1'b0}};
        case (ms_v)
            M_SQV1 : begin mag_mult_req=1'b1; mag_mult_a=sv1[active_axis][active_bin]; mag_mult_b=sv1[active_axis][active_bin]; end
            M_SQV2 : begin mag_mult_req=1'b1; mag_mult_a=sv2[active_axis][active_bin]; mag_mult_b=sv2[active_axis][active_bin]; end
            M_CV1  : begin mag_mult_req=1'b1; mag_mult_a=sc[active_bin];               mag_mult_b=sv1[active_axis][active_bin]; end
            M_CV1V2: begin mag_mult_req=1'b1; mag_mult_a=cv1_r;                        mag_mult_b=sv2[active_axis][active_bin]; end
            default: ;
        endcase
    end

    // In M_CV1V2 the shared multiplier computes cv1_r*sv2; consume its full
    // product combinationally this cycle (>>15, keep DATA_W+1 bits).
    wire signed [DATA_W:0] cv1v2_q15 = mult_full[2*DATA_W-1:DATA_W-1];

    wire signed [DATA_W+1:0] mag_sq_ext =
        $signed({2'b0, sq_v1_r}) +
        $signed({2'b0, sq_v2_r}) -
        $signed({cv1v2_q15[DATA_W], cv1v2_q15});

    wire mag_neg  = mag_sq_ext[DATA_W+1];
    // mag_sq_ext is DATA_W+2=26 bits -- always fits in 32 bits unsigned, so no
    // positive overflow is possible; just clamp negative (numerical) to 0.
    wire [31:0] mag_sq_u = mag_neg ? 32'd0 : {{(32-DATA_W-2){1'b0}}, mag_sq_ext};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_a<=M_IDLE; ms_b<=M_IDLE; ms_c<=M_IDLE;
            active_axis<=2'd0; active_bin<=2'd0;
            sq_v1_r<=0; sq_v2_r<=0; cv1_r<=0;
            mag_out<=0; mag_bin_idx<=0; mag_axis_idx<=0; mag_out_valid<=0;
        end else begin
            ms_a<=ms_next; ms_b<=ms_next; ms_c<=ms_next;
            mag_out_valid<=1'b0;
            case (ms_v)
                M_IDLE  : if (block_clear_in) begin active_axis<=2'd0; active_bin<=2'd0; end
                M_SQV1_W: sq_v1_r <= core_mult_q;   // v1^2 (saturated Q8.15)
                M_SQV2_W: sq_v2_r <= core_mult_q;   // v2^2
                M_CV1_W : cv1_r   <= core_mult_q;   // C*v1 (used next state)
                M_CV1V2 : begin
                    // cv1_r*sv2 available combinationally on mult_full now.
                    mag_out       <= mag_sq_u;
                    mag_bin_idx   <= active_bin;
                    mag_axis_idx  <= active_axis;
                    mag_out_valid <= 1'b1;
                    // advance (axis,bin): bins 0..2 then next axis
                    if (active_bin==2'd2) begin
                        active_bin  <= 2'd0;
                        active_axis <= active_axis + 2'd1;
                    end else begin
                        active_bin  <= active_bin + 2'd1;
                    end
                end
                default:;
            endcase
        end
    end

endmodule
`default_nettype wire
