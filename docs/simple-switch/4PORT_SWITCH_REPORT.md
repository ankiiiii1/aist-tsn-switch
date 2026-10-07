# Simple 4-port FPGA switch — RTL design report

## 1. Purpose and reference alignment

This report documents the standalone first-draft four-port Ethernet switching core in:

```text
device/rtl/src/simple_switch/
```

The implementation was designed from the repository documentation and the supplied IEEE Access paper's FDB Switch description.  In particular, it preserves the paper's architectural separation:

1. **FDB** learns a source MAC address and decides the destination port(s).
2. **1×3 Switch** physically forwards/copies the frame using the FDB decision.
3. **Transmission Selection** arbitrates frames for each physical egress.

This is consistent with the paper's Figure 7 text: the FDB is at the entrance, registers a source MAC with an input port, looks up the destination MAC, excludes the ingress port on flooding, and **only decides the destination**.  The repository says the same in:

- `docs/ats-switch/blocks/switch_with_fdb_block.md`
- `docs/cbs-switch/blocks/switch_with_fdb_block.md`

The current deliverable is deliberately a simple, fully RTL implementation.  It is **not** a PHY/MAC implementation and is **not** a full production TSN implementation.

---

## 2. Implemented architecture

```text
                         Shared descriptor path
   +--------------+      +------------------------------+
   | ingress 0    |----->|                              |
   | switch_1x3   |      |                              |
   +--------------+      |      fdb_request_arbiter_4   |
   +--------------+      |               |              |
   | ingress 1    |----->|               v              |
   | switch_1x3   |      |           fdb_4port          |
   +--------------+      | (learn + lookup + mask only) |
   +--------------+      +------------------------------+
   | ingress 2    |-------------------|  FDB response
   | switch_1x3   |<------------------+
   +--------------+
   +--------------+
   | ingress 3    |
   | switch_1x3   |
   +--------------+

   4 logical streams with tdest
           |
           +---> transmission_selection_4, egress 0 ---> port 0
           +---> transmission_selection_4, egress 1 ---> port 1
           +---> transmission_selection_4, egress 2 ---> port 2
           +---> transmission_selection_4, egress 3 ---> port 3
```

For each ingress, `switch_1x3` first stores one entire frame.  It extracts destination MAC bytes 0–5 and source MAC bytes 6–11, submits only those fields and the ingress-port ID to the common FDB, then acts on the returned mask:

- one selected bit → replay the frame once to that egress;
- three selected bits → replay the stored frame once to each non-ingress egress;
- no selected bits → discard the stored frame (same-port filter).

Flooded copies are replayed **sequentially** in port-number order.  This is a conscious first-draft throughput/simplicity trade-off.  It does not change the FDB interface or decision semantics.

---

## 3. Top-level interface

### Module

```systemverilog
simple_tsn_switch_4port #(
    .TABLE_ENTRIES(16),
    .MAX_FRAME_BYTES(1536)
)
```

### Clock and reset

| Signal | Direction | Meaning |
|---|---|---|
| `aclk` | input | Single core clock for all ports and all modules. |
| `aresetn` | input | Active-low **synchronous** reset. Keep low for at least one rising edge. |

The names follow the repository's AXI/Vivado convention.

### Four ingress AXI4-Stream-like ports

All per-port vectors are packed with **port 0 in the least-significant slice**.

| Signal | Direction | Width | Port `p` slice | Meaning |
|---|---:|---:|---|---|
| `s_axis_tdata` | input | 32 | `[8*p +: 8]` | Frame byte. Byte 0 is the first destination-MAC byte. |
| `s_axis_tuser` | input | 12 | `[3*p +: 3]` | Priority code, 0 through 7. It must remain stable for one frame. |
| `s_axis_tvalid` | input | 4 | `[p]` | Input byte valid. |
| `s_axis_tready` | output | 4 | `[p]` | Input byte accepted when valid and ready are both high. |
| `s_axis_tlast` | input | 4 | `[p]` | High on the final byte of the frame. |

The input sender must obey standard AXI-stream backpressure: retain `tdata`, `tuser`, and `tlast` while `tvalid=1` and `tready=0`.

### Four egress AXI4-Stream-like ports

| Signal | Direction | Width | Port `p` slice | Meaning |
|---|---:|---:|---|---|
| `m_axis_tdata` | output | 32 | `[8*p +: 8]` | Forwarded frame byte. |
| `m_axis_tuser` | output | 12 | `[3*p +: 3]` | The priority captured at ingress frame start. |
| `m_axis_tvalid` | output | 4 | `[p]` | Valid output byte. |
| `m_axis_tready` | input | 4 | `[p]` | Ready from downstream MAC/FIFO logic. |
| `m_axis_tlast` | output | 4 | `[p]` | Final byte of the forwarded frame. |

There is no output `tdest`: each `m_axis` slice already represents a physical egress port.

### Debug outputs

The top level exposes the most recent FDB response for bring-up and waveform inspection:

