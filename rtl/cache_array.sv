`timescale 1ns/1ps

import cache_pkg::*;

module cache_array (

    input logic clk,

    input logic pa_wen,
    input logic [INDEX_W-1 : 0] pa_waddr,
    input logic [$bits(cache_line_t)-1:0] pa_wdata,
    
    input logic [INDEX_W-1 : 0] pa_raddr,
    output logic [$bits(cache_line_t)-1:0] pa_rdata
);


    cache_line_t mem [NUM_SETS];

    always_ff @(posedge clk) begin 

        if (pa_wen) 
            mem[pa_waddr] <= pa_wdata;

        pa_rdata <= mem[pa_rdata];

    end
    

endmodule : cache_array