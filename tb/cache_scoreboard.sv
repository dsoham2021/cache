`timescale 1ns/1ps
import cache_pkg::*;

// ----------------------------------------------------------------
// Scoreboard — reference model and checker.
//
// Maintains a software associative array (ref_mem) that tracks the
// expected value at every word address that has been written.
//
// On every completed transaction from the monitor mailbox:
//   CORE_WR → update ref_mem[addr] with the written data (strb-aware)
//   CORE_RD → check rdata against ref_mem[addr]
//             if addr not in ref_mem, check against mem_model pattern:
//             word[w] = {addr[31:8], w[7:0]} (matches mem_model gen_data)
//
// Prints PASS/FAIL for every transaction and a summary at the end.
// ----------------------------------------------------------------
module cache_scoreboard (
    input  logic    clk,
    input  logic    rst_n,
    input  logic    done_i,     // pulsed by tb_top when all transactions sent

    ref    mailbox #(cache_trans_t) mon_mbx
);

    // Software reference model: word-address → expected 32-bit value
    logic [31:0] ref_mem [logic [31:0]];

    int pass_count = 0;
    int fail_count = 0;

    // Expected data from mem_model for a cold address (never written)
    // Matches gen_data() in mem_model: word[w] = {addr[31:8], w[7:0]}
    function automatic logic [31:0] cold_expected(logic [31:0] addr);
        logic [1:0] word_idx;
        word_idx = addr[3:2];   // byte offset → word index
        return {addr[31:8], 6'h0, word_idx};
    endfunction

    // Apply strb-masked write to a base value
    function automatic logic [31:0] apply_strb(
        logic [31:0] base,
        logic [31:0] wdata,
        logic [3:0]  strb
    );
        logic [31:0] result;
        result = base;
        for (int b = 0; b < 4; b++)
            if (strb[b]) result[b*8 +: 8] = wdata[b*8 +: 8];
        return result;
    endfunction

    initial begin
        @(posedge rst_n);

        forever begin
            cache_trans_t tr;

            // Block until monitor delivers a transaction
            mon_mbx.get(tr);

            if (tr.rw == CORE_WR) begin
                // ── Write: update reference model ─────────────────────
                logic [31:0] base;
                // If never written before, seed from mem_model pattern
                if (!ref_mem.exists(tr.addr))
                    base = cold_expected(tr.addr);
                else
                    base = ref_mem[tr.addr];

                ref_mem[tr.addr] = apply_strb(base, tr.wdata, tr.strb);
                $display("SB  WR  addr=0x%08h data=0x%08h → ref updated",
                    tr.addr, ref_mem[tr.addr]);

            end else begin
                // ── Read: check against reference model ───────────────
                logic [31:0] expected;

                if (ref_mem.exists(tr.addr))
                    expected = ref_mem[tr.addr];
                else
                    expected = cold_expected(tr.addr);

                if (!tr.got_resp) begin
                    $display("FAIL RD  addr=0x%08h — no response received", tr.addr);
                    fail_count++;
                end else if (tr.rdata === expected) begin
                    $display("PASS RD  addr=0x%08h got=0x%08h exp=0x%08h",
                        tr.addr, tr.rdata, expected);
                    pass_count++;
                end else begin
                    $display("FAIL RD  addr=0x%08h got=0x%08h exp=0x%08h",
                        tr.addr, tr.rdata, expected);
                    fail_count++;
                end
            end

            // Exit once done and mailbox is drained
            if (done_i && mon_mbx.num() == 0) break;
        end

        $display("\n=== Scoreboard: %0d PASS  %0d FAIL ===", pass_count, fail_count);
    end

endmodule : cache_scoreboard