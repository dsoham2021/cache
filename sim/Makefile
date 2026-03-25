SRC_PATH    = ../rtl
TB_PATH     = ../tb
SNAPSHOT    = cache_tb_top_snapshot
XSIM_CFG    = Makefile_cfg_xsim.tcl

.PHONY: all compile elaborate simulate simulate_dump clean

all: simulate

compile:
	xvlog -sv \
		$(SRC_PATH)/cache_pkg.sv \
		$(SRC_PATH)/cache_array.sv \
		$(SRC_PATH)/cache_perf.sv \
		$(SRC_PATH)/cache_ctrl.sv \
		$(TB_PATH)/cache_transaction.sv \
		$(TB_PATH)/mem_model.sv \
		$(TB_PATH)/cache_driver.sv \
		$(TB_PATH)/cache_monitor.sv \
		$(TB_PATH)/cache_scoreboard.sv \
		$(TB_PATH)/cache_tb_top.sv

elaborate: compile
	xelab -debug typical -top cache_tb_top -snapshot $(SNAPSHOT)

simulate: elaborate
	xsim $(SNAPSHOT) -R

simulate_dump: elaborate
	xsim $(SNAPSHOT) -tclbatch $(XSIM_CFG)
	xsim --gui $(SNAPSHOT).wdb

clean:
	find . -type f ! -name 'Makefile' ! -name '*.tcl' ! -name '*.mem' -delete
	rm -rf xsim.dir