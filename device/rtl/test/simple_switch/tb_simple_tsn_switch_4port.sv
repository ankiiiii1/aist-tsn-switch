`timescale 1ns/1ps

// End-to-end verification of the simple four-port paper-style pipeline.
// It checks frame preservation, unknown/broadcast flooding, learned unicast,
// same-port filtering, MAC movement, and priority metadata preservation.
module tb_simple_tsn_switch_4port;

    logic        aclk;
    logic        aresetn;
    logic [31:0] s_axis_tdata;
    logic [11:0] s_axis_tuser;
    logic [3:0]  s_axis_tvalid;
    wire [3:0]   s_axis_tready;
    logic [3:0]  s_axis_tlast;

    wire [31:0] m_axis_tdata;
    wire [11:0] m_axis_tuser;
    wire [3:0]  m_axis_tvalid;
    logic [3:0] m_axis_tready;
    wire [3:0]  m_axis_tlast;

    wire        fdb_decision_valid;
    wire [1:0]  fdb_decision_ingress_port;
    wire        fdb_lookup_hit;
    wire        fdb_same_port;
    wire [1:0]  fdb_dest_port;
    wire [3:0]  fdb_dest_mask;
    wire [3:0]  ingress_frame_too_long;

    localparam [47:0] MAC_A = 48'h02_00_00_00_00_0A;
    localparam [47:0] MAC_B = 48'h02_00_00_00_00_0B;
    localparam [47:0] MAC_C = 48'h02_00_00_00_00_0C;
    localparam [47:0] MAC_D = 48'h02_00_00_00_00_0D;
    localparam [47:0] MAC_E = 48'h02_00_00_00_00_0E;
    localparam [47:0] MAC_F = 48'h02_00_00_00_00_10;
    localparam [47:0] MAC_BROADCAST = 48'hFF_FF_FF_FF_FF_FF;

    integer output_frame_count [0:3];
    integer output_byte_index [0:3];
    logic [47:0] last_dst_mac [0:3];
    logic [47:0] last_src_mac [0:3];
    logic [7:0]  last_marker [0:3];
    logic [2:0]  last_priority [0:3];
    integer monitor_port;

    integer fdb_decision_count;
    logic [1:0] last_fdb_ingress_port;
    logic       last_fdb_lookup_hit;
    logic       last_fdb_same_port;
    logic [1:0] last_fdb_dest_port;
    logic [3:0] last_fdb_dest_mask;

    simple_tsn_switch_4port #(
        .TABLE_ENTRIES(16),
        .MAX_FRAME_BYTES(64)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tuser(s_axis_tuser),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tuser(m_axis_tuser),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .fdb_decision_valid(fdb_decision_valid),
        .fdb_decision_ingress_port(fdb_decision_ingress_port),
        .fdb_lookup_hit(fdb_lookup_hit),
        .fdb_same_port(fdb_same_port),
        .fdb_dest_port(fdb_dest_port),
        .fdb_dest_mask(fdb_dest_mask),
        .ingress_frame_too_long(ingress_frame_too_long)
    );

    always #5 aclk = ~aclk;

    // Every output is permanently able to accept a byte in this test.  The
    // switch itself still holds an arbitration grant through tlast.
    always_comb begin
        m_axis_tready = 4'b1111;
    end

    // Capture enough of every egress frame to prove it is an unmodified copy
    // of the supplied Ethernet header and to identify it by its final marker.
    always @(posedge aclk) begin
        if (!aresetn) begin
            for (monitor_port = 0; monitor_port < 4;
                 monitor_port = monitor_port + 1) begin
                output_frame_count[monitor_port] <= 0;
                output_byte_index[monitor_port] <= 0;
                last_dst_mac[monitor_port] <= 48'd0;
                last_src_mac[monitor_port] <= 48'd0;
                last_marker[monitor_port] <= 8'd0;
                last_priority[monitor_port] <= 3'd0;
            end
        end else begin
            for (monitor_port = 0; monitor_port < 4;
                 monitor_port = monitor_port + 1) begin
                if (m_axis_tvalid[monitor_port] &&
                    m_axis_tready[monitor_port]) begin
                    case (output_byte_index[monitor_port])
                        0:  last_dst_mac[monitor_port][47:40] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        1:  last_dst_mac[monitor_port][39:32] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        2:  last_dst_mac[monitor_port][31:24] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        3:  last_dst_mac[monitor_port][23:16] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        4:  last_dst_mac[monitor_port][15:8] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        5:  last_dst_mac[monitor_port][7:0] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        6:  last_src_mac[monitor_port][47:40] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        7:  last_src_mac[monitor_port][39:32] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        8:  last_src_mac[monitor_port][31:24] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        9:  last_src_mac[monitor_port][23:16] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        10: last_src_mac[monitor_port][15:8] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        11: last_src_mac[monitor_port][7:0] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        14: last_marker[monitor_port] <=
                                m_axis_tdata[monitor_port*8 +: 8];
                        default: ;
                    endcase
                    last_priority[monitor_port] <=
                        m_axis_tuser[monitor_port*3 +: 3];

                    if (m_axis_tlast[monitor_port]) begin
                        if (output_byte_index[monitor_port] != 14) begin
                            $fatal(1, "Port %0d: unexpected output length %0d",
                                   monitor_port,
                                   output_byte_index[monitor_port] + 1);
                        end
                        output_frame_count[monitor_port] <=
                            output_frame_count[monitor_port] + 1;
                        output_byte_index[monitor_port] <= 0;
                    end else begin
                        output_byte_index[monitor_port] <=
                            output_byte_index[monitor_port] + 1;
                    end
                end
            end
        end
    end

    // The top-level debug signals make the FDB decision observable without
    // peeking into RTL hierarchy.  Seven valid test frames should produce
    // seven responses; the same-port case still gets a decision.
    always @(posedge aclk) begin
        if (!aresetn) begin
            fdb_decision_count <= 0;
            last_fdb_ingress_port <= 2'd0;
            last_fdb_lookup_hit <= 1'b0;
            last_fdb_same_port <= 1'b0;
            last_fdb_dest_port <= 2'd0;
            last_fdb_dest_mask <= 4'd0;
        end else if (fdb_decision_valid) begin
            fdb_decision_count <= fdb_decision_count + 1;
            last_fdb_ingress_port <= fdb_decision_ingress_port;
            last_fdb_lookup_hit <= fdb_lookup_hit;
            last_fdb_same_port <= fdb_same_port;
            last_fdb_dest_port <= fdb_dest_port;
            last_fdb_dest_mask <= fdb_dest_mask;
        end
    end

    task automatic send_byte(
        input integer port_number,
        input logic [7:0] byte_value,
        input logic       last_byte,
        input logic [2:0] priority_code
    );
        begin
            @(negedge aclk);
            s_axis_tdata[port_number*8 +: 8] = byte_value;
            s_axis_tuser[port_number*3 +: 3] = priority_code;
            s_axis_tlast[port_number] = last_byte;
            s_axis_tvalid[port_number] = 1'b1;

            // AXI-stream source rule: retain the beat until ready.
            do begin
                @(posedge aclk);
            end while (!s_axis_tready[port_number]);

            @(negedge aclk);
            s_axis_tvalid[port_number] = 1'b0;
            s_axis_tlast[port_number] = 1'b0;
        end
    endtask

    task automatic send_frame(
        input integer port_number,
        input logic [47:0] dst_mac,
        input logic [47:0] src_mac,
        input logic [2:0]  priority_code,
        input logic [7:0]  marker
    );
        begin
            // 6-byte destination + 6-byte source + EtherType + marker = 15 B.
            send_byte(port_number, dst_mac[47:40], 1'b0, priority_code);
            send_byte(port_number, dst_mac[39:32], 1'b0, priority_code);
            send_byte(port_number, dst_mac[31:24], 1'b0, priority_code);
            send_byte(port_number, dst_mac[23:16], 1'b0, priority_code);
            send_byte(port_number, dst_mac[15:8],  1'b0, priority_code);
            send_byte(port_number, dst_mac[7:0],   1'b0, priority_code);
            send_byte(port_number, src_mac[47:40], 1'b0, priority_code);
            send_byte(port_number, src_mac[39:32], 1'b0, priority_code);
            send_byte(port_number, src_mac[31:24], 1'b0, priority_code);
            send_byte(port_number, src_mac[23:16], 1'b0, priority_code);
            send_byte(port_number, src_mac[15:8],  1'b0, priority_code);
            send_byte(port_number, src_mac[7:0],   1'b0, priority_code);
            send_byte(port_number, 8'h08,          1'b0, priority_code);
            send_byte(port_number, 8'h00,          1'b0, priority_code);
            send_byte(port_number, marker,         1'b1, priority_code);
        end
    endtask

    task automatic wait_for_frame_counts(
        input integer expected_0,
        input integer expected_1,
        input integer expected_2,
        input integer expected_3
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (((output_frame_count[0] < expected_0) ||
                    (output_frame_count[1] < expected_1) ||
                    (output_frame_count[2] < expected_2) ||
                    (output_frame_count[3] < expected_3)) &&
                   (wait_cycles < 2000)) begin
                @(posedge aclk);
                wait_cycles = wait_cycles + 1;
            end
            @(negedge aclk);
            if ((output_frame_count[0] != expected_0) ||
                (output_frame_count[1] != expected_1) ||
                (output_frame_count[2] != expected_2) ||
                (output_frame_count[3] != expected_3)) begin
                $fatal(1, "Unexpected output counts: got [%0d %0d %0d %0d], expected [%0d %0d %0d %0d]",
                       output_frame_count[0], output_frame_count[1],
                       output_frame_count[2], output_frame_count[3],
                       expected_0, expected_1, expected_2, expected_3);
            end
        end
    endtask

    task automatic check_last_frame(
        input integer port_number,
        input logic [47:0] expected_dst,
        input logic [47:0] expected_src,
        input logic [7:0] expected_marker,
        input logic [2:0] expected_priority
    );
        begin
            if (last_dst_mac[port_number] !== expected_dst ||
                last_src_mac[port_number] !== expected_src ||
                last_marker[port_number] !== expected_marker ||
                last_priority[port_number] !== expected_priority) begin
                $fatal(1, "Port %0d: unexpected last frame (dst=%h src=%h marker=%h prio=%0d)",
                       port_number, last_dst_mac[port_number],
                       last_src_mac[port_number], last_marker[port_number],
                       last_priority[port_number]);
            end
        end
    endtask

    initial begin
        aclk = 1'b0;
        aresetn = 1'b0;
        s_axis_tdata = 32'd0;
        s_axis_tuser = 12'd0;
        s_axis_tvalid = 4'b0000;
        s_axis_tlast = 4'b0000;

        repeat (3) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        // A enters port 0 and B is unknown: flood to ports 1, 2, and 3.
        send_frame(0, MAC_B, MAC_A, 3'd1, 8'hA0);
        wait_for_frame_counts(0, 1, 1, 1);
        check_last_frame(1, MAC_B, MAC_A, 8'hA0, 3'd1);
        check_last_frame(2, MAC_B, MAC_A, 8'hA0, 3'd1);
        check_last_frame(3, MAC_B, MAC_A, 8'hA0, 3'd1);

        // B enters port 1; destination A has been learned on port 0.
        send_frame(1, MAC_A, MAC_B, 3'd4, 8'hB1);
        wait_for_frame_counts(1, 1, 1, 1);
        check_last_frame(0, MAC_A, MAC_B, 8'hB1, 3'd4);

        // A remains known on port 0, so C's frame is a known unicast.
        send_frame(2, MAC_A, MAC_C, 3'd2, 8'hC2);
        wait_for_frame_counts(2, 1, 1, 1);
        check_last_frame(0, MAC_A, MAC_C, 8'hC2, 3'd2);

        // Broadcast is copied to all non-ingress ports and retains its priority.
        send_frame(3, MAC_BROADCAST, MAC_D, 3'd7, 8'hD3);
        wait_for_frame_counts(3, 2, 2, 1);
        check_last_frame(0, MAC_BROADCAST, MAC_D, 8'hD3, 3'd7);
        check_last_frame(1, MAC_BROADCAST, MAC_D, 8'hD3, 3'd7);
        check_last_frame(2, MAC_BROADCAST, MAC_D, 8'hD3, 3'd7);

        // A is known on ingress port 0, so this frame must be filtered.
        send_frame(0, MAC_A, MAC_E, 3'd3, 8'hE0);
        wait_for_frame_counts(3, 2, 2, 1);

        // A moves to port 3 while forwarding a known unicast to B on port 1.
        send_frame(3, MAC_B, MAC_A, 3'd6, 8'hA4);
        wait_for_frame_counts(3, 3, 2, 1);
        check_last_frame(1, MAC_B, MAC_A, 8'hA4, 3'd6);

        // The subsequent lookup of A must use its new port-3 location.
        send_frame(2, MAC_A, MAC_F, 3'd5, 8'hF5);
        wait_for_frame_counts(3, 3, 2, 2);
        check_last_frame(3, MAC_A, MAC_F, 8'hF5, 3'd5);

        if (ingress_frame_too_long != 4'b0000) begin
            $fatal(1, "A short test frame was incorrectly marked too long");
        end
        if (fdb_decision_count != 7 ||
            last_fdb_ingress_port != 2'd2 ||
            !last_fdb_lookup_hit || last_fdb_same_port ||
            last_fdb_dest_port != 2'd3 ||
            last_fdb_dest_mask != 4'b1000) begin
            $fatal(1, "Unexpected final FDB debug decision");
        end

        $display("PASS: tb_simple_tsn_switch_4port");
        $finish;
    end

endmodule
