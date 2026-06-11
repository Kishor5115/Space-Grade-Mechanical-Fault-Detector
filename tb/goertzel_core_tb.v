`timescale 1ns/1ps
`default_nettype none

module goertzel_core_tb;

    localparam integer DATA_W   = 24;
    localparam integer SAMPLE_W = 16;
    localparam integer FRAC_W   = 15;

    reg clk;
    reg rst_n;
    reg enable;
    reg data_ready;
    reg signed [SAMPLE_W-1:0] x_n;
    reg signed [DATA_W-1:0] coeff_c;
    reg block_clear;
    wire mult_req;
    wire signed [DATA_W-1:0] mult_a;
    wire signed [DATA_W-1:0] mult_b;
    wire signed [DATA_W-1:0] mult_q;
    wire signed [DATA_W-1:0] v1;
    wire signed [DATA_W-1:0] v2;
    wire sample_done;

    integer errors;
    reg signed [DATA_W-1:0] op_a;
    reg signed [DATA_W-1:0] op_b;
    wire signed [2*DATA_W-1:0] mult_prod;

    goertzel_core #(
        .DATA_W   (DATA_W),
        .SAMPLE_W (SAMPLE_W)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (enable),
        .data_ready  (data_ready),
        .x_n         (x_n),
        .coeff_c     (coeff_c),
        .block_clear (block_clear),
        .mult_req    (mult_req),
        .mult_a      (mult_a),
        .mult_b      (mult_b),
        .mult_q      (mult_q),
        .v1          (v1),
        .v2          (v2),
        .sample_done (sample_done)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

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

    task check_data;
        input signed [DATA_W-1:0] value;
        input signed [DATA_W-1:0] expected;
        input [1023:0] message;
        begin
            if (value !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s expected 0x%06h got 0x%06h at %0t",
                         message, expected[DATA_W-1:0], value[DATA_W-1:0], $time);
            end
        end
    endtask

    task send_sample;
        input signed [SAMPLE_W-1:0] sample;
        input signed [DATA_W-1:0] expected_v1;
        input signed [DATA_W-1:0] expected_v2;
        integer cycle;
        begin
            @(negedge clk);
            x_n = sample;
            data_ready = 1'b1;
            @(negedge clk);
            data_ready = 1'b0;
            for (cycle = 0; cycle < 10 && sample_done !== 1'b1; cycle = cycle + 1)
                @(posedge clk);
            if (sample_done !== 1'b1) begin
                fail("sample_done timeout");
            end else begin
                #1;
                check_data(v1, expected_v1, "v1 after sample");
                check_data(v2, expected_v2, "v2 after sample");
            end
            @(posedge clk);
            #1;
            if (sample_done !== 1'b0)
                fail("sample_done should be one cycle");
        end
    endtask

    initial begin
        errors      = 0;
        rst_n       = 1'b0;
        enable      = 1'b0;
        data_ready  = 1'b0;
        x_n         = {SAMPLE_W{1'b0}};
        coeff_c     = {DATA_W{1'b0}};
        block_clear = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        enable = 1'b1;

        send_sample(16'h1000, 24'h001000, 24'h000000);
        send_sample(16'h2000, 24'h002000, 24'h001000);
        send_sample(16'h3000, 24'h002000, 24'h002000);

        @(negedge clk);
        block_clear = 1'b1;
        @(negedge clk);
        block_clear = 1'b0;
        @(posedge clk);
        #1;
        check_data(v1, 24'h000000, "v1 clear");
        check_data(v2, 24'h000000, "v2 clear");

        if (errors == 0) begin
            $display("PASS: goertzel_core_tb completed");
            $finish;
        end else begin
            $display("FAIL: goertzel_core_tb found %0d issue(s)", errors);
            $fatal;
        end
    end

endmodule

`default_nettype wire
