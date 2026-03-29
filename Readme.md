# Direct-Mapped Write-Back Cache Controller

A fully synthesisable direct-mapped write-back cache controller implemented in SystemVerilog, with a structured verification environment using the driver/monitor/scoreboard pattern.

---

## Project Structure

```
cache/
├── rtl/
│   ├── cache_pkg.sv        # Types, parameters, FSM state enum
│   ├── cache_array.sv      # Synchronous SRAM model (148-bit wide)
│   ├── cache_perf.sv       # Saturating performance counters
│   └── cache_ctrl.sv       # Main cache controller (top-level RTL)
│
├── tb/
│   ├── cache_transaction.sv  # Transaction descriptor struct
│   ├── mem_model.sv          # Lower-level memory model (3–6 cycle latency)
│   ├── cache_driver.sv       # Core request driver
│   ├── cache_monitor.sv      # Passive interface observer
│   ├── cache_scoreboard.sv   # Reference model and checker
│   └── cache_tb_top.sv       # Testbench top — wires everything together
│
├── sim/
│   ├── Makefile
│   ├── cache_init.mem
|   └── Makefile_cfg_xsim.tcl
│
└── doc/
    └── report.pdf     # Project report
```


---

## Simulation

### Requirements

- Vivado 2023.1 (xvlog / xelab / xsim)
- GNU Make

### Running

```bash
cd sim/

# Compile + elaborate + simulate (no waveform)
make

# Compile + elaborate + simulate + open waveform GUI
make simulate_dump

# Clean build artefacts
make clean
```


---

## Cache Parameters

| Parameter    | Value  | Description                        |
|--------------|--------|------------------------------------|
| `ADDR_W`     | 32     | Physical address width (bits)      |
| `NUM_SETS`   | 1024   | Number of cache sets               |
| `LINE_BYTES` | 16     | Cache line size (bytes)            |
| `WORD_SIZE`  | 4      | Word size (bytes)                  |
| `OFFSET_W`   | 4      | Byte offset field width (bits)     |
| `INDEX_W`    | 10     | Index field width (bits)           |
| `TAG_W`      | 18     | Tag field width (bits)             |

Address breakdown: `addr[31:14]` = tag, `addr[13:4]` = index, `addr[3:0]` = byte offset.

---

## FSM States

```
S_IDLE ──(handshake)──► S_TAG_CHECK ──(hit)──────────────► S_HIT ──► S_IDLE
                               │
                               ├──(miss, clean evict)──► S_MISS ──► S_REFILL ──► S_IDLE
                               │
                               └──(miss, dirty evict)──► S_EVICT ──► S_MISS ──► S_REFILL ──► S_IDLE
```

| State         | Description                                                    |
|---------------|----------------------------------------------------------------|
| `S_IDLE`      | Ready for new request. SRAM address driven combinatorially.    |
| `S_TAG_CHECK` | SRAM output valid. Tag comparison and hit/miss evaluated.      |
| `S_HIT`       | Respond to core. Write merged line back to SRAM on CORE_WR.   |
| `S_EVICT`     | Write dirty line to memory bus before fetching new line.       |
| `S_MISS`      | Issue refill read request to memory bus. Wait for bus grant.   |
| `S_REFILL`    | Wait for memory response. Fill-and-forward to core and SRAM.  |

Hit latency: **3 cycles**. Miss latency: **3 + memory latency cycles**.

---

## Memory Bus Interface

```
Cache → Memory (request):
  mem_req_valid_o   — request valid
  mem_req_rw_o      — 0 = refill read, 1 = eviction write
  mem_req_addr_o    — cache-line-aligned address
  mem_req_data_o    — eviction data (write only)
  mem_req_ready_i   — bus grant (one cycle pulse)

Memory → Cache (response):
  mem_resp_valid_i  — refill data valid (one cycle pulse)
  mem_resp_data_i   — 128-bit refill line
```

---

## Performance Counter Interface

Registers are word-addressed via `perf_addr_i` (3-bit), read on `perf_data_o` (32-bit):

| Address | Register      | Description                              |
|---------|---------------|------------------------------------------|
| `0`     | total_reqs    | Total requests accepted                  |
| `1`     | hits          | Cache hits                               |
| `2`     | misses        | Cache misses (includes evictions)        |
| `3`     | evictions     | Dirty evictions                          |
| `4`     | hit_rate      | (hits × 256) / total_reqs  (256 = 100%) |

Assert `perf_clear_i` for one cycle to reset all counters synchronously.



---

## SRAM Initialisation File

`sim/cache_init.mem` is a 1024-line `$readmemh` file (one 37-hex-digit entry per set). Two sets are pre-loaded:

| Index  | Address      | word0        |
|--------|--------------|--------------|
| `0x100`| `0x0000_1000`| `0xAAAAAAAA` |
| `0x200`| `0x0000_2000`| `0xBBBBBBBB` |

All other sets default to `valid=0` (cold miss on first access).

---

## Design Notes

**Why no extra S_READ state?**
The SRAM read address is driven combinatorially from the live incoming request during `S_IDLE`, so the SRAM captures the address on the handshake clock edge. The output is valid by the time the FSM reaches `S_TAG_CHECK` — one cycle later. This avoids a dedicated read-wait state and keeps hit latency at 3 cycles.

**Why PIPT and not VIPT?**
The design targets embedded systems where virtual memory is absent. With the current geometry (`INDEX_HI = 13`), index bits extend beyond the 12-bit 4KB page offset boundary, making a naive VIPT implementation non-alias-free. PIPT is the correct and safe choice for this domain.

**Saturating counters**
Performance counters saturate at `2^32 - 1` rather than wrapping. A wrapping counter would produce a completely wrong hit rate after 4 billion events — saturation gives a conservative but honest reading.