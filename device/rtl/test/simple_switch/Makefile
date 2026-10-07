# Self-checking simulation targets for the simple four-port switch.
# Requires Icarus Verilog with SystemVerilog support (iverilog -g2012).

IVERILOG ?= iverilog
VVP      ?= vvp
BUILD    ?= build
RTL      := ../../src/simple_switch
RTL_SRCS := $(RTL)/priority_selector_8.sv \
            $(RTL)/fdb_4port.sv \
            $(RTL)/fdb_request_arbiter_4.sv \
            $(RTL)/switch_1x3.sv \
            $(RTL)/transmission_selection_4.sv \
            $(RTL)/simple_tsn_switch_4port.sv

.PHONY: all test test-fdb test-selector test-switch clean

all: test

test: test-fdb test-selector test-switch

test-fdb: $(BUILD)/tb_fdb_4port
	$(VVP) $<

test-selector: $(BUILD)/tb_transmission_selection_4
	$(VVP) $<

test-switch: $(BUILD)/tb_simple_tsn_switch_4port
	$(VVP) $<

$(BUILD):
	mkdir -p $@

$(BUILD)/tb_fdb_4port: tb_fdb_4port.sv $(RTL)/fdb_4port.sv | $(BUILD)
	$(IVERILOG) -g2012 -s tb_fdb_4port -o $@ $(RTL)/fdb_4port.sv tb_fdb_4port.sv

$(BUILD)/tb_transmission_selection_4: tb_transmission_selection_4.sv \
                                      $(RTL)/priority_selector_8.sv \
                                      $(RTL)/transmission_selection_4.sv | $(BUILD)
	$(IVERILOG) -g2012 -s tb_transmission_selection_4 -o $@ \
		$(RTL)/priority_selector_8.sv \
		$(RTL)/transmission_selection_4.sv \
		tb_transmission_selection_4.sv

$(BUILD)/tb_simple_tsn_switch_4port: tb_simple_tsn_switch_4port.sv $(RTL_SRCS) | $(BUILD)
	$(IVERILOG) -g2012 -s tb_simple_tsn_switch_4port -o $@ $(RTL_SRCS) \
		tb_simple_tsn_switch_4port.sv

clean:
	rm -rf $(BUILD)
