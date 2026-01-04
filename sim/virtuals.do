virtual type { \
SFS_IDLE\
SFS_SEND_CMD\
SFS_SEND_ADDR\
SFS_READ_DATA\
SFS_POST_READ\
} state_type1
virtual function -install /tb_spi_flash_stream/u_dut -env /tb_spi_flash_stream { (state_type1)/tb_spi_flash_stream/u_dut/state} fsm_state2
