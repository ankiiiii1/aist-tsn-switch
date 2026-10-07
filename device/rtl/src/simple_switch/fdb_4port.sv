`timescale 1ns / 1ps

// SPDX-License-Identifier: MIT
//
// Simple four-port Filtering Database (FDB).
//
// This block deliberately makes forwarding decisions only.  It does not carry,
// buffer, copy, or multiplex Ethernet frame data.  A separate 1x3 switching
// fabric consumes response_dest_mask.
//
// Request/response timing:
//   * Assert request_valid with a stable descriptor until request_ready is 1.
//   * The request is accepted on request_valid && request_ready.
//   * A registered response is presented during the following cycle with
//     response_valid asserted for one clock.
//
// The table is a small fully-associative table intended for a first FPGA
// implementation.  It uses no aging, hashing, CAM primitive, or VLAN state.

module fdb_4port #(
    parameter integer TABLE_ENTRIES = 16
) (
    input  wire        aclk,
    input  wire        aresetn,

    // Frame descriptor supplied by the ingress/scheduler side.
    input  wire [47:0] request_src_mac,
    input  wire [47:0] request_dst_mac,
    input  wire [1:0]  request_ingress_port,
    input  wire        request_valid,
    output wire        request_ready,

    // One-cycle forwarding decision.  response_ingress_port identifies the
    // requester so a shared FDB can serve all four ingress pipelines.
    output logic        response_valid,
    output logic [1:0]  response_ingress_port,
    output logic        response_hit,
    output logic        response_same_port,
    output logic [1:0]  response_dest_port,
    output logic [3:0]  response_dest_mask
);

    localparam integer ENTRY_INDEX_WIDTH =
        (TABLE_ENTRIES <= 1) ? 1 : $clog2(TABLE_ENTRIES);

    // Each entry is exactly: valid bit + 48-bit MAC + 2-bit learned port.
    logic        table_valid [0:TABLE_ENTRIES-1];
    logic [47:0] table_mac   [0:TABLE_ENTRIES-1];
    logic [1:0]  table_port  [0:TABLE_ENTRIES-1];

    // Used only if the fixed-size table has no invalid entry left.
    logic [ENTRY_INDEX_WIDTH-1:0] replacement_ptr;
    localparam [ENTRY_INDEX_WIDTH-1:0] LAST_ENTRY_INDEX =
        ENTRY_INDEX_WIDTH'(TABLE_ENTRIES - 1);

    logic src_found;
    logic dst_found;
    logic free_found;
    logic [ENTRY_INDEX_WIDTH-1:0] src_index;
    logic [ENTRY_INDEX_WIDTH-1:0] dst_index;
    logic [ENTRY_INDEX_WIDTH-1:0] free_index;
    logic [ENTRY_INDEX_WIDTH-1:0] learning_index;

    logic lookup_hit_comb;
    logic same_port_comb;
    logic [1:0] dest_port_comb;
    logic [3:0] dest_mask_comb;
    logic [3:0] ingress_mask;

    integer search_i;
    integer reset_i;

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

    // Fully-associative source and destination searches.  The first matching
    // table entry wins, which also provides deterministic behavior if a table
    // is inspected while being debugged.
    always_comb begin
        src_found = 1'b0;
        dst_found = 1'b0;
        free_found = 1'b0;
        src_index = '0;
        dst_index = '0;
        free_index = '0;

        for (search_i = 0; search_i < TABLE_ENTRIES; search_i = search_i + 1) begin
            if (table_valid[search_i] &&
                (table_mac[search_i] == request_src_mac) && !src_found) begin
                src_found = 1'b1;
                src_index = search_i[ENTRY_INDEX_WIDTH-1:0];
            end

            if (table_valid[search_i] &&
                (table_mac[search_i] == request_dst_mac) && !dst_found) begin
                dst_found = 1'b1;
                dst_index = search_i[ENTRY_INDEX_WIDTH-1:0];
            end

            if (!table_valid[search_i] && !free_found) begin
                free_found = 1'b1;
                free_index = search_i[ENTRY_INDEX_WIDTH-1:0];
            end
        end

        if (src_found) begin
            learning_index = src_index;
        end else if (free_found) begin
            learning_index = free_index;
        end else begin
            learning_index = replacement_ptr;
        end

        ingress_mask = port_mask(request_ingress_port);

        // A destination that equals the current source is treated as learned
        // on the ingress port even on the first occurrence.  This bypass keeps
        // the decision consistent with the learning update made below.
        lookup_hit_comb = 1'b0;
        same_port_comb = 1'b0;
        dest_port_comb = 2'd0;
        dest_mask_comb = 4'b0000;

        // Ethernet group addresses (including FF:FF:FF:FF:FF:FF) are flooded.
        // The I/G bit is bit 0 of the first MAC octet, i.e. bit 40 here.
        // Source learning remains active for such frames; this is important for
        // normal ARP/discovery based table learning.
        if (request_dst_mac[40]) begin
            dest_mask_comb = 4'b1111 & ~ingress_mask;
        end else if (request_dst_mac == request_src_mac) begin
            lookup_hit_comb = 1'b1;
            same_port_comb = 1'b1;
            dest_port_comb = request_ingress_port;
            dest_mask_comb = 4'b0000;
        end else if (dst_found) begin
            lookup_hit_comb = 1'b1;
            dest_port_comb = table_port[dst_index];
            if (table_port[dst_index] == request_ingress_port) begin
                same_port_comb = 1'b1;
                dest_mask_comb = 4'b0000;
            end else begin
                dest_mask_comb = port_mask(table_port[dst_index]);
            end
        end else begin
            // Unknown unicast: send one copy to every non-ingress port.
            dest_mask_comb = 4'b1111 & ~ingress_mask;
        end
    end

    // A response intentionally occupies one cycle by itself.  This simple
    // protocol avoids response backpressure in the first draft and makes the
    // shared-table integration easy to inspect in a waveform.
    assign request_ready = aresetn && !response_valid;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            response_valid <= 1'b0;
            response_ingress_port <= 2'd0;
            response_hit <= 1'b0;
            response_same_port <= 1'b0;
            response_dest_port <= 2'd0;
            response_dest_mask <= 4'b0000;
            replacement_ptr <= '0;

            for (reset_i = 0; reset_i < TABLE_ENTRIES; reset_i = reset_i + 1) begin
                table_valid[reset_i] <= 1'b0;
                table_mac[reset_i] <= 48'd0;
                table_port[reset_i] <= 2'd0;
            end
        end else begin
            // Default: response_valid is a one-clock pulse.
            response_valid <= 1'b0;

            if (request_valid && request_ready) begin
                // MAC learning.  A known source is refreshed/moved to the
                // current ingress port; a new source uses an invalid entry or
                // the simple round-robin victim when the table is full.
                table_valid[learning_index] <= 1'b1;
                table_mac[learning_index] <= request_src_mac;
                table_port[learning_index] <= request_ingress_port;

                if (!src_found && !free_found) begin
                    if (replacement_ptr == LAST_ENTRY_INDEX) begin
                        replacement_ptr <= '0;
                    end else begin
                        replacement_ptr <= replacement_ptr + 1'b1;
                    end
                end

                response_valid <= 1'b1;
                response_ingress_port <= request_ingress_port;
                response_hit <= lookup_hit_comb;
                response_same_port <= same_port_comb;
                response_dest_port <= dest_port_comb;
                response_dest_mask <= dest_mask_comb;
            end
        end
    end

endmodule
