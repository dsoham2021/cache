`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Simple memory model
// Responds to every request (read or write) after a random delay
// between MIN_LATENCY and MAX_LATENCY cycles.
// For reads: returns a deterministic data pattern based on address.
// For writes: just acknowledges (data is accepted but not stored,
//             sufficient for eviction testing).
// ----------------------------------------------------------------
module mem_model #(
    parameter int MIN_LATENCY = 3,
    parameter int MAX_LATENCY = 6
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  mem_req_valid_i,
    input  logic                  mem_req_rw_i,
    input  logic [ADDR_W-1:0]     mem_req_addr_i,
    input  logic [LINE_BITS-1:0]  mem_req_data_i,
    output logic                  mem_req_ready_o,

    output logic                  mem_resp_valid_o,
    output logic [LINE_BITS-1:0]  mem_resp_data_o
);

    // ----------------------------------------------------------------
    // Data pattern: each 32-bit word = {addr[31:8], word_index[7:0]}
    // Makes it easy to verify which line came back
    // ----------------------------------------------------------------
    function automatic logic [LINE_BITS-1:0] gen_data(logic [ADDR_W-1:0] addr);
        logic [LINE_BITS-1:0] d;
        for (int w = 0; w < LINE_BYTES/WORD_SIZE; w++)
            d[w*WORD_BITS +: WORD_BITS] = {addr[ADDR_W-1:8], 8'(w)};
        return d;
    endfunction

    // ----------------------------------------------------------------
    // State
    // ----------------------------------------------------------------
    typedef enum logic [1:0] {
        M_IDLE    = 2'd0,
        M_WAIT    = 2'd1,
        M_RESPOND = 2'd2
    } mem_state_e;

    mem_state_e       mState;
    int               countdown;
    logic             saved_rw;
    logic [ADDR_W-1:0] saved_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mState          <= M_IDLE;
            mem_req_ready_o <= 1'b0;
            mem_resp_valid_o<= 1'b0;
            mem_resp_data_o <= '0;
            countdown       <= 0;
            saved_rw        <= 1'b0;
            saved_addr      <= '0;
        end else begin
            // Default — deassert pulses
            mem_req_ready_o  <= 1'b0;
            mem_resp_valid_o <= 1'b0;
            mem_resp_data_o  <= '0;

            case (mState)
                M_IDLE : begin
                    if (mem_req_valid_i) begin
                        // Accept the request immediately
                        mem_req_ready_o <= 1'b1;
                        saved_rw        <= mem_req_rw_i;
                        saved_addr      <= mem_req_addr_i;
                        // Pick a random latency in [MIN, MAX]
                        countdown <= MIN_LATENCY + ($urandom % (MAX_LATENCY - MIN_LATENCY + 1));
                        mState    <= M_WAIT;
                    end
                end

                M_WAIT : begin
                    if (countdown > 1) begin
                        countdown <= countdown - 1;
                    end else begin
                        mState <= M_RESPOND;
                    end
                end

                M_RESPOND : begin
                    mem_resp_valid_o <= 1'b1;
                    // For reads: return deterministic data
                    // For writes (evictions): resp_valid pulses but data ignored
                    mem_resp_data_o  <= saved_rw ? '0 : gen_data(saved_addr);
                    mState           <= M_IDLE;
                end
            endcase
        end
    end

endmodule : mem_model