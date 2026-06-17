// 2 flip flop synchroniser

module ff_2_sync (
    input  wire clk,
    input  wire async_in,
    output reg  sync_out
);
    reg q1;
    always @(posedge clk) begin
        q1       <= async_in;
        sync_out <= q1;
    end
endmodule