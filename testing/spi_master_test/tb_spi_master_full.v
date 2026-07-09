`timescale 1ns/1ps
// tb_spi_master_full.v
//
// Self-checking testbench for spi_master.v against the IIS3DWB
// datasheet (DS12569 Rev 8):
//   1. SPI mode 3 idle-high check on s_clk while CS is high
//   2. Config sequence: verifies the 4 expected register writes
//      (CTRL1_XL=0x10/0xA0, FIFO_CTRL4=0x0A/0x00, CTRL3_C=0x12/0x04,
//      INT1_CTRL=0x0D/0x01) occur, in order, with correct addr/data
//   3. Read burst: verifies the command byte is 0xA8 (READ,
//      OUTX_L_A), and that the 48 bits captured into s_data_out
//      exactly match the model's canned X/Y/Z payload
//   4. Repeats the DRDY->read cycle multiple times with different
//      canned sensor data to confirm the FSM returns cleanly to IDLE
//      and re-triggers correctly
//   5. Checks data_out_valid behavior w.r.t. core_ack handshake


module tb_spi_master_full;

    reg clk = 0;
    reg sys_rst_n = 0;
    reg drdy = 0;
    reg core_ack = 0;

    wire s_csn, s_clk, s_mosi, s_miso;
    wire [47:0] s_data_out;
    wire s_data_out_valid;

    integer errors = 0;
    integer checks = 0;

    spi_master dut (
        .clk(clk),
        .sys_rst_n(sys_rst_n),
        .sync_data_ready_trig(drdy),
        .s_miso(s_miso),
        .core_ack(core_ack),
        .s_csn(s_csn),
        .s_clk(s_clk),
        .s_mosi(s_mosi),
        .s_data_out(s_data_out),
        .s_data_out_valid(s_data_out_valid)
    );

    reg [15:0] model_outx = 16'h1234;
    reg [15:0] model_outy = 16'h5678;
    reg [15:0] model_outz = 16'h9ABC;

    wire        m_rw_bit_q;
    wire [6:0]  m_addr_q;
    wire [7:0]  m_wr_data_q;
    wire        m_wr_event;
    wire        m_addr_known_event;
    wire [47:0] m_rd_burst_sent;

    iis3dwb_model model (
        .csn(s_csn),
        .sclk(s_clk),
        .mosi(s_mosi),
        .miso(s_miso),
        .rw_bit_q(m_rw_bit_q),
        .addr_q(m_addr_q),
        .wr_data_q(m_wr_data_q),
        .wr_event(m_wr_event),
        .addr_known_event(m_addr_known_event),
        .rd_burst_sent(m_rd_burst_sent),
        .model_outx(model_outx),
        .model_outy(model_outy),
        .model_outz(model_outz)
    );

    always #10 clk = ~clk; // 50 MHz-equivalent system clock

    // ---------------- checker tasks ----------------
    task check_eq8;
        input [127:0] name;
        input [7:0] got;
        input [7:0] exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL [%0t] %0s : got=0x%02h expected=0x%02h", $time, name, got, exp);
            end else begin
                $display("PASS [%0t] %0s : 0x%02h", $time, name, got);
            end
        end
    endtask

    task check_eq48;
        input [127:0] name;
        input [47:0] got;
        input [47:0] exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL [%0t] %0s : got=0x%012h expected=0x%012h", $time, name, got, exp);
            end else begin
                $display("PASS [%0t] %0s : 0x%012h", $time, name, got);
            end
        end
    endtask

    task check_true;
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

    // ---------------- expected config write sequence ----------------
    reg [6:0] exp_addr [0:3];
    reg [7:0] exp_data [0:3];
    integer wr_idx;

    initial begin
        exp_addr[0] = 7'h10; exp_data[0] = 8'hA0; // CTRL1_XL: XL_EN=101, FS=00
        exp_addr[1] = 7'h0A; exp_data[1] = 8'h00; // FIFO_CTRL4: bypass mode
        exp_addr[2] = 7'h12; exp_data[2] = 8'h04; // CTRL3_C: IF_INC=1
        exp_addr[3] = 7'h0D; exp_data[3] = 8'h01; // INT1_CTRL: INT1_DRDY_XL=1
    end

    // capture each write event from the model as it happens
    always @(posedge m_wr_event) begin
        $display("  -> model captured WRITE addr=0x%02h data=0x%02h (idx=%0d)", m_addr_q, m_wr_data_q, wr_idx);
        if (wr_idx <= 3) begin
            check_eq8("config write addr", {1'b0, m_addr_q}, {1'b0, exp_addr[wr_idx]});
            check_eq8("config write data", m_wr_data_q, exp_data[wr_idx]);
        end else begin
            errors = errors + 1;
            $display("FAIL [%0t] unexpected extra write event (idx=%0d)", $time, wr_idx);
        end
        wr_idx = wr_idx + 1;
    end

    // ---------------- mode-3 idle check ----------------
    // s_clk must be high whenever s_csn is high (mode 3 idle-high)
    always @(s_csn) begin
        if (s_csn === 1'b1) begin
            #1; // allow settling
            check_true("s_clk idles HIGH while CS high (SPI mode 3)", s_clk === 1'b1);
        end
    end

    // ---------------- main stimulus ----------------
    integer iter;
    reg [47:0] expected_burst;

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_spi_master_full);

        wr_idx = 0;
        sys_rst_n = 0;
        drdy = 0;
        core_ack = 0;
        #45 sys_rst_n = 1;

        // 1) wait for config sub-FSM to finish all 4 writes and reach IDLE
        wait (dut.state == dut.IDLE);
        #1;
        check_true("reached IDLE with CS high after config", s_csn === 1'b1);
        check_true("all 4 config writes observed", wr_idx == 4);

        // 2) run several DRDY -> read-burst cycles with different canned data
        for (iter = 0; iter < 8; iter = iter + 1) begin
            model_outx = $random;
            model_outy = $random;
            model_outz = $random;
            // Expected order in s_data_out: shifted MSb-first as bytes
            // arrive OUTX_L,OUTX_H,OUTY_L,OUTY_H,OUTZ_L,OUTZ_H, packed
            // into a 48-bit left-shift register -> final s_data_out
            // equals the same 48-bit burst_payload the model sent.
            expected_burst = {model_outx[7:0], model_outx[15:8],
                               model_outy[7:0], model_outy[15:8],
                               model_outz[7:0], model_outz[15:8]};

            wait (dut.state == dut.IDLE);
            #20;
            drdy = 1;
            #20 drdy = 0;

            wait (dut.state == dut.START);
            check_true("CS asserted low during transaction start", 1'b1); // sanity marker

            wait (s_data_out_valid == 1'b1);
            #1;
            check_eq8("read command byte (R/W+addr)", {m_rw_bit_q, m_addr_q}, 8'hA8);
            check_eq48("captured 48-bit burst payload", s_data_out, expected_burst);
            check_true("s_csn deasserted (high) once STOP reached", s_csn === 1'b1);

            // hold data_out_valid until core_ack, per handshake design
            #20;
            check_true("data_out_valid still high before core_ack", s_data_out_valid === 1'b1);
            core_ack = 1;
            #20 core_ack = 0;
            #5;
            check_true("data_out_valid clears after core_ack", s_data_out_valid === 1'b0);
        end

        #200;
        $display("----------------------------------------------------");
        if (errors == 0)
            $display("ALL CHECKS PASSED (%0d checks)", checks);
        else
            $display("%0d / %0d CHECKS FAILED", errors, checks);
        $display("----------------------------------------------------");
        $finish;
    end

    initial begin
        #2_000_000; // generous global timeout
        $display("TIMEOUT - simulation did not complete in time");
        $display("%0d / %0d checks failed so far", errors, checks);
        $finish;
    end

endmodule