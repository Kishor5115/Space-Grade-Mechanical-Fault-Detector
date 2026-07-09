//============================================================================
// top.v -- Space-Grade Vibration Pattern Anomaly Detector
// Integrates: spi_apb_interface (owns spi_master), axis_sequencer,
// goertzel_core, magnitude_compute, fault_flagger, tmr_reg_bank, apb
//============================================================================
`timescale 1ns/1ps
`default_nettype none



module top (
    input  wire        clk,
    input  wire        sys_rst_n,

    // IIS3DWB sensor SPI pins
    input  wire        c_miso,
    output wire        c_csn,
    output wire        c_sclk,
    output wire        c_mosi,

    // DRDY interrupt from sensor
    input  wire        sensor_drdy,

    // tmr_forward_en: 0=Option A (local read only), 1=Option B (also
    // push samples to tmr_reg_bank over apb)
    input  wire        tmr_forward_en,

    // Fault output to RISC core
    output wire        fault_flag_out
);

    // ----------------------------------------------------------------
    // spi_apb_interface: owns spi_master internally, exposes APB master
    // bus toward tmr_reg_bank AND a local req_* port for axis_sequencer
    // ----------------------------------------------------------------
    // axis_sequencer polls spi_apb_interface's local STATUS/SAMPLE0/1
    wire        seq_req_valid, seq_req_write, seq_req_done;
    wire [31:0] seq_req_addr, seq_req_wdata, seq_resp_rdata;

    // APB master bus wires (spi_apb_interface -> tmr_reg_bank)
    wire        apb_pwrite, apb_psel, apb_penable;
    wire [31:0] apb_p_addr, apb_pwdata, apb_prdata;
    wire        apb_pready;

    // tmr_sample_base: where Option B forwards sensor samples in tmr_reg_bank
    // Using 0x20 to sit after the existing reg map (0x00-0x1C)
    localparam [31:0] TMR_SAMPLE_BASE = 32'h20;

    spi_apb_interface spi_apb_inst (
        .clk               (clk),
        .sys_rst_n         (sys_rst_n),
        .tmr_forward_en    (tmr_forward_en),
        .tmr_sample_base   (TMR_SAMPLE_BASE),
        // axis_sequencer polling port
        .req_valid         (seq_req_valid),
        .req_write         (seq_req_write),
        .req_addr          (seq_req_addr),
        .req_wdata         (seq_req_wdata),
        .req_done          (seq_req_done),
        .resp_rdata        (seq_resp_rdata),
        // APB master bus to tmr_reg_bank
        .prdata            (apb_prdata),
        .pready            (apb_pready),
        .pwrite            (apb_pwrite),
        .p_addr            (apb_p_addr),
        .pwdata            (apb_pwdata),
        .psel              (apb_psel),
        .penable           (apb_penable),
        // sensor SPI
        .s_miso            (c_miso),
        .s_csn             (c_csn),
        .s_clk             (c_sclk),
        .s_mosi            (c_mosi),
        .sync_data_ready_trig(sensor_drdy)
    );

    // ----------------------------------------------------------------
    // tmr_reg_bank: APB slave, triplicated config + status
    // ----------------------------------------------------------------
    wire [23:0] cfg_c0, cfg_c1, cfg_c2;
    wire [31:0] cfg_threshold;
    wire        cfg_start, cfg_stop, cfg_fault_clear, run_enable;
    wire        fault_flag;
    wire [31:0] fault_mag_latched;
    wire [1:0]  fault_bin_latched;
    wire [1:0]  fault_axis_latched;

    tmr_reg_bank tmr_inst (
        .clk               (clk),
        .rst_n             (sys_rst_n),
        .p_addr            (apb_p_addr),
        .pwdata            (apb_pwdata),
        .psel              (apb_psel),
        .pwrite            (apb_pwrite),
        .penable           (apb_penable),
        .prdata            (apb_prdata),
        .pready            (apb_pready),
        .cfg_c0            (cfg_c0),
        .cfg_c1            (cfg_c1),
        .cfg_c2            (cfg_c2),
        .cfg_threshold     (cfg_threshold),
        .cfg_start         (cfg_start),
        .cfg_stop          (cfg_stop),
        .cfg_fault_clear   (cfg_fault_clear),
        .run_enable        (run_enable),
        .fault_flag        (fault_flag),
        .fault_mag_latched (fault_mag_latched),
        .fault_bin_latched (fault_bin_latched),
        .fault_axis_latched(fault_axis_latched)
    );

    // ----------------------------------------------------------------
    // axis_sequencer: polls spi_apb_interface, feeds goertzel_core
    // ----------------------------------------------------------------
    wire        core_data_ready;
    wire [15:0] core_x_n;
    wire        block_clear;
    wire [1:0]  current_axis;

    axis_sequencer axseq_inst (
        .clk               (clk),
        .rst_n             (sys_rst_n),
        .run_enable        (run_enable),
        .req_valid         (seq_req_valid),
        .req_write         (seq_req_write),
        .req_addr          (seq_req_addr),
        .req_wdata         (seq_req_wdata),
        .req_done          (seq_req_done),
        .resp_rdata        (seq_resp_rdata),
        .core_data_ready   (core_data_ready),
        .core_x_n          (core_x_n),
        .block_clear_pulse (block_clear),
        .current_axis      (current_axis)
    );

    // ----------------------------------------------------------------
    // goertzel_core: shared-multiplier interface wired to magnitude_compute
    // ----------------------------------------------------------------
    wire        mult_req;
    wire signed [23:0] mult_a, mult_b, mult_q;
    wire signed [23:0] v1_0, v2_0, v1_1, v2_1, v1_2, v2_2;
    wire        sample_done;

    goertzel_core #(
        .DATA_W  (24),
        .SAMPLE_W(16),
        .N_BINS  (3)
    ) goertzel_inst (
        .clk        (clk),
        .rst_n      (sys_rst_n),
        .enable     (run_enable),
        .data_ready (core_data_ready),
        .x_n        (core_x_n),
        .coeff_c0   ($signed(cfg_c0)),
        .coeff_c1   ($signed(cfg_c1)),
        .coeff_c2   ($signed(cfg_c2)),
        .block_clear(block_clear),
        .mult_req   (mult_req),
        .mult_a     (mult_a),
        .mult_b     (mult_b),
        .mult_q     (mult_q),
        .v1_0(v1_0),.v2_0(v2_0),
        .v1_1(v1_1),.v2_1(v2_1),
        .v1_2(v1_2),.v2_2(v2_2),
        .sample_done(sample_done)
    );

    // ----------------------------------------------------------------
    // magnitude_compute: services shared multiplier + computes mag per block
    // ----------------------------------------------------------------
    wire [31:0] mag_out;
    wire [1:0]  mag_bin_idx;
    wire [1:0]  mag_axis_idx;
    wire        mag_out_valid;

    magnitude_compute #(.DATA_W(24)) mag_inst (
        .clk          (clk),
        .rst_n        (sys_rst_n),
        .core_mult_req(mult_req),
        .core_mult_a  (mult_a),
        .core_mult_b  (mult_b),
        .core_mult_q  (mult_q),
        .v1_0(v1_0),.v2_0(v2_0),
        .v1_1(v1_1),.v2_1(v2_1),
        .v1_2(v1_2),.v2_2(v2_2),
        .coeff_c0     ($signed(cfg_c0)),
        .coeff_c1     ($signed(cfg_c1)),
        .coeff_c2     ($signed(cfg_c2)),
        .axis_in      (current_axis),
        .block_clear_in(block_clear),
        .mag_out      (mag_out),
        .mag_bin_idx  (mag_bin_idx),
        .mag_axis_idx (mag_axis_idx),
        .mag_out_valid(mag_out_valid)
    );

    // ----------------------------------------------------------------
    // fault_flagger: block counter + magnitude comparator
    // ----------------------------------------------------------------
    fault_flagger #(.BLOCK_SIZE(512)) ff_inst (
        .clk              (clk),
        .rst_n            (sys_rst_n),
        .sample_done      (sample_done),
        .block_clear      (block_clear),
        .mag_in           (mag_out),
        .mag_bin_idx      (mag_bin_idx),
        .mag_axis_idx     (mag_axis_idx),
        .mag_in_valid     (mag_out_valid),
        .cfg_threshold    (cfg_threshold),
        .cfg_fault_clear  (cfg_fault_clear),
        .fault_flag       (fault_flag),
        .fault_mag_latched(fault_mag_latched),
        .fault_bin_latched(fault_bin_latched),
        .fault_axis_latched(fault_axis_latched)
    );

    assign fault_flag_out = fault_flag;

endmodule
`default_nettype wire