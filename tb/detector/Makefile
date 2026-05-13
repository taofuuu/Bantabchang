# cocotb runner. Usage:
#   cd tb/detector && make                   # default: requantize
#   cd tb/detector && make TEST=requantize
#
# The simulator is iverilog (already installed system-wide). Cocotb is in the
# project venv so we use $(VENV)/bin/python for module discovery.

SIM           ?= icarus
TOPLEVEL_LANG ?= verilog

# Path to project root (two levels up from tb/detector/)
PROJ_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
RTL_DIR   := $(PROJ_ROOT)/rtl/detector
TB_DIR    := $(PROJ_ROOT)/tb/detector
VENV      := $(PROJ_ROOT)/.venv

# Force cocotb to use the venv's Python so it finds the cocotb package.
export PYTHON_BIN := $(VENV)/bin/python

# Match Vivado's include path so `include "scales.vh"` resolves under iverilog.
COMPILE_ARGS += -I$(PROJ_ROOT)/weights

# Test selection
TEST ?= requantize

ifeq ($(TEST),requantize)
    VERILOG_SOURCES = $(RTL_DIR)/requantize.v
    TOPLEVEL        = requantize
    MODULE          = test_requantize
endif

ifeq ($(TEST),weight_rom)
    VERILOG_SOURCES = $(RTL_DIR)/weight_rom.v $(TB_DIR)/wrap_weight_rom.v
    TOPLEVEL        = wrap_weight_rom
    MODULE          = test_weight_rom
endif

ifeq ($(TEST),act_buffer)
    VERILOG_SOURCES = $(RTL_DIR)/act_buffer.v $(TB_DIR)/wrap_act_buffer.v
    TOPLEVEL        = wrap_act_buffer
    MODULE          = test_act_buffer
endif

ifeq ($(TEST),frame_buffer)
    VERILOG_SOURCES = $(RTL_DIR)/frame_buffer.v
    TOPLEVEL        = frame_buffer
    MODULE          = test_frame_buffer
endif

ifeq ($(TEST),patch_extractor)
    VERILOG_SOURCES = $(RTL_DIR)/frame_buffer.v   $(RTL_DIR)/act_buffer.v \
                      $(RTL_DIR)/patch_extractor.v $(TB_DIR)/wrap_patch_extractor.v
    TOPLEVEL        = wrap_patch_extractor
    MODULE          = test_patch_extractor
endif

ifeq ($(TEST),fc_layer)
    VERILOG_SOURCES = $(RTL_DIR)/act_buffer.v $(RTL_DIR)/weight_rom.v \
                      $(RTL_DIR)/fc_layer.v   $(TB_DIR)/wrap_fc_layer.v
    TOPLEVEL        = wrap_fc_layer
    MODULE          = test_fc_layer
endif

ifeq ($(TEST),conv1)
    VERILOG_SOURCES = $(RTL_DIR)/act_buffer.v $(RTL_DIR)/weight_rom.v \
                      $(RTL_DIR)/requantize.v $(RTL_DIR)/conv_layer.v \
                      $(TB_DIR)/wrap_conv1.v
    TOPLEVEL        = wrap_conv1
    MODULE          = test_conv1
endif

ifeq ($(TEST),detector_top)
    VERILOG_SOURCES = $(RTL_DIR)/act_buffer.v $(RTL_DIR)/weight_rom.v \
                      $(RTL_DIR)/requantize.v $(RTL_DIR)/conv_layer.v \
                      $(RTL_DIR)/fc_layer.v   $(RTL_DIR)/frame_buffer.v \
                      $(RTL_DIR)/patch_extractor.v $(RTL_DIR)/detector_top.v \
                      $(TB_DIR)/wrap_detector_top.v
    TOPLEVEL        = wrap_detector_top
    MODULE          = test_detector_top
endif

# (more TEST=... blocks will appear here as we add testbenches)

include $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim
