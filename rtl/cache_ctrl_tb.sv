`timescale 1ns/1ps
import cache_pkg::*;

module cache_ctrl_tb;

    localparam CLK_PERIOD = 10;

    logic clk, rst_n;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ----------------------------------------------------------------
    // DUT + mem model
    // ----------------------------------------------------------------
    logic        core_req_ready;
    logic        core_req_valid;
    core_req_t   core_req_payload;
    logic        core_resp_valid;
    core_resp_t  core_resp_payload;

    logic                  mem_req_valid;
    logic                  mem_req_rw;
    logic [ADDR_W-1:0]     mem_req_addr;
    logic [LINE_BITS-1:0]  mem_req_data;
    logic                  mem_req_ready;
    logic                  mem_resp_valid;
    logic [LINE_BITS-1:0]  mem_resp_data;

    cache_ctrl #(.INIT_FILE("cache_init.mem")) dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .core_req_ready_o    (core_req_ready),
        .core_req_valid_i    (core_req_valid),
        .core_req_payload_i  (core_req_payload),
        .core_resp_valid_i   (1'b0),
        .core_resp_valid_o   (core_resp_valid),
        .core_resp_payload_o (core_resp_payload),
        .mem_req_valid_o     (mem_req_valid),
        .mem_req_rw_o        (mem_req_rw),
        .mem_req_addr_o      (mem_req_addr),
        .mem_req_data_o      (mem_req_data),
        .mem_req_ready_i     (mem_req_ready),
        .mem_resp_valid_i    (mem_resp_valid),
        .mem_resp_data_i     (mem_resp_data)
    );

    mem_model #(.MIN_LATENCY(3), .MAX_LATENCY(6)) u_mem (
        .clk              (clk),
        .rst_n            (rst_n),
        .mem_req_valid_i  (mem_req_valid),
        .mem_req_rw_i     (mem_req_rw),
        .mem_req_addr_i   (mem_req_addr),
        .mem_req_data_i   (mem_req_data),
        .mem_req_ready_o  (mem_req_ready),
        .mem_resp_valid_o (mem_resp_valid),
        .mem_resp_data_o  (mem_resp_data)
    );

    // ----------------------------------------------------------------
    // Addresses
    //   ADDR_A = 0x0000_1000  tag=0, idx=0x100  pre-loaded word0=0xAAAAAAAA
    //   ADDR_B = 0x0000_2000  tag=0, idx=0x200  pre-loaded word0=0xBBBBBBBB
    //   ADDR_C = 0x0000_3000  tag=0, idx=0x300  cold (not in init file)
    //   ADDR_CX= 0x0004_3000  tag=1, idx=0x300  conflicts ADDR_C
    // ----------------------------------------------------------------
    localparam logic [31:0] ADDR_A  = 32'h0000_1000;
    localparam logic [31:0] ADDR_B  = 32'h0000_2000;
    localparam logic [31:0] ADDR_C  = 32'h0000_3000;
    localparam logic [31:0] ADDR_CX = 32'h0004_3000;

    // mem_model data pattern: word[w] = {addr[31:8], w[7:0]}
    // So word0 of ADDR_C = {0x000030, 0x00} = 0x00003000
    //    word0 of ADDR_CX= {0x000430, 0x00} = 0x00043000

    // ----------------------------------------------------------------
    // do_req: issue request and advance to the point where
    // resp_valid should be high.
    // For HITS: exactly 2 clocks after handshake (deterministic)
    // For MISSES: keep clocking until resp_valid goes high
    // ----------------------------------------------------------------
    task automatic do_req_hit(
        input core_rw_t    rw,
        input logic [31:0] addr,
        input logic [31:0] wdata,
        input logic [3:0]  strb
    );
        while (!core_req_ready) @(posedge clk);
        #1;
        core_req_valid        = 1'b1;
        core_req_payload.rw   = rw;
        core_req_payload.addr = addr;
        core_req_payload.data = wdata;
        core_req_payload.strb = strb;
        @(posedge clk); #1;   // handshake → S_TAG_CHECK
        core_req_valid   = 1'b0;
        core_req_payload = '0;
        @(posedge clk); #1;   // → S_HIT, sample here
    endtask

    task automatic do_req_miss(
        input core_rw_t    rw,
        input logic [31:0] addr,
        input logic [31:0] wdata,
        input logic [3:0]  strb
    );
        while (!core_req_ready) @(posedge clk);
        #1;
        core_req_valid        = 1'b1;
        core_req_payload.rw   = rw;
        core_req_payload.addr = addr;
        core_req_payload.data = wdata;
        core_req_payload.strb = strb;
        @(posedge clk); #1;   // handshake → S_TAG_CHECK
        core_req_valid   = 1'b0;
        core_req_payload = '0;
    // Check FIRST, then clock — opposite of before
        repeat(100) begin
            if (core_resp_valid) return;   // caught it — stop here
            @(posedge clk); #1;
        end
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

        // ── T1: Read hit ──────────────────────────────────────────────
        do_req_hit(CORE_RD, ADDR_A, '0, 4'hF);
        if (core_resp_valid)
            $display("T1 RD hit  ADDR_A: got=0x%08h exp=0xAAAAAAAA  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'hAAAA_AAAA) ? "PASS" : "FAIL");
        else $display("T1 RD hit  ADDR_A: no response — FAIL");

        // ── T2: Write hit (makes line dirty) then read back ───────────
        do_req_hit(CORE_WR, ADDR_A, 32'h1234_5678, 4'hF);
        if (core_resp_valid) $display("T2 WR hit  ADDR_A: ack PASS");
        else                 $display("T2 WR hit  ADDR_A: no ack — FAIL");

        do_req_hit(CORE_RD, ADDR_A, '0, 4'hF);
        if (core_resp_valid)
            $display("T2 RD back ADDR_A: got=0x%08h exp=0x12345678  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'h1234_5678) ? "PASS" : "FAIL");
        else $display("T2 RD back ADDR_A: no response — FAIL");

        // ── T3: Read miss, cold ───────────────────────────────────────
        do_req_miss(CORE_RD, ADDR_C, '0, 4'hF);
        if (core_resp_valid)
            $display("T3 RD miss ADDR_C: got=0x%08h exp=0x00003000  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'h0000_3000) ? "PASS" : "FAIL");
        else $display("T3 RD miss ADDR_C: no response — FAIL");

        // ── T4: Write miss, cold then read back ───────────────────────
        do_req_miss(CORE_WR, ADDR_B, 32'hDEAD_BEEF, 4'hF);
        if (core_resp_valid) $display("T4 WR miss ADDR_B: ack PASS");
        else                 $display("T4 WR miss ADDR_B: no ack — FAIL");

        do_req_hit(CORE_RD, ADDR_B, '0, 4'hF);
        if (core_resp_valid)
            $display("T4 RD back ADDR_B: got=0x%08h exp=0xDEADBEEF  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'hDEAD_BEEF) ? "PASS" : "FAIL");
        else $display("T4 RD back ADDR_B: no response — FAIL");

        // ── T5: Read miss, clean evict ────────────────────────────────
        // ADDR_C is now clean in cache (from T3). ADDR_CX conflicts it.
        do_req_miss(CORE_RD, ADDR_CX, '0, 4'hF);
        if (core_resp_valid)
            $display("T5 RD miss ADDR_CX (clean evict): got=0x%08h exp=0x00043000  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'h0004_3000) ? "PASS" : "FAIL");
        else $display("T5 RD miss ADDR_CX: no response — FAIL");

        // ── T6: Read miss, dirty evict ────────────────────────────────
        // Reload ADDR_C, write to make dirty, then conflict with ADDR_CX
        do_req_miss(CORE_RD, ADDR_C, '0, 4'hF);
        if (core_resp_valid) $display("T6 reload ADDR_C: PASS");
        else                 $display("T6 reload ADDR_C: FAIL");

        do_req_hit(CORE_WR, ADDR_C, 32'hCAFE_BABE, 4'hF);
        if (core_resp_valid) $display("T6 WR ADDR_C (make dirty): PASS");
        else                 $display("T6 WR ADDR_C: FAIL");

        // Now conflict — dirty evict of ADDR_C, then refill ADDR_CX
        $display("T6 dirty evict — watch mem bus for 2 transactions:");
        do_req_miss(CORE_RD, ADDR_CX, '0, 4'hF);
        if (core_resp_valid)
            $display("T6 RD miss ADDR_CX (dirty evict): got=0x%08h exp=0x00043000  %s",
                core_resp_payload.data,
                (core_resp_payload.data === 32'h0004_3000) ? "PASS" : "FAIL");
        else $display("T6 RD miss ADDR_CX: no response — FAIL");

        $display("\n=== Done ===");
        $finish;
    end

    // Print every mem bus transaction
    always @(posedge clk) begin
        if (mem_req_valid && mem_req_ready) begin
            if (mem_req_rw)
                $display("  [MEM] EVICT WRITE addr=0x%08h", mem_req_addr);
            else
                $display("  [MEM] REFILL READ  addr=0x%08h", mem_req_addr);
        end
    end

    initial begin #50000; $display("TIMEOUT"); $finish; end

    initial begin
        $dumpfile("cache_ctrl_tb.vcd");
        $dumpvars(0, cache_ctrl_tb);
    end

endmodule : cache_ctrl_tb