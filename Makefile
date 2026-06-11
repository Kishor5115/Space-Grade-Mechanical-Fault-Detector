# Makefile for Space-Grade Mechanical Fault Detector

# Docker configuration for ASIC tools
OSIC_IMG = hpretl/iic-osic-tools:chipathon26
DOCKER_CMD = docker run --rm -v $(PWD):/project -w /project -u $(shell id -u):$(shell id -g) $(OSIC_IMG) --skip

# Directories
RTL_DIR = rtl
TB_DIR = tb
SIM_DIR = sim

# Simulation Targets
.PHONY: sim_top sim_spi sim_goertzel sim_fault sim_config clean_sim view_waves

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

sim_top: $(SIM_DIR)
	$(DOCKER_CMD) iverilog -o $(SIM_DIR)/top.vvp $(TB_DIR)/vibration_top_tb.v $(RTL_DIR)/vibration_top.v $(RTL_DIR)/spi_master.v $(RTL_DIR)/config_regs.v $(RTL_DIR)/goertzel_core.v $(RTL_DIR)/fault_flagger.v
	$(DOCKER_CMD) vvp $(SIM_DIR)/top.vvp

sim_spi: $(SIM_DIR)
	$(DOCKER_CMD) iverilog -o $(SIM_DIR)/spi.vvp $(TB_DIR)/spi_master_tb.v $(RTL_DIR)/spi_master.v
	$(DOCKER_CMD) vvp $(SIM_DIR)/spi.vvp

sim_goertzel: $(SIM_DIR)
	$(DOCKER_CMD) iverilog -o $(SIM_DIR)/goertzel.vvp $(TB_DIR)/goertzel_core_tb.v $(RTL_DIR)/goertzel_core.v
	$(DOCKER_CMD) vvp $(SIM_DIR)/goertzel.vvp

sim_fault: $(SIM_DIR)
	$(DOCKER_CMD) iverilog -o $(SIM_DIR)/fault.vvp $(TB_DIR)/fault_flagger_tb.v $(RTL_DIR)/fault_flagger.v
	$(DOCKER_CMD) vvp $(SIM_DIR)/fault.vvp

sim_config: $(SIM_DIR)
	$(DOCKER_CMD) iverilog -o $(SIM_DIR)/config.vvp $(TB_DIR)/config_regs_tb.v $(RTL_DIR)/config_regs.v
	$(DOCKER_CMD) vvp $(SIM_DIR)/config.vvp

view_waves:
	docker run -it --rm --net=host --ipc=host -v $(PWD):/project -w /project -u $(shell id -u):$(shell id -g) -e DISPLAY=$(DISPLAY) -e QT_X11_NO_MITSHM=1 -v /tmp/.X11-unix:/tmp/.X11-unix $(OSIC_IMG) --skip gtkwave $(SIM_DIR)/dump.vcd

clean_sim:
	rm -rf $(SIM_DIR)/*

# ============================================================================
# LibreLane Physical Design (RTL-to-GDSII) Targets
# ============================================================================
OPENLANE_DIR  = librelane
LIBRELANE     = librelane
CONFIG_YAML   = config.yaml

# LibreLane runs with the working directory set to librelane/ so that the
# "dir::" relative paths in config.yaml (../rtl/*.v) resolve correctly.
OL_DOCKER  = docker run --rm -v $(PWD):/project -w /project/$(OPENLANE_DIR) -u $(shell id -u):$(shell id -g) $(OSIC_IMG) --skip

# GUI variant with X11 forwarding (for KLayout). Working dir is the project
# root so the latest GDS can be located under librelane/runs/.
GUI_DOCKER = docker run -it --rm --net=host --ipc=host -v $(PWD):/project -w /project -u $(shell id -u):$(shell id -g) -e DISPLAY=$$DISPLAY -e QT_X11_NO_MITSHM=1 -v /tmp/.X11-unix:/tmp/.X11-unix $(OSIC_IMG) --skip

.PHONY: openlane_run openlane_synth openlane_clean view_gds

# Full RTL-to-GDSII flow.
openlane_run:
	$(OL_DOCKER) $(LIBRELANE) $(CONFIG_YAML)

# Synthesis only (stop after the Yosys synthesis step).
openlane_synth:
	$(OL_DOCKER) $(LIBRELANE) $(CONFIG_YAML) --to Yosys.Synthesis

# Remove all LibreLane run artifacts.
openlane_clean:
	rm -rf $(OPENLANE_DIR)/runs

# Open the most recent final GDS in KLayout.
view_gds:
	$(GUI_DOCKER) bash -c 'klayout -e "$$(ls -t /project/$(OPENLANE_DIR)/runs/*/final/gds/*.gds | head -n 1)"'
