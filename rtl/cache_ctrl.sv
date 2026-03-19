`timescale 1ns/1ps

import cache_pkg::*;


module cache_ctrl (

    input logic clk,
    input logic rst_n,

    output logic core_req_ready_o,
    input logic core_req_valid_i,
    input core_req_t core_req_payload_i,

    input logic core_resp_valid_i,      // Ignore this for now, used for non-blocking cache
    output logic core_resp_valid_o,
    output core_resp_t core_resp_payload_o
);

    logic handshake, hit;
    assign handshake = core_req_ready_o & core_req_valid_i;

    logic cState, cNextState;

    always_ff @(posedge clk or negedge rst_n) begin 

        if (!rst_n)
            cState <= S_IDLE;
        else 
            cState <= cNextState;
    end


        // Next state transition 
    always_comb begin

        cNextState = cState;

        case (cState) 
            
            S_IDLE : if (handshake) cNextState = S_TAG_CHECK;

            S_TAG_CHECK : cNextState = hit ? S_HIT : S_MISS;

            S_HIT: cNextState = S_IDLE;

            S_MISS: cNextState = S_IDLE; //to do

            default : ;

        endcase

    end

    // Latch the req during handshake

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


    

    

    logic cmem_wen;
    logic [INDEX_W-1 : 0] cmem_waddr;
    logic [$bits(cache_line_t)-1:0] cmem_wdata;
    logic [INDEX_W-1 : 0] cmem_raddr;
    logic [$bits(cache_line_t)-1:0] cmem_rdata;

    cache_array cmem (
        .clk(clk),
        .pa_wen(cmem_wen),
        .pa_waddr(cmem_waddr),
        .pa_wdata(cmem_wdata),
        .pa_raddr(cmem_raddr),
        .pa_rdata(cmem_rdata)
    );
    
    cache_line_t rd_line;
    assign rd_line = cmem_rdata;

    always_comb begin

        if (cState == S_IDLE)
            cmem_raddr = core_req_payload_i.addr[INDEX_HI:INDEX_LO];
        else
            cmem_raddr = req_index;
    end

    
    assign hit = rd_line.valid && (rd_line.tag == req_tag);


    // Write control

    always_comb begin 
        cmem_wen = 1'b0;
        cmem_waddr = req_index;
        cmem_wdata = '0;

        if (cState == S_HIT && saved_req.rw == CORE_WR) begin

            cmem_wen = 1'b1;
            cmem_waddr = req_index;
            cmem_wdata = '0; ////// IMportatnt, check this
        end
    end

    // Core resp

    assign core_req_ready_o = (cState == S_IDLE);

    always_comb begin

        core_resp_valid_o = 1'b0;
        core_resp_payload_o = '0;

        if (cState == S_HIT) begin

            core_resp_valid_o = 1'b1;
            if (saved_req.rw == CORE_RD) 
                core_resp_payload_o.data = rd_line.data[req_offset*8 +: WORD_BITS];
            
                // valid == 1 is the ack, data field is don't care
        end
    end
    



endmodule : cache_ctrl