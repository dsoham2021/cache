
import cache_pkg::*;

module cache_array (

    input logic clk,

    input logic pa_wen,
    input logic [ADDR_W-1 : 0] pa_waddr,
    input logic [LINE_BITS-1 : 0] pa_wdata,
    
    input logic [ADDR_W-1 : 0] pa_raddr,
    output logic [LINE_BITS-1 : 0] pa_rdata
);


    cache_line_t mem [0 : NUM_SETS-1];

    always_ff @(posedge clk or negedge rst_n) begin 

        if (pa_wen) 
            mem[pa_waddr] <= pa_wdata;

        pa_rdata <= mem[pa_rdata];

    end
    

endmodule : cache_array