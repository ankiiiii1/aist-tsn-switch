`timescale 1ns/1ps

// Focused FDB verification: learning, known unicast, same-port filtering,
// unknown flooding, broadcast flooding, and a learned-MAC port move.
module tb_fdb_4port;

    logic        aclk;
    logic        aresetn;
    logic [47:0] request_src_mac;
    logic [47:0] request_dst_mac;
    logic [1:0]  request_ingress_port;
    logic        request_valid;
    wire         request_ready;
    wire         response_valid;
    wire [1:0]   response_ingress_port;
    wire         response_hit;
    wire         response_same_port;
    wire [1:0]   response_dest_port;
    wire [3:0]   response_dest_mask;

    localparam [47:0] MAC_A = 48'h02_00_00_00_00_0A;
    localparam [47:0] MAC_B = 48'h02_00_00_00_00_0B;
    localparam [47:0] MAC_C = 48'h02_00_00_00_00_0C;
    localparam [47:0] MAC_D = 48'h02_00_00_00_00_0D;
    localparam [47:0] MAC_E = 48'h02_00_00_00_00_0E;
    localparam [47:0] MAC_F = 48'h02_00_00_00_00_10;
    localparam [47:0] MAC_BROADCAST = 48'hFF_FF_FF_FF_FF_FF;

    fdb_4port #(
        .TABLE_ENTRIES(16)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .request_src_mac(request_src_mac),
        .request_dst_mac(request_dst_mac),
        .request_ingress_port(request_ingress_port),
        .request_valid(request_valid),
        .request_ready(request_ready),
        .response_valid(response_valid),
        .response_ingress_port(response_ingress_port),
        .response_hit(response_hit),
        .response_same_port(response_same_port),
        .response_dest_port(response_dest_port),
        .response_dest_mask(response_dest_mask)
    );

    always #5 aclk = ~aclk;

    task automatic submit_request(
        input logic [47:0] src_mac,
        input logic [47:0] dst_mac,
        input logic [1:0]  ingress_port,
        input logic        expected_hit,
        input logic        expected_same_port,
        input logic [1:0]  expected_dest_port,
        input logic [3:0]  expected_dest_mask
    );
        begin
            @(negedge aclk);
            request_src_mac = src_mac;
            request_dst_mac = dst_mac;
            request_ingress_port = ingress_port;
            request_valid = 1'b1;

            // Hold the descriptor until the request handshake clock edge.
            do begin
                @(posedge aclk);
            end while (!request_ready);

            // fdb_4port registers the response on this same edge.
            #1;
            if (!response_valid) begin
                $fatal(1, "FDB did not produce a response");
            end
            if (response_ingress_port !== ingress_port) begin
                $fatal(1, "Response ingress port mismatch: got %0d expected %0d",
                       response_ingress_port, ingress_port);
            end
            if (response_hit !== expected_hit) begin
                $fatal(1, "Lookup-hit mismatch: got %0b expected %0b",
                       response_hit, expected_hit);
            end
            if (response_same_port !== expected_same_port) begin
                $fatal(1, "Same-port mismatch: got %0b expected %0b",
                       response_same_port, expected_same_port);
            end
            if (response_dest_port !== expected_dest_port) begin
                $fatal(1, "Destination-port mismatch: got %0d expected %0d",
                       response_dest_port, expected_dest_port);
            end
            if (response_dest_mask !== expected_dest_mask) begin
                $fatal(1, "Destination-mask mismatch: got %b expected %b",
                       response_dest_mask, expected_dest_mask);
            end

            @(negedge aclk);
            request_valid = 1'b0;
            // Let the registered response pulse finish before the next request.
            @(posedge aclk);
        end
    endtask

    initial begin
        aclk = 1'b0;
        aresetn = 1'b0;
        request_src_mac = 48'd0;
        request_dst_mac = 48'd0;
        request_ingress_port = 2'd0;
        request_valid = 1'b0;

        repeat (3) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        // Learn A on port 0.  B is unknown, therefore flood to 1,2,3.
        submit_request(MAC_A, MAC_B, 2'd0, 1'b0, 1'b0, 2'd0, 4'b1110);

        // Learn B on port 1 and verify the lookup of A on port 0.
        submit_request(MAC_B, MAC_A, 2'd1, 1'b1, 1'b0, 2'd0, 4'b0001);

        // B is now known on port 1.
        submit_request(MAC_C, MAC_B, 2'd2, 1'b1, 1'b0, 2'd1, 4'b0010);

        // The source/destination equality bypass must suppress a self-send.
        submit_request(MAC_E, MAC_E, 2'd2, 1'b1, 1'b1, 2'd2, 4'b0000);

        // Group destinations always flood to non-ingress ports, while the
        // source MAC is still learned.
        submit_request(MAC_D, MAC_BROADCAST, 2'd2,
                       1'b0, 1'b0, 2'd0, 4'b1011);

        // MAC B moves from port 1 to port 3.
        submit_request(MAC_B, MAC_A, 2'd3, 1'b1, 1'b0, 2'd0, 4'b0001);
        submit_request(MAC_F, MAC_B, 2'd1, 1'b1, 1'b0, 2'd3, 4'b1000);

        $display("PASS: tb_fdb_4port");
        $finish;
    end

endmodule
