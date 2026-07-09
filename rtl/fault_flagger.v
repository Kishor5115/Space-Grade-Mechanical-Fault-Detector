//============================================================================
// fault_flagger.v
// Owns the 512-sample block counter (counts sample_done pulses, pulses
// block_clear every 512). Compares magnitude_compute's per-bin mag_out
// stream against cfg_threshold -- immediate trip, no debounce.
// fault_flag is sticky until cfg_fault_clear. fault_bin_latched/
// fault_axis_latched jointly identify which frequency bin AND which
// physical sensor axis (X/Y/Z) produced the tripping magnitude.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module fault_flagger #(
    parameter integer BLOCK_SIZE = 512
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sample_done,
    output reg         block_clear,

    input  wire [31:0] mag_in,
    input  wire [1:0]  mag_bin_idx,
    input  wire [1:0]  mag_axis_idx,
    input  wire        mag_in_valid,

    input  wire [31:0] cfg_threshold,
    input  wire        cfg_fault_clear,

    output reg         fault_flag,
    output reg  [31:0] fault_mag_latched,
    output reg  [1:0]  fault_bin_latched,
    output reg  [1:0]  fault_axis_latched
);

    localparam integer CNT_W = $clog2(BLOCK_SIZE);

    function automatic [CNT_W-1:0] vote_cnt;
        input [CNT_W-1:0] a, b, c;
        begin vote_cnt = (a&b)|(b&c)|(a&c); end
    endfunction

    // Triplicated block counter. Natural write rate = 26.667kHz (one
    // sample_done per IIS3DWB sample), so SEU exposure per write is
    // ~37.5us -- short enough that periodic scrubbing adds no meaningful
    // benefit over the voting already applied here.
    reg [CNT_W-1:0] cnt_a, cnt_b, cnt_c;
    wire [CNT_W-1:0] cnt_v = vote_cnt(cnt_a, cnt_b, cnt_c);
    wire block_boundary = sample_done && (cnt_v == BLOCK_SIZE - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_a<=0; cnt_b<=0; cnt_c<=0;
            block_clear<=1'b0;
        end else begin
            block_clear <= block_boundary;
            if (sample_done) begin
                if (cnt_v == BLOCK_SIZE - 1) begin
                    cnt_a<=0; cnt_b<=0; cnt_c<=0;
                end else begin
                    cnt_a<=cnt_v+1'b1; cnt_b<=cnt_v+1'b1; cnt_c<=cnt_v+1'b1;
                end
            end
        end
    end

    // Magnitude comparator -- immediate trip
    wire over = mag_in_valid && (mag_in > cfg_threshold);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_flag        <= 1'b0;
            fault_mag_latched <= 32'd0;
            fault_bin_latched <= 2'd0;
            fault_axis_latched<= 2'd0;
        end else begin
            if (cfg_fault_clear)   fault_flag <= 1'b0;
            if (over && !fault_flag) begin
                fault_flag        <= 1'b1;
                fault_mag_latched <= mag_in;
                fault_bin_latched <= mag_bin_idx;
                fault_axis_latched<= mag_axis_idx;
            end
        end
    end

endmodule
`default_nettype wire