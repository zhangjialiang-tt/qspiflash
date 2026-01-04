config wave -signalnamewidth 1

add wave -divider "tb"
add wave -group tb              -radix unsigned tb_spi_flash_stream/*
add wave -group dut              -radix unsigned tb_spi_flash_stream/u_dut/*
add wave -color pink            /tb_spi_flash_stream/u_dut/fsm_state2
# add wave -group rect              -radix unsigned tb/rect_inst/*
# add wave -group top             -radix unsigned tb/dut/*
# # add wave -group vga             -radix unsigned tb/dut/i_vga_timing/*
# add wave -divider "bridge"
# add wave -group axi_video_bridge    -radix unsigned tb/dut/*
# add wave -group wr_path             -radix unsigned tb/dut/inst_axis_wr_path_new/*
# add wave -group rd_path             -radix unsigned tb/dut/inst_axis_rd_path_new/*
# add wave -group dma                 -radix unsigned tb/dut/inst_axi_dma/*
# add wave -group fifo            -radix unsigned tb/dut/wr_path_inst/u_dc_fifo/*
# add wave -divider "dma"
# add wave -group axi_dma         -radix unsigned tb/dut/i_axi_dma/*
# add wave -group axi_dma_wr      -radix unsigned tb/dut/i_axi_dma/axi_dma_wr_inst/*
# add wave -group axi_dma_rd      -radix unsigned tb/dut/i_axi_dma/axi_dma_rd_inst/*
