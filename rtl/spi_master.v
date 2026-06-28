// spi master module for IIS3DWB (SPI mode 3: CPOL=1, CPHA=1)
`include "clk_divider_5.v"
`include "ff_2_sync.v"

module spi_master (
    input  clk,                    // sys clk 50 MHz
    input  sys_rst_n,

    input  sync_data_ready_trig,   // DRDY interrupt from sensor (async)
    input  s_miso,

    input  core_ack,                // core acknowledges data_out_valid

    output reg s_csn,
    output reg s_clk,
    output reg s_mosi,
    output reg [47:0] s_data_out,  // {OUTX_H,OUTX_L,OUTY_H,OUTY_L,OUTZ_H,OUTZ_L}, to core
    output reg s_data_out_valid    // to core
);

    wire spc_raw;
    clk_divider_5 s_clk_inst (.clk_in(clk), .rst_n(sys_rst_n), .clk_out(spc_raw));

    wire sync_ready_w;
    ff_2_sync ff_sync_drdy (.clk(clk), .async_in(sync_data_ready_trig), .sync_out(sync_ready_w));

    wire s_miso_sync;
    ff_2_sync ff_s_miso (.clk(clk), .async_in(s_miso), .sync_out(s_miso_sync));

    // IMPORTANT: edge detection is derived from the actual s_clk
    // OUTPUT wire (what the slave/model physically sees on SPC),
    // not from spc_raw directly. s_clk <= spc_raw inside TX_ADDR/
    // RX_DATA is a *registered* copy, one cycle behind spc_raw.
    // Detecting edges on spc_raw directly made bit_cnt increment a
    // full cycle before the corresponding edge ever appeared on
    // s_clk, so the master's bit count silently ran ahead of what
    // it had actually clocked out -- intermittently masked by
    // whatever phase spc_raw/csn happened to align to, which is why
    // it passed on some transactions and failed on others.
    reg s_clk_d;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) s_clk_d <= 1'b1;
        else            s_clk_d <= s_clk;
    end
    wire spc_rise =  s_clk & ~s_clk_d;
    wire spc_fall = ~s_clk &  s_clk_d;

    localparam INIT_ZERO = 8'b00000000;
    localparam CFG_INIT  = 8'b00000001;
    localparam IDLE      = 8'b00000011;
    localparam START     = 8'b00000111;
    localparam TX_ADDR   = 8'b00001111;
    localparam RX_DATA   = 8'b00011111;
    localparam STOP      = 8'b00111111;

    reg [7:0] state;
    reg [5:0] bit_cnt;
    reg [7:0] cmd_byte;

    localparam CMD_READ_OUTX_BURST = 8'hA8;

    reg sub_fsm_en;
    reg sub_fsm_done;

    reg        wr_start;
    wire       wr_done;
    reg [15:0] wr_shreg;
    reg [4:0]  wr_bit_cnt;
    reg        wr_busy;

    assign wr_done = wr_busy && (wr_bit_cnt == 5'd16) && spc_rise;

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            wr_busy    <= 1'b0;
            wr_bit_cnt <= 5'd0;
            wr_shreg   <= 16'd0;
        end else if (state == CFG_INIT) begin
            if (wr_start && !wr_busy) begin
                wr_busy    <= 1'b1;
                wr_bit_cnt <= 5'd0;
                wr_shreg   <= {1'b0, config_addr[6:0], config_data};
            end else if (wr_busy) begin
                if (spc_fall && wr_bit_cnt < 5'd16) begin
                    s_mosi   <= wr_shreg[15];
                    wr_shreg <= {wr_shreg[14:0], 1'b0};
                end
                if (spc_rise) begin
                    wr_bit_cnt <= wr_bit_cnt + 1'b1;
                end
                if (wr_done) begin
                    wr_busy <= 1'b0;
                end
            end
        end
    end

    always @(*) begin
        if (state == CFG_INIT) begin
            s_csn = wr_busy ? 1'b0 : 1'b1;
            s_clk = wr_busy ? spc_raw : 1'b1;
        end
    end

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            s_csn            <= 1'b1;
            s_clk            <= 1'b1;
            s_mosi           <= 1'b0;
            s_data_out       <= 48'd0;
            s_data_out_valid <= 1'b0;
            state            <= INIT_ZERO;
            bit_cnt          <= 6'd0;
            cmd_byte         <= 8'd0;
            sub_fsm_en       <= 1'b0;
        end else begin
            s_data_out_valid <= 1'b0;

            case (state)

                INIT_ZERO: begin
                    s_mosi     <= 1'b0;
                    s_data_out <= 48'd0;
                    bit_cnt    <= 6'd0;
                    cmd_byte   <= CMD_READ_OUTX_BURST;
                    state      <= CFG_INIT;
                end

                CFG_INIT: begin
                    sub_fsm_en <= 1'b1;
                    if (sub_fsm_done) begin
                        sub_fsm_en <= 1'b0;
                        state      <= IDLE;
                    end
                end

                IDLE: begin
                    s_csn <= 1'b1;
                    s_clk <= 1'b1;
                    if (sync_ready_w) begin
                        bit_cnt <= 6'd0;
                        state   <= START;
                    end
                end

                START: begin
                    s_csn   <= 1'b0;
                    s_clk   <= 1'b1;
                    bit_cnt <= 6'd0;
                    state   <= TX_ADDR;
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

                STOP: begin
                    s_csn            <= 1'b1;
                    s_data_out_valid <= 1'b1;
                    if (core_ack) begin
                        s_data_out_valid <= 1'b0;
                        state            <= IDLE;
                    end
                end

                default: state <= INIT_ZERO;
            endcase
        end
    end

    reg [3:0] sub_state;
    reg [7:0] config_addr;
    reg [7:0] config_data;

    localparam RESET_SUB   = 4'b0000;
    localparam SET_XL_EN   = 4'b0001;
    localparam FIFO_BYPASS = 4'b0010;
    localparam IF_INC_EN   = 4'b0011;
    localparam INT1_EN     = 4'b0100;
    localparam WAIT_DONE   = 4'b0101;
    localparam DONE        = 4'b0110;

    reg [3:0] next_sub_state;

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sub_state      <= RESET_SUB;
            sub_fsm_done   <= 1'b0;
            wr_start       <= 1'b0;
            config_addr    <= 8'd0;
            config_data    <= 8'd0;
            next_sub_state <= RESET_SUB;
        end else if (!sub_fsm_en) begin
            sub_state    <= RESET_SUB;
            sub_fsm_done <= 1'b0;
            wr_start     <= 1'b0;
        end else begin
            wr_start <= 1'b0;

            case (sub_state)
                RESET_SUB: begin
                    sub_fsm_done <= 1'b0;
                    sub_state    <= SET_XL_EN;
                end

                SET_XL_EN: begin
                    config_addr    <= 8'h10;
                    config_data    <= 8'hA0;
                    wr_start       <= 1'b1;
                    next_sub_state <= FIFO_BYPASS;
                    sub_state      <= WAIT_DONE;
                end

                FIFO_BYPASS: begin
                    config_addr    <= 8'h0A;
                    config_data    <= 8'h00;
                    wr_start       <= 1'b1;
                    next_sub_state <= IF_INC_EN;
                    sub_state      <= WAIT_DONE;
                end

                IF_INC_EN: begin
                    config_addr    <= 8'h12;
                    config_data    <= 8'h04;
                    wr_start       <= 1'b1;
                    next_sub_state <= INT1_EN;
                    sub_state      <= WAIT_DONE;
                end

                INT1_EN: begin
                    config_addr    <= 8'h0D;
                    config_data    <= 8'h01;
                    wr_start       <= 1'b1;
                    next_sub_state <= DONE;
                    sub_state      <= WAIT_DONE;
                end

                WAIT_DONE: begin
                    if (wr_done) begin
                        sub_state <= next_sub_state;
                    end
                end

                DONE: begin
                    sub_fsm_done <= 1'b1;
                end

                default: sub_state <= RESET_SUB;
            endcase
        end
    end

endmodule