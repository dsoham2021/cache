`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Monitor — silent observer, never drives any signal.
// Watches the core request and response interfaces and packages
// completed transactions into the scoreboard mailbox.
//
// Two parallel threads:
//   1. req_monitor  — captures request fields on handshake
//   2. resp_monitor — captures response when core_resp_valid goes high
//                     matches it to the pending request and pushes
//                     the completed transaction to the scoreboard
// ----------------------------------------------------------------
module cache_monitor (
    input  logic        clk,
    input  logic        rst_n,

    // Observe core request interface
    input  logic        core_req_ready_i,
    input  logic        core_req_valid_i,
    input  core_req_t   core_req_payload_i,

    // Observe core response interface
    input  logic        core_resp_valid_i,
    input  core_resp_t  core_resp_payload_i,

    // Mailbox handle — monitor pushes completed transactions here
    ref    mailbox #(cache_trans_t) mon_mbx
);

    // Internal queue — holds requests seen, waiting for response
    cache_trans_t pending[$];

    // ── Thread 1: watch for requests ─────────────────────────────────
    initial begin
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            if (core_req_ready_i && core_req_valid_i) begin
                cache_trans_t tr;
                tr.rw       = core_req_payload_i.rw;
                tr.addr     = core_req_payload_i.addr;
                tr.wdata    = core_req_payload_i.data;
                tr.strb     = core_req_payload_i.strb;
                tr.rdata    = '0;
                tr.got_resp = 1'b0;
                pending.push_back(tr);
            end
        end
    end

    // ── Thread 2: watch for responses ────────────────────────────────
    initial begin
        @(posedge rst_n);
        forever begin
            // Use posedge core_resp_valid to catch the exact cycle
            @(posedge core_resp_valid_i);
            #1; // let combinatorial outputs settle
            if (pending.size() > 0) begin
                cache_trans_t tr;
                tr          = pending.pop_front();
                tr.got_resp = 1'b1;
                tr.rdata    = core_resp_payload_i.data;
                mon_mbx.put(tr);
            end
        end
    end

endmodule : cache_monitor