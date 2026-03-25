`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Testbench top — wires DUT, mem_model, driver, monitor, scoreboard.
//
// Test sequence covers all 6 cases from the verification plan:
//   T1  : Read  hit
//   T2  : Write hit + readback
//   T3  : Read  miss, cold
//   T4  : Write miss, cold + readback
//   T5  : Read  miss, clean evict
//   T6  : Read  miss, dirty evict (write first, then conflict)
//   T7  : Partial strobe write + readback
//   T8  : All four word offsets within one cache line
//
// The driver mailbox is loaded with transactions from the initial
// block. The monitor observes all completions and feeds the
// scoreboard which checks every read against its reference model.
// ----------------------------------------------------------------
module cache_tb_top;

    localparam CLK_PERIOD = 10;

    logic clk, rst_n;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ----------------------------------------------------------------
    // Mailboxes
    // ----------------------------------------------------------------
    mailbox #(cache_trans_t) drv_mbx = new();  // tb_top → driver
    mailbox #(cache_trans_t) mon_mbx = new();  // monitor → scoreboard

    // ----------------------------------------------------------------
    // DUT signals
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

    logic        perf_clear;
    logic [2:0]  perf_addr;
    logic [31:0] perf_data;
    logic        done;

    // ----------------------------------------------------------------
    // DUT
    // ----------------------------------------------------------------
    cache_ctrl #(.INIT_FILE("cache_init.mem")) dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .core_req_ready_o    (core_req_ready),
        .core_req_valid_i    (core_req_valid),
        .core_req_payload_i  (core_req_payload),
        .core_resp_valid_i   (1'b0),
        .core_resp_valid_o   (core_resp_valid),
        .core_resp_payload_o (core_resp_payload),
        .perf_clear_i        (perf_clear),
        .perf_addr_i         (perf_addr),
        .perf_data_o         (perf_data),
        .mem_req_valid_o     (mem_req_valid),
        .mem_req_rw_o        (mem_req_rw),
        .mem_req_addr_o      (mem_req_addr),
        .mem_req_data_o      (mem_req_data),
        .mem_req_ready_i     (mem_req_ready),
        .mem_resp_valid_i    (mem_resp_valid),
        .mem_resp_data_i     (mem_resp_data)
    );

    // ----------------------------------------------------------------
    // Memory model
    // ----------------------------------------------------------------
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
    // Driver
    // ----------------------------------------------------------------
    cache_driver u_drv (
        .clk               (clk),
        .rst_n             (rst_n),
        .drv_mbx           (drv_mbx),
        .core_req_ready_i  (core_req_ready),
        .core_req_valid_o  (core_req_valid),
        .core_req_payload_o(core_req_payload)
    );

    // ----------------------------------------------------------------
    // Monitor
    // ----------------------------------------------------------------
    cache_monitor u_mon (
        .clk                 (clk),
        .rst_n               (rst_n),
        .core_req_ready_i    (core_req_ready),
        .core_req_valid_i    (core_req_valid),
        .core_req_payload_i  (core_req_payload),
        .core_resp_valid_i   (core_resp_valid),
        .core_resp_payload_i (core_resp_payload),
        .mon_mbx             (mon_mbx)
    );

    // ----------------------------------------------------------------
    // Scoreboard
    // ----------------------------------------------------------------
    cache_scoreboard u_sb (
        .clk     (clk),
        .rst_n   (rst_n),
        .done_i  (done),
        .mon_mbx (mon_mbx)
    );

    // ----------------------------------------------------------------
    // Helpers — push one transaction into driver mailbox
    // ----------------------------------------------------------------
    task automatic send(
        input core_rw_t    rw,
        input logic [31:0] addr,
        input logic [31:0] wdata,
        input logic [3:0]  strb
    );
        cache_trans_t tr;
        tr.rw       = rw;
        tr.addr     = addr;
        tr.wdata    = wdata;
        tr.strb     = strb;
        tr.rdata    = '0;
        tr.got_resp = 1'b0;
        drv_mbx.put(tr);
    endtask

    // Wait until driver mailbox is empty and DUT is idle
    task automatic wait_drain();
        while (drv_mbx.num() > 0)   @(posedge clk);
        while (!core_req_ready)      @(posedge clk);
        repeat(20) @(posedge clk);  // let last response propagate to SB
    endtask

    // ----------------------------------------------------------------
    // Addresses
    //   ADDR_A  tag=0 idx=0x100  pre-loaded word0=0xAAAAAAAA
    //   ADDR_B  tag=0 idx=0x200  pre-loaded word0=0xBBBBBBBB
    //   ADDR_C  tag=0 idx=0x300  cold
    //   ADDR_CX tag=1 idx=0x300  conflicts ADDR_C
    //   ADDR_D  tag=0 idx=0x400  cold (used for offset tests)
    // ----------------------------------------------------------------
    localparam logic [31:0] ADDR_A  = 32'h0000_1000;
    localparam logic [31:0] ADDR_B  = 32'h0000_2000;
    localparam logic [31:0] ADDR_C  = 32'h0000_3000;
    localparam logic [31:0] ADDR_CX = 32'h0004_3000;
    localparam logic [31:0] ADDR_D  = 32'h0000_4000;

    // ----------------------------------------------------------------
    // Test sequence
    // ----------------------------------------------------------------
    initial begin
        perf_clear = 0;
        perf_addr  = 0;
        done       = 0;
        rst_n      = 0;
        repeat(4) @(posedge clk);
        #1; rst_n = 1;
        @(posedge clk);
        $display("=== Reset done ===\n");

        // ── T1: Read hit ──────────────────────────────────────────────
        $display("-- T1: Read hit --");
        send(CORE_RD, ADDR_A, '0, 4'hF);
        wait_drain();

        // ── T2: Write hit + readback ──────────────────────────────────
        $display("-- T2: Write hit --");
        send(CORE_WR, ADDR_A, 32'h1234_5678, 4'hF);
        send(CORE_RD, ADDR_A, '0, 4'hF);
        wait_drain();

        // ── T3: Read miss, cold ───────────────────────────────────────
        $display("-- T3: Read miss cold --");
        send(CORE_RD, ADDR_C, '0, 4'hF);
        wait_drain();

        // ── T4: Write miss, cold + readback ───────────────────────────
        $display("-- T4: Write miss cold --");
        send(CORE_WR, ADDR_B, 32'hDEAD_BEEF, 4'hF);
        send(CORE_RD, ADDR_B, '0, 4'hF);
        wait_drain();

        // ── T5: Read miss, clean evict ────────────────────────────────
        // ADDR_C is clean in cache, ADDR_CX conflicts it
        $display("-- T5: Read miss clean evict --");
        send(CORE_RD, ADDR_CX, '0, 4'hF);
        wait_drain();

        // ── T6: Read miss, dirty evict ────────────────────────────────
        // Reload ADDR_C, write to make dirty, then conflict
        $display("-- T6: Read miss dirty evict --");
        send(CORE_RD, ADDR_C,  '0,            4'hF);  // reload
        send(CORE_WR, ADDR_C,  32'hCAFE_BABE, 4'hF);  // make dirty
        send(CORE_RD, ADDR_CX, '0,            4'hF);  // conflict → evict
        wait_drain();

        // ── T7: Partial strobe write + readback ───────────────────────
        // Write only byte 0 of ADDR_D (cold miss first, then strb write)
        $display("-- T7: Partial strobe write --");
        send(CORE_RD, ADDR_D, '0,           4'hF);   // cold miss, fill line
        send(CORE_WR, ADDR_D, 32'hXX_XX_XX_FF, 4'b0001); // write byte 0 only
        send(CORE_RD, ADDR_D, '0,           4'hF);   // read back
        wait_drain();

        // ── T8: All four word offsets within one cache line ───────────
        $display("-- T8: All word offsets --");
        send(CORE_RD, ADDR_A | 32'h0, '0, 4'hF);  // offset 0
        send(CORE_RD, ADDR_A | 32'h4, '0, 4'hF);  // offset 4
        send(CORE_RD, ADDR_A | 32'h8, '0, 4'hF);  // offset 8
        send(CORE_RD, ADDR_A | 32'hC, '0, 4'hF);  // offset 12
        wait_drain();

        // ── Performance counters ──────────────────────────────────────
        $display("\n=== Performance Counters ===");
        perf_addr = 3'd0; #1; $display("  Total requests : %0d", perf_data);
        perf_addr = 3'd1; #1; $display("  Hits           : %0d", perf_data);
        perf_addr = 3'd2; #1; $display("  Misses         : %0d", perf_data);
        perf_addr = 3'd3; #1; $display("  Evictions      : %0d", perf_data);
        perf_addr = 3'd4; #1; $display("  Hit rate       : %0d/256 (%0d%%)",
                                perf_data, (perf_data * 100) / 256);

        done = 1;
        repeat(10) @(posedge clk);
        $display("\n=== Done ===");
        $finish;
    end

    // Mem bus activity monitor
    always @(posedge clk) begin
        if (mem_req_valid && mem_req_ready) begin
            if (mem_req_rw)
                $display("  [MEM] EVICT WRITE addr=0x%08h", mem_req_addr);
            else
                $display("  [MEM] REFILL READ  addr=0x%08h", mem_req_addr);
        end
    end

    initial begin #100000; $display("TIMEOUT"); $finish; end

    initial begin
        $dumpfile("cache_tb_top.vcd");
        $dumpvars(0, cache_tb_top);
    end

endmodule : cache_tb_top