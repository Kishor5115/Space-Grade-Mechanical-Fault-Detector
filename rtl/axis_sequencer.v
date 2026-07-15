//============================================================================
// axis_sequencer.v  (ITAG variant)
// Polls spi_apb_interface STATUS/SAMPLE0/SAMPLE1 for each new sensor burst,
// then presents ALL THREE axis slices (X, Y, Z) simultaneously to
// goertzel_core. Under the Interleaved Tri-Axis Goertzel (ITAG) architecture
// the core processes all three axes every sample, so this module no longer
// rotates a "current axis" across blocks -- the entire axis-index tracking,
// its triplication, and its 1024-cycle scrub are DELETED. The sensor burst
// already carries X/Y/Z together; we simply stop discarding Y and Z.
//
// Radiation hardening: the polling FSM (pstate) remains triplicated (all
// copies driven from the voted next-state so no copy self-diverges). There is
// no longer a multi-bit axis index to scrub -- removing it also removes that
// SEU attack surface.
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

    // to goertzel_core: all three axes presented together (ITAG)
    output reg         core_data_ready,
    output reg  [15:0] core_x_n,   // X-axis slice of the burst
    output reg  [15:0] core_y_n,   // Y-axis slice of the burst
    output reg  [15:0] core_z_n    // Z-axis slice of the burst
);

    localparam ADDR_STATUS  = 32'h0;
    localparam ADDR_SAMPLE0 = 32'h4;
    localparam ADDR_SAMPLE1 = 32'h8;

    // ---- voting function ----
    function automatic [2:0] vote3;
        input [2:0] a,b,c; begin vote3=(a&b)|(b&c)|(a&c); end
    endfunction

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

    // Burst layout (verified against iis3dwb_model.v + tb_top.v):
    //   spi_master shifts each arriving bit into a 48-bit left shift-in
    //   register, MSb-of-each-byte first, in datasheet auto-increment burst
    //   order OUTX_L, OUTX_H, OUTY_L, OUTY_H, OUTZ_L, OUTZ_H. The
    //   EARLIEST-arriving byte (OUTX_L) is shifted the MOST, so it ends up at
    //   the TOP of the register. Final layout:
    //     burst_r[47:32] = {OUTX_H, OUTX_L}  (X, arrived first)
    //     burst_r[31:16] = {OUTY_H, OUTY_L}  (Y, arrived middle)
    //     burst_r[15:0]  = {OUTZ_H, OUTZ_L}  (Z, arrived last)
    // Under ITAG all three slices are presented at once (no axis mux).

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_valid<=0; req_write<=0; req_addr<=0; req_wdata<=0;
            sample0_r<=0; burst_r<=0;
            core_data_ready<=0; core_x_n<=0; core_y_n<=0; core_z_n<=0;
        end else begin
            req_valid<=1'b0; core_data_ready<=1'b0;
            case (ps_v)
                S_POLL_REQ: begin req_valid<=1'b1; req_write<=0; req_addr<=ADDR_STATUS; end
                S_S0_REQ  : begin req_valid<=1'b1; req_write<=0; req_addr<=ADDR_SAMPLE0; end
                S_S0_WAIT : if (req_done) sample0_r<=resp_rdata;
                S_S1_REQ  : begin req_valid<=1'b1; req_write<=0; req_addr<=ADDR_SAMPLE1; end
                S_S1_WAIT : if (req_done) burst_r<={resp_rdata[15:0], sample0_r};
                S_PRESENT : begin
                    core_data_ready<=1'b1;
                    core_x_n<=burst_r[47:32]; // X
                    core_y_n<=burst_r[31:16]; // Y
                    core_z_n<=burst_r[15:0];  // Z
                end
                default:;
            endcase
        end
    end

endmodule
`default_nettype wire
