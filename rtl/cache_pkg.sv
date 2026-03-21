`timescale 1ns/1ps

package cache_pkg;

parameter int ADDR_W = 32;
parameter int LINE_BYTES = 16;
parameter int LINE_BITS = LINE_BYTES * 8;
parameter int NUM_SETS = 1024;

parameter int WORD_SIZE = 4;
parameter int WORD_BITS = WORD_SIZE * 8;

parameter int OFFSET_W = $clog2(LINE_BYTES);
parameter int INDEX_W = $clog2(NUM_SETS);
parameter int TAG_W = ADDR_W - INDEX_W - OFFSET_W;


parameter int OFFSET_HI = OFFSET_W - 1;
parameter int INDEX_LO = OFFSET_W;
parameter int INDEX_HI = OFFSET_W + INDEX_W - 1;
parameter int TAG_LO = OFFSET_W + INDEX_W;
parameter int TAG_HI = ADDR_W - 1;



typedef struct packed {

    logic valid;
    logic dirty;
    logic [TAG_W-1 : 0] tag;
    logic [LINE_BITS-1 : 0] data;

} cache_line_t;

typedef enum logic {

    CORE_RD = 1'b0,
    CORE_WR = 1'b1

} core_rw_t;

typedef struct packed {

    core_rw_t rw;
    logic [ADDR_W-1 : 0] addr;
    logic [WORD_BITS-1 : 0] data;
    logic [WORD_SIZE-1 : 0] strb;

} core_req_t;


typedef struct packed {

    logic [WORD_BITS-1 : 0] data;

} core_resp_t;


typedef enum logic [2:0] {

    S_IDLE = 3'd0,
    S_TAG_CHECK = 3'd1,
    S_HIT = 3'd2,
    S_MISS = 3'd3,
    S_REFILL = 3'd4

} core_state_e;

endpackage 