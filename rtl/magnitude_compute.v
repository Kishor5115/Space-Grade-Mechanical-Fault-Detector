//============================================================================
// magnitude_compute.v
// Services goertzel_core's shared multiplier (mult_req/mult_a/mult_b/mult_q)
// and computes mag_sq_k = v1_k^2 + v2_k^2 - C_k*v1_k*v2_k once per block,
// triggered by block_clear_in (snapshotting v1/v2 before goertzel_core
// zeros them on that same edge). Outputs one mag_out pulse per bin (3
// per block) to fault_flagger, tagged with BOTH the frequency-bin index
// (mag_bin_idx, 0-2) and the sensor axis that produced the block
// (mag_axis_idx, 0=X/1=Y/2=Z) -- axis_sequencer already computes
// current_axis for its own multiplexing but nothing downstream consumed
// it before, so a fault could not be attributed to a physical axis.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module magnitude_compute #(
    parameter integer DATA_W = 24
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // shared multiplier: goertzel_core is the primary user;
    // this module services it and steals idle cycles for mag computation
    input  wire                       core_mult_req,
    input  wire signed [DATA_W-1:0]   core_mult_a,
    input  wire signed [DATA_W-1:0]   core_mult_b,
    output reg  signed [DATA_W-1:0]   core_mult_q,

    // goertzel_core state (sampled on block_clear_in)
    input  wire signed [DATA_W-1:0]   v1_0, v2_0,
    input  wire signed [DATA_W-1:0]   v1_1, v2_1,
    input  wire signed [DATA_W-1:0]   v1_2, v2_2,
    input  wire signed [DATA_W-1:0]   coeff_c0, coeff_c1, coeff_c2,

    // which physical sensor axis (X=0/Y=1/Z=2) produced the block being
    // closed out this cycle -- sampled alongside v1/v2/coeff below so the
    // 3 mag_out pulses this block are correctly attributed even though
    // axis_sequencer may have already advanced current_axis by the time
    // they're computed.
    input  wire [1:0]                 axis_in,

    // block boundary from fault_flagger (same cycle it drives block_clear)
    input  wire                       block_clear_in,

    // magnitude result stream to fault_flagger (3 pulses per block)
    output reg  [31:0]                mag_out,
    output reg  [1:0]                 mag_bin_idx,
    output reg  [1:0]                 mag_axis_idx,
    output reg                        mag_out_valid
);

    // ---- shared multiplier (Q8.15 * Q8.15 -> Q8.15, saturated) ----
    reg                     mag_mult_req;
    reg signed [DATA_W-1:0] mag_mult_a, mag_mult_b;

    wire                      mult_req_w = core_mult_req | mag_mult_req;
    wire signed [DATA_W-1:0]  mult_a_w   = core_mult_req ? core_mult_a : mag_mult_a;
    wire signed [DATA_W-1:0]  mult_b_w   = core_mult_req ? core_mult_b : mag_mult_b;

    wire signed [2*DATA_W-1:0] mult_full    = mult_a_w * mult_b_w;
    wire signed [DATA_W+1:0]   mult_shifted = mult_full[2*DATA_W-1:DATA_W-2]; // >>15, keep DATA_W+2 bits

    localparam signed [DATA_W-1:0] MQ_MAX = {1'b0, {(DATA_W-1){1'b1}}};
    localparam signed [DATA_W-1:0] MQ_MIN = {1'b1, {(DATA_W-1){1'b0}}};

    wire ovf_pos = (mult_shifted > $signed({{2{1'b0}}, MQ_MAX}));
    wire ovf_neg = (mult_shifted < $signed({{2{MQ_MIN[DATA_W-1]}}, MQ_MIN}));
    wire signed [DATA_W-1:0] mult_sat = ovf_pos ? MQ_MAX : ovf_neg ? MQ_MIN : mult_shifted[DATA_W-1:0];

    // Shared-multiplier pipeline register: goertzel_core's own mult_a/
    // mult_b are held stable by ITS output registers for the full MUL
    // state, but magnitude_compute's mag_mult_a/mag_mult_b are driven
    // combinationally and fall back to 0 the very next cycle (once
    // ms_v leaves M_SQV1/M_SQV2/M_CV1). So core_mult_q must capture
    // mult_sat in the SAME cycle the request is asserted (mult_req_w),
    // not one cycle later -- gating on a delayed mult_req_d would read
    // mult_sat after the requesting FSM's operands (and thus mult_sat
    // itself) had already fallen back to 0, silently losing every
    // magnitude multiply (bug found via tb_top.v: mag_out was always 0
    // despite nonzero v1/v2 state feeding the block).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_mult_q <= {DATA_W{1'b0}};
        end else if (mult_req_w) begin
            core_mult_q <= mult_sat;
        end
    end

    // ---- snapshot on block_clear_in ----
    reg signed [DATA_W-1:0] sv1 [0:2];
    reg signed [DATA_W-1:0] sv2 [0:2];
    reg signed [DATA_W-1:0] sc  [0:2];
    reg [1:0] saxis; // axis snapshot: single 2-bit reg, not per-bin (all
                      // 3 bins in a block share the same axis)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sv1[0]<=0; sv1[1]<=0; sv1[2]<=0;
            sv2[0]<=0; sv2[1]<=0; sv2[2]<=0;
            sc[0] <=0; sc[1] <=0; sc[2] <=0;
            saxis <=0;
        end else if (block_clear_in) begin
            sv1[0]<=v1_0; sv1[1]<=v1_1; sv1[2]<=v1_2;
            sv2[0]<=v2_0; sv2[1]<=v2_1; sv2[2]<=v2_2;
            sc[0] <=coeff_c0; sc[1]<=coeff_c1; sc[2]<=coeff_c2;
            saxis <=axis_in;
        end
    end

    // ---- magnitude FSM: 3 bins x 3 multiplies each ----
    // States reused across bins via active_bin; triplicated per Rule C
    // (a hung mag FSM holds the shared multiplier indefinitely)
    localparam [2:0]
        M_IDLE=3'd0, M_ARM=3'd1,
        M_SQV1=3'd2, M_SQV1_W=3'd3,
        M_SQV2=3'd4, M_SQV2_W=3'd5,
        M_CV1 =3'd6, M_CV1_W =3'd7;

    function automatic [2:0] vote3;
        input [2:0] a,b,c;
        begin vote3=(a&b)|(b&c)|(a&c); end
    endfunction

    reg [2:0] ms_a, ms_b, ms_c;
    wire [2:0] ms_v = vote3(ms_a, ms_b, ms_c);
    reg [2:0] ms_next;
    reg [1:0] active_bin;

    always @(*) begin
        ms_next = ms_v;
        case (ms_v)
            M_IDLE : ms_next = block_clear_in ? M_ARM   : M_IDLE;
            M_ARM  : ms_next = M_SQV1;
            M_SQV1 : ms_next = M_SQV1_W;
            M_SQV1_W: ms_next = M_SQV2;
            M_SQV2 : ms_next = M_SQV2_W;
            M_SQV2_W: ms_next = M_CV1;
            M_CV1  : ms_next = M_CV1_W;
            M_CV1_W: ms_next = (active_bin==2'd2) ? M_IDLE : M_SQV1;
            default: ms_next = M_IDLE;
        endcase
    end

    reg signed [DATA_W-1:0] sq_v1_r, sq_v2_r, cv1_r;

    // drive shared multiplier from mag FSM
    always @(*) begin
        mag_mult_req = 1'b0; mag_mult_a = 0; mag_mult_b = 0;
        case (ms_v)
            M_SQV1: begin mag_mult_req=1'b1; mag_mult_a=sv1[active_bin]; mag_mult_b=sv1[active_bin]; end
            M_SQV2: begin mag_mult_req=1'b1; mag_mult_a=sv2[active_bin]; mag_mult_b=sv2[active_bin]; end
            M_CV1 : begin mag_mult_req=1'b1; mag_mult_a=sc[active_bin];  mag_mult_b=sv1[active_bin]; end
            default: ;
        endcase
    end

    // cv1*v2 final step: combinational extra multiply off shared bus
    wire signed [2*DATA_W-1:0] cv1v2_full = $signed(cv1_r) * $signed(sv2[active_bin]);
    wire signed [DATA_W:0]     cv1v2_q15  = cv1v2_full[2*DATA_W-1:DATA_W-1]; // >>15

    wire signed [DATA_W+1:0] mag_sq_ext =
        $signed({2'b0, sq_v1_r}) +
        $signed({2'b0, sq_v2_r}) -
        $signed({cv1v2_q15[DATA_W], cv1v2_q15});

    wire mag_neg  = mag_sq_ext[DATA_W+1];
    // mag_sq_ext is DATA_W+2=26 bits -- always fits in 32 bits unsigned,
    // so no positive overflow is possible; just clamp negative to 0.
    wire [31:0] mag_sq_u = mag_neg ? 32'd0 : {{(32-DATA_W-2){1'b0}}, mag_sq_ext};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_a<=M_IDLE; ms_b<=M_IDLE; ms_c<=M_IDLE;
            active_bin<=2'd0;
            sq_v1_r<=0; sq_v2_r<=0; cv1_r<=0;
            mag_out<=0; mag_bin_idx<=0; mag_axis_idx<=0; mag_out_valid<=0;
        end else begin
            ms_a<=ms_next; ms_b<=ms_next; ms_c<=ms_next;
            mag_out_valid<=1'b0;
            case (ms_v)
                M_IDLE  : if (block_clear_in) active_bin<=2'd0;
                M_SQV1_W: sq_v1_r <= core_mult_q;
                M_SQV2_W: sq_v2_r <= core_mult_q;
                M_CV1_W : begin
                    cv1_r <= core_mult_q;
                    mag_out       <= mag_sq_u;
                    mag_bin_idx   <= active_bin;
                    mag_axis_idx  <= saxis;
                    mag_out_valid <= 1'b1;
                    active_bin    <= active_bin + 2'd1;
                end
                default:;
            endcase
        end
    end

endmodule
`default_nettype wire