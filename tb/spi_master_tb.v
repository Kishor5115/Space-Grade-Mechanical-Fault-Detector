`timescale 1ns/1ps
`default_nettype none

module spi_master_tb;

    localparam integer SAMPLE_W   = 8;
    localparam integer SCLK_DIV   = 1;
    localparam integer SAMPLE_DIV = 4;

    reg clk;
    reg rst_n;
    reg miso;
    wire sclk;
    wire cs_n;
    wire data_ready;
    wire signed [SAMPLE_W-1:0] x_n;

    integer errors;
    integer sample_index;
    integer bit_index;
    integer ready_count;
    reg [SAMPLE_W-1:0] spi_word;
    reg [SAMPLE_W-1:0] expected_word;

    spi_master #(
        .SAMPLE_W   (SAMPLE_W),
        .SCLK_DIV   (SCLK_DIV),
        .SAMPLE_DIV (SAMPLE_DIV)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .miso       (miso),
        .sclk       (sclk),
        .cs_n       (cs_n),
        .data_ready (data_ready),
        .x_n        (x_n)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function [SAMPLE_W-1:0] sample_at;
        input integer index;
        begin
            case (index)
                0: sample_at = 8'ha5;
                1: sample_at = 8'h3c;
                default: sample_at = 8'h00;
            endcase
        end
    endfunction

    always @(negedge cs_n) begin
        spi_word = sample_at(sample_index);
        sample_index = sample_index + 1;
        bit_index = SAMPLE_W - 1;
        miso = spi_word[bit_index];
    end

    always @(negedge sclk) begin
        if (!cs_n) begin
            if (bit_index > 0)
                bit_index = bit_index - 1;
            miso = spi_word[bit_index];
        end else begin
            miso = 1'b0;
        end
    end

    task fail;
        input [1023:0] message;
        begin
            errors = errors + 1;
            $display("FAIL: %0s at %0t", message, $time);
        end
    endtask

    task wait_for_ready;
        input [SAMPLE_W-1:0] expected;
        input integer max_cycles;
        integer cycle;
        begin
            for (cycle = 0; cycle < max_cycles && data_ready !== 1'b1; cycle = cycle + 1)
                @(posedge clk);
            if (data_ready !== 1'b1) begin
                fail("data_ready timeout");
            end else begin
                #1;
                if (x_n !== expected) begin
                    errors = errors + 1;
                    $display("FAIL: SPI sample expected 0x%02h got 0x%02h at %0t",
                             expected, x_n, $time);
                end
            end
            @(posedge clk);
            #1;
            if (data_ready !== 1'b0)
                fail("data_ready should be a one-cycle pulse");
        end
    endtask

    initial begin
        errors       = 0;
        sample_index = 0;
        bit_index    = 0;
        ready_count  = 0;
        spi_word     = {SAMPLE_W{1'b0}};
        expected_word = {SAMPLE_W{1'b0}};
        rst_n        = 1'b0;
        miso         = 1'b0;

        repeat (3) @(posedge clk);
        #1;
        if (sclk !== 1'b0 || cs_n !== 1'b1 || data_ready !== 1'b0 || x_n !== 0)
            fail("reset outputs");
        rst_n = 1'b1;

        wait_for_ready(8'ha5, 80);
        wait_for_ready(8'h3c, 80);
        repeat (2) @(posedge clk);
        if (sclk !== 1'b0 && cs_n === 1'b1)
            fail("sclk should park low while idle");

        if (errors == 0) begin
            $display("PASS: spi_master_tb completed");
            $finish;
        end else begin
            $display("FAIL: spi_master_tb found %0d issue(s)", errors);
            $fatal;
        end
    end

endmodule

`default_nettype wire
