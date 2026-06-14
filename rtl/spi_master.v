// spi master module

module spi_master (
    input clk,
    input sys_rst_n,
    input sync_data_ready_trig,
    input s_miso,
    output reg s_csn,
    output s_clk,
    output reg s_mosi,
    output [15:0] s_data_out,
    output reg s_data_out_valid
);

always@(posedge clk or negedge sys_rst_n) begin
    if(!sys_rst_n) begin
        s_csn <= 1'b1;
        s_clk <= 1'b0;
        s_mosi <= 1'b0;
        s_data_out <= 16'd0;
        s_data_out_valid <= 1'b0;
    end else begin
        // SPI master logic here
    end
end

endmodule 