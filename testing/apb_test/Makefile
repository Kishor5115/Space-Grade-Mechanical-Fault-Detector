# Makefile for spi_apb_interface testbench

RTL_DIR   := ../../rtl
TEST_DIR  := .

TOP_TB    := tb_spi_apb_interface.v
STUB      := tmr_slave_stub.v

# All RTL source files needed by spi_apb_interface (no `include directives)
RTL_SRCS  := $(RTL_DIR)/spi_apb_interface.v \
             $(RTL_DIR)/apb.v \
             $(RTL_DIR)/spi_master.v \
             $(RTL_DIR)/clk_divider_5.v \
             $(RTL_DIR)/ff_2_sync.v

SRCS      := $(TOP_TB) $(RTL_SRCS) $(STUB)

SIM       := sim.out
WAVE      := waves.vcd

IVERILOG  := iverilog
VVP       := vvp

IFLAGS    := -g2012 -I $(RTL_DIR)

.PHONY: all sim run wave clean

all: run

# compile only
sim: $(SIM)

$(SIM): $(SRCS)
	$(IVERILOG) $(IFLAGS) -o $(SIM) $(SRCS)

# compile + execute
run: $(SIM)
	$(VVP) $(SIM)

# compile + execute + dump waveform (requires $dumpfile/$dumpvars in the tb)
wave: $(SIM)
	$(VVP) $(SIM) -vcd
	@echo "If no $(WAVE) appeared, add \$$dumpfile/\$$dumpvars to $(TOP_TB)."

clean:
	rm -f $(SIM) $(WAVE)
