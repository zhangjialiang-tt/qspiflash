################################################################################
#
# Makefile for spi_flash_stream testbench simulation
#
################################################################################

# Simulator selection (iverilog, verilator, or modelsim)
SIM ?= modelsim

# Source files
RTL_DIR = ../rtl
MODEL_DIR = model
TB_FILE = tb_spi_flash_stream.v
TB_NAME = tb_spi_flash_stream
RTL_FILE = $(RTL_DIR)/spi_flash_stream.v
MODEL_FILES = $(MODEL_DIR)/w25q128jvxim/W25Q128JVxIM.v
# Output files
SIM_OUT = spi_flash_stream_sim
VCD_FILE = spi_flash_stream.vcd
WLF_FILE = spi_flash_stream.wlf

# Compiler flags
IVERILOG_FLAGS = -g2012 -Wall
VERILOG_FLAGS = --trace --trace-structs -Wall

################################################################################
# Targets
################################################################################

.PHONY: all clean sim wave help sim_iverilog sim_verilator sim_modelsim

all: sim

# Main simulation target - dispatch to specific simulator
sim:
ifeq ($(SIM),iverilog)
	$(MAKE) sim_iverilog
else ifeq ($(SIM),verilator)
	$(MAKE) sim_verilator
else ifeq ($(SIM),modelsim)
	$(MAKE) sim_modelsim
else
	@echo "Unknown simulator: $(SIM)"
	@echo "Supported simulators: iverilog, verilator, modelsim"
endif

# Icarus Verilog simulation
sim_iverilog: $(TB_FILE) $(RTL_FILE) $(MODEL_FILES)
	@echo "Compiling with Icarus Verilog..."
	iverilog $(IVERILOG_FLAGS) -o $(SIM_OUT) \
		$(TB_FILE) $(RTL_FILE) $(MODEL_FILES)
	@echo "Running simulation..."
	vvp $(SIM_OUT)
	@echo "Simulation complete. Waveform saved to $(VCD_FILE)"

# Verilator simulation (not yet configured)
sim_verilator:
	@echo "Verilator simulation not yet configured"
	@echo "Please use: make SIM=iverilog"

# ModelSim simulation
sim_modelsim:
	vsim -do "do run.do"
# 	@echo "Compiling with ModelSim..."
# 	@if [ ! -d "work" ]; then vlib work; fi
# 	@echo "Compiling source files..."
# 	vlog -sv $(MODEL_FILES) $(RTL_FILE) $(TB_FILE)
# 	@echo "Running simulation..."
	
# 	vsim -c -do "run" $(TB_NAME) -wlf $(WLF_FILE) +notimingchecks
# # 	vsim -c -do "add wave -r /*; run -all; wlf finish; quit" $(TB_NAME) -wlf $(WLF_FILE) +notimingchecks
# 	@echo "Simulation complete. Waveform saved to $(WLF_FILE)"

# View waveform
wave:
ifeq ($(SIM),modelsim)
	@echo "Opening waveform viewer with ModelSim..."
	@vsim -view $(WLF_FILE) &
else
	@echo "Opening waveform viewer with GTKWave..."
	gtkwave $(VCD_FILE) &
endif

# Clean generated files
clean:
	@echo "Cleaning simulation files..."
	rm -f $(SIM_OUT) $(VCD_FILE) $(WLF_FILE)
	rm -f *.vcd *.lxt *.fst *.wlf *.log virtuals.do
	rm -rf work transcript
	@echo "Clean complete."

# Help message
help:
	@echo "Makefile for spi_flash_stream testbench simulation"
	@echo ""
	@echo "Targets:"
	@echo "  make sim       - Compile and run simulation (default: iverilog)"
	@echo "  make wave      - Open waveform viewer (GTKWave for iverilog, vsim for modelsim)"
	@echo "  make clean     - Remove generated files"
	@echo "  make help      - Show this help message"
	@echo ""
	@echo "Options:"
	@echo "  SIM=iverilog   - Use Icarus Verilog (default)"
	@echo "  SIM=verilator  - Use Verilator (not yet configured)"
	@echo "  SIM=modelsim   - Use ModelSim/QuestaSim"
	@echo ""
	@echo "Examples:"
	@echo "  make sim                   # Run simulation with iverilog"
	@echo "  make SIM=modelsim sim      # Run simulation with ModelSim"
	@echo "  make SIM=modelsim wave     # View waveform with ModelSim"
	@echo ""
