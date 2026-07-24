//============================================================================
// clk_divider.v -- synchronous power-of-2 clock divider (glitch-free)
//----------------------------------------------------------------------------
// Generates a divided, 50%-duty bit clock for the sensor SPI bus from the
// single system clock. The divide ratio is 2**DIV_LOG2:
//
//     DIV_LOG2 = 1  ->  divide by 2
//     DIV_LOG2 = 2  ->  divide by 4
//     DIV_LOG2 = 3  ->  divide by 8   (DEFAULT: 2 MHz from a 16 MHz clk)
//
// Implementation: the output is simply the MSB of a free-running counter
// clocked by clk_in. Tapping the counter MSB is inherently glitch-free and
// produces an exact 50% duty cycle, and -- crucially for STA/CDC -- the
// divided signal is NEVER used to clock a flip-flop anywhere in the design.
// It is consumed only by clk-domain edge detectors inside spi_master (which
// re-time it to clk) and driven straight out onto the c_sclk pin. The whole
// chip therefore remains a single synchronous clock domain; c_sclk is a
// generated clock for signoff (see librelane/constraints.sdc).
//
// Why /8 (DIV_LOG2=3) and NOT a faster divide -- SPI return-path margin:
//   The sensor drives MISO half an SPI period before spi_master samples it,
//   and the sampled MISO first passes through a 2-FF metastability
//   synchronizer (ff_2_sync, 2-clk latency) plus a 1-clk edge-detect stage.
//   The SPI half-period must therefore be >= ~3-4 clk for the synchronized
//   MISO to be stable at the sample edge. /8 gives a 4-clk half-period (2 clk
//   of margin); /4 gives only 2 clk and samples the PREVIOUS bit (off-by-one).
//   The 2-FF synchronizer is mandatory (RHBD metastability protection), so the
//   half-period -- not the synchronizer -- is what we size.
//
// Clock-rate rationale (see docs/specs/IO_SPECIFICATION.md):
//   * IIS3DWB SPI max clock (datasheet DS12569, fc(SPC)) = 10 MHz;
//     min clock period tc(SPC) = 100 ns. 2 MHz (500 ns) is well inside this.
//   * A DRDY-triggered burst read is 8 (command) + 48 (data) = 56 SPI bits.
//     At 2 MHz that is 28 us, comfortably inside the sensor's 37.5 us sample
//     period (26.667 kHz ODR), leaving ~25% headroom so no sample is dropped.
//     (A 10 MHz system clock with /8 -> 1.25 MHz would take 44.8 us and
//     OVERRUN the sample period -- which is why the system clock is 16 MHz.)
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module clk_divider #(
    parameter integer DIV_LOG2 = 3   // divide ratio = 2**DIV_LOG2 (default /8)
) (
    input  wire clk_in,   // system clock
    input  wire rst_n,    // active-low async reset
    output reg  clk_out   // divided, 50%-duty SPI bit clock
);

    // Counter width equals DIV_LOG2 so its MSB (bit DIV_LOG2-1) toggles with
    // a period of 2**DIV_LOG2 input clocks.
    localparam integer CW = (DIV_LOG2 < 1) ? 1 : DIV_LOG2;

    reg [CW-1:0] count;

    always @(posedge clk_in or negedge rst_n) begin
        if (!rst_n) begin
            count   <= {CW{1'b0}};
            clk_out <= 1'b0;
        end else begin
            count   <= count + 1'b1;
            clk_out <= count[CW-1];
        end
    end

endmodule

`default_nettype wire
