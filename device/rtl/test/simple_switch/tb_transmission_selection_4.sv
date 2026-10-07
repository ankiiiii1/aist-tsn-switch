`timescale 1ns/1ps

// Verifies strict priority at a frame boundary and round-robin tie breaking.
module tb_transmission_selection_4;

    logic aclk;
    logic aresetn;
    logic [31:0] s_axis_tdata;
    logic [11:0] s_axis_tuser;
    logic [7:0]  s_axis_tdest;
    logic [3:0]  s_axis_tvalid;
    wire [3:0]   s_axis_tready;
    logic [3:0]  s_axis_tlast;
    wire [7:0]   m_axis_tdata;
    wire [2:0]   m_axis_tuser;
    wire         m_axis_tvalid;
    logic        m_axis_tready;
    wire         m_axis_tlast;

    transmission_selection_4 #(
        .EGRESS_PORT(2'd0)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tuser(s_axis_tuser),
        .s_axis_tdest(s_axis_tdest),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tuser(m_axis_tuser),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    always #5 aclk = ~aclk;

    task automatic expect_one_byte(
        input logic [7:0] expected_data,
        input logic [2:0] expected_priority
    );
        begin
            // Sample in the active region at the transfer edge, before the
            // arbiter advances to the following one-byte frame.
            @(posedge aclk);
            if ((s_axis_tready == 4'b0000) ||
                !m_axis_tvalid || !m_axis_tlast ||
                (m_axis_tdata !== expected_data) ||
                (m_axis_tuser !== expected_priority)) begin
                $fatal(1, "Unexpected arbitration result: valid=%0b data=%h prio=%0d last=%0b",
                       m_axis_tvalid, m_axis_tdata, m_axis_tuser, m_axis_tlast);
            end
        end
    endtask

    initial begin
        aclk = 1'b0;
        aresetn = 1'b0;
        s_axis_tdata = 32'd0;
        s_axis_tuser = 12'd0;
        s_axis_tdest = 8'd0;
        s_axis_tvalid = 4'd0;
        s_axis_tlast = 4'd0;
        m_axis_tready = 1'b1;

        repeat (3) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        // Ports 0 and 2 have equal priority 5.  Port 1 has priority 7, so it
        // must win first.  All are addressed to egress 0 and are one-byte
        // frames for a concise arbitration test.
        @(negedge aclk);
        s_axis_tdata = {8'h00, 8'hC2, 8'hB1, 8'hA0};
        s_axis_tuser = {3'd0, 3'd5, 3'd7, 3'd5};
        s_axis_tdest = {2'd3, 2'd0, 2'd0, 2'd0};
        s_axis_tlast = 4'b0111;
        s_axis_tvalid = 4'b0111;

        expect_one_byte(8'hB1, 3'd7);
        @(negedge aclk);
        s_axis_tvalid[1] = 1'b0;

        // The high-priority frame advanced the tie-breaker to port 2, so port
        // 2 wins the equal-priority tie over port 0.
        expect_one_byte(8'hC2, 3'd5);
        @(negedge aclk);
        s_axis_tvalid[2] = 1'b0;

        expect_one_byte(8'hA0, 3'd5);
        @(negedge aclk);
        s_axis_tvalid = 4'b0000;
        s_axis_tlast = 4'b0000;

        $display("PASS: tb_transmission_selection_4");
        $finish;
    end

endmodule
