# Makefile for spi_master_test
# Run from testing/spi_master_test/, or `make -C testing/spi_master_test`
# from the repo root.

RTL_DIR   := ../../rtl
TEST_DIR  := .

TOP_TB    := tb_spi_master_full.v
MODEL     := iis3dwb_model.v

# All RTL source files needed by spi_master (no `include directives)
RTL_SRCS  := $(RTL_DIR)/spi_master.v \
             $(RTL_DIR)/clk_divider.v \
             $(RTL_DIR)/ff_2_sync.v

SRCS      := $(TOP_TB) $(RTL_SRCS) $(MODEL)

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

run: $(SIM)
	$(VVP) $(SIM)

wave: $(SIM)
	$(VVP) $(SIM) -vcd
	@echo "If no $(WAVE) appeared, add \$$dumpfile/\$$dumpvars to $(TOP_TB)."

clean:
	rm -f $(SIM) $(WAVE)
