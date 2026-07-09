# Makefile for tb_top.v (full-chip end-to-end testbench)

RTL_DIR   := ../../rtl
TEST_DIR  := .

TOP_TB    := tb_top.v
MODEL     := ../spi_master_test/iis3dwb_model.v

# All RTL source files (no `include directives -- list explicitly)
RTL_SRCS  := $(RTL_DIR)/top.v \
             $(RTL_DIR)/spi_apb_interface.v \
             $(RTL_DIR)/apb.v \
             $(RTL_DIR)/spi_master.v \
             $(RTL_DIR)/clk_divider_5.v \
             $(RTL_DIR)/ff_2_sync.v \
             $(RTL_DIR)/axis_sequencer.v \
             $(RTL_DIR)/goertzel_core.v \
             $(RTL_DIR)/magnitude_compute.v \
             $(RTL_DIR)/fault_flagger.v \
             $(RTL_DIR)/tmr_reg_bank.v

SRCS      := $(TOP_TB) $(RTL_SRCS) $(MODEL)

SIM       := sim.out
WAVE      := tb_top.vcd

IVERILOG  := iverilog
VVP       := vvp

IFLAGS    := -g2012 -I $(RTL_DIR)

.PHONY: all sim run wave clean

all: run

sim: $(SIM)

$(SIM): $(SRCS)
	$(IVERILOG) $(IFLAGS) -o $(SIM) $(SRCS)

run: $(SIM)
	$(VVP) $(SIM)

wave: run
	@echo "Waveform: $(WAVE)"

clean:
	rm -f $(SIM) $(WAVE)