| Signal | Meaning |
|---|---|
| `fdb_decision_valid` | One clock when the shared FDB returns a decision. |
| `fdb_decision_ingress_port` | Ingress port which owns the response. |
| `fdb_lookup_hit` | Destination unicast MAC was in the FDB. |
| `fdb_same_port` | Learned destination is the ingress port; frame is filtered. |
| `fdb_dest_port` | Learned destination port for a hit; zero for unknown/group. |
| `fdb_dest_mask` | Physical copy mask, bit 0 = egress 0 through bit 3 = egress 3. |
| `ingress_frame_too_long` | Sticky per-ingress indication that a frame exceeded `MAX_FRAME_BYTES`. |

---

## 4. FDB specification

### Module interface

```systemverilog
fdb_4port #(.TABLE_ENTRIES(16))
```

It uses a simple descriptor request/response interface:

| Request signal | Meaning |
|---|---|
| `request_src_mac[47:0]` | Source MAC extracted from Ethernet bytes 6–11. |
| `request_dst_mac[47:0]` | Destination MAC extracted from Ethernet bytes 0–5. |
| `request_ingress_port[1:0]` | Input port: `0`, `1`, `2`, or `3`. |
| `request_valid` / `request_ready` | Descriptor handshake. |

| Response signal | Meaning |
|---|---|
| `response_valid` | One-cycle registered response pulse, one clock after acceptance. |
| `response_ingress_port[1:0]` | Original requester ID. |
| `response_hit` | Learned unicast destination hit. |
| `response_same_port` | Destination resolves to the input port. |
| `response_dest_port[1:0]` | Resolved destination port on a hit. |
| `response_dest_mask[3:0]` | Forwarding/copy mask consumed by the 1×3 switching fabric. |

The shared FDB accepts one descriptor, emits a one-cycle response, then accepts the next descriptor.  `fdb_request_arbiter_4` supplies fair round-robin request selection across the four ingress pipelines.

### MAC-table structure

Each of the default 16 entries has exactly the requested first-draft fields:

```text
valid : 1 bit
mac   : 48 bits
port  : 2 bits
```

The table is fully associative: all entries are compared in parallel in straightforward RTL.  This keeps the implementation understandable for synthesis and debugging.  It deliberately does **not** use a hash, CAM primitive, VLAN key, timer, or aging mechanism.

When a source address arrives:

1. If its MAC already exists, overwrite its stored port with the current ingress port.
2. Otherwise use the first invalid entry.
3. If all entries are valid, replace an entry using a simple round-robin victim pointer.

The round-robin victim policy is only a small deterministic fallback for a full 16-entry table; it is not an aging algorithm.

### Learning and lookup sequence

On an accepted descriptor request, the FDB:

1. learns/refreshes `(request_src_mac → request_ingress_port)`;
2. compares `request_dst_mac` against every valid table entry;
3. registers a forwarding decision for the next cycle.

A `dst_mac == src_mac` bypass is included so that a source seen for the first time is still recognized as residing on the current input and is not sent back to that input.

### Forwarding decision table

| Destination kind | `response_hit` | `response_same_port` | `response_dest_mask` |
|---|---:|---:|---|
| Known unicast on a different port | 1 | 0 | exactly one bit: `1 << learned_port` |
| Known unicast on ingress port | 1 | 1 | `4'b0000` (filter/drop) |
| Unknown unicast | 0 | 0 | all four bits except ingress bit |
| Broadcast or multicast destination | 0 | 0 | all four bits except ingress bit |

For example, an unknown unicast received at port 2 yields `4'b1011`, which means copies go to ports 0, 1, and 3.

The Ethernet individual/group test uses the I/G bit in the **first MAC octet** (`dst_mac[40]` in this `[47:0]` representation).  Thus `FF:FF:FF:FF:FF:FF` and all multicast destinations flood correctly, while ordinary unicast MAC addresses are eligible for a lookup.

Source learning remains enabled for broadcast/multicast-destination frames, which allows normal discovery/ARP traffic to populate the FDB.

---

## 5. Module report

| File / module | Function | Important behavior |
|---|---|---|
| `fdb_4port.sv` / `fdb_4port` | Shared FDB | Stores valid/MAC/port entries, learns source MACs, and returns a 4-bit forwarding mask. It has no frame-data ports. |
| `fdb_request_arbiter_4.sv` / `fdb_request_arbiter_4` | Descriptor arbiter | Serializes descriptor requests from four ingress buffers using round-robin fairness. |
| `switch_1x3.sv` / `switch_1x3` | Ingress buffer and physical fabric | Stores one complete frame, extracts MACs, waits for FDB response, and replays frame copies according to the mask. It never performs an FDB lookup itself. |
| `priority_selector_8.sv` / `priority_selector_8` | Traffic-class decode | Converts the three-bit externally supplied priority to an 8-bit one-hot traffic-class indication. It does not parse VLAN tags. |
| `transmission_selection_4.sv` / `transmission_selection_4` | Per-egress arbiter | Selects a stream whose internal `tdest` matches its egress. At frame start, higher `tuser` priority wins; equal priority uses round-robin. The grant is held to `tlast`. |
| `simple_tsn_switch_4port.sv` / `simple_tsn_switch_4port` | Complete core | Instantiates four 1×3 fabrics, one shared FDB plus request arbiter, and four transmission-selection blocks. |

