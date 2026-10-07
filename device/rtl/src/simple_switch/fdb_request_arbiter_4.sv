`timescale 1ns / 1ps

// SPDX-License-Identifier: MIT
// Round-robin arbiter for the four ingress FDB descriptor producers.
//
// It is intentionally separate from fdb_4port: the FDB owns the learning
// table, while this block only serializes four independent descriptor requests.

module fdb_request_arbiter_4 (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [3:0]  s_valid,
    output logic [3:0] s_ready,
    input  wire [4*48-1:0] s_src_mac,
    input  wire [4*48-1:0] s_dst_mac,
    input  wire [4*2-1:0]  s_ingress_port,

    output logic        m_valid,
    input  wire         m_ready,
    output logic [47:0] m_src_mac,
    output logic [47:0] m_dst_mac,
    output logic [1:0]  m_ingress_port
);

    logic [1:0] round_robin_start;
    logic [1:0] selected_port;
    logic       selected_valid;
    integer offset;
    logic [1:0] candidate;

    always_comb begin
        selected_port = round_robin_start;
        selected_valid = 1'b0;

        // Search in round-robin order.  The first valid requester is granted.
        for (offset = 0; offset < 4; offset = offset + 1) begin
            candidate = round_robin_start + offset[1:0];
            if (!selected_valid && s_valid[candidate]) begin
                selected_port = candidate[1:0];
                selected_valid = 1'b1;
            end
        end

        s_ready = 4'b0000;
        m_valid = selected_valid;
        m_src_mac = 48'd0;
        m_dst_mac = 48'd0;
        m_ingress_port = 2'd0;

        if (selected_valid) begin
            s_ready[selected_port] = m_ready;
            case (selected_port)
                2'd0: begin
                    m_src_mac = s_src_mac[47:0];
                    m_dst_mac = s_dst_mac[47:0];
                    m_ingress_port = s_ingress_port[1:0];
                end
                2'd1: begin
                    m_src_mac = s_src_mac[95:48];
                    m_dst_mac = s_dst_mac[95:48];
                    m_ingress_port = s_ingress_port[3:2];
                end
                2'd2: begin
                    m_src_mac = s_src_mac[143:96];
                    m_dst_mac = s_dst_mac[143:96];
                    m_ingress_port = s_ingress_port[5:4];
                end
                default: begin
                    m_src_mac = s_src_mac[191:144];
                    m_dst_mac = s_dst_mac[191:144];
                    m_ingress_port = s_ingress_port[7:6];
                end
            endcase
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            round_robin_start <= 2'd0;
        end else if (m_valid && m_ready) begin
            if (selected_port == 2'd3) begin
                round_robin_start <= 2'd0;
            end else begin
                round_robin_start <= selected_port + 1'b1;
            end
        end
    end

endmodule
