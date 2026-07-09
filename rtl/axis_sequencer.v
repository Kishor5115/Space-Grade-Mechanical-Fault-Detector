//============================================================================
// axis_sequencer.v
// Polls spi_apb_interface STATUS/SAMPLE0/SAMPLE1 for each new sensor
// sample, then feeds the active-axis slice to goertzel_core. Advances
// current_axis every block_clear_pulse (X->Y->Z->X).
// Radiation hardening: pstate triplicated (all copies driven from voted
// next-state so no copy self-diverges); axis index triplicated + scrubbed
// every 1024 cycles.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module axis_sequencer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        run_enable,

    // spi_apb_interface local register port
    output reg         req_valid,
    output reg         req_write,
    output reg  [31:0] req_addr,
    output reg  [31:0] req_wdata,
    input  wire        req_done,
    input  wire [31:0] resp_rdata,

    // to goertzel_core
    output reg         core_data_ready,
    output reg  [15:0] core_x_n,

    // block boundary
    input  wire        block_clear_pulse,
    output reg  [1:0]  current_axis
);

    localparam ADDR_STATUS  = 32'h0;
    localparam ADDR_SAMPLE0 = 32'h4;
    localparam ADDR_SAMPLE1 = 32'h8;

    // ---- voting functions ----
    function automatic [2:0] vote3;
        input [2:0] a,b,c; begin vote3=(a&b)|(b&c)|(a&c); end
    endfunction
    function automatic [1:0] vote2;
        input [1:0] a,b,c; begin vote2=(a&b)|(b&c)|(a&c); end
    endfunction

    // ---- axis index: triplicated + 1024-cycle scrub ----
    localparam integer SCRUB_W = 10; // 2^10 = 1024
    reg [SCRUB_W-1:0] scrub_cnt;
    reg               scrub_strobe;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scrub_cnt<=0; scrub_strobe<=0; end
        else begin
            scrub_strobe <= (scrub_cnt == {SCRUB_W{1'b1}});
            scrub_cnt    <= scrub_cnt + 1'b1;
        end
    end

    reg [1:0] axis_a, axis_b, axis_c;
    wire [1:0] axis_v = vote2(axis_a, axis_b, axis_c);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axis_a<=0; axis_b<=0; axis_c<=0;
        end else if (block_clear_pulse) begin
            // real write wins over scrub
            if (axis_v==2'd2) begin axis_a<=0; axis_b<=0; axis_c<=0; end
            else begin axis_a<=axis_v+2'd1; axis_b<=axis_v+2'd1; axis_c<=axis_v+2'd1; end
        end else if (scrub_strobe) begin
            axis_a<=axis_v; axis_b<=axis_v; axis_c<=axis_v;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_axis<=2'd0;
        else        current_axis<=axis_v;
    end

    // ---- polling FSM: triplicated pstate ----
    localparam [2:0]
        S_IDLE=3'd0, S_POLL_REQ=3'd1, S_POLL_WAIT=3'd2,
        S_S0_REQ=3'd3, S_S0_WAIT=3'd4,
        S_S1_REQ=3'd5, S_S1_WAIT=3'd6, S_PRESENT=3'd7;

    reg [2:0] ps_a, ps_b, ps_c;
    wire [2:0] ps_v = vote3(ps_a, ps_b, ps_c);
    reg [2:0]  ps_next;

    // next-state computed ONLY from ps_v (voted), so a flipped copy
    // gets corrected next cycle rather than self-diverging
    always @(*) begin
        ps_next = ps_v;
        if (!run_enable) begin
            ps_next = S_IDLE;
        end else case (ps_v)
            S_IDLE     : ps_next = S_POLL_REQ;
            S_POLL_REQ : ps_next = S_POLL_WAIT;
            S_POLL_WAIT: ps_next = req_done ? (resp_rdata[0] ? S_S0_REQ : S_POLL_REQ) : S_POLL_WAIT;
            S_S0_REQ   : ps_next = S_S0_WAIT;
            S_S0_WAIT  : ps_next = req_done ? S_S1_REQ  : S_S0_WAIT;
            S_S1_REQ   : ps_next = S_S1_WAIT;
            S_S1_WAIT  : ps_next = req_done ? S_PRESENT : S_S1_WAIT;
            S_PRESENT  : ps_next = S_POLL_REQ;
            default    : ps_next = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ps_a<=S_IDLE; ps_b<=S_IDLE; ps_c<=S_IDLE; end
        else begin ps_a<=ps_next; ps_b<=ps_next; ps_c<=ps_next; end
    end

    // ---- datapath ----
    reg [31:0] sample0_r;
    reg [47:0] burst_r;

    reg [15:0] xn_comb;
    always @(*) begin
        // spi_master's RX_DATA shifts bytes in via a 48-bit left
        // shift-in register (s_data_out <= {s_data_out[46:0],bit}),
        // MSb-of-each-byte first, burst order OUTX_L, OUTX_H, OUTY_L,
        // OUTY_H, OUTZ_L, OUTZ_H (datasheet auto-increment burst read
        // starting at OUTX_L_A). Tracing the shift explicitly: the
        // EARLIEST-arriving byte (OUTX_L) is shifted the MOST times by
        // the time all 48 bits have arrived, so it ends up at the
        // TOP of the register, not the bottom. Final layout:
        //   s_data_out[47:32] = {OUTX_H, OUTX_L}  (X, arrived first)
        //   s_data_out[31:16] = {OUTY_H, OUTY_L}  (Y, arrived middle)
        //   s_data_out[15:0]  = {OUTZ_H, OUTZ_L}  (Z, arrived last)
        // (Verified against iis3dwb_model.v's burst_payload byte
        // order and cross-checked live in tb_top.v against
        // model_outx/y/z.)
        case (axis_v)
            2'd0: xn_comb = burst_r[47:32]; // X
            2'd1: xn_comb = burst_r[31:16]; // Y
            default: xn_comb = burst_r[15:0]; // Z
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_valid<=0; req_write<=0; req_addr<=0; req_wdata<=0;
            sample0_r<=0; burst_r<=0;
            core_data_ready<=0; core_x_n<=0;
        end else begin
            req_valid<=1'b0; core_data_ready<=1'b0;
            case (ps_v)
                S_POLL_REQ: begin req_valid<=1'b1; req_write<=0; req_addr<=ADDR_STATUS; end
                S_S0_REQ  : begin req_valid<=1'b1; req_write<=0; req_addr<=ADDR_SAMPLE0; end
                S_S0_WAIT : if (req_done) sample0_r<=resp_rdata;
                S_S1_REQ  : begin req_valid<=1'b1; req_write<=0; req_addr<=ADDR_SAMPLE1; end
                S_S1_WAIT : if (req_done) burst_r<={resp_rdata[15:0], sample0_r};
                S_PRESENT : begin core_data_ready<=1'b1; core_x_n<=xn_comb; end
                default:;
            endcase
        end
    end

endmodule
`default_nettype wire