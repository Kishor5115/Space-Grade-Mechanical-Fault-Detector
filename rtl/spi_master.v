// spi master module for IIS3DWB (SPI mode 3: CPOL=1, CPHA=1)
`include "clk_divider_5.v"
`include "ff_2_sync.v"

module spi_master (
    input  clk,                    // sys clk 50 MHz
    input  sys_rst_n,

    input  sync_data_ready_trig,   // DRDY interrupt from sensor (async)
    input  s_miso,

    input core_ack,                // core acknowledges data_out_valid

    output reg s_csn,
    output reg s_clk,
    output reg s_mosi,
    output reg [47:0] s_data_out,  // {OUTX_H,OUTX_L,OUTY_H,OUTY_L,OUTZ_H,OUTZ_L}, to core
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
    localparam INIT_ZERO = 8'h00;
  localparam CFG_INIT = 8'b00000001;
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

    reg sub_fsm_en; //needed for config sub fsm
    reg sub_fsm_done; 
    
  always @(posedge clk or negedge sys_rst_n)
  begin
    if (!sys_rst_n)
    begin
      s_csn           <= 1'b1;
      s_clk           <= 1'b1;   // mode 3: idle high
      s_mosi          <= 1'b0;
      s_data_out      <= 48'd0;
      s_data_out_valid<= 1'b0;
      state           <= INIT_ZERO;
      bit_cnt         <= 6'd0;
      cmd_byte        <= 8'd0;
    end
    else
    begin
      s_data_out_valid <= 1'b0; // default; pulsed for 1 cycle in STOP

      case (state)

        // NOTE: accelerometer init (CTRL1_XL enable, FS select,
        // ODR/FIFO config) must happen here over a separate
        // write sequence before relying on DRDY. Left as a
        // TODO hook; this fix focuses on the read-burst FSM.

          INIT_ZERO: begin
              s_csn           <= 1'b1;
                s_clk           <= 1'b1;   // mode 3: idle high
              s_mosi          <= 1'b0;
              s_data_out      <= 48'd0;
              s_data_out_valid<= 1'b0;
              state           <= INIT_ZERO;
              bit_cnt         <= 6'd0;
              cmd_byte        <= 8'd0;
              state<=CFG_INIT;
          end
        CFG_INIT:
        begin
            sub_fsm_en <= 1'b1;
            if (sub_fsm_done) begin 
                state <= IDLE;
                sub_fsm_done<=1'b0;
            end
            else state <=CFG_INIT;
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
          state <= TX_ADDR;
        end

        TX_ADDR:
        begin
          s_clk <= spc_raw;
          // drive MOSI on SPC falling edge, MSb first
          if (spc_fall)
          begin
            s_mosi <= cmd_byte[7 - bit_cnt];
          end
          if (spc_rise)
          begin
            bit_cnt <= bit_cnt + 1'b1;
            if (bit_cnt == 6'd7)
            begin
              bit_cnt <= 6'd0;
              state   <= RX_DATA;
            end
          end
        end

        RX_DATA:
        begin
          s_clk <= spc_raw;
          // sample MISO on SPC rising edge, MSb first, 48 bits total
          if (spc_rise)
          begin
            s_data_out <= {s_data_out[46:0], s_miso_sync};
            bit_cnt <= bit_cnt + 1'b1;
            if (bit_cnt == 6'd47)
            begin
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
            state <= INIT_ZERO; // or IDLE (i am not sure of which state)
      endcase
    end
  end

    //CFG_INIT Sub FSM for configuration of registers before actual data transfer occurs

    reg [3:0] sub_state;    
    reg [7:0] config_addr;    // Targeted register
    reg [7:0] config_data;    // Data to write

    localparam RESET_SUB <=5'b00000;
    localparam SET_ODR <=5'b00001;
    localparam FIFO_BYPASS <=5'b00011;
    localparam IF_INC_EN <= 5'b00111;
    localparam INT1_EN <= 5'b01111;
    localparam DONE <= 5'b11111;
    
    
    always @(posedge clk) begin
        if (sub_fsm_en) begin
        case (sub_state)
            RESET_SUB: begin
                sub_state<=SET_ODR;
            end
            SET_ODR: begin // CTRL1_XL: ODR=12.5Hz
                {config_addr, config_data} <= {8'h10, 8'h60}; 

                //TODO: IS THIS THE CORRECT WAY TO PERFORM TX WRITE FOR CONFIG
                
              s_clk <= spc_raw;
              // drive MOSI on SPC falling edge, MSb first
                if (spc_fall) begin
                    s_mosi <= cmd_byte[7 - bit_cnt];
              end
                if (spc_rise) begin
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 6'd7) begin
                          bit_cnt <= 6'd0;
                    end
              end
            end
            FIFO_BYPASS: begin // FIFO_CTRL4: Bypass Mode
                {config_addr, config_data} <= {8'h0A, 8'h00}; 
            end
            IF_INC_EN: begin // CTRL3_C: IF_INC enabled
                {config_addr, config_data} <= {8'h12, 8'h04}; 
            end
            INT1_EN: begin // CTRL4_C: Int1 enabled
                {config_addr, config_data} <= {8'h13, 8'h01}; 
            end
            DONE: begin 
                sub_fsm_en <=1'b0;
                sub_fsm_done <= 1'b1; 
            end
        endcase
    end
        else sub_state<=RESET_SUB;
end

endmodule
