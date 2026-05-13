# cocotb tests for rtl/camera/
# Usage:
#   cd tb/camera && make                         # default: pixel_stream_cdc
#   cd tb/camera && make TEST=pixel_stream_cdc
#   cd tb/camera && make TEST=ov7670_capture
#   cd tb/camera && make TEST=ov7670_config

SIM           ?= icarus
TOPLEVEL_LANG ?= verilog

PROJ_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
RTL_DIR   := $(PROJ_ROOT)/rtl/camera
TB_DIR    := $(PROJ_ROOT)/tb/camera
VENV      := $(PROJ_ROOT)/.venv

export PYTHON_BIN := $(VENV)/bin/python

TEST ?= pixel_stream_cdc

ifeq ($(TEST),pixel_stream_cdc)
    VERILOG_SOURCES = $(RTL_DIR)/pixel_stream_cdc.v
    TOPLEVEL        = pixel_stream_cdc
    MODULE          = test_pixel_stream_cdc
endif

ifeq ($(TEST),ov7670_capture)
    VERILOG_SOURCES = $(RTL_DIR)/ov7670_capture.v
    TOPLEVEL        = ov7670_capture
    MODULE          = test_ov7670_capture
endif

ifeq ($(TEST),ov7670_config)
    VERILOG_SOURCES = $(RTL_DIR)/ov7670_config.v $(TB_DIR)/wrap_ov7670_config.v
    TOPLEVEL        = wrap_ov7670_config
    MODULE          = test_ov7670_config
endif

include $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim
