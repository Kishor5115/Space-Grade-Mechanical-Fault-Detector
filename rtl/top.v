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

    // External command-SPI bus (host/RISC-V -> chip): write-only config
    // channel for Goertzel coefficients, threshold, and control. Sampled
    // asynchronously and 2-FF synchronized into the clk domain (single-clock,
    // oversampled receiver -- see cmd_spi_slave.v). Host must clock cmd_sclk
    // at <= clk/4 (<= 4 MHz at 16 MHz). Tie cmd_csn high if unused.
    input  wire        cmd_sclk,
    input  wire        cmd_csn,
    input  wire        cmd_mosi,

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

    // APB master bus wires (spi_apb_interface Option-B forwarder -> arbiter m0)
    wire        fwd_apb_pwrite, fwd_apb_psel, fwd_apb_penable;
    wire [31:0] fwd_apb_p_addr, fwd_apb_pwdata;
    wire        fwd_apb_pready;
    wire [31:0] fwd_apb_prdata;

    // Command-SPI config APB master bus (cmd apb master -> arbiter m1)
    wire        cmd_apb_pwrite, cmd_apb_psel, cmd_apb_penable;
    wire [31:0] cmd_apb_p_addr, cmd_apb_pwdata;
    wire        cmd_apb_pready;
    wire [31:0] cmd_apb_prdata;

    // Arbitrated APB slave bus (arbiter -> tmr_reg_bank). NOTE: these net
    // names are kept as apb_* because the top-level testbench drives config
    // by force/release on exactly these wires (a stand-in for the command-SPI
    // host); the command-SPI path drives them for real in silicon.
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
        // APB master bus to tmr_reg_bank (via arbiter, Option-B forwarder path)
        .prdata            (fwd_apb_prdata),
        .pready            (fwd_apb_pready),
        .pwrite            (fwd_apb_pwrite),
        .p_addr            (fwd_apb_p_addr),
        .pwdata            (fwd_apb_pwdata),
        .psel              (fwd_apb_psel),
        .penable           (fwd_apb_penable),
        // sensor SPI
        .s_miso            (c_miso),
        .s_csn             (c_csn),
        .s_clk             (c_sclk),
        .s_mosi            (c_mosi),
        .sync_data_ready_trig(sensor_drdy)
    );

    // ----------------------------------------------------------------
    // cmd_spi_slave: external host/RISC-V configuration receiver.
    // Oversampled, single-clock, write-only. Emits a req_* handshake that
    // its own apb master (cmd_apb_master) turns into APB writes.
    // ----------------------------------------------------------------
    wire        cmd_req_valid, cmd_req_write, cmd_req_done;
    wire [31:0] cmd_req_addr, cmd_req_wdata;
    wire [31:0] cmd_req_rdata_unused;

    cmd_spi_slave cmd_spi_inst (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .cmd_sclk  (cmd_sclk),
        .cmd_csn   (cmd_csn),
        .cmd_mosi  (cmd_mosi),
        .req_valid (cmd_req_valid),
        .req_write (cmd_req_write),
        .req_addr  (cmd_req_addr),
        .req_wdata (cmd_req_wdata),
        .req_done  (cmd_req_done)
    );

    apb cmd_apb_master (
        .clk        (clk),
        .sys_rst_n  (sys_rst_n),
        .req_valid  (cmd_req_valid),
        .req_write  (cmd_req_write),
        .req_addr   (cmd_req_addr),
        .req_wdata  (cmd_req_wdata),
        .req_done   (cmd_req_done),
        .resp_rdata (cmd_req_rdata_unused),
        .prdata     (cmd_apb_prdata),
        .pready     (cmd_apb_pready),
        .pwrite     (cmd_apb_pwrite),
        .p_addr     (cmd_apb_p_addr),
        .pwdata     (cmd_apb_pwdata),
        .psel       (cmd_apb_psel),
        .penable    (cmd_apb_penable)
    );

    // ----------------------------------------------------------------
    // apb_arb2: share the single tmr_reg_bank APB slave between the
    // Option-B sample forwarder (m0) and the command-SPI config path (m1).
    // ----------------------------------------------------------------
    apb_arb2 apb_arb_inst (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .m0_psel   (fwd_apb_psel),
        .m0_penable(fwd_apb_penable),
        .m0_pwrite (fwd_apb_pwrite),
        .m0_paddr  (fwd_apb_p_addr),
        .m0_pwdata (fwd_apb_pwdata),
        .m0_pready (fwd_apb_pready),
        .m0_prdata (fwd_apb_prdata),
        .m1_psel   (cmd_apb_psel),
        .m1_penable(cmd_apb_penable),
        .m1_pwrite (cmd_apb_pwrite),
        .m1_paddr  (cmd_apb_p_addr),
        .m1_pwdata (cmd_apb_pwdata),
        .m1_pready (cmd_apb_pready),
        .m1_prdata (cmd_apb_prdata),
        .s_psel    (apb_psel),
        .s_penable (apb_penable),
        .s_pwrite  (apb_pwrite),
        .s_paddr   (apb_p_addr),
        .s_pwdata  (apb_pwdata),
        .s_pready  (apb_pready),
        .s_prdata  (apb_prdata)
    );

    // ----------------------------------------------------------------
    // tmr_reg_bank: APB slave, triplicated config + status
    // ----------------------------------------------------------------
    wire signed [23:0] cfg_c0, cfg_c1, cfg_c2;
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
    wire [15:0] core_x_n, core_y_n, core_z_n;
    wire        block_clear;

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
        .core_y_n          (core_y_n),
        .core_z_n          (core_z_n)
    );

    // ----------------------------------------------------------------
    // goertzel_core: shared-multiplier interface wired to magnitude_compute
    // ----------------------------------------------------------------
    wire        mult_req;
    wire signed [23:0] mult_a, mult_b, mult_q;
    wire signed [23:0] v1x_0, v2x_0, v1x_1, v2x_1, v1x_2, v2x_2;
    wire signed [23:0] v1y_0, v2y_0, v1y_1, v2y_1, v1y_2, v2y_2;
    wire signed [23:0] v1z_0, v2z_0, v1z_1, v2z_1, v1z_2, v2z_2;
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
        .y_n        (core_y_n),
        .z_n        (core_z_n),
        .coeff_c0   (cfg_c0),
        .coeff_c1   (cfg_c1),
        .coeff_c2   (cfg_c2),
        .block_clear(block_clear),
        .mult_req   (mult_req),
        .mult_a     (mult_a),
        .mult_b     (mult_b),
        .mult_q     (mult_q),
        .v1x_0(v1x_0),.v2x_0(v2x_0),.v1x_1(v1x_1),.v2x_1(v2x_1),.v1x_2(v1x_2),.v2x_2(v2x_2),
        .v1y_0(v1y_0),.v2y_0(v2y_0),.v1y_1(v1y_1),.v2y_1(v2y_1),.v1y_2(v1y_2),.v2y_2(v2y_2),
        .v1z_0(v1z_0),.v2z_0(v2z_0),.v1z_1(v1z_1),.v2z_1(v2z_1),.v1z_2(v1z_2),.v2z_2(v2z_2),
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
        .v1x_0(v1x_0),.v2x_0(v2x_0),.v1x_1(v1x_1),.v2x_1(v2x_1),.v1x_2(v1x_2),.v2x_2(v2x_2),
        .v1y_0(v1y_0),.v2y_0(v2y_0),.v1y_1(v1y_1),.v2y_1(v2y_1),.v1y_2(v1y_2),.v2y_2(v2y_2),
        .v1z_0(v1z_0),.v2z_0(v2z_0),.v1z_1(v1z_1),.v2z_1(v2z_1),.v1z_2(v1z_2),.v2z_2(v2z_2),
        .coeff_c0     (cfg_c0),
        .coeff_c1     (cfg_c1),
        .coeff_c2     (cfg_c2),
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