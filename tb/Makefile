# cocotb test dispatcher for Space-Grade Mechanical Fault Detector.
#
# RTL sim (pre-synthesis):
#   make test-spi           # SPI master: boot sequence + burst-read framing
#   make test-goertzel      # Goertzel core: Q8.15 arithmetic + 3-axis ITAG
#   make test-top           # Full chip: fault detection on X / Y / Z / all-3 axes
#   make test-all
#
# Gate-level sim (post-synthesis, against LibreLane GF180 netlists):
#   make test-top-gl        # top.nl.v + gf180 stdcell models
#   make test-gl-all
#
#   make clean
#
# Requires:  cocotb, icarus-verilog  (both in hpretl/iic-osic-tools:chipathon26)
# GL builds assume LibreLane has already produced build/top/nl/top.nl.v

.PHONY: test-spi test-goertzel test-top test-all \
        test-top-gl test-gl-all clean

TOPLEVEL_LANG ?= verilog
SIM           ?= icarus

RTL   = ../rtl
BUILD = ../librelane/build

# All RTL sources in dependency order (combinational modules first)
RTL_SOURCES = \
    $(RTL)/clk_divider.v   \
    $(RTL)/ff_2_sync.v       \
    $(RTL)/multiplier.v      \
    $(RTL)/apb_arb2.v        \
    $(RTL)/cmd_spi_slave.v   \
    $(RTL)/apb.v             \
    $(RTL)/spi_master.v      \
    $(RTL)/spi_apb_interface.v \
    $(RTL)/tmr_reg_bank.v    \
    $(RTL)/axis_sequencer.v  \
    $(RTL)/goertzel_core.v   \
    $(RTL)/magnitude_compute.v \
    $(RTL)/fault_flagger.v   \
    $(RTL)/top.v

# GF180 PDK stdcell verilog (same fallback as reference example)
PDK_VLOG ?= $(firstword \
    $(wildcard /foss/designs/multimacro_chipathon/template/gf180mcu/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog) \
    $(wildcard /foss/designs/chipathon_padring/template/gf180mcu/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog))

# ----- RTL sim ---------------------------------------------------------

test-spi:
	$(MAKE) -f Makefile.cocotb \
	    TOPLEVEL=spi_master \
	    MODULE=test_spi \
	    VERILOG_SOURCES="$(RTL)/clk_divider.v $(RTL)/ff_2_sync.v $(RTL)/spi_master.v" \
	    SIM_BUILD=sim_build_spi

test-goertzel:
	$(MAKE) -f Makefile.cocotb \
	    TOPLEVEL=goertzel_core \
	    MODULE=test_goertzel \
	    VERILOG_SOURCES="$(RTL)/multiplier.v $(RTL)/goertzel_core.v" \
	    SIM_BUILD=sim_build_goertzel

test-top:
	$(MAKE) -f Makefile.cocotb \
	    TOPLEVEL=top \
	    MODULE=test_top \
	    VERILOG_SOURCES="$(RTL_SOURCES)" \
	    SIM_BUILD=sim_build_top

test-all: test-spi test-goertzel test-top

# ----- Gate-level sim --------------------------------------------------
# Uses the logical netlist (nl/) so cocotb does not need to wire VDD/VSS.
# COMPILE_ARGS: -g2012 so iverilog accepts specify blocks in stdcell models.
# -DFUNCTIONAL disables timing checks; -DUNIT_DELAY=#1 gives 1 ns unit delay.

COMPILE_ARGS = -g2012

test-top-gl:
	$(MAKE) -f Makefile.cocotb \
	    TOPLEVEL=top \
	    MODULE=test_top \
	    COMPILE_ARGS="$(COMPILE_ARGS) -DFUNCTIONAL -DUNIT_DELAY=\#1" \
	    VERILOG_SOURCES="timescale.v $(PDK_VLOG)/primitives.v $(PDK_VLOG)/gf180mcu_fd_sc_mcu7t5v0.v $(BUILD)/top/nl/top.nl.v" \
	    SIM_BUILD=sim_build_top_gl

test-gl-all: test-top-gl

# ----- Clean -----------------------------------------------------------
clean:
	rm -rf sim_build sim_build_spi sim_build_goertzel sim_build_top \
	       sim_build_top_gl results.xml __pycache__
