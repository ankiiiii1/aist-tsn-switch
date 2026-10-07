# Simple-switch simulations

These self-checking SystemVerilog testbenches exercise the new standalone four-port switch RTL.

```sh
cd device/rtl/test/simple_switch
make test
```

The Makefile expects `iverilog` with SystemVerilog support and `vvp` in `PATH`.

| Testbench | Focus |
|---|---|
| `tb_fdb_4port.sv` | FDB learning, lookup, flood masks, same-port filtering, and MAC movement. |
| `tb_transmission_selection_4.sv` | Strict priority at a frame boundary and round-robin ties. |
| `tb_simple_tsn_switch_4port.sv` | Full four-port frame-path integration, forwarding copies, metadata preservation, and FDB behavior. |

The design report is at [`../../../../docs/simple-switch/4PORT_SWITCH_REPORT.md`](../../../../docs/simple-switch/4PORT_SWITCH_REPORT.md).
