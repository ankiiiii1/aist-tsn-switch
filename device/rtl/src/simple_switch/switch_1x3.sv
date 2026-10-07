`timescale 1ns / 1ps

// SPDX-License-Identifier: MIT
//
// Store-and-forward 1x3 switching fabric for one ingress port.
//
// The block has three distinct jobs:
//   1. store one complete ingress Ethernet frame and extract its two MACs;
//   2. present the extracted descriptor to the shared FDB; and
//   3. after the FDB returns a destination mask, replay the frame once for
//      every selected egress port.
//
// It never contains an FDB table or makes a MAC-learning/lookup decision.
// Unknown-destination flooding is realized solely by replaying the FDB-provided
// mask one port at a time.  Sequential replication is intentional here: it is
// simple, synthesizable, and easy to debug for a first draft.  It can later be
// replaced by a multi-read-port/queued fabric without changing fdb_4port.

module switch_1x3 #(
    parameter [1:0] INGRESS_PORT     = 2'd0,
    parameter integer MAX_FRAME_BYTES = 1536,
    parameter integer MIN_HEADER_BYTES = 12
) (
    input  wire        aclk,
    input  wire        aresetn,

    // 8-bit AXI4-Stream-like ingress.  tuser is a frame priority (0..7) and
    // must be stable for a frame; it is sampled on the first accepted beat.
    input  wire [7:0]  s_axis_tdata,
    input  wire [2:0]  s_axis_tuser,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // Descriptor request to the common FDB.
    output wire [47:0] meta_src_mac,
    output wire [47:0] meta_dst_mac,
    output wire [1:0]  meta_ingress_port,
    output wire        meta_valid,
    input  wire        meta_ready,

    // Broadcast response bus from the shared FDB.  Only the instance whose
    // INGRESS_PORT equals decision_ingress_port consumes the response.
    input  wire        decision_valid,
    input  wire [1:0]  decision_ingress_port,
    input  wire [3:0]  decision_dest_mask,

    // One logical output stream.  tdest selects one physical egress; an
    // external 4x4/transmission-selection stage arbitrates it with peers.
    output wire [7:0]  m_axis_tdata,
    output wire [2:0]  m_axis_tuser,
    output wire [1:0]  m_axis_tdest,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,

    // Helpful synthesis/simulation status for an over-sized stored frame.
    output logic       frame_too_long
);

    localparam integer COUNTER_WIDTH =
        (MAX_FRAME_BYTES <= 1) ? 1 : $clog2(MAX_FRAME_BYTES + 1);
    localparam integer MEM_ADDR_WIDTH =
        (MAX_FRAME_BYTES <= 1) ? 1 : $clog2(MAX_FRAME_BYTES);
    localparam [COUNTER_WIDTH-1:0] MAX_FRAME_COUNT =
        COUNTER_WIDTH'(MAX_FRAME_BYTES);
    localparam [COUNTER_WIDTH-1:0] MIN_HEADER_LAST_INDEX =
        COUNTER_WIDTH'(MIN_HEADER_BYTES - 1);

    localparam [1:0]
        ST_CAPTURE       = 2'd0,
        ST_REQUEST       = 2'd1,
        ST_WAIT_DECISION = 2'd2,
        ST_SEND          = 2'd3;

    logic [1:0] state;

    // A one-frame store.  Most FPGA tools infer LUTRAM or BRAM according to
    // the target and the MAX_FRAME_BYTES setting.
    logic [7:0] frame_mem [0:MAX_FRAME_BYTES-1];
    logic [COUNTER_WIDTH-1:0] write_count;
    logic [COUNTER_WIDTH-1:0] read_count;
    logic [COUNTER_WIDTH-1:0] frame_length;
    logic                     frame_overflow;

    logic [47:0] frame_src_mac;
    logic [47:0] frame_dst_mac;
    logic [2:0]  frame_priority;

    logic [3:0] remaining_dest_mask;
    logic [1:0] selected_dest_port;
    wire [3:0]  remaining_after_current;

    wire ingress_fire;
    wire egress_fire;

    function automatic [3:0] port_mask(input [1:0] port_number);
        begin
            case (port_number)
                2'd0:   port_mask = 4'b0001;
                2'd1:   port_mask = 4'b0010;
                2'd2:   port_mask = 4'b0100;
                default:port_mask = 4'b1000;
            endcase
        end
    endfunction

    function automatic [1:0] first_set_port(input [3:0] mask);
        begin
            // Lowest-numbered requested egress is emitted first.
            casez (mask)
                4'b???1: first_set_port = 2'd0;
                4'b??10: first_set_port = 2'd1;
                4'b?100: first_set_port = 2'd2;
                default:  first_set_port = 2'd3;
            endcase
        end
    endfunction

    assign s_axis_tready = aresetn && (state == ST_CAPTURE);
    assign ingress_fire = s_axis_tvalid && s_axis_tready;

    assign meta_src_mac = frame_src_mac;
    assign meta_dst_mac = frame_dst_mac;
    assign meta_ingress_port = INGRESS_PORT;
    assign meta_valid = (state == ST_REQUEST);

    assign m_axis_tvalid = aresetn && (state == ST_SEND);
    assign m_axis_tdata = (state == ST_SEND) ?
                          frame_mem[read_count[MEM_ADDR_WIDTH-1:0]] : 8'd0;
    assign m_axis_tuser = (state == ST_SEND) ? frame_priority : 3'd0;
    assign m_axis_tdest = selected_dest_port;
    assign m_axis_tlast = (state == ST_SEND) &&
                          (read_count == (frame_length - 1'b1));
    assign egress_fire = m_axis_tvalid && m_axis_tready;

    assign remaining_after_current =
        remaining_dest_mask & ~port_mask(selected_dest_port);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state <= ST_CAPTURE;
            write_count <= '0;
            read_count <= '0;
            frame_length <= '0;
            frame_overflow <= 1'b0;
            frame_too_long <= 1'b0;
            frame_src_mac <= 48'd0;
            frame_dst_mac <= 48'd0;
            frame_priority <= 3'd0;
            remaining_dest_mask <= 4'd0;
            selected_dest_port <= 2'd0;
        end else begin
            case (state)
                ST_CAPTURE: begin
                    if (ingress_fire) begin
                        if (write_count < MAX_FRAME_COUNT) begin
                            frame_mem[write_count[MEM_ADDR_WIDTH-1:0]] <= s_axis_tdata;
                            write_count <= write_count + 1'b1;
                        end else begin
                            // Continue accepting through tlast so the source is
                            // not left mid-frame, but discard this frame.
                            frame_overflow <= 1'b1;
                            frame_too_long <= 1'b1;
                        end

                        if (write_count == 0) begin
                            frame_priority <= s_axis_tuser;
                        end

                        // Ethernet destination MAC: bytes 0 through 5.
                        // Ethernet source MAC:      bytes 6 through 11.
                        case (write_count)
                            0:  frame_dst_mac[47:40] <= s_axis_tdata;
                            1:  frame_dst_mac[39:32] <= s_axis_tdata;
                            2:  frame_dst_mac[31:24] <= s_axis_tdata;
                            3:  frame_dst_mac[23:16] <= s_axis_tdata;
                            4:  frame_dst_mac[15:8]  <= s_axis_tdata;
                            5:  frame_dst_mac[7:0]   <= s_axis_tdata;
                            6:  frame_src_mac[47:40] <= s_axis_tdata;
                            7:  frame_src_mac[39:32] <= s_axis_tdata;
                            8:  frame_src_mac[31:24] <= s_axis_tdata;
                            9:  frame_src_mac[23:16] <= s_axis_tdata;
                            10: frame_src_mac[15:8]  <= s_axis_tdata;
                            11: frame_src_mac[7:0]   <= s_axis_tdata;
                            default: ;
                        endcase

                        if (s_axis_tlast) begin
                            // We need at least the complete destination and
                            // source MAC fields.  Longer Ethernet validity
                            // checks (CRC, MTU policy, etc.) stay outside this
                            // intentionally simple core.
                            if (frame_overflow ||
                                (write_count >= MAX_FRAME_COUNT) ||
                                (write_count < MIN_HEADER_LAST_INDEX)) begin
                                state <= ST_CAPTURE;
                                write_count <= '0;
                                frame_overflow <= 1'b0;
                            end else begin
                                frame_length <= write_count + 1'b1;
                                state <= ST_REQUEST;
                            end
                        end
                    end
                end

                ST_REQUEST: begin
                    if (meta_ready) begin
                        state <= ST_WAIT_DECISION;
                    end
                end

                ST_WAIT_DECISION: begin
                    if (decision_valid &&
                        (decision_ingress_port == INGRESS_PORT)) begin
                        if (decision_dest_mask == 4'b0000) begin
                            // Known destination on the same input port: the
                            // FDB filters the frame, so there is no replay.
                            state <= ST_CAPTURE;
                            write_count <= '0;
                            frame_overflow <= 1'b0;
                        end else begin
                            remaining_dest_mask <= decision_dest_mask;
                            selected_dest_port <=
                                first_set_port(decision_dest_mask);
                            read_count <= '0;
                            state <= ST_SEND;
                        end
                    end
                end

                ST_SEND: begin
                    if (egress_fire) begin
                        if (m_axis_tlast) begin
                            if (remaining_after_current != 4'b0000) begin
                                // Replay the same stored frame to the next
                                // requested output port.
                                remaining_dest_mask <= remaining_after_current;
                                selected_dest_port <=
                                    first_set_port(remaining_after_current);
                                read_count <= '0;
                            end else begin
                                state <= ST_CAPTURE;
                                write_count <= '0;
                                read_count <= '0;
                                frame_overflow <= 1'b0;
                            end
                        end else begin
                            read_count <= read_count + 1'b1;
                        end
                    end
                end

                default: begin
                    state <= ST_CAPTURE;
                    write_count <= '0;
                    read_count <= '0;
                end
            endcase
        end
    end

endmodule
