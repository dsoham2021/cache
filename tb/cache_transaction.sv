`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Transaction descriptor — one complete core request/response pair.
// Filled in two stages:
//   1. Driver fills rw/addr/wdata/strb before sending to DUT
//   2. Monitor fills rdata/hit/miss after observing the response
// ----------------------------------------------------------------
typedef struct {
    // Request fields (set by driver)
    core_rw_t       rw;
    logic [31:0]    addr;
    logic [31:0]    wdata;
    logic [3:0]     strb;
    // Response fields (set by monitor)
    logic [31:0]    rdata;
    logic           got_resp;
} cache_trans_t;