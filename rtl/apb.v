// apb module

module apb (
    input clk,
    input sys_rst_n,
    input [31:0] prdata, // from slave
    input penable, // from slave
    output reg pwrite,
    output reg [31:0] p_addr, // to TMR regs
    output reg [31:0] pwdata,
    output reg psel,
    output reg pready //to core
);
always@(posedge clk or negedge sys_rst_n) begin
    if(!sys_rst_n) begin
        prdata <= 32'd0;
        pready <= 1'b0;
    end else begin
        // APB logic here
    end
end 

endmodule