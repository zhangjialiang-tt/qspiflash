////////////////////////////////////////////////////////////////////////////////
//
// 文件名: 	spi_flash_stream.v
// {{{
// 项目:	流式 SPI Flash 控制器
//
// 目的:	该模块旨在作为一个低逻辑资源消耗的 Flash 控制器，
//       用于从 SPI Flash 中读取数据并以流式方式输出。
//       它使用来自 Flash 的 8'h03 读取命令，因此不能用于
//       时钟频率高于 50MHz 的场合。
//
// 功能:
//  该控制器支持通过地址和长度指定的块读取操作。
//  读取的数据以流式方式输出，无需握手信号。
//
// 接口信号:
//  - i_start_read: 开始读取信号
//  - i_addr: 要读取的起始地址 (24位)
//  - i_length: 要读取的字节数 (24位)
//  - o_data: 输出数据 (8位)
//  - o_valid: 输出数据有效信号
//  - o_done: 读取完成信号
//  - o_spi_cs_n, o_spi_sck, o_spi_mosi: SPI控制信号
//  - i_spi_miso: SPI输入数据
//
// SPI协议:
//  该控制器使用标准SPI协议与Flash通信，使用8'h03命令进行标准读取操作。
//  通信序列: CS拉低 -> 发送命令(0x03) -> 发送24位地址 -> 等待 -> 接收数据
//
// 创建者:	Modified from spixpress.v by Qwen Code
//		基于 Gisselquist Technology, LLC 的原始设计
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// 版权所有 (C) 2018-2021, Gisselquist Technology, LLC
// {{{
// 该文件是 SPI Flash 控制器项目的一部分
//
// SPI Flash 控制器项目是自由软件(固件):
// 您可以重新分发和/或根据 GNU 较宽松公共许可证的条款
// 进行修改，由自由软件基金会发布，许可证版本为 3，
// 或(根据您的选择)任何更高版本。
//
// SPI Flash 控制器项目发布是希望它会有用，
// 但没有任何保证;甚至没有适销性或特定用途适用性的
// 隐含保证。有关详细信息，请参见 GNU 较宽松公共许可证。
//
// 您应该已收到 GNU 较宽松公共许可证的副本
// 与本程序一起。(它在 $(ROOT)/doc 目录中。如果 PDF
// 文件不存在，请在该目录中运行不带目标的 make。) 如果没有，请参见
// <http://www.gnu.org/licenses/> 获取副本。
// }}}
// 许可证:	LGPL, v3, 在 www.gnu.org 上定义和找到,
// {{{
//		http://www.gnu.org/licenses/lgpl.html
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
// }}}
module	spi_flash_stream (
		// {{{
		input	wire		i_clk, i_reset,
		// 控制信号
		input	wire		i_start_read,
		input	wire	[23:0]	i_addr,
		input	wire	[23:0]	i_length,
		// 流式输出
		output	reg	[7:0]	o_data,
		output	reg		o_valid,
		output	reg		o_done,
		// SPI 接口
		output	reg		o_spi_cs_n, o_spi_sck, o_spi_mosi,
		input	wire		i_spi_miso
		// }}}
	);

	// 信号声明
	// {{{
	reg	[32:0]	wdata_pipe;  // 包含命令、地址和数据的移位寄存器
	reg		actual_sck;     // 实际SCK信号（延迟一个时钟）

	// 内部状态机控制
	reg	[3:0]	state;        // 状态机状态
	reg	[23:0]	current_addr; // 当前读取地址
	reg	[23:0]	remaining_bytes; // 剩余字节数
	reg	[4:0]	bit_count;    // 位计数器
	reg	[23:0]	addr_byte_count; // 地址字节计数器
	reg		data_ready;     // 数据准备好标志
	reg	[7:0]	temp_data;    // 临时数据寄存器
	// }}}

	// 状态定义
	localparam	IDLE_STATE = 4'd0,
			SEND_CMD_STATE = 4'd1,
			SEND_ADDR_STATE = 4'd2,
			READ_DATA_STATE = 4'd3,
			POST_READ_STATE = 4'd4;


	// wdata_pipe - 移位寄存器，用于发送命令和地址
	// {{{
	// wdata_pipe 是一个长移位寄存器，包含需要发送到SPI端口的值。
	// 基本事务需要发送 8'h03 (读取) 命令，后跟 24 位地址。
	initial	wdata_pipe = 0;
	always @(posedge i_clk)
	if (i_reset)
		wdata_pipe <= 0;
	else if (state == IDLE_STATE && i_start_read)
		// 在开始读取时，设置命令和地址
		wdata_pipe <= { 1'b0, 8'h03, i_addr[23:0] };  // 33位: 1位填充 + 8位命令 + 24位地址
	else if (o_spi_sck && !actual_sck)  // 在SCK上升沿时移位
		// 在时钟上升沿时，移位寄存器左移
		wdata_pipe <= { wdata_pipe[31:0], i_spi_miso };
	// }}}

	// 发送到 Flash 的输出位简单地由这个 wdata_pipe 移位寄存器的最高位给出。
	always @(*)
		o_spi_mosi = wdata_pipe[32];

	// actual_sck
	// {{{
	// Actual_sck (SCK, 但延迟一个时钟)
	//
	// 这是硬件看到的 SCK 信号
	initial	actual_sck = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		actual_sck <= 1'b0;
	else
		// 我们的 SCK 信号比我们请求传输 SCK 的时钟延迟一个时钟。
		// 我们在这里创建一个延迟副本，这样我们就能知道实际的
		// SCK 在做什么。
		actual_sck <= o_spi_sck;
	// }}}

	// 状态机控制
	// {{{
	initial state = IDLE_STATE;
	always @(posedge i_clk)
	if (i_reset) begin
		state <= IDLE_STATE;
		current_addr <= 0;
		remaining_bytes <= 0;
		data_ready <= 0;
		temp_data <= 0;
		o_done <= 0;
		bit_count <= 0;
		addr_byte_count <= 0;
	end
	else begin
		case (state)
			IDLE_STATE: begin
				o_done <= 0;
				if (i_start_read) begin
					current_addr <= i_addr;
					remaining_bytes <= i_length;
					bit_count <= 0;
					addr_byte_count <= 0;
					wdata_pipe <= { 1'b0, 8'h03, current_addr[23:0] };  // 设置初始命令和地址
					state <= SEND_CMD_STATE;
				end
			end

			SEND_CMD_STATE: begin
				// 发送读取命令 (8'h03) - 8位
				if (o_spi_sck && !actual_sck) begin  // 在SCK上升沿移位
					wdata_pipe <= { wdata_pipe[31:0], 1'b0 };  // 移位发送命令位
					bit_count <= bit_count + 1'b1;
					if (bit_count == 7) begin  // 8位发送完成
						bit_count <= 0;
						addr_byte_count <= 0;  // 重置地址字节计数
						state <= SEND_ADDR_STATE;
					end
				end
			end

			SEND_ADDR_STATE: begin
				// 发送24位地址 - 每次发送8位
				if (o_spi_sck && !actual_sck) begin  // 在SCK上升沿移位
					wdata_pipe <= { wdata_pipe[31:0], 1'b0 };  // 移位发送地址位
					bit_count <= bit_count + 1'b1;
					if (bit_count == 7) begin  // 8位发送完成
						bit_count <= 0;
						addr_byte_count <= addr_byte_count + 1'b1;
						if (addr_byte_count == 2) begin  // 3个字节(24位)发送完成 (0,1,2 = 3个字节)
							// 地址发送完成后，立即进入读取状态
							// SPI Flash在发送完地址后，下一个时钟周期开始输出数据
							bit_count <= 0;
							state <= READ_DATA_STATE;
						end
					end
				end
			end

			READ_DATA_STATE: begin
				// 读取数据字节 - 8位
				if (o_spi_sck && !actual_sck) begin  // 在SCK上升沿移位
					wdata_pipe <= { wdata_pipe[31:0], i_spi_miso };  // 移位接收数据
					bit_count <= bit_count + 1'b1;
					if (bit_count == 7) begin  // 8位接收完成
						// 数据已接收完成
						temp_data <= { wdata_pipe[7:0] };  // 从移位寄存器获取读取的数据
						data_ready <= 1;
						remaining_bytes <= remaining_bytes - 1'b1;
						current_addr <= current_addr + 1'b1;
						bit_count <= 0;

						if (remaining_bytes > 1'b1) begin
							// 还有更多字节要读取，继续读取下一个字节
							// 为下一个字节重新设置命令和地址
							wdata_pipe <= { 1'b0, 8'h03, current_addr + 1'b1 };
							// 重新开始发送命令阶段
							state <= SEND_CMD_STATE;
						end
						else begin
							// 读取完成
							state <= POST_READ_STATE;
						end
					end
				end
			end

			POST_READ_STATE: begin
				// 完成读取操作
				o_done <= 1;
				data_ready <= 0;
				state <= IDLE_STATE;
			end

			default: state <= IDLE_STATE;
		endcase
	end
	// }}}

	// SPI 信号控制
	// {{{
	// CSN / o_spi_cs_n
	// 这是负逻辑芯片选择。
	initial	o_spi_cs_n = 1'b1;
	always @(posedge i_clk)
	if (i_reset)
		// 复位时空闲
		o_spi_cs_n <= 1'b1;
	else if (state == IDLE_STATE)
		// 空闲时保持CS高电平（非激活）
		o_spi_cs_n <= 1'b1;
	else if (state == SEND_CMD_STATE)
		// 开始传输时激活CS
		o_spi_cs_n <= 1'b0;
	else if (state == POST_READ_STATE)
		// 传输完成后禁用CS
		o_spi_cs_n <= 1'b1;

	// o_spi_sck / SCK
	// SPI时钟信号
	initial	o_spi_sck = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_spi_sck <= 1'b0;
	else if (state == SEND_CMD_STATE || state == SEND_ADDR_STATE || state == READ_DATA_STATE)
		// 在数据传输期间生成时钟
		o_spi_sck <= ~o_spi_sck;  // 翻转时钟
	else
		// 其他时间保持低电平
		o_spi_sck <= 1'b0;
	// }}}

	// 流式输出控制
	// {{{
	// o_data, o_valid
	// 当数据准备好时输出数据并置有效信号
	initial o_data = 0;
	initial o_valid = 0;
	always @(posedge i_clk)
	if (i_reset) begin
		o_data <= 0;
		o_valid <= 0;
	end
	else begin
		// 在读取数据状态的下一个时钟周期输出数据
		if (state == READ_DATA_STATE && bit_count == 7) begin
			// 在一个字节读取完成时输出数据
			o_data <= { wdata_pipe[7:0] };  // 输出从SPI接收的数据
			o_valid <= 1'b1;
		end
		else begin
			o_valid <= 1'b0;  // 仅在数据有效时置高
		end
	end
	// }}}

	// 让 Verilator 满意
	// {{{
	// verilator lint_off UNUSED
	// 没有未使用的信号，因为我们移除了Wishbone接口
	// verilator lint_on  UNUSED
	// }}}

endmodule