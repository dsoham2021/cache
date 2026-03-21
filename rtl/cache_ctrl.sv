`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Blocking direct-mapped write-back cache controller.
//
// Timing summary (synchronous SRAM, no extra S_READ state needed):
//
//   Cycle 1  S_IDLE       handshake detected
//                         cmem_raddr driven from live core_req_payload_i
//                         SRAM captures address on this rising edge
//                         FSM→S_TAG_CHECK, saved_req latched
//
//   Cycle 2  S_TAG_CHECK  cmem_rdata valid (SRAM output settled)
//                         tag comparison and hit/miss evaluated
//
//   Cycle 3  S_HIT        response sent to core
//                         write-back merged line written to SRAM (if WR)
//
// Miss path (S_MISS) is left as a stub for the memory-bus refill FSM.
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
    output core_resp_t  core_resp_payload_o
);

    // ----------------------------------------------------------------
    // FSM
    // ----------------------------------------------------------------
    core_state_e cState, cNextState;
    logic hit;

    logic      handshake;
    assign handshake = core_req_ready_o & core_req_valid_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cState <= S_IDLE;
        else        cState <= cNextState;
    end

    always_comb begin
        cNextState = cState;
        case (cState)
            S_IDLE      : if (handshake) cNextState = S_TAG_CHECK;
            S_TAG_CHECK : cNextState = hit ? S_HIT : S_MISS;
            S_HIT       : cNextState = S_IDLE;
            S_MISS      : cNextState = S_IDLE;   // stub
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
    logic [INDEX_W-1:0]  req_index;
    logic [TAG_W-1:0]    req_tag;

    assign req_offset = saved_req.addr[OFFSET_HI:0];
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
        end
    end

    // ----------------------------------------------------------------
    // Core response
    // ----------------------------------------------------------------

    logic[OFFSET_W+2: 0] req_byte_off;
    assign req_byte_off = {req_offset, 3'b000};

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
    end

endmodule : cache_ctrl