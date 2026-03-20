`timescale 1ns/1ps
import cache_pkg::*;
 
module cache_ctrl_tb;
 
    // ----------------------------------------------------------------
    // Clock / reset
    // ----------------------------------------------------------------
    localparam CLK_PERIOD = 10;
 
    logic clk, rst_n;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
 
    // ----------------------------------------------------------------
    // DUT signals
    // ----------------------------------------------------------------
    logic        core_req_ready;
    logic        core_req_valid;
    core_req_t   core_req_payload;
    logic        core_resp_valid;
    core_resp_t  core_resp_payload;
 
    // Pass the init file — SRAM is pre-loaded before simulation starts
    cache_ctrl #(.INIT_FILE("cache_init.mem")) dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .core_req_ready_o    (core_req_ready),
        .core_req_valid_i    (core_req_valid),
        .core_req_payload_i  (core_req_payload),
        .core_resp_valid_i   (1'b0),
        .core_resp_valid_o   (core_resp_valid),
        .core_resp_payload_o (core_resp_payload)
    );
 
    // ----------------------------------------------------------------
    // Addresses
    //   ADDR_A: index=0x100, tag=0, offset=0  → word0=0xAAAAAAAA
    //   ADDR_B: index=0x200, tag=0, offset=0  → word0=0xBBBBBBBB
    // ----------------------------------------------------------------
    localparam logic [31:0] ADDR_A = 32'h0000_1000;
    localparam logic [31:0] ADDR_B = 32'h0000_2000;
 
    initial begin
        // ── Reset ────────────────────────────────────────────────────
        core_req_valid   = 0;
        core_req_payload = '0;
        rst_n = 0;
        repeat(4) @(posedge clk);
        #1; rst_n = 1;
        @(posedge clk);
        $display("Reset done");
 
        // ── Read ADDR_A ───────────────────────────────────────────────
        while (!core_req_ready) @(posedge clk);
        #1; 
        core_req_valid        = 1'b1;
        core_req_payload.rw   = CORE_RD;
        core_req_payload.addr = ADDR_A;
        core_req_payload.data = '0;
        core_req_payload.strb = 4'hF;
        @(posedge clk); #1;    // handshake edge: FSM→S_TAG_CHECK, SRAM captures addr
        core_req_valid   = 0;
        core_req_payload = '0;
        @(posedge clk); #1;    // S_TAG_CHECK→S_HIT, pa_rdata valid
        @(posedge clk); #1;    // now in S_HIT, resp_valid asserted
        if (core_resp_valid)
            $display("ADDR_A: got=0x%08h exp=0xAAAAAAAA  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'hAAAA_AAAA) ? "PASS" : "FAIL");
        else
            $display("ADDR_A: no response — FAIL");
 
        // ── Read ADDR_B ───────────────────────────────────────────────
        while (!core_req_ready) @(posedge clk);
        #1;
        core_req_valid        = 1'b1;
        core_req_payload.rw   = CORE_RD;
        core_req_payload.addr = ADDR_B;
        core_req_payload.data = '0;
        core_req_payload.strb = 4'hF;
        @(posedge clk); #1;
        core_req_valid   = 0;
        core_req_payload = '0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        if (core_resp_valid)
            $display("ADDR_B: got=0x%08h exp=0xBBBBBBBB  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'hBBBB_BBBB) ? "PASS" : "FAIL");
        else
            $display("ADDR_B: no response — FAIL");
 
        #20;
        $display("Done");
        $finish;
    end
 
    initial begin #5000; $display("TIMEOUT"); $finish; end
 
    initial begin
        $dumpfile("cache_ctrl_tb.vcd");
        $dumpvars(0, cache_ctrl_tb);
    end
 
endmodule : cache_ctrl_tb