// TMR register bank

module tmr_reg_bank (
    input clk,
    input rst_n,

    //from APB
    input [31:0] p_addr,
    input [31:0] pwdata,
    input psel,
    input pwrite, 
    input penable, 

    // to APB
    output reg [31:0] prdata,
    output reg pready, 

    //to Goertzel core
    output reg [15:0] cfg_c,
    output reg [15:0] cfg_n,
    output reg cfg_start,

    // to fault flagger (mag comparator)
    output reg [31:0] cfg_threshold
);
always@(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        prdata <= 32'd0;
        pready <= 1'b0;
        cfg_c <= 16'd0;
        cfg_n <= 16'd0;
        cfg_start <= 1'b0;
        cfg_threshold <= 32'd0;
    end else begin
        // TMR register bank logic here
    end
end

endmodule