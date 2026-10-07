`timescale 1ns / 1ps

// SPDX-License-Identifier: MIT
//
// Simple traffic-class selector used by the first-draft transmission selector.
// Priority 0 is the least preferred class and priority 7 is the most preferred
// class.  Priority is supplied as metadata; this block deliberately does not
// parse a VLAN header and does not implement ATS/CBS/TAS shaping.

module priority_selector_8 (
    input  wire [2:0] priority_code,
    output wire [7:0] traffic_class_onehot
);

    assign traffic_class_onehot = (8'b00000001 << priority_code);

endmodule
