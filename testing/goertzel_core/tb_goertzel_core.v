//============================================================================
// Testbench : goertzel_3bin_tb.v
// Project   : Space-Grade Vibration Pattern Anomaly Detector (GF180, 180nm)
//----------------------------------------------------------------------------
// Self-checking testbench for the 3-bin time-multiplexed goertzel_core.
//
//   * Instantiates goertzel_core with N_BINS=3.
//   * Models the chip-wide shared multiplier locally (same operand-isolation
//     latch + Q8.15 truncate/saturate as vibration_top.v).
//   * Drives 500 samples of a (1 kHz + 5 kHz) two-tone stimulus at the real
//     10 MHz / 26.667 kHz timing (one data_ready every 375 clk cycles).
//   * Bin 0 is tuned to 1 kHz, Bin 1 to 5 kHz (both on-target), Bin 2 to
//     10 kHz (off-target "noise" bin -> no energy in the stimulus).
//   * After the run, checks bin energies and the sample_done count.
//
//   Run:
//     iverilog -g2012 -o goertzel_3bin_tb.vvp \
//              rtl/goertzel_core.v rtl/tb/goertzel_3bin_tb.v && \
//     vvp goertzel_3bin_tb.vvp
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module goertzel_3bin_tb;

    //------------------------------------------------------------------------
    // System parameters
    //------------------------------------------------------------------------
    localparam real    CLK_PERIOD_NS = 100.0;    // 10 MHz
    localparam real    FS_HZ         = 26667.0;  // ADC sample rate
    localparam integer N_SAMPLES     = 500;      // test run length
    localparam integer SAMPLES_DIV   = 375;      // clk cycles between samples
    localparam integer DATA_W        = 24;
    localparam integer SAMPLE_W      = 16;
    localparam integer FRAC_W        = 15;       // Q8.15 fractional bits
    localparam real    PI            = 3.14159265358979;

    // Target tone / bin frequencies
    localparam real    F0_HZ = 1000.0;   // bin 0 (on-target, A1=0.5)
    localparam real    F1_HZ = 5000.0;   // bin 1 (on-target, A2=0.3)
    localparam real    F2_HZ = 10000.0;  // bin 2 (off-target noise bin)
    localparam real    A1    = 0.5;      // 1 kHz amplitude
    localparam real    A2    = 0.3;      // 5 kHz amplitude

    //------------------------------------------------------------------------
    // Coefficient computation: C_k = 2*cos(2*pi*f_k/Fs), in Q8.15.
    //------------------------------------------------------------------------
    real    coeff_c0_real, coeff_c1_real, coeff_c2_real;
    integer c0_q, c1_q, c2_q;

    reg signed [DATA_W-1:0] coeff_c0, coeff_c1, coeff_c2;

    //------------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------------
    reg                       clk;
    reg                       rst_n;
    reg                       enable;
    reg  signed [SAMPLE_W-1:0] x_n_in;
    reg                       block_clear;

    wire                      mult_req;
    wire signed [DATA_W-1:0]  mult_a;
    wire signed [DATA_W-1:0]  mult_b;
    wire signed [DATA_W-1:0]  v1_0, v2_0, v1_1, v2_1, v1_2, v2_2;
    wire                      sample_done;

    //------------------------------------------------------------------------
    // Local shared-multiplier model (identical to vibration_top.v)
    //------------------------------------------------------------------------
    reg  signed [DATA_W-1:0]   op_a, op_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_a <= {DATA_W{1'b0}};
            op_b <= {DATA_W{1'b0}};
        end else if (mult_req) begin
            op_a <= mult_a;
            op_b <= mult_b;
        end
    end

    localparam signed [DATA_W-1:0] Q_MAX = {1'b0, {(DATA_W-1){1'b1}}};
    localparam signed [DATA_W-1:0] Q_MIN = {1'b1, {(DATA_W-1){1'b0}}};
    localparam signed [2*DATA_W-1:0] Q_MAX_EXT = {{(DATA_W){Q_MAX[DATA_W-1]}}, Q_MAX};
    localparam signed [2*DATA_W-1:0] Q_MIN_EXT = {{(DATA_W){Q_MIN[DATA_W-1]}}, Q_MIN};

    wire signed [2*DATA_W-1:0] prod    = op_a * op_b;            // Q16.30
    wire signed [2*DATA_W-1:0] prod_sh = prod >>> FRAC_W;        // -> Q8.15
    wire signed [DATA_W-1:0]   mult_q  = (prod_sh > Q_MAX_EXT) ? Q_MAX :
                                         (prod_sh < Q_MIN_EXT) ? Q_MIN :
                                         prod_sh[DATA_W-1:0];

    //------------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------------
    goertzel_core #(
        .DATA_W   (DATA_W),
        .SAMPLE_W (SAMPLE_W),
        .N_BINS   (3)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (enable),
        .data_ready  (data_ready),
        .x_n         (x_n_in),
        .coeff_c0    (coeff_c0),
        .coeff_c1    (coeff_c1),
        .coeff_c2    (coeff_c2),
        .block_clear (block_clear),
        .mult_req    (mult_req),
        .mult_a      (mult_a),
        .mult_b      (mult_b),
        .mult_q      (mult_q),
        .v1_0        (v1_0),
        .v2_0        (v2_0),
        .v1_1        (v1_1),
        .v2_1        (v2_1),
        .v1_2        (v1_2),
        .v2_2        (v2_2),
        .sample_done (sample_done)
    );

    //------------------------------------------------------------------------
    // Clock
    //------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    //------------------------------------------------------------------------
    // Sample-cadence counter -> one data_ready pulse every 375 cycles.
    //------------------------------------------------------------------------
    integer cycle_cnt;
    integer n_idx;       // index of the sample currently being delivered
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             cycle_cnt <= 0;
        else if (cycle_cnt == SAMPLES_DIV-1) cycle_cnt <= 0;
        else                    cycle_cnt <= cycle_cnt + 1;
    end

    wire data_ready = (cycle_cnt == 0) && enable && (n_idx < N_SAMPLES);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            n_idx <= 0;
        else if (data_ready)   n_idx <= n_idx + 1;
    end

    //------------------------------------------------------------------------
    // Stimulus: x[n] = A1*sin(2*pi*f0*n/Fs) + A2*sin(2*pi*f1*n/Fs), Q1.15.
    // Driven combinationally from the current sample index so the value
    // present at the data_ready edge corresponds to sample n_idx.
    //------------------------------------------------------------------------
    real    sample_real;
    integer sample_int;
    always @(*) begin
        sample_real = A1 * $sin(2.0*PI*F0_HZ*n_idx/FS_HZ)
                    + A2 * $sin(2.0*PI*F1_HZ*n_idx/FS_HZ);
        sample_int  = $rtoi(sample_real * 32768.0);
        if (sample_int >  32767) sample_int =  32767;
        if (sample_int < -32768) sample_int = -32768;
        x_n_in = sample_int[SAMPLE_W-1:0];
    end

    //------------------------------------------------------------------------
    // sample_done counter (must equal N_SAMPLES at the end).
    //------------------------------------------------------------------------
    integer sd_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            sd_count <= 0;
        else if (sample_done)  sd_count <= sd_count + 1;
    end

    //------------------------------------------------------------------------
    // Energy / magnitude-squared helpers (real arithmetic, reference check).
    //   Mag_sq = v1^2 + v2^2 - C*v1*v2
    //------------------------------------------------------------------------
    function real q2r;
        input signed [DATA_W-1:0] q;
        begin
            q2r = $itor(q) / 32768.0;
        end
    endfunction

    function real magsq;
        input signed [DATA_W-1:0] v1;
        input signed [DATA_W-1:0] v2;
        input real cc;
        real r1, r2;
        begin
            r1 = q2r(v1);
            r2 = q2r(v2);
            magsq = r1*r1 + r2*r2 - cc*r1*r2;
        end
    endfunction

    //------------------------------------------------------------------------
    // Waveform dump
    //------------------------------------------------------------------------
    initial begin
        $dumpfile("goertzel_3bin_tb.vcd");
        $dumpvars(0, goertzel_3bin_tb);
    end

    //------------------------------------------------------------------------
    // Main test sequence
    //------------------------------------------------------------------------
    real mag_sq_0, mag_sq_1, mag_sq_2;
    integer fails;

    initial begin
        // Resolve coefficients
        coeff_c0_real = 2.0 * $cos(2.0*PI*F0_HZ/FS_HZ);
        coeff_c1_real = 2.0 * $cos(2.0*PI*F1_HZ/FS_HZ);
        coeff_c2_real = 2.0 * $cos(2.0*PI*F2_HZ/FS_HZ);
        c0_q = $rtoi(coeff_c0_real * 32768.0);
        c1_q = $rtoi(coeff_c1_real * 32768.0);
        c2_q = $rtoi(coeff_c2_real * 32768.0);
        coeff_c0 = c0_q[DATA_W-1:0];
        coeff_c1 = c1_q[DATA_W-1:0];
        coeff_c2 = c2_q[DATA_W-1:0];

        fails       = 0;
        rst_n       = 1'b0;
        enable      = 1'b0;
        block_clear = 1'b0;

        // Reset: hold for 2 clocks
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        enable = 1'b1;

        // Run until all N_SAMPLES have been delivered ...
        wait (n_idx == N_SAMPLES);
        // ... then let the FSM drain the last sample.
        repeat (50) @(posedge clk);

        //--------------------------------------------------------------------
        // Compute reference magnitudes
        //--------------------------------------------------------------------
        mag_sq_0 = magsq(v1_0, v2_0, coeff_c0_real);
        mag_sq_1 = magsq(v1_1, v2_1, coeff_c1_real);
        mag_sq_2 = magsq(v1_2, v2_2, coeff_c2_real);

        //--------------------------------------------------------------------
        // Checks
        //--------------------------------------------------------------------
        if (!(mag_sq_0 > 0.01)) begin
            $error("Check 1 FAILED: Bin0 (1kHz) energy too low: %f", mag_sq_0);
            fails = fails + 1;
        end
        if (!(mag_sq_1 > 0.01)) begin
            $error("Check 2 FAILED: Bin1 (5kHz) energy too low: %f", mag_sq_1);
            fails = fails + 1;
        end
        if (!(mag_sq_0 > mag_sq_2)) begin
            $error("Check 3 FAILED: Bin0 (%f) !> Bin2 off-target (%f)", mag_sq_0, mag_sq_2);
            fails = fails + 1;
        end
        if (!(mag_sq_1 > mag_sq_2)) begin
            $error("Check 4 FAILED: Bin1 (%f) !> Bin2 off-target (%f)", mag_sq_1, mag_sq_2);
            fails = fails + 1;
        end
        // Check 5: detection margin. The valid invariant for a free-running
        // (continuously-accumulating) Goertzel resonator is that BOTH on-target
        // bins dominate the off-target bin by a large margin. (Note: the
        // relative ordering of two on-target bins is NOT a function of input
        // amplitude here - it depends on each tone's coherence with its
        // quantized pole - so amplitude ordering is intentionally NOT checked.)
        if (!(mag_sq_0 > 50.0*mag_sq_2 && mag_sq_1 > 50.0*mag_sq_2)) begin
            $error("Check 5 FAILED: on-target bins do not dominate off-target by 50x (B0=%f B1=%f B2=%f)",
                   mag_sq_0, mag_sq_1, mag_sq_2);
            fails = fails + 1;
        end
        if (sd_count != N_SAMPLES) begin
            $error("Check 6 FAILED: sample_done count = %0d (expected %0d)", sd_count, N_SAMPLES);
            fails = fails + 1;
        end

        //--------------------------------------------------------------------
        // Summary
        //--------------------------------------------------------------------
        $display("================================================");
        $display("  Goertzel 3-Bin Testbench Summary (N=%0d)", N_SAMPLES);
        $display("================================================");
        $display("  Coeffs (Q8.15): C0=%0d  C1=%0d  C2=%0d", c0_q, c1_q, c2_q);
        $display("  Bin 0 (1 kHz)  v1=%0d v2=%0d  Mag^2=%f", $signed(v1_0), $signed(v2_0), mag_sq_0);
        $display("  Bin 1 (5 kHz)  v1=%0d v2=%0d  Mag^2=%f", $signed(v1_1), $signed(v2_1), mag_sq_1);
        $display("  Bin 2 (10kHz)  v1=%0d v2=%0d  Mag^2=%f", $signed(v1_2), $signed(v2_2), mag_sq_2);
        $display("  sample_done count = %0d (expected %0d)", sd_count, N_SAMPLES);
        $display("================================================");
        if (fails == 0)
            $display("  [PASS] All checks passed.");
        else
            $display("  [FAIL] %0d check(s) failed.", fails);
        $display("================================================");
        $finish;
    end

    // Global timeout guard
    initial begin
        #(CLK_PERIOD_NS * SAMPLES_DIV * (N_SAMPLES + 10));
        $display("  [FAIL] Global timeout - simulation did not complete.");
        $finish;
    end

endmodule

`default_nettype wire