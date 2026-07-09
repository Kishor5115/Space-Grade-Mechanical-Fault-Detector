`timescale 1ns/1ps
// ------------------------------------------------------------------
// tb_top.v -- end-to-end testbench for the full 3-axis time-multiplexed
// vibration-fault-detector chain (top.v).
//
// Drives the real IIS3DWB SPI bus functional model (iis3dwb_model.v,
// reused from testing/spi_master_test/) into top.v's c_miso/c_csn/c_sclk/
// c_mosi/sensor_drdy pins, exactly as the physical sensor would.
//
// top.v has no external APB/command-SPI port (per the current RTL, the
// Command-SPI-to-APB bridge that would drive cfg_c0/c1/c2/cfg_threshold/
// run_enable in real silicon is a system-level concern outside top.v's
// boundary), so this testbench pokes the internal APB bus directly via
// hierarchical reference (dut.apb_*) to load coefficients/threshold and
// assert run_enable -- the same signals a real command-SPI bridge would
// drive, just without re-implementing that bridge's own protocol here.
//
// Coverage:
//   1. Normal operation: broadband/off-target stimulus on all 3 axes,
//      below threshold -> fault_flag_out must stay low.
//   2. Fault on X: inject a bin-0-frequency tone on the X axis at an
//      amplitude that pushes bin 0's magnitude over cfg_threshold ->
//      fault_flag_out must assert, and FAULT_BIN[3:2] (axis) must read
//      back as X (0).
//   3. Fault on Y (after clearing the X fault): same, but with the tone
//      injected only on the Y axis -> fault must assert with axis=Y (1).
//   4. Fault on Z (after clearing): same for Z axis -> axis=Z (2).
//
// This test's central purpose (per the project brief) is to catch axis-
// routing bugs like the X/Z swap found and fixed in axis_sequencer.v
// during this same pass -- by injecting a tone on ONE axis only and
// checking BOTH that the fault fires AND that the reported axis matches
// the axis that was actually excited.
// ------------------------------------------------------------------

module tb_top;

    localparam real PI = 3.14159265358979;

    reg clk = 0;
    reg sys_rst_n = 0;
    reg sensor_drdy = 0;
    reg tmr_forward_en = 0;
    wire c_csn, c_sclk, c_mosi;
    wire c_miso;
    wire fault_flag_out;

    integer errors = 0;
    integer checks = 0;

    // ---------------- DUT ----------------
    top dut (
        .clk            (clk),
        .sys_rst_n      (sys_rst_n),
        .c_miso         (c_miso),
        .c_csn          (c_csn),
        .c_sclk         (c_sclk),
        .c_mosi         (c_mosi),
        .sensor_drdy    (sensor_drdy),
        .tmr_forward_en (tmr_forward_en),
        .fault_flag_out (fault_flag_out)
    );

    // ---------------- IIS3DWB SPI bus functional model ----------------
    // model_outx/y/z are driven combinationally from a synthetic
    // per-axis Q1.15 sample stream, advanced one sample every time the
    // model captures a fresh burst read (i.e. once per DRDY cycle).
    reg [15:0] model_outx, model_outy, model_outz;

    wire        m_rw_bit_q;
    wire [6:0]  m_addr_q;
    wire [7:0]  m_wr_data_q;
    wire        m_wr_event;
    wire        m_addr_known_event;
    wire [47:0] m_rd_burst_sent;

    iis3dwb_model model (
        .csn(c_csn), .sclk(c_sclk), .mosi(c_mosi), .miso(c_miso),
        .rw_bit_q(m_rw_bit_q), .addr_q(m_addr_q), .wr_data_q(m_wr_data_q),
        .wr_event(m_wr_event), .addr_known_event(m_addr_known_event),
        .rd_burst_sent(m_rd_burst_sent),
        .model_outx(model_outx), .model_outy(model_outy), .model_outz(model_outz)
    );

    always #10 clk = ~clk; // 50 MHz-equivalent system clock (matches other TBs)

    // ---------------- synthetic per-axis stimulus generator ----------------
    // Each axis gets its own independent tone-injection control so a
    // fault can be excited on exactly one axis at a time. Frequencies
    // match tb_goertzel_core.v's bin tuning (bin0=1kHz, bin1=5kHz,
    // bin2=10kHz off-target) so a bin-0 tone reliably trips a threshold
    // set between the "normal" and "fault" magnitudes.
    localparam real FS_HZ = 26667.0;
    localparam real F_BIN0_HZ = 1000.0;

    real    amp_x = 0.0, amp_y = 0.0, amp_z = 0.0; // 0 = no injected tone
    integer n_x = 0, n_y = 0, n_z = 0;

    task automatic gen_sample;
        output [15:0] word;
        input  real   amp;
        input  integer n;
        real r; integer i;
        begin
            r = amp * $sin(2.0*PI*F_BIN0_HZ*n/FS_HZ);
            i = $rtoi(r * 32768.0);
            if (i >  32767) i =  32767;
            if (i < -32768) i = -32768;
            word = i[15:0];
        end
    endtask

    // Advance the synthetic stimulus once per sensor burst (captured via
    // the model's own addr_known_event on the read command byte, which
    // fires once per DRDY-triggered transaction regardless of R/W).
    always @(posedge m_addr_known_event) begin
        if (m_rw_bit_q == 1'b1) begin // only advance on read-burst frames
            gen_sample(model_outx, amp_x, n_x); n_x = n_x + 1;
            gen_sample(model_outy, amp_y, n_y); n_y = n_y + 1;
            gen_sample(model_outz, amp_z, n_z); n_z = n_z + 1;
        end
    end

    // ---------------- DRDY pump ----------------
    // Fires sensor_drdy repeatedly once boot config is done, at a rate
    // fast enough to complete a 512-sample block per axis (1536 samples
    // total) in a practical sim time. Absolute timing accuracy against
    // the real 26.667 kHz ODR is not required here (that is covered by
    // tb_spi_master_full.v); this pump just needs to keep drdy pulses
    // coming faster than spi_master can service them, one at a time.
    reg drdy_pump_en = 0;
    always @(posedge clk) begin
        if (drdy_pump_en && dut.spi_apb_inst.spi_master_inst.state ==
            dut.spi_apb_inst.spi_master_inst.IDLE) begin
            sensor_drdy <= 1'b1;
        end else begin
            sensor_drdy <= 1'b0;
        end
    end

    // ---------------- APB config helper (hierarchical whitebox drive) ----------------
    // top.v has no external command-SPI/APB port; drive the internal
    // apb_* wires directly via hierarchical reference, exactly as a
    // (not-yet-modeled) command-SPI-to-APB bridge would from outside.
    task apb_write_reg;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            force {dut.apb_psel, dut.apb_penable, dut.apb_pwrite, dut.apb_p_addr, dut.apb_pwdata}
                  = {1'b1, 1'b0, 1'b1, {24'd0, addr}, data};
            @(negedge clk);
            force {dut.apb_psel, dut.apb_penable, dut.apb_pwrite, dut.apb_p_addr, dut.apb_pwdata}
                  = {1'b1, 1'b1, 1'b1, {24'd0, addr}, data};
            @(posedge clk); // ACCESS phase sampled by tmr_reg_bank here
            @(negedge clk);
            release {dut.apb_psel, dut.apb_penable, dut.apb_pwrite, dut.apb_p_addr, dut.apb_pwdata};
            @(posedge clk);
        end
    endtask

    task apb_read_reg;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(negedge clk);
            force {dut.apb_psel, dut.apb_penable, dut.apb_pwrite, dut.apb_p_addr}
                  = {1'b1, 1'b0, 1'b0, {24'd0, addr}};
            @(posedge clk); // SETUP phase: tmr_reg_bank pre-fetches prdata here
            @(negedge clk);
            force {dut.apb_psel, dut.apb_penable, dut.apb_pwrite, dut.apb_p_addr}
                  = {1'b1, 1'b1, 1'b0, {24'd0, addr}};
            @(posedge clk);
            data = dut.apb_prdata;
            @(negedge clk);
            release {dut.apb_psel, dut.apb_penable, dut.apb_pwrite, dut.apb_p_addr};
            @(posedge clk);
        end
    endtask

    // Q8.15 coefficient helper: C_k = 2*cos(2*pi*f_k/Fs)
    function [23:0] q815_coeff;
        input real f_hz;
        real c; integer q;
        begin
            c = 2.0 * $cos(2.0*PI*f_hz/FS_HZ);
            q = $rtoi(c * 32768.0);
            q815_coeff = q[23:0];
        end
    endfunction

    task automatic check_true;
        input [127:0] name;
        input cond;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL [%0t] %0s", $time, name);
            end else begin
                $display("PASS [%0t] %0s", $time, name);
            end
        end
    endtask

    task automatic check_eq2;
        input [127:0] name;
        input [1:0] got, exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL [%0t] %0s : got=%0d expected=%0d", $time, name, got, exp);
            end else begin
                $display("PASS [%0t] %0s : %0d", $time, name, got);
            end
        end
    endtask

    // Clear a latched fault via CTRL.cfg_fault_clear (bit1) and wait a
    // few cycles for the sticky flag to actually drop.
    task automatic clear_fault;
        begin
            apb_write_reg(8'h00, 32'h0000_0002);
            repeat (5) @(posedge clk);
        end
    endtask

    // Wait for at least one full block_clear pulse on the given axis,
    // so any samples still in flight from a PREVIOUS amplitude setting
    // (queued in the SPI/burst pipeline between iis3dwb_model and
    // axis_sequencer at the moment amp_x/y/z was changed) have fully
    // drained out of that axis's block before the next check -- without
    // this, a residual tail of stale-amplitude samples can trip a
    // second, spurious fault on the WRONG axis immediately after
    // clear_fault(), before the intended axis's fresh block completes.
    task automatic wait_for_axis_block;
        input [1:0] axis;
        integer t;
        begin
            for (t = 0; t < 2_000_000; t = t + 1) begin
                @(posedge clk);
                if (dut.block_clear && dut.current_axis == axis) begin
                    t = 2_000_000; // exit
                end
            end
        end
    endtask

    // Wait (with a bounded timeout) for fault_flag_out to assert.
    task automatic wait_fault_or_timeout;
        output got_fault;
        integer t;
        begin
            got_fault = 1'b0;
            for (t = 0; t < 5_000_000 && !got_fault; t = t + 1) begin
                @(posedge clk);
                if (fault_flag_out) got_fault = 1'b1;
            end
        end
    endtask

    // Debug visibility: log every magnitude_compute pulse; useful for
    // calibrating cfg_threshold against real DUT behavior (the
    // free-running Goertzel resonator's magnitude oscillates block-
    // to-block with the tone's phase alignment rather than growing
    // monotonically, so the threshold must clear the smallest nearby
    // peak, not just the largest).
    // (Optional debug visibility -- uncomment to trace magnitude_compute
    // pulses when recalibrating cfg_threshold against DUT behavior.)
    // always @(posedge clk)
    //     if (dut.mag_out_valid)
    //         $display("  [%0t] mag_out=%0d bin=%0d axis=%0d",
    //                   $time, dut.mag_out, dut.mag_bin_idx, dut.mag_axis_idx);

    reg [31:0] rd_val;
    reg        got_fault;

    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);

        sys_rst_n = 0;
        drdy_pump_en = 0;
        #100;
        sys_rst_n = 1;

        // ---- wait for spi_master's power-on boot config sequence ----
        wait (dut.spi_apb_inst.spi_master_inst.state == dut.spi_apb_inst.spi_master_inst.IDLE);
        repeat (10) @(posedge clk);

        // ---- program Goertzel coefficients + threshold over the internal APB bus ----
        // bin0 tuned to 1kHz (matches the injected fault tone); bin1/2
        // arbitrary off-target bins, not exercised by this test.
        apb_write_reg(8'h04, {8'd0, q815_coeff(1000.0)});  // CFG_C0
        apb_write_reg(8'h08, {8'd0, q815_coeff(5000.0)});  // CFG_C1
        apb_write_reg(8'h0C, {8'd0, q815_coeff(10000.0)}); // CFG_C2
        // Threshold chosen well above the observed "normal" (quiet)
        // magnitude (~0) but comfortably below the peak magnitude
        // measured empirically for a 0.8-amplitude on-target 1kHz
        // tone over a 171-sample block. Scaled from original 512-sample
        // threshold by (171/512)² = 0.112 factor, since Goertzel magnitude
        // scales as N². Original: 120, New: 120×0.112 ≈ 14.
        apb_write_reg(8'h10, 32'd14);                      // CFG_THRESHOLD (BLOCK_SIZE=171)

        // ---- start the detector (run_enable) ----
        apb_write_reg(8'h00, 32'h0000_0001);

        drdy_pump_en = 1'b1;

        // =================================================================
        // Case 1: Normal operation -- no tone on any axis, must NOT fault.
        // =================================================================
        amp_x = 0.0; amp_y = 0.0; amp_z = 0.0;
        wait_fault_or_timeout(got_fault);
        check_true("Case1 Normal: no fault asserted (all axes quiet)", !got_fault);

        // =================================================================
        // Case 2: Fault on X only.
        // =================================================================
        amp_x = 0.8; amp_y = 0.0; amp_z = 0.0;
        wait_fault_or_timeout(got_fault);
        check_true("Case2 FaultX: fault_flag_out asserted", got_fault);
        apb_read_reg(8'h1C, rd_val);
        check_eq2("Case2 FaultX: reported axis == X(0)", rd_val[3:2], 2'd0);
        clear_fault();

        // =================================================================
        // Case 3: Fault on Y only.
        // =================================================================
        amp_x = 0.0; amp_y = 0.8; amp_z = 0.0;
        // Drain any X-tone samples still in flight (queued between the
        // sensor model and axis_sequencer at the moment amp_x dropped
        // to 0) by waiting for X's block to close out once more before
        // trusting the next fault as genuinely Y's.
        wait_for_axis_block(2'd0);
        clear_fault();
        wait_fault_or_timeout(got_fault);
        check_true("Case3 FaultY: fault_flag_out asserted", got_fault);
        apb_read_reg(8'h1C, rd_val);
        check_eq2("Case3 FaultY: reported axis == Y(1)", rd_val[3:2], 2'd1);
        clear_fault();

        // =================================================================
        // Case 4: Fault on Z only.
        // =================================================================
        amp_x = 0.0; amp_y = 0.0; amp_z = 0.8;
        wait_for_axis_block(2'd1); // drain any Y-tone tail samples
        clear_fault();
        wait_fault_or_timeout(got_fault);
        check_true("Case4 FaultZ: fault_flag_out asserted", got_fault);
        apb_read_reg(8'h1C, rd_val);
        check_eq2("Case4 FaultZ: reported axis == Z(2)", rd_val[3:2], 2'd2);
        clear_fault();

        $display("----------------------------------------------------");
        if (errors == 0)
            $display("ALL CHECKS PASSED (%0d checks)", checks);
        else
            $display("%0d / %0d CHECKS FAILED", errors, checks);
        $display("----------------------------------------------------");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT - simulation did not complete in time");
        $display("%0d / %0d checks failed so far", errors, checks);
        $finish;
    end

endmodule
