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

    localparam logic [31:0] ADDR_A = 32'h0000_1000;
    localparam logic [31:0] ADDR_B = 32'h0000_2000;

    // ----------------------------------------------------------------
    // Cycle timing (hit path):
    //
    //   Cycle 1  S_IDLE       handshake, SRAM captures addr
    //   Cycle 2  S_TAG_CHECK  pa_rdata valid, hit evaluated
    //   Cycle 3  S_HIT        resp_valid HIGH (combinatorial)
    //            ^ sample HERE, before this edge clocks FSM to S_IDLE
    //   Cycle 4  S_IDLE       resp_valid LOW again
    //
    // So after the handshake edge, wait ONE more edge (lands in S_HIT),
    // then sample immediately with a small #1 delta — do NOT clock again.
    // ----------------------------------------------------------------
    task automatic do_req(
        input  core_rw_t    rw,
        input  logic [31:0] addr,
        input  logic [31:0] wdata,
        input  logic [3:0]  strb
    );
        while (!core_req_ready) @(posedge clk);
        #1;
        core_req_valid        = 1'b1;
        core_req_payload.rw   = rw;
        core_req_payload.addr = addr;
        core_req_payload.data = wdata;
        core_req_payload.strb = strb;
        @(posedge clk); #1;   // Cycle 1: handshake, FSM→S_TAG_CHECK
        core_req_valid   = 1'b0;
        core_req_payload = '0;
        @(posedge clk); #1;   // Cycle 2: FSM→S_HIT, pa_rdata valid
        // ↑ we are now IN S_HIT — resp_valid is combinatorially HIGH
        // sample immediately, do not clock again
    endtask

    // ----------------------------------------------------------------
    // Test sequence
    // ----------------------------------------------------------------
    initial begin
        core_req_valid   = 0;
        core_req_payload = '0;
        rst_n = 0;
        repeat(4) @(posedge clk);
        #1; rst_n = 1;
        @(posedge clk);
        $display("=== Reset done ===\n");

        // ── Read hit: ADDR_A ──────────────────────────────────────────
        do_req(CORE_RD, ADDR_A, '0, 4'hF);
        if (core_resp_valid)
            $display("RD ADDR_A: got=0x%08h exp=0xAAAAAAAA  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'hAAAA_AAAA) ? "PASS" : "FAIL");
        else
            $display("RD ADDR_A: no response — FAIL");

        // ── Read hit: ADDR_B ──────────────────────────────────────────
        do_req(CORE_RD, ADDR_B, '0, 4'hF);
        if (core_resp_valid)
            $display("RD ADDR_B: got=0x%08h exp=0xBBBBBBBB  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'hBBBB_BBBB) ? "PASS" : "FAIL");
        else
            $display("RD ADDR_B: no response — FAIL");

        $display("");

        // ── Write hit: ADDR_A — overwrite with 0x12345678 ─────────────
        do_req(CORE_WR, ADDR_A, 32'h1234_5678, 4'hF);
        if (core_resp_valid)
            $display("WR ADDR_A: ack received                      PASS");
        else
            $display("WR ADDR_A: no ack — FAIL");

        // Read back to verify
        do_req(CORE_RD, ADDR_A, '0, 4'hF);
        if (core_resp_valid)
            $display("RD ADDR_A: got=0x%08h exp=0x12345678  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'h1234_5678) ? "PASS" : "FAIL");
        else
            $display("RD ADDR_A: no response — FAIL");

        // ── Write hit: ADDR_B — overwrite with 0xDEADBEEF ─────────────
        do_req(CORE_WR, ADDR_B, 32'hDEAD_BEEF, 4'hF);
        if (core_resp_valid)
            $display("WR ADDR_B: ack received                      PASS");
        else
            $display("WR ADDR_B: no ack — FAIL");

        // Read back to verify
        do_req(CORE_RD, ADDR_B, '0, 4'hF);
        if (core_resp_valid)
            $display("RD ADDR_B: got=0x%08h exp=0xDEADBEEF  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'hDEAD_BEEF) ? "PASS" : "FAIL");
        else
            $display("RD ADDR_B: no response — FAIL");

        $display("\nDone");
        $finish;
    end

    initial begin #5000; $display("TIMEOUT"); $finish; end

    initial begin
        $dumpfile("cache_ctrl_tb.vcd");
        $dumpvars(0, cache_ctrl_tb);
    end

endmodule : cache_ctrl_tb