# Verilator Makefile

# Define variables
TESTNAME       ?= tb_cubic_solver
TB_NAME        ?= tb_cubic_solver
SIM_DEBUG      ?= 1
COMPILE_F      ?= ../compile_files
USE_UNISIM     ?= 
XILINX_VIVADO  ?= /opt/Xilinx/Vivado/2023.1# UPDATE THIS to your Vivado path

# Verilator Flags
VFLAGS := --binary --timing --trace --coverage
VFLAGS += --top-module $(TB_NAME)
VFLAGS += $(if $(SIM_DEBUG),+define+SIM_DEBUG,)

# Xilinx UNISIM Handling in Verilator (Read from source, no pre-compilation)
ifeq ($(USE_UNISIM),1)
    VFLAGS += +define+USE_UNISIM
    VFLAGS += -y $(XILINX_VIVADO)/data/verilog/src/unisims
    VFLAGS += -y $(XILINX_VIVADO)/data/verilog/src/retarget
    VFLAGS += $(XILINX_VIVADO)/data/verilog/src/glbl.v
    # UNISIMs often trigger Verilator lint warnings. We disable fatal errors for them.
    VFLAGS += -Wno-fatal
endif

ARGS := $(MAKECMDGOALS)

# Insert new commands here if you want to add more make targets
COMMANDS := all allwave allcov \
            build buildcov \
            run runcov \
            wave \
            gencov genhtml \
            xilinx_libs check_xilinx_libs clean_libs \
            clean \
            help

TEST_ARG := $(filter-out $(COMMANDS),$(ARGS))

ifneq ($(TEST_ARG),)
    TESTNAME := $(firstword $(TEST_ARG))
    TB_NAME  := $(firstword $(TEST_ARG))

    $(TEST_ARG):
        @:
endif

# Standard Targets

all: clean build run

allwave: clean build run wave

allcov: clean buildcov runcov

build: $(if $(USE_UNISIM),check_xilinx_libs,)
	@rm -f verilator_temp.f
	@touch verilator_temp.f
	@bash -c '\
		cd $(COMPILE_F) || exit 1; \
		tr -d "\r" < compile.f | awk "/-[fF]/ {print \$$2}" | while read subfile; do \
			if [ -f "$$subfile" ]; then \
				tr -d "\r" < "$$subfile" | grep -E -v "^[[:space:]]*(#|//|$$)" | while read -r line; do \
					for expanded in $$line; do \
						echo "$$expanded" >> ../verilator/verilator_temp.f; \
					done; \
				done; \
			else \
				echo "    [!] WARNING: Cannot find sub-file: $$subfile"; \
			fi; \
		done \
	'
	@echo "Generated verilator_temp.f contents:"
	@cat verilator_temp.f
	@echo "----------------------------------------"
	@echo "Building $(TB_NAME) with Verilator"
	verilator $(VFLAGS) -f verilator_temp.f | tee compile.log

# In Verilator, there is no difference between building normally and building for coverage,
# as long as --coverage is passed (which is included in VFLAGS above).
buildcov: build

run:
	@echo "--> Running simulation..."
	./obj_dir/V$(TB_NAME) | tee $(TESTNAME).log

runcov: run

wave:
	@echo "--> Opening waveform in GTKWave..."
	gtkwave dump.vcd &

# Coverage Targets

gencov:
	@echo "--> Generating annotated coverage text reports..."
	mkdir -p coverage
	verilator_coverage --annotate coverage/annotated --write coverage/merged.dat coverage.dat
	@echo "Text coverage generated in coverage/annotated/"

genhtml:
	@echo "--> Generating HTML coverage report using lcov..."
	mkdir -p coverage
	# Convert Verilator coverage data to lcov format
	verilator_coverage --write-info coverage/coverage.info coverage.dat
	# Generate HTML using standard lcov tool
	genhtml coverage/coverage.info --output-directory coverage/html
	@echo "HTML coverage generated in coverage/html/index.html"

# Xilinx Library Targets
# Note: Verilator doesn't precompile libraries into a folder like Questa.
# It parses them directly from the Vivado source during the 'build' step.
# These targets are kept for compatibility with your workflow.

xilinx_libs:
	@echo "Note: Verilator does not precompile libraries. It will read UNISIMs directly from $(XILINX_VIVADO)/data/verilog/src/unisims during 'make build'."

clean_libs:
	@echo "Note: No precompiled libraries to clean for Verilator."

check_xilinx_libs:
	@if [ ! -d "$(XILINX_VIVADO)/data/verilog/src/unisims" ]; then \
		echo "ERROR: Cannot find Vivado UNISIM directory at $(XILINX_VIVADO)/data/verilog/src/unisims"; \
		echo "Please update XILINX_VIVADO variable in the Makefile."; \
		exit 1; \
	fi

# Cleanup & Help

clean:
	rm -rf obj_dir
	rm -rf coverage
	rm -f *.log
	rm -f *.vcd
	rm -f *.fst
	rm -f coverage.dat
	rm -f verilator_temp.f

help:
	@echo ""
	@echo "****************************************"
	@echo "** make clean    : clean all compiled data (removes obj_dir, logs, wave files)"
	@echo "** make build    : build the design using Verilator"
	@echo "** make run      : run the Verilated executable"
	@echo "** make all      : build and run simulation"
	@echo "** make wave     : open waveform in GTKWave"
	@echo "** make gen_cov  : generate text-based annotated coverage"
	@echo "** make gen_html : generate HTML coverage report (requires lcov)"
	@echo "** make help     : print this help message"
	@echo "****************************************"
	@echo ""