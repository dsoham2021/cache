`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Cache performance counter block
//
// Tracks four events by observing the cache FSM state transitions:
//   - hits        : TAG_CHECK → HIT
//   - misses      : TAG_CHECK → MISS or EVICT
//   - evictions   : TAG_CHECK → EVICT (dirty line displaced)
//   - total reqs  : IDLE → TAG_CHECK (every handshake)
//
// All counters are CNT_W bits wide (default 32).
// Counters saturate at max value rather than wrapping.
//
// Register read interface (word-addressed, no write):
//   addr 0 : total_reqs
//   addr 1 : hits
//   addr 2 : misses
//   addr 3 : evictions
//   addr 4 : hit rate approximation = (hits * 256) / total_reqs
//            (integer, 8 fractional bits — 256 = 100%)
//
// A single clear_i pulse resets all counters synchronously.
// ----------------------------------------------------------------
module cache_perf #(
    parameter int CNT_W = 32
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear_i,        // synchronous counter clear

    // Observe FSM state transitions
    input  core_state_e cState,
    input  core_state_e cNextState,

    // Register read port
    input  logic [2:0]          reg_addr_i,
    output logic [CNT_W-1:0]    reg_data_o
);

    // ----------------------------------------------------------------
    // Counters
    // ----------------------------------------------------------------
    logic [CNT_W-1:0] cnt_reqs;
    logic [CNT_W-1:0] cnt_hits;
    logic [CNT_W-1:0] cnt_misses;
    logic [CNT_W-1:0] cnt_evictions;

    // Saturating increment helper
    function automatic logic [CNT_W-1:0] sat_inc(input logic [CNT_W-1:0] v);
        return (&v) ? v : v + 1'b1;   // if all ones, hold; else increment
    endfunction

    // ----------------------------------------------------------------
    // Event detection — all based on state transitions
    // ----------------------------------------------------------------
    logic ev_req;       // new request accepted
    logic ev_hit;       // tag check resolved as hit
    logic ev_miss;      // tag check resolved as miss (clean or dirty)
    logic ev_evict;     // tag check resolved as dirty eviction

    assign ev_req   = (cState == S_IDLE)      && (cNextState == S_TAG_CHECK);
    assign ev_hit   = (cState == S_TAG_CHECK) && (cNextState == S_HIT);
    assign ev_miss  = (cState == S_TAG_CHECK) && (cNextState == S_MISS);
    assign ev_evict = (cState == S_TAG_CHECK) && (cNextState == S_EVICT);

    // ----------------------------------------------------------------
    // Counter update
    // ----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear_i) begin
            cnt_reqs      <= '0;
            cnt_hits      <= '0;
            cnt_misses    <= '0;
            cnt_evictions <= '0;
        end else begin
            if (ev_req)   cnt_reqs      <= sat_inc(cnt_reqs);
            if (ev_hit)   cnt_hits      <= sat_inc(cnt_hits);
            if (ev_miss)  cnt_misses    <= sat_inc(cnt_misses);
            if (ev_evict) begin
                cnt_misses    <= sat_inc(cnt_misses);   // eviction is also a miss
                cnt_evictions <= sat_inc(cnt_evictions);
            end
        end
    end

    // ----------------------------------------------------------------
    // Hit rate: (hits * 256) / total_reqs
    // Computed combinatorially — integer division, 8 fractional bits.
    // 256/256 = 100% hit rate, 128/256 = 50%, etc.
    // ----------------------------------------------------------------
    logic [CNT_W-1:0] hit_rate;

    always_comb begin
        if (cnt_reqs == '0)
            hit_rate = '0;
        else
            hit_rate = (cnt_hits << 8) / cnt_reqs;
    end

    // ----------------------------------------------------------------
    // Register read
    // ----------------------------------------------------------------
    always_comb begin
        case (reg_addr_i)
            3'd0:    reg_data_o = cnt_reqs;
            3'd1:    reg_data_o = cnt_hits;
            3'd2:    reg_data_o = cnt_misses;
            3'd3:    reg_data_o = cnt_evictions;
            3'd4:    reg_data_o = hit_rate;
            default: reg_data_o = '0;
        endcase
    end

endmodule : cache_perf