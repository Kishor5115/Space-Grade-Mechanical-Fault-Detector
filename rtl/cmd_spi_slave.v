//============================================================================
// cmd_spi_slave.v -- external configuration receiver (command SPI slave)
//----------------------------------------------------------------------------
// Receives Goertzel coefficients / threshold / control writes from an external
// host (e.g. a RISC-V core) and turns each frame into a single APB write via
// the request handshake below. Write-only: the host only ever pushes config
// into this chip; fault status leaves on the dedicated fault_flag_out pin.
//
// SINGLE-CLOCK, OVERSAMPLED design (NO second clock domain):
//   The incoming cmd_sclk / cmd_csn / cmd_mosi are treated as ASYNCHRONOUS
//   inputs. Each is passed through the same 2-FF metastability synchronizer
//   (ff_2_sync) used elsewhere in the chip, and SCLK edges are detected in the
//   core clk domain -- identical in spirit to how spi_master samples the
//   sensor's s_miso. Nothing here is clocked by cmd_sclk, so the whole design
//   stays in the single system-clock domain: no inter-clock CDC, no extra STA
//   clock groups. The only requirement is that the host clock the command bus
//   at cmd_sclk <= clk/4 (>=4x oversampling); at clk = 16 MHz that means
//   cmd_sclk <= 4 MHz, trivially satisfied for a boot-time config transfer.
//
// SPI mode 3 (CPOL=1/CPHA=1): SCLK idles high, host drives MOSI on the falling
// edge, slave samples on the RISING edge.
//
// Frame = 40 bits, MSB first, sent with cmd_csn held low for the whole frame:
//     bits [39:32] = register byte address (matches tmr_reg_bank map:
//                    0x00 CTRL, 0x04 CFG_C0, 0x08 CFG_C1, 0x0C CFG_C2,
//                    0x10 CFG_THRESHOLD)
//     bits [31:0]  = 32-bit write data (24-bit coeffs are zero-extended)
//   The write is issued on the rising (deassert) edge of cmd_csn, and only
//   if exactly 40 bits were shifted in (partial/garbled frames are ignored).
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module cmd_spi_slave (
    input  wire        clk,
    input  wire        rst_n,

    // external command SPI bus (async inputs from the host)
    input  wire        cmd_sclk,
    input  wire        cmd_csn,
    input  wire        cmd_mosi,

    // APB-request handshake toward an apb master (write-only)
    output reg         req_valid,
    output wire        req_write,
    output reg  [31:0] req_addr,
    output reg  [31:0] req_wdata,
    input  wire        req_done
);

    assign req_write = 1'b1; // this slave only ever writes config registers

    // ---- 2-FF synchronize the async SPI pins into the clk domain ----
    wire sclk_s, csn_s, mosi_s;
    ff_2_sync sync_sclk (.clk(clk), .async_in(cmd_sclk), .sync_out(sclk_s));
    ff_2_sync sync_csn  (.clk(clk), .async_in(cmd_csn),  .sync_out(csn_s));
    ff_2_sync sync_mosi (.clk(clk), .async_in(cmd_mosi), .sync_out(mosi_s));

    // ---- edge detectors in the clk domain ----
    reg sclk_d, csn_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sclk_d <= 1'b1; csn_d <= 1'b1; end
        else        begin sclk_d <= sclk_s; csn_d <= csn_s; end
    end
    wire sclk_rise = sclk_s & ~sclk_d;      // mode-3 sample edge
    wire csn_fall  = ~csn_s &  csn_d;       // frame start
    wire csn_rise  =  csn_s & ~csn_d;       // frame end (deassert)

    // ---- frame shift register + bit counter ----
    localparam integer FRAME_BITS = 40;
    reg [39:0] shreg;
    reg [5:0]  bit_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shreg   <= 40'd0;
            bit_cnt <= 6'd0;
        end else begin
            if (csn_fall) begin
                // new frame: clear the bit counter (shreg refilled as bits arrive)
                bit_cnt <= 6'd0;
            end else if (!csn_s && sclk_rise) begin
                // sample MOSI on the rising SCLK edge, MSB-first
                shreg   <= {shreg[38:0], mosi_s};
                if (bit_cnt != 6'd63) bit_cnt <= bit_cnt + 1'b1;
            end
        end
    end

    // ---- emit one APB write per complete 40-bit frame ----
    // A boot-time config SPI bus (<=4 MHz) is orders of magnitude slower than
    // the 16 MHz APB write it triggers, so a single outstanding request never
    // overruns; we simply latch on frame-complete and hold req_valid until the
    // apb master reports req_done.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_valid <= 1'b0;
            req_addr  <= 32'd0;
            req_wdata <= 32'd0;
        end else begin
            if (csn_rise && bit_cnt == FRAME_BITS && !req_valid) begin
                req_valid <= 1'b1;
                req_addr  <= {24'd0, shreg[39:32]};
                req_wdata <= shreg[31:0];
            end else if (req_valid && req_done) begin
                req_valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
