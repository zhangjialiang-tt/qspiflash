################################################################################
#
# Makefile for spixpress testbench simulation
#
################################################################################

# Simulator selection (iverilog or verilator)
SIM ?= iverilog

# Source files
RTL_DIR = ..
MODEL_DIR = model
TB_FILE = tb_spi_flash_stream.v
RTL_FILE = $(RTL_DIR)/spi_flash_stream.v
MODEL_FILES = $(MODEL_DIR)/w25q128jvxim/W25Q128JVxIM.v

# Output files
SIM_OUT = spi_flash_stream_sim
VCD_FILE = spi_flash_stream.vcd

# Compiler flags
IVERILOG_FLAGS = -g2012 -Wall
VERILOG_FLAGS = --trace --trace-structs -Wall

################################################################################
# Targets
################################################################################

.PHONY: all clean sim wave help

all: sim

# Compile and run simulation with iverilog
sim: $(TB_FILE) $(RTL_FILE) $(MODEL_FILES)
ifeq ($(SIM),iverilog)
	@echo "Compiling with Icarus Verilog..."
	iverilog $(IVERILOG_FLAGS) -o $(SIM_OUT) \
		$(TB_FILE) $(RTL_FILE) $(MODEL_FILES)
	@echo "Running simulation..."
	vvp $(SIM_OUT)
	@echo "Simulation complete. Waveform saved to $(VCD_FILE)"
endif

# Rule to generate the VCD file by running simulation
$(VCD_FILE): sim

# View waveform with GTKWave
wave: $(VCD_FILE)
	@echo "Opening waveform viewer..."
	gtkwave $(VCD_FILE) &

# Clean generated files
clean:
	@echo "Cleaning simulation files..."
	rm -f $(SIM_OUT) $(VCD_FILE)
	rm -f *.vcd *.lxt *.fst
	@echo "Clean complete."

# Help message
help:
	@echo "Makefile for spixpress testbench simulation"
	@echo ""
	@echo "Targets:"
	@echo "  make sim       - Compile and run simulation (default: iverilog)"
	@echo "  make wave      - Open waveform viewer (GTKWave)"
	@echo "  make clean     - Remove generated files"
	@echo "  make help      - Show this help message"
	@echo ""
	@echo "Options:"
	@echo "  SIM=iverilog   - Use Icarus Verilog (default)"
	@echo "  SIM=verilator  - Use Verilator (not yet configured)"
	@echo ""
	@echo "Examples:"
	@echo "  make sim              # Run simulation with iverilog"
	@echo "  make SIM=iverilog sim # Same as above"
	@echo "  make wave             # View waveform"
	@echo ""
