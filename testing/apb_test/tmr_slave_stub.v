// tmr_slave_stub.v
//
// Lightweight APB slave test double for tb_spi_apb_interface.v.
//
// tb_spi_apb_interface.v only needs to verify that spi_apb_interface's
// Option-B forwarder issues exactly the right sequence of APB writes
// (address + data, in order) -- it does not need TMR voting, scrubbing,
// or the full tmr_reg_bank.v register map. Wiring in the real
// tmr_reg_bank.v for this purpose is both wrong (it doesn't expose
// last_wr_addr/last_wr_data/wr_event monitor ports, so it doesn't even
// elaborate against this testbench) and unnecessary (it drags in ~150
// lines of TMR voting/scrub logic that this test isn't exercising).
//
// This stub implements just enough APB slave protocol (SETUP/ACCESS
// with pready asserted combinationally -- zero wait states) to accept
// writes and no-op reads, while exposing the three monitor signals the
// testbench watches:
//   last_wr_addr / last_wr_data : captured on every accepted write
//   wr_event                    : 1-cycle pulse, one per accepted write
`timescale 1ns/1ps
`default_nettype none

module tmr_slave_stub (
    input  wire        clk,
    input  wire        sys_rst_n,

    input  wire [31:0] p_addr,
    input  wire [31:0] pwdata,
    input  wire        psel,
    input  wire        pwrite,
    input  wire        penable,
    output reg  [31:0] prdata,
    output wire         pready,

    output reg  [31:0] last_wr_addr,
    output reg  [31:0] last_wr_data,
    output reg          wr_event
);

    // Zero-wait-state slave: ready the same cycle penable asserts.
    assign pready = psel & penable;

    wire apb_write = psel & penable & pwrite;

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            last_wr_addr <= 32'd0;
            last_wr_data <= 32'd0;
            wr_event     <= 1'b0;
            prdata       <= 32'd0;
        end else begin
            wr_event <= 1'b0; // default; pulsed below on an accepted write
            if (apb_write) begin
                last_wr_addr <= p_addr;
                last_wr_data <= pwdata;
                wr_event     <= 1'b1;
            end
            if (psel & penable & !pwrite) begin
                prdata <= 32'd0; // reads always return 0; unused by this test
            end
        end
    end

endmodule
`default_nettype wire
