# ========================< 清空软件残留信息 >==============================

#1.exit modelsim simulation
quit -sim

#2.clear messages
# .main clear

#3.delete the existing work dir
if [file exists work] {vdel -all}

# =========================< 建立工程并仿真 >===============================

#4.建立新的工程库
vlib work

#5.映射逻辑库到物理目录
vmap work work

set ROOT ../rtl
set COMMON $ROOT/common
set AXI $ROOT/lib/verilog-axi
#6.编译仿真文件
vlog -work work ./tb_spi_flash_stream.v
vlog -work work $ROOT/spi_flash_stream.v
vlog -work work model/W25Q128JVxIM/W25Q128JVxIM.v

#7.start simulation
vsim -t ns -voptargs=+acc work.tb_spi_flash_stream
# =====================< 状态机名称,不用请删除 >=============================

# 结构体设置
virtual type { 
		{ 3'd0 S_IDLE } 
		{ 3'd1 S_SEND_HEADER}
		{ 3'd2 S_READ_DATA}
		{ 3'd3 S_FINISH}
	} state_type2;
virtual function {(state_type2)/tb_spi_flash_stream/u_dut/state} fsm_state2
# Load wave configuration from wave.do
do wave.do
# do wave_ghe.do

#9.run
# temp
run 1ms
