`timescale 1ns / 1ps

// SPDX-License-Identifier: MIT
//
// Simplified per-egress Transmission Selection block.
//
// Four candidate 1x3-switch streams are examined.  Only streams whose tdest
// matches EGRESS_PORT are eligible.  At a frame boundary the block chooses the
// highest tuser priority (7 is highest); equal-priority contenders use a
// round-robin starting point.  The selected input remains locked until its
// tlast transfer, so Ethernet frames are never interleaved.
//
// This is intentionally a small first-draft substitute for the paper's deeper
// ATS/CBS queues.  It has no shaping, eligibility-time calculation, or
// per-traffic-class FIFO.  Backpressure holds unselected frames at the 1x3
// store-and-forward fabrics.

module transmission_selection_4 #(
    parameter [1:0] EGRESS_PORT = 2'd0
) (
    input  wire         aclk,
    input  wire         aresetn,

    // Four packed input streams.  Port 0 occupies the least-significant slice.
    input  wire [4*8-1:0] s_axis_tdata,
    input  wire [4*3-1:0] s_axis_tuser,
    input  wire [4*2-1:0] s_axis_tdest,
    input  wire [3:0]     s_axis_tvalid,
    output logic [3:0]    s_axis_tready,
    input  wire [3:0]     s_axis_tlast,

    // Physical egress stream.
    output logic [7:0]    m_axis_tdata,
    output logic [2:0]    m_axis_tuser,
    output logic          m_axis_tvalid,
    input  wire           m_axis_tready,
    output logic          m_axis_tlast
);

    localparam [1:0] EGRESS_PORT_ID = EGRESS_PORT;

    logic       active;
    logic [1:0] active_port;
    logic [1:0] round_robin_start;

    logic [3:0] eligible;
    logic [1:0] selected_port;
    logic       selected_valid;
    logic [2:0] best_priority;

    wire [7:0] traffic_class_0;
    wire [7:0] traffic_class_1;
    wire [7:0] traffic_class_2;
    wire [7:0] traffic_class_3;

    integer offset;
    logic [1:0] candidate;

    priority_selector_8 priority_selector_0 (
        .priority_code(s_axis_tuser[2:0]),
        .traffic_class_onehot(traffic_class_0)
    );

    priority_selector_8 priority_selector_1 (
        .priority_code(s_axis_tuser[5:3]),
        .traffic_class_onehot(traffic_class_1)
    );

    priority_selector_8 priority_selector_2 (
        .priority_code(s_axis_tuser[8:6]),
        .traffic_class_onehot(traffic_class_2)
    );

    priority_selector_8 priority_selector_3 (
        .priority_code(s_axis_tuser[11:9]),
        .traffic_class_onehot(traffic_class_3)
    );

    function automatic [2:0] onehot_to_priority(input [7:0] onehot);
        begin
            case (onehot)
                8'b00000001: onehot_to_priority = 3'd0;
                8'b00000010: onehot_to_priority = 3'd1;
                8'b00000100: onehot_to_priority = 3'd2;
                8'b00001000: onehot_to_priority = 3'd3;
                8'b00010000: onehot_to_priority = 3'd4;
                8'b00100000: onehot_to_priority = 3'd5;
                8'b01000000: onehot_to_priority = 3'd6;
                default:      onehot_to_priority = 3'd7;
            endcase
        end
    endfunction

    function automatic [2:0] priority_for_port(input [1:0] port_number);
        begin
            case (port_number)
                2'd0:   priority_for_port = onehot_to_priority(traffic_class_0);
                2'd1:   priority_for_port = onehot_to_priority(traffic_class_1);
                2'd2:   priority_for_port = onehot_to_priority(traffic_class_2);
                default:priority_for_port = onehot_to_priority(traffic_class_3);
            endcase
        end
    endfunction

    always_comb begin
        eligible = 4'b0000;
        eligible[0] = s_axis_tvalid[0] &&
                      (s_axis_tdest[1:0] == EGRESS_PORT_ID);
        eligible[1] = s_axis_tvalid[1] &&
                      (s_axis_tdest[3:2] == EGRESS_PORT_ID);
        eligible[2] = s_axis_tvalid[2] &&
                      (s_axis_tdest[5:4] == EGRESS_PORT_ID);
        eligible[3] = s_axis_tvalid[3] &&
                      (s_axis_tdest[7:6] == EGRESS_PORT_ID);

        selected_port = round_robin_start;
        selected_valid = 1'b0;
        best_priority = 3'd0;

        if (active) begin
            selected_port = active_port;
            selected_valid = eligible[active_port];
            best_priority = priority_for_port(active_port);
        end else begin
            // Highest priority wins.  Since the scan starts at the rolling
            // pointer and equal priorities do not replace an earlier winner,
            // it is also a round-robin tie breaker.
            for (offset = 0; offset < 4; offset = offset + 1) begin
                candidate = round_robin_start + offset[1:0];
                if (eligible[candidate] &&
                    (!selected_valid ||
                     (priority_for_port(candidate[1:0]) > best_priority))) begin
                    selected_port = candidate[1:0];
                    selected_valid = 1'b1;
                    best_priority = priority_for_port(candidate[1:0]);
                end
            end
        end

        s_axis_tready = 4'b0000;
        m_axis_tdata = 8'd0;
        m_axis_tuser = 3'd0;
        m_axis_tvalid = 1'b0;
        m_axis_tlast = 1'b0;

        if (selected_valid) begin
            s_axis_tready[selected_port] = m_axis_tready;
            m_axis_tvalid = 1'b1;

            case (selected_port)
                2'd0: begin
                    m_axis_tdata = s_axis_tdata[7:0];
                    m_axis_tuser = s_axis_tuser[2:0];
                    m_axis_tlast = s_axis_tlast[0];
                end
                2'd1: begin
                    m_axis_tdata = s_axis_tdata[15:8];
                    m_axis_tuser = s_axis_tuser[5:3];
                    m_axis_tlast = s_axis_tlast[1];
                end
                2'd2: begin
                    m_axis_tdata = s_axis_tdata[23:16];
                    m_axis_tuser = s_axis_tuser[8:6];
                    m_axis_tlast = s_axis_tlast[2];
                end
                default: begin
                    m_axis_tdata = s_axis_tdata[31:24];
                    m_axis_tuser = s_axis_tuser[11:9];
                    m_axis_tlast = s_axis_tlast[3];
                end
            endcase
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            active <= 1'b0;
            active_port <= 2'd0;
            round_robin_start <= 2'd0;
        end else if (active) begin
            if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                active <= 1'b0;
                if (active_port == 2'd3) begin
                    round_robin_start <= 2'd0;
                end else begin
                    round_robin_start <= active_port + 1'b1;
                end
            end
        end else if (selected_valid) begin
            // Claim the selected stream even when the egress is stalled.  This
            // preserves AXI stream stability and prevents mid-frame changes.
            active_port <= selected_port;
            if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                active <= 1'b0;
                if (selected_port == 2'd3) begin
                    round_robin_start <= 2'd0;
                end else begin
                    round_robin_start <= selected_port + 1'b1;
                end
            end else begin
                active <= 1'b1;
            end
        end
    end

endmodule
