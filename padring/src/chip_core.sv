// SPDX-FileCopyrightText: 2026 Team B22 "Space Jam" -- SSCS Chipathon 2026
// SPDX-License-Identifier: Apache-2.0
//
//============================================================================
// chip_core.sv -- Space-Grade Mechanical Fault Detector, chip-level core
//                 wrapper for the wafer-space gf180mcu `slot_1x1` padring.
//============================================================================
//
// This module is the ONLY thing that sits between the fixed padring
// (`chip_top.sv`, which we must not modify) and the hardened `top` macro
// (the ITAG Goertzel vibration-fault detector, 800 x 800 um, signed off
// separately -- see librelane/01_fault_detector_macro.ipynb).
//
// It contains no logic of its own beyond pad-control tie-offs and the
// port mapping below. All functionality lives inside the `top` macro,
// which is instantiated here as a pre-hardened black box
// (gds/lef/vh/lib registered under MACROS: in librelane/chip_overrides.yaml).
//
//----------------------------------------------------------------------------
// PAD MAP (slot_1x1)
//----------------------------------------------------------------------------
// `slot_1x1` provides 12 in_c input pads (all on PAD_WEST), 40 bi_24t bidir
// pads (S/E/N), 2 asig_5p0 analog pads (N), plus the two hard-wired
// single-instance pads `clk_pad` (Schmitt in_s) and `rst_n_pad` (in_c),
// both at the SOUTH-WEST corner.
//
// Pad lists in slot_1x1.yaml read clockwise from the SW corner, so
// PAD_NORTH is ordered E->W and PAD_WEST is ordered N->S. The pads
// geometrically nearest the NW corner are therefore the LAST PAD_NORTH
// entries and the FIRST PAD_WEST entries. The macro is placed top-left of
// the core with all 12 of its pins on its N and W edges (see
// docs/specs/PIN_PLACEMENT_RATIONALE.md), so we pick pads accordingly.
//
//   top.v pin        dir  core port        pad instance      side / position
//   ---------------  ---  ---------------  ----------------  ----------------------
//   clk              in   clk              clk_pad (in_s)    S, SW corner (fixed)
//   sys_rst_n        in   rst_n            rst_n_pad (in_c)  S, SW corner (fixed)
//   c_miso           in   input_in[11]     inputs[11].pad    W, topmost input pad
//   sensor_drdy      in   input_in[10]     inputs[10].pad    W
//   tmr_forward_en   in   input_in[9]      inputs[9].pad     W
//   cmd_sclk         in   input_in[8]      inputs[8].pad     W
//   cmd_csn          in   input_in[7]      inputs[7].pad     W
//   cmd_mosi         in   input_in[6]      inputs[6].pad     W
//   c_csn            out  bidir_out[26]    bidir[26].pad     N, nearest NW corner
//   c_sclk           out  bidir_out[27]    bidir[27].pad     N
//   c_mosi           out  bidir_out[28]    bidir[28].pad     N
//   fault_flag_out   out  bidir_out[29]    bidir[29].pad     N
//
// NOTE on clk / sys_rst_n: clk_pad and rst_n_pad are pinned to the SW
// corner by the slot and cannot be moved. With the macro at top-left those
// two nets run roughly the full core height (~4.6 mm). At the 62.5 ns
// (16 MHz) chip clock this closes comfortably, but chip-top CTS will insert
// several buffer stages on the clock and repair_design will buffer
// sys_rst_n. Measured route length is reported by the integration notebook.
//
//----------------------------------------------------------------------------
// UNUSED PAD POLICY
//----------------------------------------------------------------------------
// Every chip_core output must be driven or Yosys halts the flow, and a pad
// left in an indeterminate state is a power / ESD concern. Therefore:
//
//   * unused bidir pads : oe=0 (high-Z output driver)
//                         ie=0 (input receiver DISABLED -- nothing floats
//                               into the core)
//                         pu=0, pd=0, cs=0, sl=0, out=0
//   * used bidir pads   : oe=1 (drive outwards), ie=0 (pure output, receiver
//                         off), cs=0 (CMOS buffer, not Schmitt),
//                         sl=0 (fast slew), pu=0, pd=0
//   * all input pads    : pu=0, pd=0 (no pull-ups / pull-downs); unused
//                         input_in bits are folded into `_unused`
//   * analog[1:0]       : left unconnected at the core boundary, i.e. a pure
//                         pass-through to the asig_5p0 pad cells, so a probe
//                         on either ana pin sees the bondpad directly.
//                         This design has no analog IP.
//
// bidir_ie is written per-bit rather than as a blanket `~bidir_oe` so the
// intent survives future edits (a blanket inversion happens to be correct
// only while every used pad is a pure output).
//============================================================================

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
    )(
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif

    input  wire clk,       // from clk_pad   (gf180mcu_fd_io__in_s, Schmitt)
    input  wire rst_n,     // from rst_n_pad (gf180mcu_fd_io__in_c), active low

    input  wire [NUM_INPUT_PADS-1:0] input_in,   // Input value
    output wire [NUM_INPUT_PADS-1:0] input_pu,   // Pull-up
    output wire [NUM_INPUT_PADS-1:0] input_pd,   // Pull-down

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,   // Input value
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,  // Output value
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,   // Output enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,   // Input type (0=CMOS, 1=Schmitt)
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,   // Slew rate (0=fast, 1=slow)
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,   // Input enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,   // Pull-up
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,   // Pull-down

    inout  wire [NUM_ANALOG_PADS-1:0] analog     // Analog (unused by this design)
);

    //------------------------------------------------------------------
    // Pad index constants -- single source of truth for the pad map.
    // Kept as localparams so the integration notebook can cross-check
    // them against its own PAD_MAP table by parsing this file.
    //------------------------------------------------------------------
    localparam int IN_C_MISO         = 11;
    localparam int IN_SENSOR_DRDY    = 10;
    localparam int IN_TMR_FORWARD_EN =  9;
    localparam int IN_CMD_SCLK       =  8;
    localparam int IN_CMD_CSN        =  7;
    localparam int IN_CMD_MOSI       =  6;

    localparam int BO_C_CSN          = 26;
    localparam int BO_C_SCLK         = 27;
    localparam int BO_C_MOSI         = 28;
    localparam int BO_FAULT_FLAG     = 29;

    //------------------------------------------------------------------
    // Input pads: no pull-ups / pull-downs anywhere.
    //------------------------------------------------------------------
    assign input_pu = '0;
    assign input_pd = '0;

    //------------------------------------------------------------------
    // Macro outputs -> bidir pads
    //------------------------------------------------------------------
    wire c_csn;
    wire c_sclk;
    wire c_mosi;
    wire fault_flag_out;

    // Output-enable mask: exactly the four pads we drive.
    localparam logic [NUM_BIDIR_PADS-1:0] BIDIR_OE_MASK =
          (1 << BO_C_CSN)
        | (1 << BO_C_SCLK)
        | (1 << BO_C_MOSI)
        | (1 << BO_FAULT_FLAG);

    logic [NUM_BIDIR_PADS-1:0] bidir_out_mux;
    always_comb begin
        bidir_out_mux                 = '0;   // every unused pad drives 0 (and has oe=0 anyway)
        bidir_out_mux[BO_C_CSN]       = c_csn;
        bidir_out_mux[BO_C_SCLK]      = c_sclk;
        bidir_out_mux[BO_C_MOSI]      = c_mosi;
        bidir_out_mux[BO_FAULT_FLAG]  = fault_flag_out;
    end

    assign bidir_out = bidir_out_mux;
    assign bidir_oe  = BIDIR_OE_MASK;   // 1 = drive outwards, 0 = high-Z
    assign bidir_ie  = '0;              // no bidir pad is ever read by this design
    assign bidir_cs  = '0;              // CMOS input buffer (irrelevant with ie=0)
    assign bidir_sl  = '0;              // fast slew
    assign bidir_pu  = '0;
    assign bidir_pd  = '0;

    //------------------------------------------------------------------
    // Consume the pad inputs we do not use, so neither Verilator nor
    // Yosys reports them as dangling. `bidir_in` is entirely unused
    // (all 40 receivers are disabled via ie=0); of `input_in` only the
    // six bits mapped above are consumed by the macro.
    //------------------------------------------------------------------
    wire [NUM_INPUT_PADS-1:0] input_used_mask =
          (1 << IN_C_MISO)
        | (1 << IN_SENSOR_DRDY)
        | (1 << IN_TMR_FORWARD_EN)
        | (1 << IN_CMD_SCLK)
        | (1 << IN_CMD_CSN)
        | (1 << IN_CMD_MOSI);

    logic _unused;
    assign _unused = &{1'b0,
                       bidir_in,
                       input_in & ~input_used_mask};

    //------------------------------------------------------------------
    // The hardened macro.
    //
    // `top` is a pre-characterised black box at this level: LibreLane
    // reads its port list from build/top/vh/top.vh, its abstract layout
    // from build/top/lef/top.lef, its timing from the nine
    // build/top/lib/<corner>/top__<corner>.lib views, and its geometry
    // from build/top/gds/top.gds. See librelane/chip_overrides.yaml.
    //
    // Instance name `u_fault_detector` is referenced verbatim by
    // MACROS.top.instances and by PDN_MACRO_CONNECTIONS -- do not rename
    // it without updating both.
    //------------------------------------------------------------------
    top u_fault_detector (
        `ifdef USE_POWER_PINS
        .VDD            (VDD),
        .VSS            (VSS),
        `endif

        // clock and reset, straight off the two SW-corner pads
        .clk            (clk),
        .sys_rst_n      (rst_n),

        // IIS3DWB sensor SPI bus
        .c_miso         (input_in[IN_C_MISO]),
        .c_csn          (c_csn),
        .c_sclk         (c_sclk),
        .c_mosi         (c_mosi),

        // sensor data-ready interrupt
        .sensor_drdy    (input_in[IN_SENSOR_DRDY]),

        // Option A/B sample-forwarding mode select
        .tmr_forward_en (input_in[IN_TMR_FORWARD_EN]),

        // host-facing command-SPI bus (write-only config channel)
        .cmd_sclk       (input_in[IN_CMD_SCLK]),
        .cmd_csn        (input_in[IN_CMD_CSN]),
        .cmd_mosi       (input_in[IN_CMD_MOSI]),

        // sticky fault alarm to the host / RISC-V core
        .fault_flag_out (fault_flag_out)
    );

endmodule

`default_nettype wire
