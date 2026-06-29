// tmr_reg_bank.v
//
// Minimal behavioral APB slave stub standing in for tmr_reg_bank.v,
// used only to verify spi_apb_interface's Option-B forwarding path.
// Implements a simple memory-mapped write-capable register file with
// zero wait states (pready asserted combinationally with psel&penable).

module tmr_reg_bank (
    input  wire        clk,
    input  wire        sys_rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] p_addr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,

    // testbench-visible: last captured write, for checking
    output reg [31:0] last_wr_addr,
    output reg [31:0] last_wr_data,
    output reg         wr_event
);

    assign pready = psel & penable; // zero-wait-state slave

    reg [31:0] mem [0:255];

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            wr_event <= 1'b0;
        end else begin
            wr_event <= 1'b0;
            if (psel && penable) begin
                if (pwrite) begin
                    mem[p_addr[9:2]] <= pwdata; // word-addressed
                    last_wr_addr     <= p_addr;
                    last_wr_data     <= pwdata;
                    wr_event         <= 1'b1;
                end else begin
                    prdata <= mem[p_addr[9:2]];
                end
            end
        end
    end

endmodule