Although `transmission_selection_4` has four packed inputs for simple regular wiring, the FDB never selects a frame's own ingress port.  Therefore, each physical egress normally sees at most the three non-self inputs described in the paper.

---

## 6. Priority and transmission selection

The full paper has richer Traffic-Class and ATS transmission-selection structures.  This first draft provides the structural blocks but keeps behavior intentionally simple:

- Priority comes from `s_axis_tuser[2:0]`; `7` is highest and `0` is lowest.
- A priority is captured on the first input byte and carried unchanged to output `m_axis_tuser`.
- At the start of a frame, an egress chooses the eligible highest-priority stream.
- Equal priorities use a rolling round-robin starting point.
- Once a frame begins, the selected input remains locked through its `tlast` transfer.
- There is no per-class queue, traffic shaper, eligibility time, CBS credit, TAS gate, or VLAN PCP parser.

This provides a synthesizable placeholder/first working arbitration stage while preserving the paper's FDB → physical switch → transmission-selection separation.

---

## 7. Integration with the existing repository

The repository's existing designs use 8-bit AXI4-Stream internally at 125 MHz and contain a third-party `mactable_mod`/`channel_in_mod` FDB path managed in Vivado block-design Tcl.  This new core deliberately uses the same basic `tdata/tvalid/tready/tlast` streaming convention, but it is a **new standalone RTL core**, not a drop-in change to the existing generated Vivado block design.

To integrate it into a board design:

1. Put `simple_tsn_switch_4port.sv` and every file listed in `filelist.f` into the HDL compilation set.
2. Connect the existing FPGA-core-side output of each pre-switch FIFO/MAC pipeline to the corresponding `s_axis` slice.
3. Connect `aclk` and the existing active-low core reset to `aresetn`.
4. If a priority classifier exists upstream, connect its priority to `s_axis_tuser`; otherwise drive every priority slice with `3'd0`.
5. Connect each `m_axis` slice to the corresponding egress FIFO/MAC pipeline and return its `tready`.
6. Keep the existing PHY/MAC, CDC FIFO, and board constraints outside this core.

For a true replacement of the current ATS/CBS production block, the Vivado Tcl design must be intentionally edited to replace the relevant FDB-switch hierarchy.  Do not wire both this core and the existing third-party switch fabric to the same streams.

---

## 8. Parameters and resource/throughput implications

| Parameter | Default | Meaning |
|---|---:|---|
| `TABLE_ENTRIES` | 16 | Number of FDB entries. |
| `MAX_FRAME_BYTES` | 1536 | Capacity of each one-frame ingress store. |

The four ingress frame stores total approximately `4 × MAX_FRAME_BYTES` bytes before FPGA memory mapping overhead.  The fully associative FDB requires `TABLE_ENTRIES` parallel 48-bit equality comparisons.  Both choices are deliberately small and easy to inspect.

Important first-draft behavior:

- Each ingress accepts one frame, then applies backpressure until that frame has been forwarded or filtered.
- Flooding sends three serial copies from a given ingress; it is correct but not maximum-throughput replication.
- No buffering is provided beyond one stored frame per ingress and downstream backpressure.
- Frames shorter than 12 bytes are discarded because they cannot contain both MAC addresses.
- A frame exceeding `MAX_FRAME_BYTES` is consumed through `tlast`, discarded, and sets its sticky `ingress_frame_too_long` bit.
- CRC/FCS, length-policy, malformed-frame checks, preamble/SFD, and PHY behavior belong in surrounding MAC logic.

---

## 9. Verification

The following self-checking SystemVerilog testbenches were added under `device/rtl/test/simple_switch/`:

| Testbench | Checks |
|---|---|
| `tb_fdb_4port.sv` | Source learning, known lookup, unknown flooding, broadcast flooding, same-port filtering, and MAC movement. |
| `tb_transmission_selection_4.sv` | Higher-priority selection and round-robin tie behavior. |
| `tb_simple_tsn_switch_4port.sv` | End-to-end frame copying, FDB behavior, same-port filtering, MAC movement, frame content, and priority preservation. |

They were linted with Verilator 5.050 and simulated successfully during implementation.  The provided `Makefile` uses `iverilog -g2012` and `vvp` when those tools are installed:

```sh
cd device/rtl/test/simple_switch
make test
```

---

## 10. Intentional exclusions and next steps

Before using this core for a high-rate hardware deployment, consider adding in separate, reviewable increments:

1. standards-compliant MAC source validation and optional MAC aging;
2. deeper ingress/egress queues and concurrent multicast replication;
3. formal AXI-stream protocol assertions and random/backpressure tests;
4. VLAN parsing/classification outside the FDB;
5. a management/control interface for table inspection and static entries;
6. ATS/CBS/TAS only after the basic switching path is validated;
7. board-specific PHY/MAC, CDC, timing, and resource verification.

None of those features should be inserted into `fdb_4port` unless they are genuinely part of forwarding database behavior.
