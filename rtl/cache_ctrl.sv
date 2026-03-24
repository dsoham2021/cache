`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Blocking direct-mapped write-back cache controller.
//
// Hit path  (3 cycles):
//   S_IDLE → S_TAG_CHECK → S_HIT → S_IDLE
//
// Clean miss path:
//   S_IDLE → S_TAG_CHECK → S_MISS → S_REFILL → S_IDLE
//
// Dirty eviction + miss path:
//   S_IDLE → S_TAG_CHECK → S_EVICT → S_MISS → S_REFILL → S_IDLE
//
//   S_EVICT  : dirty line in cache, must write back before fetching new.
//              Drives write request on mem bus. rd_line is latched into
//              evict_line in this state so SRAM can be reused for refill.
//              Leaves when mem_req_ready_i — write accepted by bus.
//              No mem_resp needed for writes.
//
//   S_MISS   : issue read request for the new line.
//              req_sent prevents re-assertion after bus grants.
//              Leaves when mem_req_ready_i — read accepted by bus.
//
//   S_REFILL : wait for mem_resp_valid_i (refill data arrives).
//              Fill-and-forward: write SRAM + respond to core same cycle.
// ----------------------------------------------------------------

module cache_ctrl #(
    parameter string INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,

    // Core request channel (ready/valid handshake)
    output logic        core_req_ready_o,
    input  logic        core_req_valid_i,
    input  core_req_t   core_req_payload_i,

    // Core response channel
    input  logic        core_resp_valid_i,   // reserved for non-blocking use
    output logic        core_resp_valid_o,
    output core_resp_t  core_resp_payload_o,


    // Memory bus - request channel
    output logic mem_req_valid_o,
    output logic mem_req_rw_o,                         // read=0, write=1
    output logic [ADDR_W-1 : 0] mem_req_addr_o,
    output logic [LINE_BITS-1 : 0] mem_req_data_o,
    input logic mem_req_ready_i,

    // Memory bus - response channel
    input logic mem_resp_valid_i,
    input logic [LINE_BITS-1:0] mem_resp_data_i,

    // Performance counter interface
    input  logic        perf_clear_i,
    input  logic [2:0]  perf_addr_i,
    output logic [31:0] perf_data_o
);

    // ----------------------------------------------------------------
    // FSM
    // ----------------------------------------------------------------
    core_state_e cState, cNextState;
    logic hit;

    logic      handshake;
    assign handshake = core_req_ready_o & core_req_valid_i;

    logic need_evict;
    assign need_evict = rd_line.valid && rd_line.dirty && !hit;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cState <= S_IDLE;
        else        cState <= cNextState;
    end

    always_comb begin
        cNextState = cState;
        case (cState)
            S_IDLE      : if (handshake) cNextState = S_TAG_CHECK;

            S_TAG_CHECK : begin 

                if(hit)              cNextState = S_HIT;
                else if (need_evict) cNextState = S_EVICT;
                else                 cNextState = S_MISS;

            end

            S_HIT       : cNextState = S_IDLE;
            S_EVICT     : if(mem_req_ready_i) cNextState = S_MISS;
            S_MISS      : if(mem_req_ready_i) cNextState = S_REFILL;
            S_REFILL    : if(mem_resp_valid_i) cNextState = S_IDLE;
            default     : ;
        endcase
    end

    // ----------------------------------------------------------------
    // Request latch
    // ----------------------------------------------------------------
    core_req_t saved_req;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            saved_req <= '0;
        else if (cState == S_IDLE && handshake)
            saved_req <= core_req_payload_i;
    end

    // ----------------------------------------------------------------
    // Address field extraction (from saved_req)
    // ----------------------------------------------------------------
    logic [OFFSET_W-1:0] req_offset;
    logic[OFFSET_W+2: 0] req_byte_off;
    logic [INDEX_W-1:0]  req_index;
    logic [TAG_W-1:0]    req_tag;

    assign req_offset = saved_req.addr[OFFSET_HI:0];
    assign req_byte_off = {req_offset, 3'b000};
    assign req_index  = saved_req.addr[INDEX_HI:INDEX_LO];
    assign req_tag    = saved_req.addr[TAG_HI:TAG_LO];

    // ----------------------------------------------------------------
    // Cache array interface
    // ----------------------------------------------------------------
    logic                            cmem_wen;
    logic [INDEX_W-1:0]              cmem_waddr;
    logic [$bits(cache_line_t)-1:0]  cmem_wdata;
    logic [INDEX_W-1:0]              cmem_raddr;
    logic [$bits(cache_line_t)-1:0]  cmem_rdata;

    cache_array #(.INIT_FILE(INIT_FILE)) cmem (
        .clk      (clk),
        .pa_wen   (cmem_wen),
        .pa_waddr (cmem_waddr),
        .pa_wdata (cmem_wdata),
        .pa_raddr (cmem_raddr),
        .pa_rdata (cmem_rdata)
    );

    // Unpack the SRAM output into a cache_line_t for easy field access
    cache_line_t rd_line;
    assign rd_line = cmem_rdata;


    // ----------------------------------------------------------------
    // Eviction line latch
    // rd_line is valid in S_TAG_CHECK. Latch it on the S_TAG_CHECK→S_EVICT
    // transition so it stays stable while the SRAM is reused for refill.
    // ----------------------------------------------------------------

    cache_line_t evict_line;

    always_ff @(posedge clk or negedge rst_n) begin

        if(!rst_n)
            evict_line <= '0;
        
        else if (cState == S_TAG_CHECK && need_evict)
            evict_line <= rd_line;
    end

    // Reconstruct the evicted line's full address:
    // tag comes from evict_line, index from the current req, the offset would be 0x00, because the entire line is being evicted (16 bytes)

    logic [ADDR_W-1 : 0] evict_addr;
    assign evict_addr = {evict_line.tag, req_index, {OFFSET_W{1'b0}}};


    // ----------------------------------------------------------------
    // Read address steering:
    //   S_IDLE      → use LIVE incoming address so SRAM captures it on
    //                 the handshake edge; pa_rdata valid in S_TAG_CHECK
    //   other states→ hold saved index (keeps address bus stable)
    // ----------------------------------------------------------------
    always_comb begin
        if (cState == S_IDLE)
            cmem_raddr = core_req_payload_i.addr[INDEX_HI:INDEX_LO];
        else
            cmem_raddr = req_index;
    end

    // ----------------------------------------------------------------
    // Hit detection (evaluated in S_TAG_CHECK, rd_line is valid)
    // ----------------------------------------------------------------
    
    assign hit = rd_line.valid && (rd_line.tag == req_tag);

    // ----------------------------------------------------------------
    // Write-merge: splice the new word into the cache line using strb
    // ----------------------------------------------------------------
    cache_line_t         merged_line;
    logic [LINE_BITS-1:0] merged_data;

    always_comb begin : write_merge
        merged_data = rd_line.data;
        for (int b = 0; b < WORD_SIZE; b++) begin
            if (saved_req.strb[b])
                merged_data[(req_offset*8 + b*8) +: 8] = saved_req.data[b*8 +: 8];
        end
    end

    always_comb begin : build_merged_line
        merged_line       = rd_line;
        merged_line.data  = merged_data;
        merged_line.dirty = 1'b1;
    end

    // ----------------------------------------------------------------
    // Refill line construction (used in S_REFILL)
    // Fill-and-forward: if the miss was a CORE_WR, apply the write
    // directly onto the refill data so we don't need another pass.
    // ----------------------------------------------------------------

    cache_line_t refill_line;
    logic [LINE_BITS-1 : 0] refill_data;

    always_comb begin : write_merge_refill

        refill_data = mem_resp_data_i;
        if(saved_req == CORE_WR) begin
            for(int b = 0; b < WORD_SIZE; b++) begin
                if(saved_req.strb[b])
                    refill_data[(req_byte_off) + b*8 +: 8] = saved_req.data[b*8 +: 8];
            end
        end
    end

    always_comb begin : build_refill_line

        refill_line.valid = 1'b1;
        refill_line.dirty = (saved_req == CORE_WR);
        refill_line.tag = req_tag;
        refill_line.data = refill_data;
    end


    // ----------------------------------------------------------------
    // SRAM write control
    //   Write hit  → write merged line back in S_HIT
    //   Miss refill→ written in S_MISS (TODO)
    // ----------------------------------------------------------------
    always_comb begin
        cmem_wen   = 1'b0;
        cmem_waddr = {INDEX_W{1'b0}};
        cmem_wdata = '0;

        if (cState == S_HIT && saved_req.rw == CORE_WR) begin
            cmem_wen   = 1'b1;
            cmem_waddr = req_index;
            cmem_wdata = merged_line;
        end else if (cState == S_REFILL && mem_resp_valid_i) begin
            cmem_wen = 1'b1;
            cmem_waddr = req_index;
            cmem_wdata = refill_line;
        end
    end


    // ----------------------------------------------------------------
    // Memory bus request
    //   S_MISS: issue read request for the missing line.
    //   Eviction (dirty writeback) TODO: check rd_line.dirty and issue
    //   a write before the read — needs an extra S_EVICT state.
    // ----------------------------------------------------------------

        logic req_sent;

        always_ff @(posedge clk or negedge rst_n) begin

            if(!rst_n)
                req_sent <= 1'b0;
            else if (cState == S_EVICT && mem_req_ready_i)
                req_sent <= 1'b0;  // evict accepted → entering S_MISS, re-arm for refill read
            else if (cState == S_MISS && mem_req_ready_i)
                req_sent <= 1'b1;  // refill read accepted → entering S_REFILL
            else if (cState == S_IDLE)
                req_sent <= 1'b0;


        end

        always_comb begin 

            mem_req_valid_o = 1'b0;
            mem_req_rw_o = 1'b0;
            mem_req_addr_o = '0;
            mem_req_data_o = '0;

            if (!req_sent) begin

                if(cState == S_EVICT) begin
                    mem_req_valid_o = 1'b1;
                    mem_req_rw_o = 1'b1;
                    mem_req_addr_o = evict_addr;
                    mem_req_data_o = evict_line.data;
                end 

                else if (cState == S_MISS) begin
                    mem_req_valid_o = 1'b1;
                    mem_req_rw_o = 1'b0;
                    mem_req_addr_o = {saved_req.addr[ADDR_W-1:OFFSET_W], {OFFSET_W{1'b0}}};
                end
            end
        end
        

    // ----------------------------------------------------------------
    // Core response
    // ----------------------------------------------------------------


    assign core_req_ready_o = (cState == S_IDLE);

    always_comb begin
        core_resp_valid_o   = 1'b0;
        core_resp_payload_o = '0;

        if (cState == S_HIT) begin
            core_resp_valid_o = 1'b1;
            if (saved_req.rw == CORE_RD)
                // Extract the requested word from the line using byte offset

                // Wrong, SV multiplies 4 bit value and overflow leads to always being zero
                core_resp_payload_o.data = rd_line.data[req_offset*8 +: WORD_BITS];

                //core_resp_payload_o.data = rd_line.data[req_byte_off +: WORD_BITS];

            // CORE_WR: valid=1 is the write-ack, data field is don't-care
        end

        else if (cState == S_REFILL && mem_resp_valid_i) begin

            core_resp_valid_o = 1'b1;
            if(saved_req.rw == CORE_RD)
                core_resp_payload_o.data = refill_data[req_byte_off +: WORD_BITS];

        end
    end

    // ----------------------------------------------------------------
    // Performance counters
    // ----------------------------------------------------------------
    cache_perf #(.CNT_W(32)) u_perf (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear_i      (perf_clear_i),
        .cState       (cState),
        .cNextState   (cNextState),
        .reg_addr_i   (perf_addr_i),
        .reg_data_o   (perf_data_o)
    );

endmodule : cache_ctrl