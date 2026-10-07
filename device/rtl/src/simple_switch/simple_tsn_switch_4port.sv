`timescale 1ns / 1ps

// SPDX-License-Identifier: MIT
//
// First-draft, four-port FPGA Ethernet switch core.
//
// Paper-aligned pipeline (without PHY/MAC or TSN shapers):
//
//   four AXI4-Stream ingress ports
//       -> four store-and-forward 1x3 fabrics / MAC extractors
//       -> one shared FDB (learning + destination decision only)
//       -> four per-egress Transmission Selection blocks
//       -> four AXI4-Stream egress ports
//
// The FDB remains a separate module.  switch_1x3 physically replays frames
// after receiving an FDB mask, while transmission_selection_4 arbitrates each
// physical egress.  This is deliberately a basic L2 design: it has no PHY,
// MAC, CRC checker, VLAN parser, aging, ATS, CBS, TAS, or other TSN shaping.

module simple_tsn_switch_4port #(
    parameter integer TABLE_ENTRIES   = 16,
    parameter integer MAX_FRAME_BYTES = 1536
) (
    input  wire         aclk,
    input  wire         aresetn,

    // Four 8-bit AXI4-Stream-like ingress ports.  Port 0 is in the least
    // significant slice.  tuser[2:0] is the externally supplied priority
    // metadata for the frame; use 3'd0 when no priority classification exists.
    input  wire [4*8-1:0] s_axis_tdata,
    input  wire [4*3-1:0] s_axis_tuser,
    input  wire [3:0]     s_axis_tvalid,
    output wire [3:0]     s_axis_tready,
    input  wire [3:0]     s_axis_tlast,

    // Four physical egress streams.  m_axis_tuser preserves the selected
    // ingress frame priority.  There is no tdest because each output is a
    // physical port already.
    output wire [4*8-1:0] m_axis_tdata,
    output wire [4*3-1:0] m_axis_tuser,
    output wire [3:0]     m_axis_tvalid,
    input  wire [3:0]     m_axis_tready,
    output wire [3:0]     m_axis_tlast,

    // Debug/bring-up visibility of the latest FDB decision.
    output wire           fdb_decision_valid,
    output wire [1:0]     fdb_decision_ingress_port,
    output wire           fdb_lookup_hit,
    output wire           fdb_same_port,
    output wire [1:0]     fdb_dest_port,
    output wire [3:0]     fdb_dest_mask,
    output wire [3:0]     ingress_frame_too_long
);

    // Descriptor sideband from the four captured frames to the shared FDB.
    wire [3:0]      meta_valid;
    wire [3:0]      meta_ready;
    wire [4*48-1:0] meta_src_mac;
    wire [4*48-1:0] meta_dst_mac;
    wire [4*2-1:0]  meta_ingress_port;

    wire        fdb_request_valid;
    wire        fdb_request_ready;
    wire [47:0] fdb_request_src_mac;
    wire [47:0] fdb_request_dst_mac;
    wire [1:0]  fdb_request_ingress_port;

    // Frame streams leaving the four 1x3 fabrics.  tdest still identifies the
    // desired physical egress while a transmission selector chooses a source.
    wire [4*8-1:0] fabric_tdata;
    wire [4*3-1:0] fabric_tuser;
    wire [4*2-1:0] fabric_tdest;
    wire [3:0]     fabric_tvalid;
    wire [3:0]     fabric_tready;
    wire [3:0]     fabric_tlast;

    wire [3:0] selector_0_ready;
    wire [3:0] selector_1_ready;
    wire [3:0] selector_2_ready;
    wire [3:0] selector_3_ready;

    genvar port_index;
    generate
        for (port_index = 0; port_index < 4; port_index = port_index + 1) begin : GEN_INGRESS_1X3
            switch_1x3 #(
                .INGRESS_PORT(port_index),
                .MAX_FRAME_BYTES(MAX_FRAME_BYTES)
            ) ingress_switch_1x3 (
                .aclk(aclk),
                .aresetn(aresetn),
                .s_axis_tdata(s_axis_tdata[port_index*8 +: 8]),
                .s_axis_tuser(s_axis_tuser[port_index*3 +: 3]),
                .s_axis_tvalid(s_axis_tvalid[port_index]),
                .s_axis_tready(s_axis_tready[port_index]),
                .s_axis_tlast(s_axis_tlast[port_index]),
                .meta_src_mac(meta_src_mac[port_index*48 +: 48]),
                .meta_dst_mac(meta_dst_mac[port_index*48 +: 48]),
                .meta_ingress_port(meta_ingress_port[port_index*2 +: 2]),
                .meta_valid(meta_valid[port_index]),
                .meta_ready(meta_ready[port_index]),
                .decision_valid(fdb_decision_valid),
                .decision_ingress_port(fdb_decision_ingress_port),
                .decision_dest_mask(fdb_dest_mask),
                .m_axis_tdata(fabric_tdata[port_index*8 +: 8]),
                .m_axis_tuser(fabric_tuser[port_index*3 +: 3]),
                .m_axis_tdest(fabric_tdest[port_index*2 +: 2]),
                .m_axis_tvalid(fabric_tvalid[port_index]),
                .m_axis_tready(fabric_tready[port_index]),
                .m_axis_tlast(fabric_tlast[port_index]),
                .frame_too_long(ingress_frame_too_long[port_index])
            );
        end
    endgenerate

    // Four ingress descriptors share one table, so this round-robin arbiter
    // guarantees only one table request is in flight at a time.
    fdb_request_arbiter_4 fdb_request_arbiter (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_valid(meta_valid),
        .s_ready(meta_ready),
        .s_src_mac(meta_src_mac),
        .s_dst_mac(meta_dst_mac),
        .s_ingress_port(meta_ingress_port),
        .m_valid(fdb_request_valid),
        .m_ready(fdb_request_ready),
        .m_src_mac(fdb_request_src_mac),
        .m_dst_mac(fdb_request_dst_mac),
        .m_ingress_port(fdb_request_ingress_port)
    );

    // The FDB sees descriptors only; it has no frame-data interface.
    fdb_4port #(
        .TABLE_ENTRIES(TABLE_ENTRIES)
    ) fdb (
        .aclk(aclk),
        .aresetn(aresetn),
        .request_src_mac(fdb_request_src_mac),
        .request_dst_mac(fdb_request_dst_mac),
        .request_ingress_port(fdb_request_ingress_port),
        .request_valid(fdb_request_valid),
        .request_ready(fdb_request_ready),
        .response_valid(fdb_decision_valid),
        .response_ingress_port(fdb_decision_ingress_port),
        .response_hit(fdb_lookup_hit),
        .response_same_port(fdb_same_port),
        .response_dest_port(fdb_dest_port),
        .response_dest_mask(fdb_dest_mask)
    );

    // Each physical egress owns an independent transmission-selection block.
    // Only the selector matching a fabric's current tdest asserts its ready;
    // OR-ing those four ready vectors is safe because every fabric emits only
    // one destination at a time.
    transmission_selection_4 #(.EGRESS_PORT(0)) transmission_selection_port_0 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(fabric_tdata),
        .s_axis_tuser(fabric_tuser),
        .s_axis_tdest(fabric_tdest),
        .s_axis_tvalid(fabric_tvalid),
        .s_axis_tready(selector_0_ready),
        .s_axis_tlast(fabric_tlast),
        .m_axis_tdata(m_axis_tdata[7:0]),
        .m_axis_tuser(m_axis_tuser[2:0]),
        .m_axis_tvalid(m_axis_tvalid[0]),
        .m_axis_tready(m_axis_tready[0]),
        .m_axis_tlast(m_axis_tlast[0])
    );

    transmission_selection_4 #(.EGRESS_PORT(1)) transmission_selection_port_1 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(fabric_tdata),
        .s_axis_tuser(fabric_tuser),
        .s_axis_tdest(fabric_tdest),
        .s_axis_tvalid(fabric_tvalid),
        .s_axis_tready(selector_1_ready),
        .s_axis_tlast(fabric_tlast),
        .m_axis_tdata(m_axis_tdata[15:8]),
        .m_axis_tuser(m_axis_tuser[5:3]),
        .m_axis_tvalid(m_axis_tvalid[1]),
        .m_axis_tready(m_axis_tready[1]),
        .m_axis_tlast(m_axis_tlast[1])
    );

    transmission_selection_4 #(.EGRESS_PORT(2)) transmission_selection_port_2 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(fabric_tdata),
        .s_axis_tuser(fabric_tuser),
        .s_axis_tdest(fabric_tdest),
        .s_axis_tvalid(fabric_tvalid),
        .s_axis_tready(selector_2_ready),
        .s_axis_tlast(fabric_tlast),
        .m_axis_tdata(m_axis_tdata[23:16]),
        .m_axis_tuser(m_axis_tuser[8:6]),
        .m_axis_tvalid(m_axis_tvalid[2]),
        .m_axis_tready(m_axis_tready[2]),
        .m_axis_tlast(m_axis_tlast[2])
    );

    transmission_selection_4 #(.EGRESS_PORT(3)) transmission_selection_port_3 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(fabric_tdata),
        .s_axis_tuser(fabric_tuser),
        .s_axis_tdest(fabric_tdest),
        .s_axis_tvalid(fabric_tvalid),
        .s_axis_tready(selector_3_ready),
        .s_axis_tlast(fabric_tlast),
        .m_axis_tdata(m_axis_tdata[31:24]),
        .m_axis_tuser(m_axis_tuser[11:9]),
        .m_axis_tvalid(m_axis_tvalid[3]),
        .m_axis_tready(m_axis_tready[3]),
        .m_axis_tlast(m_axis_tlast[3])
    );

    assign fabric_tready = selector_0_ready |
                           selector_1_ready |
                           selector_2_ready |
                           selector_3_ready;

endmodule
