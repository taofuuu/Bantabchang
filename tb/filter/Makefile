SIM           ?= icarus
TOPLEVEL_LANG ?= verilog

PROJ_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
RTL_DIR   := $(PROJ_ROOT)/rtl/filter
TB_DIR    := $(PROJ_ROOT)/tb/filter
VENV      := $(PROJ_ROOT)/.venv

export PYTHON_BIN := $(VENV)/bin/python

TEST ?= filter_frame_buffer

ifeq ($(TEST),filter_frame_buffer)
    VERILOG_SOURCES = $(RTL_DIR)/filter_frame_buffer.v
    TOPLEVEL        = filter_frame_buffer
    MODULE          = test_filter_frame_buffer
endif

ifeq ($(TEST),image_filter)
    VERILOG_SOURCES = $(RTL_DIR)/image_filter.v
    TOPLEVEL        = image_filter
    MODULE          = test_image_filter
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
