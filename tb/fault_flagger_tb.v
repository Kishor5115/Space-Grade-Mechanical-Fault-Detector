`timescale 1ns/1ps
`default_nettype none

module fault_flagger_tb;

    localparam integer DATA_W     = 24;
    localparam integer MAG_W      = 24;
    localparam integer BLOCK_N    = 2;
    localparam integer DEB_W      = 4;
    localparam integer DEB_TARGET = 2;
    localparam integer FRAC_W     = 15;

    reg clk;
    reg rst_n;
    reg enable;
    reg rst_alarm;
    reg sample_done;
    reg signed [DATA_W-1:0] v1;
    reg signed [DATA_W-1:0] v2;
    reg signed [DATA_W-1:0] coeff_c;
    reg [MAG_W-1:0] thresh_sq;
    wire mult_req;
    wire signed [DATA_W-1:0] mult_a;
    wire signed [DATA_W-1:0] mult_b;
    wire signed [DATA_W-1:0] mult_q;
    wire block_clear;
    wire hw_interrupt;
    wire alarm_active;

    integer errors;
    reg signed [DATA_W-1:0] op_a;
    reg signed [DATA_W-1:0] op_b;
    wire signed [2*DATA_W-1:0] mult_prod;

    fault_flagger #(
        .DATA_W     (DATA_W),
        .MAG_W      (MAG_W),
        .BLOCK_N    (BLOCK_N),
        .DEB_W      (DEB_W),
        .DEB_TARGET (DEB_TARGET)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (enable),
        .rst_alarm    (rst_alarm),
        .sample_done  (sample_done),
        .v1           (v1),
        .v2           (v2),
        .coeff_c      (coeff_c),
        .thresh_sq    (thresh_sq),
        .mult_req     (mult_req),
        .mult_a       (mult_a),
        .mult_b       (mult_b),
        .mult_q       (mult_q),
        .block_clear  (block_clear),
        .hw_interrupt (hw_interrupt),
        .alarm_active (alarm_active)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

`ifdef DEBUG_FAULT_FLAGGER_TB
    always @(posedge clk) begin
        #1;
        $display("DBG t=%0t fstate=%0d bcnt=%0d trig=%0b deb=%0d t1=%h t2=%h t4=%h over=%0b clr=%0b irq=%0b",
                 $time, dut.fstate, dut.bcnt_v, dut.block_trig, dut.deb_v,
                 dut.t1, dut.t2, dut.t4, dut.over_thresh, block_clear, hw_interrupt);
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_a <= {DATA_W{1'b0}};
            op_b <= {DATA_W{1'b0}};
        end else if (mult_req) begin
            op_a <= mult_a;
            op_b <= mult_b;
        end
    end

    assign mult_prod = op_a * op_b;
    assign mult_q = mult_prod >>> FRAC_W;

    task fail;
        input [1023:0] message;
        begin
            errors = errors + 1;
            $display("FAIL: %0s at %0t", message, $time);
        end
    endtask

    task pulse_sample_done;
        begin
            @(negedge clk);
            sample_done = 1'b1;
            @(negedge clk);
            sample_done = 1'b0;
        end
    endtask

    task wait_for_block_clear;
        input integer max_cycles;
        integer cycle;
        integer found;
        begin
            found = 0;
            for (cycle = 0; cycle < max_cycles && !found; cycle = cycle + 1) begin
                @(posedge clk);
                #1;
                if (block_clear === 1'b1)
                    found = 1;
            end
            if (!found)
                fail("block_clear timeout");
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        errors      = 0;
        rst_n       = 1'b0;
        enable      = 1'b0;
        rst_alarm   = 1'b0;
        sample_done = 1'b0;
        v1          = 24'h004000;
        v2          = 24'h000000;
        coeff_c     = 24'h000000;
        thresh_sq   = 24'h000000;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        enable = 1'b1;

        pulse_sample_done();
        pulse_sample_done();
        wait_for_block_clear(20);
        if (hw_interrupt !== 1'b0 || alarm_active !== 1'b0)
            fail("first bad block should not trip debounce target");

        pulse_sample_done();
        pulse_sample_done();
        wait_for_block_clear(20);
        if (hw_interrupt !== 1'b1 || alarm_active !== 1'b1)
            fail("second consecutive bad block should assert interrupt");

        @(negedge clk);
        rst_alarm = 1'b1;
        @(negedge clk);
        rst_alarm = 1'b0;
        @(posedge clk);
        #1;
        if (hw_interrupt !== 1'b0)
            fail("rst_alarm should clear interrupt");

        thresh_sq = 24'hffffff;
        pulse_sample_done();
        pulse_sample_done();
        wait_for_block_clear(20);
        if (hw_interrupt !== 1'b0)
            fail("healthy block should not retrigger interrupt");

        if (errors == 0) begin
            $display("PASS: fault_flagger_tb completed");
            $finish;
        end else begin
            $display("FAIL: fault_flagger_tb found %0d issue(s)", errors);
            $fatal;
        end
    end

endmodule

`default_nettype wire
