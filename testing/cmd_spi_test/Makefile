# Makefile for tb_cmd_spi.v (external coefficient reception, end-to-end via top)

RTL_DIR   := ../../rtl
TEST_DIR  := .

TOP_TB    := tb_cmd_spi.v

# Full chip + all deps (top instantiates the command-SPI config path).
RTL_SRCS  := $(RTL_DIR)/top.v \
             $(RTL_DIR)/spi_apb_interface.v \
             $(RTL_DIR)/apb.v \
             $(RTL_DIR)/apb_arb2.v \
             $(RTL_DIR)/cmd_spi_slave.v \
             $(RTL_DIR)/spi_master.v \
             $(RTL_DIR)/clk_divider.v \
             $(RTL_DIR)/ff_2_sync.v \
             $(RTL_DIR)/axis_sequencer.v \
             $(RTL_DIR)/goertzel_core.v \
             $(RTL_DIR)/multiplier.v \
             $(RTL_DIR)/magnitude_compute.v \
             $(RTL_DIR)/fault_flagger.v \
             $(RTL_DIR)/tmr_reg_bank.v

SRCS      := $(TOP_TB) $(RTL_SRCS)

SIM       := sim.out
WAVE      := tb_cmd_spi.vcd

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
