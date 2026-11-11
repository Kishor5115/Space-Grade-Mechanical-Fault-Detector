// B22_A: the 1110 x 1110 um Block A wrapper from the organizers' B22_A.def.
// It holds the signed-off `top` macro unchanged and only connects its pins and
// power to the fixed Metal2 positions the shared padring expects.
`default_nettype none

module B22_A (
`ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
`endif
    input  wire clk,
    input  wire sys_rst_n,
    input  wire c_miso,
    output wire c_csn_OUT,
    output wire c_sclk_OUT,
    output wire c_mosi_OUT,
    input  wire sensor_drdy,
    input  wire tmr_forward_en,
    input  wire cmd_sclk,
    input  wire cmd_csn,
    input  wire cmd_mosi,
    output wire clk_PD,
    output wire clk_PU,
    output wire sys_rst_n_PD,
    output wire sys_rst_n_PU,
    output wire c_miso_PD,
    output wire c_miso_PU,
    output wire sensor_drdy_PD,
    output wire sensor_drdy_PU,
    output wire tmr_forward_en_PD,
    output wire tmr_forward_en_PU,
    output wire cmd_sclk_PD,
    output wire cmd_sclk_PU,
    output wire cmd_csn_PD,
    output wire cmd_csn_PU,
    output wire cmd_mosi_PD,
    output wire cmd_mosi_PU,
    output wire c_csn_PD,
    output wire c_csn_PU,
    output wire c_csn_CS,
    output wire c_csn_SL,
    output wire c_csn_IE,
    output wire c_csn_OE,
    output wire c_sclk_PD,
    output wire c_sclk_PU,
    output wire c_sclk_CS,
    output wire c_sclk_SL,
    output wire c_sclk_IE,
    output wire c_sclk_OE,
    output wire c_mosi_PD,
    output wire c_mosi_PU,
    output wire c_mosi_CS,
    output wire c_mosi_SL,
    output wire c_mosi_IE,
    output wire c_mosi_OE,
    output wire fault_flag_out_PD,
    output wire fault_flag_out_PU,
    output wire fault_flag_out_CS,
    output wire fault_flag_out_SL,
    output wire fault_flag_out_IE,
    output wire fault_flag_out_OE,
    input  wire c_csn_IN,
    input  wire c_sclk_IN,
    input  wire c_mosi_IN,
    input  wire fault_flag_out_IN,
    output wire fault_flag_out_OUT
);

    // c_sclk_OUT runs ~740 um from the macro's top edge to its west-edge pin.
    // The flow's repair_design leaves that one net unbuffered, so it is buffered
    // here: the placer spreads the chain along the route.
    wire c_sclk_raw, c_sclk_b1, c_sclk_b2;
    gf180mcu_fd_sc_mcu7t5v0__buf_4 u_sclk_buf0 (.I(c_sclk_raw), .Z(c_sclk_b1));
    gf180mcu_fd_sc_mcu7t5v0__buf_4 u_sclk_buf1 (.I(c_sclk_b1), .Z(c_sclk_b2));
    gf180mcu_fd_sc_mcu7t5v0__buf_4 u_sclk_buf2 (.I(c_sclk_b2), .Z(c_sclk_OUT));

    top u_top (
`ifdef USE_POWER_PINS
        .VDD(VDD),
        .VSS(VSS),
`endif
        .clk(clk),
        .sys_rst_n(sys_rst_n),
        .c_miso(c_miso),
        .c_csn_OUT(c_csn_OUT),
        .c_sclk_OUT(c_sclk_raw),
        .c_mosi_OUT(c_mosi_OUT),
        .sensor_drdy(sensor_drdy),
        .tmr_forward_en(tmr_forward_en),
        .cmd_sclk(cmd_sclk),
        .cmd_csn(cmd_csn),
        .cmd_mosi(cmd_mosi),
        .clk_PD(clk_PD),
        .clk_PU(clk_PU),
        .sys_rst_n_PD(sys_rst_n_PD),
        .sys_rst_n_PU(sys_rst_n_PU),
        .c_miso_PD(c_miso_PD),
        .c_miso_PU(c_miso_PU),
        .sensor_drdy_PD(sensor_drdy_PD),
        .sensor_drdy_PU(sensor_drdy_PU),
        .tmr_forward_en_PD(tmr_forward_en_PD),
        .tmr_forward_en_PU(tmr_forward_en_PU),
        .cmd_sclk_PD(cmd_sclk_PD),
        .cmd_sclk_PU(cmd_sclk_PU),
        .cmd_csn_PD(cmd_csn_PD),
        .cmd_csn_PU(cmd_csn_PU),
        .cmd_mosi_PD(cmd_mosi_PD),
        .cmd_mosi_PU(cmd_mosi_PU),
        .c_csn_PD(c_csn_PD),
        .c_csn_PU(c_csn_PU),
        .c_csn_CS(c_csn_CS),
        .c_csn_SL(c_csn_SL),
        .c_csn_IE(c_csn_IE),
        .c_csn_OE(c_csn_OE),
        .c_sclk_PD(c_sclk_PD),
        .c_sclk_PU(c_sclk_PU),
        .c_sclk_CS(c_sclk_CS),
        .c_sclk_SL(c_sclk_SL),
        .c_sclk_IE(c_sclk_IE),
        .c_sclk_OE(c_sclk_OE),
        .c_mosi_PD(c_mosi_PD),
        .c_mosi_PU(c_mosi_PU),
        .c_mosi_CS(c_mosi_CS),
        .c_mosi_SL(c_mosi_SL),
        .c_mosi_IE(c_mosi_IE),
        .c_mosi_OE(c_mosi_OE),
        .fault_flag_out_PD(fault_flag_out_PD),
        .fault_flag_out_PU(fault_flag_out_PU),
        .fault_flag_out_CS(fault_flag_out_CS),
        .fault_flag_out_SL(fault_flag_out_SL),
        .fault_flag_out_IE(fault_flag_out_IE),
        .fault_flag_out_OE(fault_flag_out_OE),
        .c_csn_IN(c_csn_IN),
        .c_sclk_IN(c_sclk_IN),
        .c_mosi_IN(c_mosi_IN),
        .fault_flag_out_IN(fault_flag_out_IN),
        .fault_flag_out_OUT(fault_flag_out_OUT)
    );

endmodule

`default_nettype wire
