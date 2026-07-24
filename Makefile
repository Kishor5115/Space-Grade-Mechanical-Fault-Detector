# Root Makefile -- Space-Grade Mechanical Fault Detector
#
# Verification entry points for the four testbench suites. Each target
# delegates to the corresponding per-module testbench directory under
# testing/, so this file has no simulation logic of its own -- it is a
# thin convenience wrapper for `make sim_<block>` from the repo root.
#
# Targets:
#   sim_spi      -- rtl/spi_master.v standalone (boot config-write FSM +
#                    read-burst FSM) against the IIS3DWB bus functional model
#   sim_apb      -- rtl/spi_apb_interface.v + tmr_slave_stub.v (Option A/B
#                    sample delivery and APB forwarding)
#   sim_goertzel -- rtl/goertzel_core.v standalone (3-bin time-multiplexed
#                    Goertzel resonator, two-tone stimulus)
#   sim_top      -- full end-to-end chain (rtl/top.v): sensor SPI in,
#                    fault_flag_out + axis attribution out
#   sim_all      -- run all four in sequence
#   clean        -- remove all generated sim binaries and VCD dumps
#
# All targets produce a VCD waveform dump in their respective
# testing/<block>/ directory (goertzel_3bin_tb.vcd, waves.vcd, tb_top.vcd)
# for viewing with gtkwave or any other VCD viewer.

SPI_DIR      := testing/spi_master_test
APB_DIR      := testing/apb_test
GOERTZEL_DIR := testing/goertzel_core
TOP_DIR      := testing/top_test
CMD_SPI_DIR  := testing/cmd_spi_test

IVERILOG := iverilog
VVP      := vvp
IFLAGS   := -g2012 -I rtl

.PHONY: all sim_all sim_spi sim_apb sim_goertzel sim_top sim_cmd_spi clean

all: sim_all

sim_all: sim_spi sim_apb sim_goertzel sim_top sim_cmd_spi

sim_spi:
	$(MAKE) -C $(SPI_DIR) run

sim_apb:
	$(MAKE) -C $(APB_DIR) run

# goertzel_core has no per-directory Makefile (single-file DUT + TB);
# compile/run it directly against rtl/goertzel_core.v from the root.
sim_goertzel:
	$(IVERILOG) $(IFLAGS) -o $(GOERTZEL_DIR)/sim.out \
		rtl/goertzel_core.v $(GOERTZEL_DIR)/tb_goertzel_core.v
	$(VVP) $(GOERTZEL_DIR)/sim.out

sim_top:
	$(MAKE) -C $(TOP_DIR) run

sim_cmd_spi:
	$(MAKE) -C $(CMD_SPI_DIR) run

clean:
	$(MAKE) -C $(SPI_DIR) clean
	$(MAKE) -C $(APB_DIR) clean
	$(MAKE) -C $(TOP_DIR) clean
	$(MAKE) -C $(CMD_SPI_DIR) clean
	rm -f $(GOERTZEL_DIR)/sim.out goertzel_3bin_tb.vcd
