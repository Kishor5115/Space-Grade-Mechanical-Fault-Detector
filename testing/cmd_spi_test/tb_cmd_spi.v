`timescale 1ns/1ps
// ------------------------------------------------------------------
// tb_cmd_spi.v -- end-to-end test of the external coefficient reception
// path: drive real SPI mode-3 frames into top.v's command-SPI pins
// (cmd_sclk/cmd_csn/cmd_mosi) and confirm the values land in tmr_reg_bank
// (cfg_c0/c1/c2, cfg_threshold, run_enable) through the oversampled
// cmd_spi_slave -> apb -> apb_arb2 -> tmr_reg_bank chain.
//
// This exercises the same signals a real RISC-V host would drive, with no
// hierarchical force -- proving the silicon-legal configuration path.
//
// Frame = 40 bits, MSB first, cmd_csn low for the whole frame:
//   [39:32] = register byte address, [31:0] = write data.
// Mode 3: SCLK idles high; host drives MOSI on the falling edge; slave
// samples on the rising edge.
// ------------------------------------------------------------------

module tb_cmd_spi;

    reg clk = 0;
    reg sys_rst_n = 0;

    // command-SPI host-side drivers
    reg cmd_sclk = 1'b1;   // mode 3 idle high
    reg cmd_csn  = 1'b1;   // idle deasserted
    reg cmd_mosi = 1'b0;

    integer errors = 0;
    integer checks = 0;

    // DUT: full chip. Sensor side held quiet; we only drive the config bus.
    top dut (
        .clk            (clk),
        .sys_rst_n      (sys_rst_n),
        .c_miso         (1'b0),
        .c_csn          (),
        .c_sclk         (),
        .c_mosi         (),
        .sensor_drdy    (1'b0),
        .tmr_forward_en (1'b0),
        .cmd_sclk       (cmd_sclk),
        .cmd_csn        (cmd_csn),
        .cmd_mosi       (cmd_mosi),
        .fault_flag_out ()
    );

    always #10 clk = ~clk; // 50 MHz-equivalent sim clock

    // ---- command-SPI host bit-bang (async to clk; slow enough to oversample) ----
    // Half-bit period 100 ns -> 5 MHz command clock; DUT clk (50 MHz sim) gives
    // 10x oversampling, comfortably above the >=4x the receiver requires.
    localparam integer THALF = 100;

    task automatic cmd_send_frame;
        input [7:0]  addr;
        input [31:0] data;
        reg   [39:0] frame;
        integer i;
        begin
            frame = {addr, data};
            cmd_csn  = 1'b0;          // assert chip-select
            #THALF;
            for (i = 39; i >= 0; i = i - 1) begin
                cmd_sclk = 1'b0;      // falling (leading) edge: drive MOSI
                cmd_mosi = frame[i];
                #THALF;
                cmd_sclk = 1'b1;      // rising (trailing) edge: slave samples
                #THALF;
            end
            cmd_csn  = 1'b1;          // deassert -> frame complete, issue write
            cmd_mosi = 1'b0;
            #(THALF*4);               // let the APB write drain
            // wait a few core clocks for the register to update
            repeat (8) @(posedge clk);
        end
    endtask

    task automatic check_eq;
        input [127:0] name;
        input [31:0]  got, exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL [%0t] %0s : got=0x%08h expected=0x%08h", $time, name, got, exp);
            end else begin
                $display("PASS [%0t] %0s : 0x%08h", $time, name, got);
            end
        end
    endtask

    task automatic check_true;
        input [127:0] name;
        input cond;
        begin
            checks = checks + 1;
            if (!cond) begin errors=errors+1; $display("FAIL [%0t] %0s", $time, name); end
            else       $display("PASS [%0t] %0s", $time, name);
        end
    endtask

    initial begin
        $dumpfile("tb_cmd_spi.vcd");
        $dumpvars(0, tb_cmd_spi);

        sys_rst_n = 0;
        repeat (5) @(posedge clk);
        sys_rst_n = 1;
        repeat (5) @(posedge clk);

        // ---- program the three Goertzel coefficients (24-bit, zero-extended) ----
        cmd_send_frame(8'h04, 32'h0012_3456); // CFG_C0
        check_eq("CFG_C0 received", {8'd0, dut.cfg_c0}, 32'h0012_3456);

        cmd_send_frame(8'h08, 32'h000A_BCDE); // CFG_C1
        check_eq("CFG_C1 received", {8'd0, dut.cfg_c1}, 32'h000A_BCDE);

        cmd_send_frame(8'h0C, 32'h007F_FFFF); // CFG_C2
        check_eq("CFG_C2 received", {8'd0, dut.cfg_c2}, 32'h007F_FFFF);

        // ---- program the 32-bit threshold ----
        cmd_send_frame(8'h10, 32'hDEAD_BEEF); // CFG_THRESHOLD
        check_eq("CFG_THRESHOLD received", dut.cfg_threshold, 32'hDEAD_BEEF);

        // ---- CTRL: start (bit0) -> run_enable asserts ----
        cmd_send_frame(8'h00, 32'h0000_0001);
        check_true("CTRL start -> run_enable=1", dut.run_enable === 1'b1);

        // ---- CTRL: stop (bit2) -> run_enable clears ----
        cmd_send_frame(8'h00, 32'h0000_0004);
        check_true("CTRL stop -> run_enable=0", dut.run_enable === 1'b0);

        // ---- coefficients must be unchanged by the CTRL writes ----
        check_eq("CFG_C0 retained", {8'd0, dut.cfg_c0}, 32'h0012_3456);
        check_eq("CFG_THRESHOLD retained", dut.cfg_threshold, 32'hDEAD_BEEF);

        #200;
        $display("----------------------------------------------------");
        if (errors == 0) $display("ALL CHECKS PASSED (%0d checks)", checks);
        else             $display("%0d / %0d CHECKS FAILED", errors, checks);
        $display("----------------------------------------------------");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT - simulation did not complete");
        $display("%0d / %0d checks failed so far", errors, checks);
        $finish;
    end

endmodule
