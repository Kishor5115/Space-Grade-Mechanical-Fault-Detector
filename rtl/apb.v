// apb master module
//
// Standard APB master/slave signal directions (per AMBA APB spec):
//   pwrite, p_addr, pwdata, psel, penable : MASTER outputs (driven here)
//   prdata, pready                        : SLAVE outputs, MASTER inputs
//
// This module is a request-driven APB master: it sits idle until the
// requester (spi_apb_interface, on behalf of the core/TMR side) asserts
// req_valid with req_write/req_addr/req_wdata, then runs one APB
// transfer (SETUP cycle, then ACCESS cycle held until pready) and
// reports completion + (for reads) the captured data back.

module apb (
    input  clk,
    input  sys_rst_n,

    // ---- request side (from spi_apb_interface / core) ----
    input         req_valid,   // pulse: start a transaction
    input         req_write,   // 1 = write, 0 = read
    input  [31:0] req_addr,
    input  [31:0] req_wdata,
    output reg    req_done,    // pulses 1 cycle when the transfer completes
    output reg [31:0] resp_rdata, // valid the same cycle req_done pulses (read only)

    // ---- APB bus: slave-driven inputs ----
    input  [31:0] prdata,  // from slave
    input         pready,  // from slave

    // ---- APB bus: master-driven outputs ----
    output reg        pwrite,
    output reg [31:0] p_addr,   // to TMR regs
    output reg [31:0] pwdata,
    output reg         psel,
    output reg         penable
);

    localparam IDLE   = 2'b00;
    localparam SETUP  = 2'b01; // address phase: psel=1, penable=0
    localparam ACCESS = 2'b10; // data phase:    psel=1, penable=1, hold until pready

    reg [1:0] state;

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            state      <= IDLE;
            psel       <= 1'b0;
            penable    <= 1'b0;
            pwrite     <= 1'b0;
            p_addr     <= 32'd0;
            pwdata     <= 32'd0;
            req_done   <= 1'b0;
            resp_rdata <= 32'd0;
        end else begin
            req_done <= 1'b0; // default; pulsed below on completion

            case (state)
                IDLE: begin
                    psel    <= 1'b0;
                    penable <= 1'b0;
                    if (req_valid) begin
                        pwrite <= req_write;
                        p_addr <= req_addr;
                        pwdata <= req_wdata;
                        psel   <= 1'b1;   // SETUP: select asserted, enable not yet
                        state  <= SETUP;
                    end
                end

                SETUP: begin
                    // one cycle with psel=1, penable=0 (address phase),
                    // then move into ACCESS with penable=1
                    penable <= 1'b1;
                    state   <= ACCESS;
                end

                ACCESS: begin
                    // hold psel=1, penable=1 until the slave asserts pready
                    if (pready) begin
                        if (!pwrite) begin
                            resp_rdata <= prdata;
                        end
                        req_done <= 1'b1;
                        psel     <= 1'b0;
                        penable  <= 1'b0;
                        state    <= IDLE;
                    end
                    // else: stay in ACCESS (slave-inserted wait state)
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule