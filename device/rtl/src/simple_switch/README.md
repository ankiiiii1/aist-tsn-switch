# Simple 4-port FPGA switch RTL

This directory contains a **standalone, synthesizable SystemVerilog first draft** of the paper-style four-port L2 switch pipeline.  It was added as clean RTL alongside the existing Vivado/IP-based design; it does not alter the repository's production ATS/CBS block designs.

## Scope

The implementation follows the separation described for the IEEE Access paper's Figure 7 and the repository's `switch_with_fdb_block.md` documentation:

```text
4 x 8-bit AXI-stream ingress
       |
       +--> switch_1x3 (one per ingress: store frame, extract MACs,
       |                request FDB decision, replay selected copies)
                         |
                         +--> shared fdb_4port (decision only)
                         |
                         +--> 4 x transmission_selection_4
                                      |
                                4 x AXI-stream egress
```

The FDB **does not physically move frame bytes**.  It learns and responds with a 4-bit destination mask.  `switch_1x3` performs the actual frame replay/copying after receiving that mask.

This intentionally small implementation includes:

- four Ethernet-facing logical ports;
- a 16-entry, fully associative source-MAC table by default;
- source-MAC learning and learned-port refresh/move;
- known-unicast forwarding, same-port filtering, unknown-unicast flooding, and group/broadcast flooding;
- one store-and-forward frame buffer per ingress;
- a simple priority-aware egress selector with round-robin ties.

It intentionally excludes PHY/MAC, CRC/FCS handling, VLAN parsing, MAC aging, management registers, queues deeper than one frame per ingress, ATS, CBS, TAS, and other TSN shaping.  Priority is supplied as external AXI metadata rather than parsed from a VLAN PCP.

Read [`../../../../docs/simple-switch/4PORT_SWITCH_REPORT.md`](../../../../docs/simple-switch/4PORT_SWITCH_REPORT.md) for the complete interface, module, integration, and limitation report.

## Source files

| File | Module | Purpose |
|---|---|---|
| `simple_tsn_switch_4port.sv` | `simple_tsn_switch_4port` | Four-port top level. |
| `fdb_4port.sv` | `fdb_4port` | Learning database and forwarding-mask decision only. |
| `fdb_request_arbiter_4.sv` | `fdb_request_arbiter_4` | Round-robin arbitration of four FDB descriptor producers. |
| `switch_1x3.sv` | `switch_1x3` | One ingress store/replay fabric; parses Ethernet MAC bytes 0–11. |
| `priority_selector_8.sv` | `priority_selector_8` | Converts three-bit metadata to a traffic-class one-hot value. |
| `transmission_selection_4.sv` | `transmission_selection_4` | Per-egress strict-priority / round-robin frame selector. |
| `filelist.f` | — | Compile-order file list. |

## Quick simulation

The testbench sources are under `device/rtl/test/simple_switch/`.  With Icarus Verilog installed:

```sh
cd device/rtl/test/simple_switch
make test
```

The three tests cover the FDB behavior, the full switch pipeline, and priority/round-robin egress selection.
