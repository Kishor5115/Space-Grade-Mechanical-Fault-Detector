//============================================================================
// Module : multiplier.v
// Project: Space-Grade Vibration Pattern Anomaly Detector (GF180, 180nm)
//----------------------------------------------------------------------------
// Function:
//   THE single, chip-wide hardware multiplier. This module contains the ONLY
//   `*` operator in the entire synthesizable datapath. Every product in the
//   design -- the Goertzel recurrence term C_k*v1_k, and all three magnitude
//   terms v1^2, v2^2, and C_k*v1*v2 -- is time-multiplexed onto this one
//   instance via the arbiter in magnitude_compute.v.
//
//   Making the multiplier an explicit, singly-instantiated module (rather
//   than an inline `*` scattered across magnitude_compute) turns Design
//   Invariant #2 ("single shared hardware multiplier -- no additional
//   multipliers") into a STRUCTURAL, auditable property: a reviewer (or a
//   grep for `*`/`multiplier`) can confirm exactly one multiplier exists.
//
//----------------------------------------------------------------------------
// Interface:
//   Pure combinational signed A*B. The full 2*DATA_W-bit product is returned
//   unshifted and unsaturated -- each consumer applies its own Q-format shift
//   (>>15) and saturation, because the two use sites need slightly different
//   post-scaling (Q8.15 result with saturation for the recurrence/mag squares
//   vs. the widened intermediate for C*v1*v2). Keeping scaling OUT of this
//   module keeps the shared unit a single, clean, format-agnostic multiply.
//
// Power / radiation:
//   The multiplier holds no state -- operand isolation is enforced by the
//   caller (magnitude_compute drives a=b=0 whenever no client requests it),
//   so the combinational cone does not toggle in the >95% idle window. No
//   TMR here: there is no sequential state to upset (Rule C -- datapath).
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module multiplier #(
    parameter integer DATA_W = 24   // Q8.15 operand width
)(
    input  wire signed [DATA_W-1:0]     a,   // operand A (e.g. coefficient / v1)
    input  wire signed [DATA_W-1:0]     b,   // operand B (e.g. v1 / v2)
    output wire signed [2*DATA_W-1:0]   p    // full Q16.30 product (unshifted)
);

    // The one and only hardware multiplier in the design.
    assign p = a * b;

endmodule

`default_nettype wire
