// fault flagger module

module fault_flagger (
    input clk,
    input rst_n,

    // from Goertzel core
    input [31:0] mag_in,
    input mag_in_valid,

    // from TMR reg bank
    input [31:0] cfg_threshold,

    // to risc core (status reg)
    output reg fault_flag
  );

  always@(posedge clk or negedge rst_n)
  begin
    if(!rst_n)
    begin
      fault_flag <= 1'b0;
    end
    else
    begin
      // Fault flagger logic here
    end
  end
endmodule
