//clock frequency divider by 5


module clk_divider_5 (
    input wire clk_in,
    input wire rst_n,
    output reg clk_out
);

reg [2:0] count;

always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        count <= 3'd0;
        clk_out <= 1'b0;
    end else begin
        count <= count + 1;
        clk_out <= count[2];
    end
end

endmodule