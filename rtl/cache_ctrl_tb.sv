import cache_pkg::*;

// ----------------------------------------------------------------
// Simple directed testbench for cache_ctrl (hit path only)
//
// Test cases:
//   1. Cold read  → miss  (valid=0 in SRAM after reset)
//   2. Write      → miss  (same address, cold)
//   3. Read after write → should still miss (no refill implemented)
//
// For the HIT path we manually backdoor-initialise the SRAM so we
// can test hits without needing a real refill path.
//
// Backdoor: the testbench reaches into cmem.mem[] directly to plant
// a valid cache line before issuing the request.
// ----------------------------------------------------------------

`timescale 1ns/1ps

module cache_ctrl_tb;

    // ----------------------------------------------------------------
    // Clock / reset
    // ----------------------------------------------------------------
    localparam CLK_PERIOD = 10; // 100 MHz

    logic clk, rst_n;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic do_reset();
        rst_n = 0;
        repeat(4) @(posedge clk);
        #1; // small delta after edge
        rst_n = 1;
        @(posedge clk);
    endtask

    // ----------------------------------------------------------------
    // DUT signals
    // ----------------------------------------------------------------
    logic        core_req_ready;
    logic        core_req_valid;
    core_req_t   core_req_payload;

    logic        core_resp_valid_i;   // unused for now
    logic        core_resp_valid;
    core_resp_t  core_resp_payload;

    assign core_resp_valid_i = 1'b0;

    cache_ctrl dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .core_req_ready_o     (core_req_ready),
        .core_req_valid_i     (core_req_valid),
        .core_req_payload_i   (core_req_payload),
        .core_resp_valid_i    (core_resp_valid_i),
        .core_resp_valid_o    (core_resp_valid),
        .core_resp_payload_o  (core_resp_payload)
    );

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    // Drive a single request and wait for the response.
    // Returns the response data for reads.
    task automatic send_req (
        input  core_rw_t           rw,
        input  logic [31:0]        addr,
        input  logic [31:0]        wdata,
        input  logic [3:0]         strb,
        output logic [31:0]        rdata,
        output logic               got_resp
    );
        // Wait until cache is ready
        @(posedge clk);
        while (!core_req_ready) @(posedge clk);

        // Present request
        #1;
        core_req_valid          = 1'b1;
        core_req_payload.rw     = rw;
        core_req_payload.addr   = addr;
        core_req_payload.data   = wdata;
        core_req_payload.strb   = strb;

        // Wait for handshake
        @(posedge clk);
        #1;
        core_req_valid = 1'b0;
        core_req_payload = '0;

        // Wait for response — sample BEFORE the clock edge since
        // resp_valid is combinatorial (asserted during S_HIT, cleared
        // when FSM returns to S_IDLE on the next rising edge)
        got_resp = 1'b0;
        rdata    = '0;
        repeat(5) begin
            @(posedge clk);
            #1; // small delta — let combinatorial outputs settle
            if (core_resp_valid) begin
                got_resp = 1'b1;
                rdata    = core_resp_payload.data;
                disable send_req;
            end
        end
    endtask

    // Plant a valid cache line directly into the SRAM (backdoor)
    task automatic backdoor_plant (
        input logic [31:0]        addr,
        input logic [127:0]       line_data
    );
        logic [9:0]  index;
        logic [17:0] tag;
        cache_line_t line;

        index          = addr[13:4];
        tag            = addr[31:14];
        line.valid     = 1'b1;
        line.dirty     = 1'b0;
        line.tag       = tag;
        line.data      = line_data;

        dut.cmem.mem[index] = line;
    endtask

    // ----------------------------------------------------------------
    // Scoreboard / checker
    // ----------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;

    task automatic check (
        input string       test_name,
        input logic        got_resp,
        input logic        exp_resp,
        input logic [31:0] got_data,
        input logic [31:0] exp_data,
        input logic        check_data  // only meaningful on reads
    );
        if (got_resp !== exp_resp) begin
            $display("FAIL [%s] resp_valid: got=%0b exp=%0b", test_name, got_resp, exp_resp);
            fail_count++;
        end else if (check_data && got_resp && (got_data !== exp_data)) begin
            $display("FAIL [%s] data: got=0x%08h exp=0x%08h", test_name, got_data, exp_data);
            fail_count++;
        end else begin
            $display("PASS [%s]", test_name);
            pass_count++;
        end
    endtask

    // ----------------------------------------------------------------
    // Test sequence
    // ----------------------------------------------------------------
    logic [31:0] rdata;
    logic        got_resp;
    logic [31:0] addr_a_w1;
    logic [31:0] addr_tag_mismatch;

    // Addresses crafted so they are easy to reason about:
    //   OFFSET = addr[3:0], INDEX = addr[13:4], TAG = addr[31:14]
    localparam logic [31:0] ADDR_A = 32'h0000_1000; // index=0x100, tag=0
    localparam logic [31:0] ADDR_B = 32'h0000_2000; // index=0x200, tag=0

    initial begin
        // Initialise inputs
        core_req_valid   = 0;
        core_req_payload = '0;

        // ── Reset ────────────────────────────────────────────────────
        do_reset();
        $display("\n=== Reset done ===\n");

        // ── Test 1: Cold read miss ────────────────────────────────────
        // SRAM contents are undefined after reset; valid bit is 0 so miss
        send_req(CORE_RD, ADDR_A, '0, 4'hF, rdata, got_resp);
        // Miss → FSM goes IDLE→TAG_CHECK→MISS→IDLE, no resp_valid asserted
        check("T1 cold read miss", got_resp, 1'b0, rdata, '0, 1'b0);

        // ── Test 2: Cold write miss ───────────────────────────────────
        send_req(CORE_WR, ADDR_A, 32'hDEAD_BEEF, 4'hF, rdata, got_resp);
        check("T2 cold write miss", got_resp, 1'b0, rdata, '0, 1'b0);

        // ── Test 3: Read HIT ─────────────────────────────────────────
        // Plant a line at ADDR_A with known data
        // Line data layout: word0 at byte offset 0, word1 at offset 4, ...
        // We put 0xCAFEBABE at word offset 0 (addr[3:2]=00 → byte offset 0)
        backdoor_plant(ADDR_A, 128'hDEAD_BEEF_CAFE_BABE_1234_5678_CAFE_BABE);
        send_req(CORE_RD, ADDR_A, '0, 4'hF, rdata, got_resp);
        // Word at byte offset 0 = bits [31:0] of line data
        check("T3 read hit", got_resp, 1'b1, rdata, 32'hCAFE_BABE, 1'b1);

        // ── Test 4: Read HIT different word in same line ──────────────
        // Read word at byte offset 4 (addr[3:0] = 4'h4)
        addr_a_w1 = ADDR_A | 32'h4;  // same index/tag, offset=4
        send_req(CORE_RD, addr_a_w1, '0, 4'hF, rdata, got_resp);
        // bits [63:32] of line = 32'h1234_5678
        check("T4 read hit word1", got_resp, 1'b1, rdata, 32'h1234_5678, 1'b1);

        // ── Test 5: Write HIT — full word ────────────────────────────
        // Overwrite word0 of ADDR_A with 0x12345678, all byte enables
        send_req(CORE_WR, ADDR_A, 32'h1234_5678, 4'hF, rdata, got_resp);
        check("T5 write hit ack", got_resp, 1'b1, rdata, '0, 1'b0);

        // Verify the write stuck: read back word0
        send_req(CORE_RD, ADDR_A, '0, 4'hF, rdata, got_resp);
        check("T5 write hit verify", got_resp, 1'b1, rdata, 32'h1234_5678, 1'b1);

        // ── Test 6: Write HIT — partial strobe (low byte only) ────────
        // Plant fresh line: word0 = 0xAABBCCDD
        backdoor_plant(ADDR_A, 128'h0000_0000_0000_0000_0000_0000_AABB_CCDD);
        // Write 0xFF to byte 0 only (strb=4'b0001)
        send_req(CORE_WR, ADDR_A, 32'h0000_00FF, 4'b0001, rdata, got_resp);
        check("T6 partial write ack", got_resp, 1'b1, rdata, '0, 1'b0);
        // Expected word0 = 0xAABBCCFF (only byte0 changed)
        send_req(CORE_RD, ADDR_A, '0, 4'hF, rdata, got_resp);
        check("T6 partial write verify", got_resp, 1'b1, rdata, 32'hAABB_CCFF, 1'b1);

        // ── Test 7: Different index, read hit ─────────────────────────
        backdoor_plant(ADDR_B, 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_BEEF_CAFE);
        send_req(CORE_RD, ADDR_B, '0, 4'hF, rdata, got_resp);
        check("T7 read hit addr B", got_resp, 1'b1, rdata, 32'hBEEF_CAFE, 1'b1);

        // ── Test 8: Tag mismatch → miss ───────────────────────────────
        // Same index as ADDR_A but different tag (bit 14 set)
        addr_tag_mismatch = ADDR_A | 32'h0000_4000; // tag bit 14 set
        send_req(CORE_RD, addr_tag_mismatch, '0, 4'hF, rdata, got_resp);
        check("T8 tag mismatch miss", got_resp, 1'b0, rdata, '0, 1'b0);

        // ── Summary ──────────────────────────────────────────────────
        $display("\n=== Results: %0d PASS, %0d FAIL ===\n", pass_count, fail_count);

        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    // ----------------------------------------------------------------
    // Timeout watchdog
    // ----------------------------------------------------------------
    initial begin
        #10000;
        $display("TIMEOUT — simulation hung");
        $finish;
    end

    // ----------------------------------------------------------------
    // Waveform dump (works with VCS, Xcelium, Verilator, ModelSim)
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("cache_ctrl_tb.vcd");
        $dumpvars(0, cache_ctrl_tb);
    end

endmodule : cache_ctrl_tb