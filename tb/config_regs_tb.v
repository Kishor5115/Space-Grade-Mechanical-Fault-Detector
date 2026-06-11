`timescale 1ns/1ps
`default_nettype none

module config_regs_tb;

    localparam integer APB_AW = 8;
    localparam integer APB_DW = 32;
    localparam integer DATA_W = 24;
    localparam integer MAG_W  = 24;

    localparam [APB_AW-1:0] ADDR_COEFF   = 8'h00;
    localparam [APB_AW-1:0] ADDR_THRESH  = 8'h04;
    localparam [APB_AW-1:0] ADDR_CONTROL = 8'h08;

    reg                    clk;
    reg                    rst_n;
    reg                    PSEL;
    reg                    PENABLE;
    reg                    PWRITE;
    reg  [APB_AW-1:0]      PADDR;
    reg  [APB_DW-1:0]      PWDATA;
    wire [APB_DW-1:0]      PRDATA;
    wire                   PREADY;
    reg                    alarm_active;
    wire signed [DATA_W-1:0] cfg_coeff_c;
    wire [MAG_W-1:0]       cfg_thresh_sq;
    wire                   cfg_enable;
    wire                   cfg_rst_alarm;

    integer errors;
    reg [APB_DW-1:0] read_data;

    config_regs #(
        .APB_AW (APB_AW),
        .APB_DW (APB_DW),
        .DATA_W (DATA_W),
        .MAG_W  (MAG_W)
    ) dut (
        .PCLK          (clk),
        .PRESETn       (rst_n),
        .PSEL          (PSEL),
        .PENABLE       (PENABLE),
        .PWRITE        (PWRITE),
        .PADDR         (PADDR),
        .PWDATA        (PWDATA),
        .PRDATA        (PRDATA),
        .PREADY        (PREADY),
        .alarm_active  (alarm_active),
        .cfg_coeff_c   (cfg_coeff_c),
        .cfg_thresh_sq (cfg_thresh_sq),
        .cfg_enable    (cfg_enable),
        .cfg_rst_alarm (cfg_rst_alarm)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task fail;
        input [1023:0] message;
        begin
            errors = errors + 1;
            $display("FAIL: %0s at %0t", message, $time);
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

    task check_bit;
        input value;
        input expected;
        input [1023:0] message;
        begin
            if (value !== expected)
                fail(message);
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
        input [APB_AW-1:0] addr;
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

    initial begin
        errors       = 0;
        rst_n        = 1'b0;
        PSEL         = 1'b0;
        PENABLE      = 1'b0;
        PWRITE       = 1'b0;
        PADDR        = {APB_AW{1'b0}};
        PWDATA       = {APB_DW{1'b0}};
        alarm_active = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        check_bit(PREADY, 1'b1, "PREADY should be tied high");
        check_bit(cfg_enable, 1'b0, "enable reset value");
        check_bit(cfg_rst_alarm, 1'b0, "reset-alarm reset value");
        check_word({{(APB_DW-DATA_W){cfg_coeff_c[DATA_W-1]}}, cfg_coeff_c}, 32'h00000000, "coefficient reset value");
        check_word({{(APB_DW-MAG_W){1'b0}}, cfg_thresh_sq}, 32'h00000000, "threshold reset value");

        apb_write(ADDR_COEFF, 32'h00ff8000);
        apb_write(ADDR_THRESH, 32'h0055aa33);
        alarm_active = 1'b1;
        apb_write(ADDR_CONTROL, 32'h00000003);
        @(posedge clk);
        check_bit(cfg_enable, 1'b1, "enable write");
        check_bit(cfg_rst_alarm, 1'b1, "reset_alarm should pulse after control write");
        @(posedge clk);
        check_bit(cfg_rst_alarm, 1'b0, "reset_alarm should self clear");

        apb_read(ADDR_COEFF, read_data);
        check_word(read_data, 32'hffff8000, "signed coefficient readback");
        apb_read(ADDR_THRESH, read_data);
        check_word(read_data, 32'h0055aa33, "threshold readback");
        apb_read(ADDR_CONTROL, read_data);
        check_bit(read_data[0], 1'b1, "enable status readback");
        check_bit(read_data[8], 1'b1, "alarm_active status readback");

        apb_write(8'hfc, 32'hffffffff);
        apb_read(8'hfc, read_data);
        check_word(read_data, 32'h00000000, "unknown address readback");

        if (errors == 0) begin
            $display("PASS: config_regs_tb completed");
            $finish;
        end else begin
            $display("FAIL: config_regs_tb found %0d issue(s)", errors);
            $fatal;
        end
    end

endmodule

`default_nettype wire
