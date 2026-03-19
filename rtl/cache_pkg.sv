

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


typedef struct packed {

    logic valid;
    logic dirty;
    logic [TAG_W-1 : 0] tag;
    logic [LINE_BITS-1 : 0] data;

} cache_line_t;

typedef enum {

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

    
}

endpackage 