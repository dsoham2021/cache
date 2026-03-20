`timescale 1ns/1ps

import cache_pkg::*;

module cache_array # (
    parameter string INIT_FILE = ""
)(

    input logic clk,

    input logic pa_wen,
    input logic [INDEX_W-1 : 0] pa_waddr,
    input cache_line_t pa_wdata,
    
    input logic [INDEX_W-1 : 0] pa_raddr,
    output cache_line_t pa_rdata
);

    cache_line_t mem [NUM_SETS];

    initial begin 
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
            $display("cache array: loaded '%s'", INIT_FILE);
        end
    end


    always_ff @(posedge clk) begin 

        if (pa_wen) 
            mem[pa_waddr] <= pa_wdata;

        pa_rdata <= mem[pa_raddr];

    end
    

endmodule : cache_array