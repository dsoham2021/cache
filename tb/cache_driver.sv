`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Driver — plays the role of the CPU.
// Picks transactions from the mailbox and drives the core request
// interface. Does not know or care what the correct response is.
//
// After issuing a request it waits for core_req_ready_o to go high
// again (FSM back in S_IDLE) before accepting the next transaction.
// This models a blocking CPU — one outstanding request at a time.
// ----------------------------------------------------------------
module cache_driver (
    input  logic        clk,
    input  logic        rst_n,

    // Mailbox handle — driver reads transactions from here
    // (passed as a parameter at elaboration via the tb top)
    ref    mailbox #(cache_trans_t) drv_mbx,

    // Core request interface (drives DUT)
    input  logic        core_req_ready_i,
    output logic        core_req_valid_o,
    output core_req_t   core_req_payload_o
);

    initial begin
        core_req_valid_o   = 1'b0;
        core_req_payload_o = '0;

        // Wait for reset to deassert
        @(posedge rst_n);
        @(posedge clk);

        forever begin
            cache_trans_t tr;

            // Get next transaction from mailbox (blocks if empty)
            drv_mbx.get(tr);

            // Wait until DUT is ready
            while (!core_req_ready_i) @(posedge clk);

            // Drive request
            #1;
            core_req_valid_o          = 1'b1;
            core_req_payload_o.rw     = tr.rw;
            core_req_payload_o.addr   = tr.addr;
            core_req_payload_o.data   = tr.wdata;
            core_req_payload_o.strb   = tr.strb;

            // Hold for one cycle (handshake)
            @(posedge clk); #1;
            core_req_valid_o   = 1'b0;
            core_req_payload_o = '0;
        end
    end

endmodule : cache_driver