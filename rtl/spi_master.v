// spi master module for IIS3DWB (SPI mode 3: CPOL=1, CPHA=1)


module spi_master (
    input  clk,                    // sys clk 50 MHz
    input  sys_rst_n,

    input  sync_data_ready_trig,   // DRDY interrupt from sensor (async)
    input  s_miso,

    input  core_ack,                // core acknowledges data_out_valid

    output reg s_csn,
    output reg s_clk,
    output reg s_mosi,
    output reg [47:0] s_data_out,  // 48-bit left shift-in register. Burst
                                    // order is OUTX_L,OUTX_H,OUTY_L,OUTY_H,
                                    // OUTZ_L,OUTZ_H (earliest-arriving byte
                                    // ends up at the TOP of the register):
                                    // {OUTX_H,OUTX_L,OUTY_H,OUTY_L,OUTZ_H,OUTZ_L}
                                    // (X in bits[47:32], Z in bits[15:0]).
                                    // Verified against iis3dwb_model.v and
                                    // live simulation in tb_top.v -- see
                                    // axis_sequencer.v's xn_comb mux.
    output reg s_data_out_valid    // to core
);

  // ------------------------------------------------------------
  // SPI bit clock: mode 3 idles high, data driven on falling SPC,
  // sampled on rising SPC (per datasheet Section 3.2 / Figure 3).
  // clk_divider_5 produces a 0/1 toggling clk_out; invert/idle-high
  // it only while a transfer is active (CS low). While idle, hold
  // SPC high per mode-3 requirement ("SPC ... stopped high when CS
  // is high").
  // ------------------------------------------------------------
  wire spc_raw;
  clk_divider_5 s_clk_inst (.clk_in(clk), .rst_n(sys_rst_n), .clk_out(spc_raw));

    wire sync_ready_w;
    ff_2_sync ff_sync_drdy (.clk(clk), .async_in(sync_data_ready_trig), .sync_out(sync_ready_w));

    wire s_miso_sync;
    ff_2_sync ff_s_miso (.clk(clk), .async_in(s_miso), .sync_out(s_miso_sync));

  // edge detectors on the divided SPI bit clock, used to gate
  // driving (falling edge) vs sampling (rising edge) of the bus
  reg spc_raw_d;
  always @(posedge clk or negedge sys_rst_n)
  begin
    if (!sys_rst_n)
      spc_raw_d <= 1'b0;
    else
      spc_raw_d <= spc_raw;
  end
  wire spc_rise =  spc_raw & ~spc_raw_d;
  wire spc_fall = ~spc_raw &  spc_raw_d;

  // FSM states (thermometer-coded)
  localparam CFG_INIT  = 8'b00000001;
  localparam CFG_WR    = 8'b01000001;  // drive 16-bit write frame (addr+data)
  localparam CFG_NEXT  = 8'b01000011;  // advance to next boot register or IDLE
  localparam IDLE      = 8'b00000011;
  localparam START     = 8'b00000111;
  localparam TX_ADDR   = 8'b00001111;
  localparam RX_DATA   = 8'b00011111;
  localparam STOP      = 8'b00111111;

    reg [7:0] state;
    reg [5:0] bit_cnt;
    reg [7:0] cmd_byte;

  // Read command for OUTX_L_A (28h), burst auto-increments through
  // OUTX_H, OUTY_L, OUTY_H, OUTZ_L, OUTZ_H (IF_INC=1 by default in
  // CTRL3_C). bit0 = READ(1), bits1-7 = address 010_1000 -> 0xA8.
  localparam CMD_READ_OUTX_BURST = 8'hA8;

  // ------------------------------------------------------------
  // Boot config-write sequence (IIS3DWB datasheet DS12569 Rev 8):
  //   CTRL1_XL   (0x10) <= 0xA0  : XL_EN[2:0]=101 (26.667 kHz ODR), FS=00
  //   FIFO_CTRL4 (0x0A) <= 0x00  : FIFO_MODE=000 (bypass, no FIFO)
  //   CTRL3_C    (0x12) <= 0x04  : IF_INC=1 (auto-increment burst reads)
  //   INT1_CTRL  (0x0D) <= 0x01  : INT1_DRDY_XL=1 (DRDY routed to INT1)
  //
  // Stored as two tiny 4-entry lookup tables (7-bit addr + 8-bit data)
  // indexed by a 2-bit counter, rather than four discrete FSM states:
  // this reuses the SAME 16-bit write-frame datapath for all four
  // registers (one shift counter, one address/data mux) instead of
  // replicating write logic per register. This keeps the added state
  // to a single 2-bit index (4 flops of state total, vs. ~4x the
  // control logic for a fully-unrolled per-register FSM) -- important
  // on an area/power-constrained RHBD part where every flop is
  // triplication-tax'd downstream if promoted to a protected field.
  // ------------------------------------------------------------
  localparam integer NUM_BOOT_REGS = 4;
  reg [6:0] boot_addr [0:NUM_BOOT_REGS-1];
  reg [7:0] boot_data [0:NUM_BOOT_REGS-1];
  reg [1:0] boot_idx;
  reg [4:0] wr_bit_cnt; // 0..15 across the 16-bit write frame
  reg       boot_active; // 1 while boot writes are in flight; routes
                          // the shared START state to CFG_WR instead
                          // of TX_ADDR (single flop, cheaper than
                          // duplicating START for each caller)

  initial begin
    boot_addr[0] = 7'h10; boot_data[0] = 8'hA0; // CTRL1_XL
    boot_addr[1] = 7'h0A; boot_data[1] = 8'h00; // FIFO_CTRL4
    boot_addr[2] = 7'h12; boot_data[2] = 8'h04; // CTRL3_C
    boot_addr[3] = 7'h0D; boot_data[3] = 8'h01; // INT1_CTRL
  end

  // Combinational 16-bit write frame for the current boot_idx:
  // bit0=R/W(0=write), bits1-7=addr MSb-first, bits8-15=data MSb-first.
  // Frame is transmitted MSb-first via boot_frame[15-wr_bit_cnt], so
  // bit position 15 (sent first) must hold R/W, position 8 must hold
  // addr[0] (sent last of the address field), etc.
  wire [15:0] boot_frame = {1'b0, boot_addr[boot_idx], boot_data[boot_idx]};

  always @(posedge clk or negedge sys_rst_n)
  begin
    if (!sys_rst_n)
    begin
      s_csn           <= 1'b1;
      s_clk           <= 1'b1;   // mode 3: idle high
      s_mosi          <= 1'b0;
      s_data_out      <= 48'd0;
      s_data_out_valid<= 1'b0;
      state           <= CFG_INIT;
      bit_cnt         <= 6'd0;
      cmd_byte        <= 8'd0;
      boot_idx        <= 2'd0;
      wr_bit_cnt      <= 5'd0;
      boot_active     <= 1'b0;
    end
    else
    begin
      s_data_out_valid <= 1'b0; // default; pulsed for 1 cycle in STOP

            case (state)

        // Power-on boot sequence: write the 4 mandatory config
        // registers (CTRL1_XL, FIFO_CTRL4, CTRL3_C, INT1_CTRL) before
        // ever looking at sync_data_ready_trig, per the IIS3DWB
        // datasheet. cmd_byte for the read-burst path is latched
        // here once and reused for every subsequent read (it never
        // changes), so this state only runs once at power-up.
        CFG_INIT:
        begin
          s_csn      <= 1'b1;
          s_clk      <= 1'b1;
          s_mosi     <= 1'b0;
          cmd_byte   <= CMD_READ_OUTX_BURST;
          boot_idx   <= 2'd0;
          wr_bit_cnt <= 5'd0;
          boot_active<= 1'b1;
          state      <= START;
          // NOTE: reuses the START/CFG_WR/CFG_NEXT path below instead
          // of a bespoke first-write FSM -- START just needs to know
          // whether to route to TX_ADDR (read burst) or CFG_WR (boot
          // write) next, which is decided by an explicit "in boot
          // sequence" state below rather than by adding a new signal.
        end

        CFG_WR:
        begin
          // 16-bit write frame: bit0=R/W(0), bits1-7=addr, bits8-15=data,
          // MSb-first -- identical protocol/edge-timing to the read
          // burst's TX_ADDR state, just reusing boot_frame as the byte
          // source instead of cmd_byte.
          s_clk <= spc_raw;
          if (spc_fall) begin
            s_mosi <= boot_frame[15 - wr_bit_cnt];
          end
          if (spc_rise) begin
            wr_bit_cnt <= wr_bit_cnt + 1'b1;
            if (wr_bit_cnt == 5'd15) begin
              wr_bit_cnt <= 5'd0;
              state      <= CFG_NEXT;
            end
          end
        end

        CFG_NEXT:
        begin
          // One-cycle CS deassert between back-to-back boot writes
          // (datasheet requires CS to toggle between accesses), then
          // either move to the next boot register or fall through to
          // the normal read-burst IDLE loop once all 4 are written.
          s_csn <= 1'b1;
          if (boot_idx == NUM_BOOT_REGS-1) begin
            boot_idx    <= 2'd0;
            boot_active <= 1'b0;
            state       <= IDLE;
          end else begin
            boot_idx <= boot_idx + 1'b1;
            state    <= START;
          end
        end

        IDLE:
        begin
          s_csn <= 1'b1;
          s_clk <= 1'b1;          // hold SPC high while CS high
          if (sync_ready_w)
          begin
            bit_cnt <= 6'd0;
            state   <= START;
          end
        end

        START:
        begin
          s_csn <= 1'b0;          // CS low: sensor selected
          bit_cnt <= 6'd0;
          state <= boot_active ? CFG_WR : TX_ADDR;
        end

                TX_ADDR: begin
                    s_clk <= spc_raw;
                    if (spc_fall) begin
                        s_mosi <= cmd_byte[7 - bit_cnt];
                    end
                    if (spc_rise) begin
                        bit_cnt <= bit_cnt + 1'b1;
                        if (bit_cnt == 6'd7) begin
                            bit_cnt <= 6'd0;
                            state   <= RX_DATA;
                        end
                    end
                end

                RX_DATA: begin
                    s_clk <= spc_raw;
                    if (spc_rise) begin
                        s_data_out <= {s_data_out[46:0], s_miso_sync};
                        bit_cnt    <= bit_cnt + 1'b1;
                        if (bit_cnt == 6'd47) begin
                            state <= STOP;
                        end
                    end
                end

        STOP:
        begin
          s_csn  <= 1'b1;
          s_data_out_valid <= 1'b1; // Pulse high

          // HOLD HERE until core acknowledges
          if (core_ack)
          begin
            s_data_out_valid <= 1'b0;
            state <= IDLE;
          end
          else
          begin
            state<=STOP;
          end
        end

        default:
          state <= CFG_INIT;
      endcase
    end
  end

endmodule