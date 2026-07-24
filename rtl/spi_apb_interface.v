// spi_apb_interface.v
//
// Communication-layer integration wrapper. Each child module owns its
// own FSM in its own scope (spi_master runs its sensor-acquisition FSM
// independently; apb runs its bus-transfer FSM independently). This
// wrapper's job is to instantiate both and wire them together, plus
// hold the sensor sample in local registers since spi_master's data
// arrives asynchronously relative to any APB transaction.
//
// ---- Two sample-delivery modes, selected by tmr_forward_en ----
//
// Option A (tmr_forward_en = 0, default): the core/TMR side reads the
// sample directly out of this wrapper's local registers via the
// req_valid/req_addr/req_wdata port below (poll-a-status-register
// model). Fast, simple, single copy of the data. No TMR protection on
// the sample itself between latch and consumption.
//
// Option B (tmr_forward_en = 1): in addition to being locally
// readable as in Option A, every freshly-latched sample is also
// pushed across the apb bus into the TMR reg bank by this wrapper's
// own internal forwarding FSM (fwd_state below), using a SECOND,
// independent request path into the same `apb` master instance. The
// local path and the forwarding path are arbitrated so they can never
// collide on apb's single request port (see arbitration note below).
//
// tmr_forward_en is intended to be a real pin/config-fuse input so the
// choice can be made post-fabrication without an RTL respin; tie it
// low for the initial bring-up/validation pass.
//
// Local register map (APB byte addresses, decoded on req_addr[3:0]):
//   0x0 : STATUS   { 31:1 = 0, 0 = data_ready }
//   0x4 : SAMPLE0  = s_data_out[31:0]
//   0x8 : SAMPLE1  = { 16'd0, s_data_out[47:32] }
// A read of SAMPLE1 clears data_ready (acts as the "consume" signal).



