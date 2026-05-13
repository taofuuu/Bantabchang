SIM           ?= icarus
TOPLEVEL_LANG ?= verilog

PROJ_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
RTL_DIR   := $(PROJ_ROOT)/rtl/overlay
TB_DIR    := $(PROJ_ROOT)/tb/overlay
VENV      := $(PROJ_ROOT)/.venv

export PYTHON_BIN := $(VENV)/bin/python

TEST ?= vga_controller

ifeq ($(TEST),vga_controller)
    VERILOG_SOURCES = $(RTL_DIR)/vga_controller.v
    TOPLEVEL        = vga_controller
    MODULE          = test_vga_controller
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
