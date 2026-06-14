// goertzel core shell

module goertzel_core (
    input clk,
    input rst_n,

    //from TMR reg bank
    input [15:0] cfg_c,
    input [15:0] cfg_n,
    input cfg_start,

    // to fault flagger (mag comparator)
    output reg [31:0] mag_out,
    output reg mag_out_valid
);
always@(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        mag_out <= 32'd0;
        mag_out_valid <= 1'b0;
    end else begin
        // Goertzel core logic here
    end
end 

endmodule