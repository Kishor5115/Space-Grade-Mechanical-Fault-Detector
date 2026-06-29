# Makefile for spi_apb_interface testbench

RTL_DIR   := ../../rtl
TEST_DIR  := .

TOP_TB    := tb_spi_apb_interface.v
DUT1       := $(RTL_DIR)/spi_apb_interface.v
DUT2       := $(RTL_DIR)/tmr_reg_bank.v
# MODEL     := iis3dwb_model.v

SRCS      := $(TOP_TB) $(DUT1) $(DUT2) 
#$(MODEL)

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