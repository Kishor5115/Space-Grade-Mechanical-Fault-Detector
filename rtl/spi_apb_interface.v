// spi-apb interface module

`include "apb.v"

module spi_apb_interface (
    input clk,
    input sys_rst_n,

    //APB inputs
    input [31:0] prdata, // from slave
    input penable, // from slave

    //SPI inputs
    input c_csn,
    input c_sclk,
    input c_mosi,

    //APB outputs
    output reg pwrite,
    output reg [31:0] p_addr, // to TMR regs
    output reg [31:0] pwdata,
    output reg psel,
    output reg pready, //to core

    //SPI output
    output reg c_miso
  );

  apb apb_inst (
        .clk(clk),
        .sys_rst_n(sys_rst_n),
        .prdata(prdata),
        .penable(penable),
        .pwrite(pwrite),
        .p_addr(p_addr),
        .pwdata(pwdata),
        .psel(psel),
        .pready(pready)
      );

  always@(posedge clk or negedge sys_rst_n)
  begin
    if(!sys_rst_n)
    begin
      c_miso <= 1'b0;
    end
    else
    begin
      // SPI-APB interface logic here
    end
  end

endmodule
