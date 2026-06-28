// iis3dwb_model.v

// includes normal functioning only. doesnt consider the case of any radiation hampering the module

// behavioral model of the IIS3DWB SPI slave (mode 3), used
// only to verify spi_master.v protocol compliance in simulation.
//
// SDI/SDO driven at the falling edge of SPC, captured at the rising edge of SPC. Frame = 16 clocks for a
// single-byte access, +8 clocks per extra byte in a burst.
//   bit 0       : R/W bit (1=read, 0=write)
//   bits 1-7    : address AD[6:0], MSb first
//   bits 8-15.. : data DI/DO[7:0] (..per byte), MSb first


module iis3dwb_model (
    input  wire csn,
    input  wire sclk,
    input  wire mosi,
    output reg  miso,

    output reg        rw_bit_q,      // latched R/W bit for this frame
    output reg [6:0]  addr_q,        // latched address for this frame
    output reg [7:0]  wr_data_q,     // latched write data (valid when wr_event pulses)
    output reg         wr_event,      // 1-clk pulse: 16-bit write frame complete
    output reg         addr_known_event, // 1-clk pulse: R/W + addr fully captured (after bit 7)
    output reg [47:0] rd_burst_sent, // value actually shifted out for a burst read, latched at CS rising

    input wire [15:0] model_outx,
    input wire [15:0] model_outy,
    input wire [15:0] model_outz
);

    reg [5:0] bit_idx;       // 0-based index of the bit currently being captured
    reg [6:0] addr_shift;    // shifts in AD6..AD0 as they arrive
    reg [7:0] data_shift;    // shifts in the active data byte as it arrives

    wire [47:0] burst_payload = {
        model_outx[7:0],  model_outx[15:8],   // OUTX_L_A (sent first), OUTX_H_A
        model_outy[7:0],  model_outy[15:8],   // OUTY_L_A, OUTY_H_A
        model_outz[7:0],  model_outz[15:8]    // OUTZ_L_A, OUTZ_H_A
    };

    reg [47:0] tx_shift;

    // ---- capture path: sample MOSI on SCLK rising edge ----
    always @(posedge sclk or posedge csn) begin
        if (csn) begin
            bit_idx          <= 6'd0;
            wr_event         <= 1'b0;
            addr_known_event <= 1'b0;
        end else begin
            wr_event         <= 1'b0;
            addr_known_event <= 1'b0;

            if (bit_idx == 6'd0) begin
                rw_bit_q <= mosi;                 // bit 0: R/W
            end else if (bit_idx >= 6'd1 && bit_idx <= 6'd7) begin
                addr_shift <= {addr_shift[5:0], mosi}; // bits 1-7: address, MSb first
                if (bit_idx == 6'd7) begin
                    addr_q            <= {addr_shift[5:0], mosi};
                    addr_known_event  <= 1'b1;
                end
            end else begin
                // data phase: bits 8-15 (first byte), 16-23 (second byte), etc.
                data_shift <= {data_shift[6:0], mosi};
                if (bit_idx[2:0] == 3'd7) begin
                    // a full data byte (8 bits) just landed on this edge
                    if (bit_idx == 6'd15 && rw_bit_q == 1'b0) begin
                        wr_data_q <= {data_shift[6:0], mosi};
                        wr_event  <= 1'b1;
                    end
                end
            end

            bit_idx <= bit_idx + 1'b1;
        end
    end

    // ---- drive path: shift MISO out on SCLK falling edge ----
    // Slave only drives once R/W+addr are known (datasheet: "the chip
    // drives SDO at the start of bit 8"), and only for read frames.
    always @(negedge sclk or posedge csn) begin
        if (csn) begin
            miso     <= 1'b0;
            tx_shift <= burst_payload;
        end else if (bit_idx == 6'd8 && rw_bit_q == 1'b1) begin
            // first falling edge of the data phase: load and present MSb
            tx_shift <= {burst_payload[46:0], 1'b0};
            miso     <= burst_payload[47];
        end else if (bit_idx > 6'd8 && rw_bit_q == 1'b1) begin
            miso     <= tx_shift[47];
            tx_shift <= {tx_shift[46:0], 1'b0};
        end else begin
            miso <= 1'b0;
        end
    end

    always @(posedge csn) begin
        if (rw_bit_q) rd_burst_sent <= burst_payload;
    end

endmodule