// top module
`include "spi_master.v"
`include "apb.v"
`include "spi_apb_interface.v"
`include "tmr_reg_bank.v"
`include "goertzel_core.v"
`include "fault_flagger.v"

module top (
    input clk,
    input rst_n,

    //SPI interface
    input c_miso,
    output c_csn,
    output c_sclk,
    output c_mosi,

    //to RISC core
    output fault_flag
  );

  //internal wires SPI-APB interface
  wire [31:0] prdata;
  wire penable;
  wire pwrite;
  wire [31:0] p_addr;
  wire [31:0] pwdata;
  wire psel;
  wire pready;

  uut spi_master spi_master_inst (
        .clk(clk),
        .sys_rst_n(rst_n),
        .sync_data_ready_trig(), // connect as needed
        .s_miso(c_miso),
        .s_csn(c_csn),
        .s_clk(c_sclk),
        .s_mosi(c_mosi),
        .s_data_out(), // connect as needed
        .s_data_out_valid() // connect as needed
      );

  uut spi_apb_interface spi_apb_interface_inst (
        .clk(clk),
        .sys_rst_n(rst_n),
        .prdata(prdata),
        .penable(penable),
        .pwrite(pwrite),
        .p_addr(p_addr),
        .pwdata(pwdata),
        .psel(psel),
        .pready(pready),
        .c_miso(c_miso)
      );

  // Internal wires TMR-Core-Fault_flagger
  wire [15:0] wire_cfg_c;
  wire [15:0] wire_cfg_n;
  wire wire_cfg_start;
  wire [31:0] wire_cfg_threshold;
  wire [31:0] wire_mag_out;
  wire wire_mag_out_valid;

  uut tmr_reg_bank tmr_reg_bank_inst (
        .clk(clk),
        .rst_n(rst_n),
        .p_addr(p_addr),
        .pwdata(pwdata),
        .psel(psel),
        .pwrite(pwrite),
        .penable(penable),
        .prdata(prdata),
        .pready(pready),
        .cfg_c(wire_cfg_c),
        .cfg_n(wire_cfg_n),
        .cfg_start(wire_cfg_start),
        .cfg_threshold(wire_cfg_threshold)
      );

  uut goertzel_core goertzel_core_inst (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_c(wire_cfg_c),
        .cfg_n(wire_cfg_n),
        .cfg_start(wire_cfg_start),
        .mag_out(wire_mag_out),
        .mag_out_valid(wire_mag_out_valid)
      );

  uut fault_flagger fault_flagger_inst (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_threshold(wire_cfg_threshold),
        .mag_in(wire_mag_out),
        .fault_flag(fault_flag)
      );


endmodule
