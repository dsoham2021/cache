SRC_PATH    = ../rtl
TOP_NAME    = cache_ctrl
TB_NAME     = cache_ctrl_tb
SNAPSHOT    = $(TB_NAME)_snapshot
XSIM_CFG    = Makefile_cfg_xsim.tcl

.PHONY: all sv_compile elaborate simulate simulate_dump clean

all: simulate

# ── Compile ──────────────────────────────────────────────────────────
# All files must be listed: pkg first (dependency order matters in SV)
sv_compile:
	xvlog -sv \
		$(SRC_PATH)/cache_pkg.sv \
		$(SRC_PATH)/cache_array.sv \
		$(SRC_PATH)/$(TOP_NAME).sv \
		$(SRC_PATH)/$(TB_NAME).sv

# ── Elaborate ────────────────────────────────────────────────────────
elaborate: sv_compile
	xelab -debug typical -top $(TB_NAME) -snapshot $(SNAPSHOT)

# ── Simulate (run to finish, no waveform) ────────────────────────────
simulate: elaborate
	xsim $(SNAPSHOT) -R

# ── Simulate + dump waveform, then open GUI ──────────────────────────
simulate_dump: elaborate
	xsim $(SNAPSHOT) -tclbatch $(XSIM_CFG)
	xsim --gui $(SNAPSHOT).wdb

# ── Clean ────────────────────────────────────────────────────────────
clean:
	find . -type f ! -name 'Makefile*' -delete
	rm -rf xsim.dir