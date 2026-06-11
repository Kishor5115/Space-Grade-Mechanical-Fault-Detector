`timescale 1ns/1ps
`default_nettype none

module vibration_top_tb;

    localparam integer DATA_W     = 24;
    localparam integer FRAC_W     = 15;
    localparam integer SAMPLE_W   = 16;
    localparam integer MAG_W      = 24;
    localparam integer APB_AW     = 8;
    localparam integer APB_DW     = 32;
    localparam integer BLOCK_N    = 2;
    localparam integer DEB_W      = 4;
    localparam integer DEB_TARGET = 2;
    localparam integer SCLK_DIV   = 1;
    localparam integer SAMPLE_DIV = 16;

    localparam [APB_AW-1:0] ADDR_COEFF   = 8'h00;
    localparam [APB_AW-1:0] ADDR_THRESH  = 8'h04;
    localparam [APB_AW-1:0] ADDR_CONTROL = 8'h08;

    reg                  clk;
    reg                  rst_n;
    reg                  miso;
    wire                 sclk;
    wire                 cs_n;
    reg                  PSEL;
    reg                  PENABLE;
    reg                  PWRITE;
    reg  [APB_AW-1:0]    PADDR;
    reg  [APB_DW-1:0]    PWDATA;
    wire [APB_DW-1:0]    PRDATA;
    wire                 PREADY;
    wire                 hw_interrupt;

    integer errors;
    integer sample_count;
    integer bit_index;
    reg [SAMPLE_W-1:0] spi_word;
    reg [APB_DW-1:0] read_data;

    vibration_top #(
        .DATA_W     (DATA_W),
        .FRAC_W     (FRAC_W),
        .SAMPLE_W   (SAMPLE_W),
        .MAG_W      (MAG_W),
        .APB_AW     (APB_AW),
        .APB_DW     (APB_DW),
        .BLOCK_N    (BLOCK_N),
        .DEB_W      (DEB_W),
        .DEB_TARGET (DEB_TARGET),
        .SCLK_DIV   (SCLK_DIV),
        .SAMPLE_DIV (SAMPLE_DIV)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .miso         (miso),
        .sclk         (sclk),
        .cs_n         (cs_n),
        .PSEL         (PSEL),
        .PENABLE      (PENABLE),
        .PWRITE       (PWRITE),
        .PADDR        (PADDR),
        .PWDATA       (PWDATA),
        .PRDATA       (PRDATA),
        .PREADY       (PREADY),
        .hw_interrupt (hw_interrupt)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function [SAMPLE_W-1:0] adc_sample;
        input integer index;
        begin
            case (index)
                0, 1, 2, 3, 4, 5: adc_sample = 16'h4000;
                default:          adc_sample = 16'h0000;
            endcase
        end
    endfunction

    always @(negedge cs_n) begin
        spi_word = adc_sample(sample_count);
        sample_count = sample_count + 1;
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

    task check_bit;
        input value;
        input expected;
        input [1023:0] message;
        begin
            if (value !== expected)
                fail(message);
        end
    endtask

    task check_word;
        input [APB_DW-1:0] value;
        input [APB_DW-1:0] expected;
        input [1023:0] message;
        begin
            if (value !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s expected 0x%08h got 0x%08h at %0t",
                         message, expected, value, $time);
            end
        end
    endtask

    task apb_write;
        input [APB_AW-1:0] addr;
        input [APB_DW-1:0] data;
        begin
            @(negedge clk);
            PADDR   = addr;
            PWDATA  = data;
            PWRITE  = 1'b1;
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            @(negedge clk);
            PENABLE = 1'b1;
            @(negedge clk);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = {APB_AW{1'b0}};
            PWDATA  = {APB_DW{1'b0}};
        end
    endtask

    task apb_read;
        input  [APB_AW-1:0] addr;
        output [APB_DW-1:0] data;
        begin
            @(negedge clk);
            PADDR   = addr;
            PWRITE  = 1'b0;
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            @(posedge clk);
            #1 data = PRDATA;
            @(negedge clk);
            PENABLE = 1'b1;
            @(negedge clk);
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PADDR   = {APB_AW{1'b0}};
        end
    endtask

    task wait_for_irq;
        input expected;
        input integer max_cycles;
        input [1023:0] message;
        integer cycle;
        begin
            for (cycle = 0; cycle < max_cycles && hw_interrupt !== expected; cycle = cycle + 1)
                @(posedge clk);
            if (hw_interrupt !== expected)
                fail(message);
        end
    endtask

    task wait_cycles;
        input integer count;
        integer cycle;
        begin
            for (cycle = 0; cycle < count; cycle = cycle + 1)
                @(posedge clk);
        end
    endtask

    initial begin
        errors       = 0;
        sample_count = 0;
        bit_index    = 0;
        spi_word     = {SAMPLE_W{1'b0}};
        rst_n        = 1'b0;
        miso         = 1'b0;
        PSEL         = 1'b0;
        PENABLE      = 1'b0;
        PWRITE       = 1'b0;
        PADDR        = {APB_AW{1'b0}};
        PWDATA       = {APB_DW{1'b0}};

        wait_cycles(4);
        rst_n = 1'b1;
        wait_cycles(2);

        check_bit(PREADY, 1'b1, "APB slave should be zero-wait-state ready");

        apb_write(ADDR_COEFF,   32'h00000000);
        apb_write(ADDR_THRESH,  32'h00000000);
        apb_write(ADDR_CONTROL, 32'h00000001);

        apb_read(ADDR_COEFF, read_data);
        check_word(read_data, 32'h00000000, "coefficient register readback");
        apb_read(ADDR_THRESH, read_data);
        check_word(read_data, 32'h00000000, "threshold register readback");
        apb_read(ADDR_CONTROL, read_data);
        check_bit(read_data[0], 1'b1, "enable bit should read back high");
        check_bit(read_data[8], 1'b0, "alarm status should start low");

        wait_for_irq(1'b1, 600, "fault interrupt should assert after debounced bad blocks");
        if (sample_count < (BLOCK_N * DEB_TARGET))
            fail("interrupt asserted before enough SPI samples were launched");

        apb_read(ADDR_CONTROL, read_data);
        check_bit(read_data[8], 1'b1, "alarm status should mirror interrupt");

        apb_write(ADDR_THRESH, 32'h00ffffff);
        apb_write(ADDR_CONTROL, 32'h00000003);
        wait_for_irq(1'b0, 20, "reset_alarm strobe should clear interrupt");

        apb_read(ADDR_CONTROL, read_data);
        check_bit(read_data[0], 1'b1, "enable should remain high when clearing alarm");
        check_bit(read_data[8], 1'b0, "alarm status should clear after reset_alarm");

        wait_cycles(260);
        check_bit(hw_interrupt, 1'b0, "high threshold should prevent interrupt retrigger");

        if (errors == 0) begin
            $display("PASS: vibration_top self-checking testbench completed");
            $finish;
        end else begin
            $display("FAIL: vibration_top self-checking testbench found %0d issue(s)", errors);
            $fatal;
        end
    end

endmodule

`default_nettype wire
