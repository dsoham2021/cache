`timescale 1ns/1ps
import cache_pkg::*;

module cache_array_tb;

    // Signals
    logic clk;
    logic pa_wen;
    logic [INDEX_W-1 : 0] pa_waddr;
    cache_line_t pa_wdata;
    logic [INDEX_W-1 : 0] pa_raddr;
    cache_line_t pa_rdata;

    // Instantiate DUT
    cache_array # (
    .INIT_FILE("cache_init.mem") 
    ) dut (
        .clk(clk),
        .pa_wen(pa_wen),
        .pa_waddr(pa_waddr),
        .pa_wdata(pa_wdata),
        .pa_raddr(pa_raddr),
        .pa_rdata(pa_rdata)
    );

    // Clock Generation (100MHz)
    initial clk = 0;
    always #5 clk = ~clk;

    // Test Procedure
    initial begin
        // Initialize
        pa_wen   = 0;
        pa_waddr = 0;
        pa_wdata = 0;
        pa_raddr = 0;

        @(posedge clk);
        
        // 1. Write data to index 5
        $display("[%0t] Writing to index 5...", $time);
        pa_wen   = 1;
        pa_waddr = 5;
        // Constructing a test line
        pa_wdata = {1'b1, 1'b0, {TAG_W{1'b1}}, {LINE_BITS{1'hA}}}; 
        
        @(posedge clk);
        pa_wen = 0;

        // 2. Read back from index 5
        $display("[%0t] Reading from index 5...", $time);
        pa_raddr = 5;
        
        // Wait for the synchronous read (1 clock cycle)
        @(posedge clk);
        #1; // Small delay to observe the stable output
        
        if (pa_rdata === {1'b1, 1'b0, {TAG_W{1'b1}}, {LINE_BITS{1'hA}}}) begin
            $display("[%0t] SUCCESS: Data matches!", $time);
        end else begin
            $display("[%0t] ERROR: Data mismatch! Expected %h, Got %h", $time, {1'b1, 1'b0, {TAG_W{1'b1}}, {LINE_BITS{1'hA}}}, pa_rdata);
        end

        #20;
        $finish;
    end

endmodule