module spi_apb_interface (
    input clk,
    input sys_rst_n,

    // Option A/B select. 0 = local-read only (Option A). 1 = also
    // forward each sample into the TMR reg bank over apb (Option B).
    input tmr_forward_en,

    // TMR reg bank base address for the forwarded sample (Option B
    // only; ignored entirely when tmr_forward_en=0). Sample words are
    // written at tmr_sample_base+0x0 and tmr_sample_base+0x4.
    input [31:0] tmr_sample_base,

    // ---- request side: core/TMR asking to read/write the local regs ----
    input         req_valid,
    input         req_write,
    input  [31:0] req_addr,
    input  [31:0] req_wdata,
    output        req_done,
    output [31:0] resp_rdata,

    // ---- apb bus toward the TMR reg bank (master outputs / slave inputs) ----
    input  [31:0] prdata,
    input         pready,
    output        pwrite,
    output [31:0] p_addr,
    output [31:0] pwdata,
    output        psel,
    output        penable,

    // ---- sensor-facing SPI pins (to the IIS3DWB) ----
    input  s_miso,
    output s_csn,
    output s_clk,
    output s_mosi,

    // DRDY interrupt line from the sensor
    input  sync_data_ready_trig
  );

  // ------------------------------------------------------------
  // spi_master: talks to the physical IIS3DWB. Fully self-contained
  // FSM; this wrapper only consumes its outputs.
  // ------------------------------------------------------------
  wire [47:0] sm_data_out;
  wire        sm_data_out_valid;
  reg         sm_core_ack;

  spi_master spi_master_inst (
               .clk(clk),
               .sys_rst_n(sys_rst_n),
               .sync_data_ready_trig(sync_data_ready_trig),
               .s_miso(s_miso),
               .core_ack(sm_core_ack),
               .s_csn(s_csn),
               .s_clk(s_clk),
               .s_mosi(s_mosi),
               .s_data_out(sm_data_out),
               .s_data_out_valid(sm_data_out_valid)
             );

  // ------------------------------------------------------------
  // Local holding registers for the most recent sensor sample.
  // ------------------------------------------------------------
  reg [47:0] sample_reg;
  reg        data_ready;
  reg        fresh_sample_pending; // set with sample_reg/data_ready, cleared once
  // the Option-B forwarder (if enabled) has sent it

  localparam ADDR_STATUS  = 4'h0;
  localparam ADDR_SAMPLE0 = 4'h4;
  localparam ADDR_SAMPLE1 = 4'h8;

  wire [3:0] local_addr = req_addr[3:0];

  // Forward declarations — these wires are defined in their proper sections
  // below, but iverilog requires all wires used in always blocks to be declared
  // before (or at the same scope as) their first use.
  wire req_valid_pulse; // defined near line 175 (edge-qualified req_valid)
  wire fwd_done;        // defined near line 264 (FWD_DONE_S state reached)

  // ack spi_master as soon as we've latched its data, freeing it to
  // go back to IDLE and wait for the next DRDY
  always @(posedge clk or negedge sys_rst_n)
  begin
    if (!sys_rst_n)
    begin
      sm_core_ack <= 1'b0;
    end
    else
    begin
      sm_core_ack <= sm_data_out_valid; // ack one cycle after valid asserts
    end
  end

  always @(posedge clk or negedge sys_rst_n)
  begin
    if (!sys_rst_n)
    begin
      sample_reg            <= 48'd0;
      data_ready            <= 1'b0;
      fresh_sample_pending  <= 1'b0;
    end
    else
    begin
      if (sm_data_out_valid)
      begin
        sample_reg           <= sm_data_out;
        data_ready           <= 1'b1;
        fresh_sample_pending <= 1'b1; // new sample: (re-)arm the forwarder
      end
      else
      begin
        if (req_valid_pulse && !req_write && local_addr == ADDR_SAMPLE1)
        begin
          data_ready <= 1'b0; // Option A: cleared once core has read it
        end
        if (fwd_done)
        begin
          fresh_sample_pending <= 1'b0; // Option B: cleared once forwarded
        end
      end
    end
  end

  // ------------------------------------------------------------
  // Local register read mux -- always live (Option A path), entirely
  // independent of tmr_forward_en.
  //
  // req_valid is edge-qualified (req_valid_d) rather than reacting
  // to its level: a requester that holds req_valid high across
  // multiple cycles (e.g. while itself waiting for req_done before
  // dropping it -- a perfectly normal handshake style) must only
  // have its request serviced ONCE, not re-triggered on every cycle
  // it stays high. Without this, a held-high req_valid races with
  // local_done's own one-cycle pulse and can latch a stale
  // local_addr/local_rdata pair from whatever request happened to
  // be in flight the cycle before, silently returning the wrong
  // register's value.
  // ------------------------------------------------------------
  reg [31:0] local_rdata;
  reg        local_done;
  reg        req_valid_d;
  assign     req_valid_pulse = req_valid & ~req_valid_d;

  always @(posedge clk or negedge sys_rst_n)
  begin
    if (!sys_rst_n)
      req_valid_d <= 1'b0;
    else
      req_valid_d <= req_valid;
  end

  always @(posedge clk or negedge sys_rst_n)
  begin
    if (!sys_rst_n)
    begin
      local_rdata <= 32'd0;
      local_done  <= 1'b0;
    end
    else
    begin
      local_done <= 1'b0;
      if (req_valid_pulse)
      begin
        local_done <= 1'b1;
        case (local_addr)
          ADDR_STATUS:
            local_rdata <= {31'd0, data_ready};
          ADDR_SAMPLE0:
            local_rdata <= sample_reg[31:0];
          ADDR_SAMPLE1:
            local_rdata <= {16'd0, sample_reg[47:32]};
          default:
            local_rdata <= 32'd0;
        endcase
      end
    end
  end

  assign req_done   = local_done;
  assign resp_rdata = local_rdata;

  // ------------------------------------------------------------
  // Option B: TMR-forwarding FSM + apb master instance.
  //
  // This drives a SEPARATE request path into `apb`, independent of
  // the core's local-register req_valid/req_addr port above. Since
  // `apb` only has one request port, arbitrate here: the forwarder
  // only ever runs when tmr_forward_en=1 AND fresh_sample_pending=1,
  // and it owns the apb request port for the duration of its own
  // two-word write sequence. There is currently no other source
  // contending for the apb master (the core's local reads never
  // touch apb at all in either option), so no true arbitration
  // logic is needed yet -- if a future revision adds a second
  // apb-bus consumer, add a request-mux/grant stage here rather
  // than letting two sources drive apb's req_* inputs directly.
  // ------------------------------------------------------------
  wire        apb_req_valid;
  wire        apb_req_write;
  wire [31:0] apb_req_addr;
  wire [31:0] apb_req_wdata;
  wire        apb_req_done;
  wire [31:0] apb_resp_rdata; // unused on writes; kept for completeness

  apb apb_inst (
        .clk(clk),
        .sys_rst_n(sys_rst_n),
        .req_valid(apb_req_valid),
        .req_write(apb_req_write),
        .req_addr(apb_req_addr),
        .req_wdata(apb_req_wdata),
        .req_done(apb_req_done),
        .resp_rdata(apb_resp_rdata),
        .prdata(prdata),
        .pready(pready),
        .pwrite(pwrite),
        .p_addr(p_addr),
        .pwdata(pwdata),
        .psel(psel),
        .penable(penable)
      );

  localparam FWD_IDLE   = 2'b00;
  localparam FWD_WORD0  = 2'b01; // write sample_reg[31:0]  to tmr_sample_base+0x0
  localparam FWD_WORD1  = 2'b10; // write sample_reg[47:32] to tmr_sample_base+0x4
  localparam FWD_DONE_S = 2'b11;

  reg [1:0]  fwd_state;
  reg        fwd_req_valid;
  reg [31:0] fwd_req_addr;
  reg [31:0] fwd_req_wdata;
  assign     fwd_done = (fwd_state == FWD_DONE_S);

  assign apb_req_valid = tmr_forward_en ? fwd_req_valid : 1'b0;
  assign apb_req_write = 1'b1; // forwarder only ever writes
  assign apb_req_addr  = fwd_req_addr;
  assign apb_req_wdata = fwd_req_wdata;

  always @(posedge clk or negedge sys_rst_n)
  begin
    if (!sys_rst_n)
    begin
      fwd_state     <= FWD_IDLE;
      fwd_req_valid <= 1'b0;
      fwd_req_addr  <= 32'd0;
      fwd_req_wdata <= 32'd0;
    end
    else if (!tmr_forward_en)
    begin
      // Option A: forwarder stays parked, never touches apb
      fwd_state     <= FWD_IDLE;
      fwd_req_valid <= 1'b0;
    end
    else
    begin
      fwd_req_valid <= 1'b0; // default; pulsed below for one cycle

      case (fwd_state)
        FWD_IDLE:
        begin
          if (fresh_sample_pending)
          begin
            fwd_req_valid <= 1'b1;
            fwd_req_addr  <= tmr_sample_base + 32'h0;
            fwd_req_wdata <= sample_reg[31:0];
            fwd_state     <= FWD_WORD0;
          end
        end

        FWD_WORD0:
        begin
          if (apb_req_done)
          begin
            fwd_req_valid <= 1'b1;
            fwd_req_addr  <= tmr_sample_base + 32'h4;
            fwd_req_wdata <= {16'd0, sample_reg[47:32]};
            fwd_state     <= FWD_WORD1;
          end
        end

        FWD_WORD1:
        begin
          if (apb_req_done)
          begin
            fwd_state <= FWD_DONE_S;
          end
        end

        FWD_DONE_S:
        begin
          fwd_state <= FWD_IDLE; // fresh_sample_pending cleared by the
          // sample-latch process above, via fwd_done
        end

        default:
          fwd_state <= FWD_IDLE;
      endcase
    end
  end

endmodule
