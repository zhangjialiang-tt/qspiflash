////////////////////////////////////////////////////////////////////////////////
//
// 文件名: 	spixpress.v
// {{{
// 项目:	一组由 Wishbone 控制的 SPI Flash 控制器
//
// 目的:	该模块旨在作为一个低逻辑资源消耗的 Flash 控制器。
// 		它使用来自 Flash 的 8'h03 读取命令，因此不能用于
// 		时钟频率高于 50MHz 的场合。
//
//	虽然该控制器没有直接的擦除或编程功能，但它包含一个控制端口。
//	通过使用控制端口，你应该能够向 Flash 发送任意命令——但在该时间内
//	不能从 Flash 进行正常的存储器读取。
//
// 配置项:
//	{{{
//	为了追求 *极低* 的逻辑资源消耗，控制器提供了 OPT_CFG 和 OPT_PIPE 选项。
//	如果两者都设置为 0，控制器将处于最低逻辑配置。也就是说，如果你将 OPT_CFG
//	设置为 0，你还必须将 i_cfg_stb 保持为 0——除非你期望在 i_cfg_stb 为高时
//	发出的请求会得到应答（实则不会）。
//	}}}
//
// 内存映射:
// {{{
// 	控制端口 (Control Port)
// 	[31:9]	未使用，写入时忽略，读取为零
// 	[8]	CS_n
// 			可以通过写入控制端口来激活。
// 			这将导致内存地址暂时不可读取。
// 			向此位写入 '1' 可使内存返回正常操作模式。
// 	[7:0]	字节数据 (BYTE-DATA)
// 			当控制端口写入且位 [8] 为低时，控制器将位 [7:0] 
// 			通过 SPI 端口发送出去（最高位优先）。
// 			完成后，可以读取控制端口以查看从 SPI 端口读取到的值。
// 			这些值也将存储在相同的位 [7:0] 中。
//
//	内存访问 (Memory)
//		返回所读取地址的数据。
//
//		要求控制端口中的 CS_N 设定处于非激活状态，
//		否则读取内存的请求将直接立即返回控制端口寄存器的内容，
//		而不执行任何实际的 Flash 读取操作。
// }}}
//
// 创建者:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// 版权所有 (C) 2018-2021, Gisselquist Technology, LLC
// {{{
// 该文件是 Wishbone 控制的 SPI Flash 控制器集项目的一部分
//
// Wishbone SPI Flash 控制器项目是自由软件(固件):
// 您可以重新分发和/或根据 GNU 较宽松公共许可证的条款
// 进行修改，由自由软件基金会发布，许可证版本为 3，
// 或(根据您的选择)任何更高版本。
//
// Wishbone SPI Flash 控制器项目发布是希望它会有用，
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
module	spixpress #(
		// {{{
		// OPT_PIPE
		// {{{
		// OPT_PIPE 允许连续的、顺序的事务访问递增地址，
		// 而无需发送新地址。
		//
		// 随机访问性能:	65+64(N-1)
		// 流水线性能:	65+32(N-1)
		//
		parameter [0:0]	OPT_PIPE = 1'b1,
		// }}}
		// OPT_CFG
		// {{{
		// OPT_CFG 创建一个配置寄存器，可以在核心不忙时通过
		// i_cfg_stb 访问。使用此配置寄存器，可以向 Flash
		// 发送任意命令，从而可以擦除或编程 Flash。
		// 由于访问是任意的，其他 Flash 功能也得到支持，
		// 例如编程或读取一次性可编程存储器等。
		parameter [0:0]	OPT_CFG  = 1'b1
		// }}}
		// }}}
	) (
		// {{{
		input	wire		i_clk, i_reset,
		//
		input	wire		i_wb_cyc, i_wb_stb, i_cfg_stb, i_wb_we,
		input	wire	[21:0]	i_wb_addr,
		input	wire	[31:0]	i_wb_data,
		output	reg		o_wb_stall, o_wb_ack,
		output	reg	[31:0]	o_wb_data,
		//
		output	reg		o_spi_cs_n, o_spi_sck, o_spi_mosi,
		input	wire		i_spi_miso
		// }}}
	);

	// 信号声明
	// {{{
	reg		cfg_user_mode;
	reg	[32:0]	wdata_pipe;
	reg	[6:0]	ack_delay;
	reg		actual_sck;

	wire	[21:0]	next_addr;

	wire	bus_request, next_request, user_request;
	// }}}

	assign	bus_request  = (i_wb_stb)&&(!o_wb_stall)
					&&(!i_wb_we)&&(!cfg_user_mode);
	assign	next_request = (OPT_PIPE)&&(i_wb_stb)&&(!i_wb_we)
					&&(!cfg_user_mode)
					&&(i_wb_addr == next_addr);
	assign	user_request = (OPT_CFG)&&(i_cfg_stb)&&(!o_wb_stall)
					&&(i_wb_we)&&(!i_wb_data[8]);


	// ack_delay (状态控制)
	// {{{
	// 状态控制名义上是等待当前操作完成所需的时钟数。
	// 一旦 ack_delay 过渡到 0，操作完成，o_wb_ack 应该为高电平。
	initial	ack_delay = 0;
	always @(posedge i_clk)
	if ((i_reset)||(!i_wb_cyc))
		ack_delay <= 0;
	else if (bus_request)
		ack_delay <= ((o_spi_cs_n)||(!OPT_PIPE)) ? 7'd65 : 7'd32;
	else if (user_request)
		ack_delay <= 7'd9;
	else if (ack_delay != 0)
		ack_delay <= ack_delay - 1'b1;
	// }}}

	// wdata_pipe
	// {{{
	// MOSI
	// {{{
	// wdata_pipe 是一个长移位寄存器，包含当前事务需要发送到
	// SPI 端口的值。基本事务需要发送 8'h03 (读取) 命令，
	// 后跟 24 位地址。
	//
	// 为了逻辑最小化，wdata_pipe 的设置分为两个部分，
	// 但基本上遵循几种模型：
	//
	// 1. 在任何 Flash 读取请求时，从 i_wb_addr[21:0] 和 2'b00
	//	形成的 24 位地址请求读取--因为我们只执行对齐的事务。
	//
	//	wdata_pipe <= { 1'b0, 8'h03, i_wb_addr[21:0], 2'b00 };
	//
	// 2. 在任何配置端口写入时，根据 i_wb_data 中包含的
	//	所需 8 位命令设置数据
	//
	//	wdata_pipe <= { 1'b0, i_wb_data[7:0], 24'bz };
	//
	// 3. 在任何操作期间，每个时钟将管道向上/向左移动一位，
	//	名义上用 1'bz 填充，但实际上用 1'b0
	//
	// 4. 如果接口空闲，wdata_pipe 是无关项。
	// }}}
	//
	initial	wdata_pipe = 0;
	always @(posedge i_clk)
	if (!o_wb_stall)
		// 在任何读取请求时，这设置要读取的地址。
		//
		// 在配置写入请求时，或总线空闲时，
		// 这些位是无关项，因此我们可以稍微优化它们
		wdata_pipe[23:0] <= { i_wb_addr[21:0], 2'b00 };
	else
		// 在操作期间，一次只向左移动一位
		wdata_pipe[23:0] <= { wdata_pipe[22:0], 1'b0 };

	always @(posedge i_clk)
	if (((!OPT_CFG)||(i_wb_stb))&&(!o_wb_stall)) // (bus_request)
		// 请求从 Flash 读取
		wdata_pipe[32:24] <= { 1'b0, 8'h03 };
	else if ((OPT_CFG)&&(!o_wb_stall)) // (user_request)
		// 请求向 Flash 发送特殊数据
		wdata_pipe[32:24] <= { 1'b0, i_wb_data[7:0] };
	else
		// 否则只是将寄存器向左移动
		wdata_pipe[32:24] <= { wdata_pipe[31:23] };
	// }}}

	// 发送到 Flash 的输出位简单地由这个 wdata_pipe 移位寄存器的
	// 最高位给出。
	always @(*)
		o_spi_mosi = wdata_pipe[32];

	// o_wb_ack, WB-ACK
	// {{{
	initial	o_wb_ack = 0;
	always @(posedge i_clk)
	if (i_reset)
		// 在复位时清除任何确认
		o_wb_ack <= 0;
	else if (ack_delay == 1)
		// 确认任何操作的结束，无论是来自配置端口还是来自
		// 读取内存
		o_wb_ack <= (i_wb_cyc);
	else if ((i_wb_stb)&&(!o_wb_stall)&&(!bus_request))
		// 立即确认对内存地址空间的任何写入，或配置端口
		// 激活时的任何读/写。
		o_wb_ack <= 1'b1;
	else if ((i_cfg_stb)&&(!o_wb_stall)&&(!user_request))
		// 立即确认来自配置端口的任何读取。
		// 不需要任何操作。
		o_wb_ack <= 1'b1;
	else
		// 在所有其他情况下，将确认线保持低电平。
		o_wb_ack <= 0;
	// }}}

	// cfg_user_mode, CFG 用户模式 (即覆盖模式)
	// {{{
	// 如果我们在配置/用户模式下，CS 线将被人为地保持低电平。
	// 这允许我们通过一系列配置写入发送多字节命令。
	//
	initial	cfg_user_mode = 0;
	always @(posedge i_clk)
	if (i_reset)
		cfg_user_mode <= 0;
	else if ((OPT_CFG)&&(i_cfg_stb)&&(!o_wb_stall)&&(i_wb_we))
		cfg_user_mode <= !i_wb_data[8];
	// }}}

	// actual_sck
	// {{{
	// Actual_sck (SCK, 但延迟一个时钟)
	//
	// 这是硬件看到的 SCK 信号
	initial	actual_sck = 1'b0;
	always @(posedge i_clk)
	if ((i_reset)||(!i_wb_cyc))
		actual_sck <= 1'b0;
	else
		// 我们的 SCK 信号比我们请求传输 SCK 的时钟延迟一个时钟。
		// 我们在这里创建一个延迟副本，这样我们就能知道实际的
		// SCK 在做什么。
		actual_sck <= o_spi_sck;
	// }}}

	// o_wb_data, 输出的 WB-Data
	// {{{
	always @(posedge i_clk)
	begin
		if (actual_sck)
		begin
			if (cfg_user_mode)
				o_wb_data <= { 19'h0, 1'b1, 4'h0, o_wb_data[6:0], i_spi_miso };
			else
				o_wb_data <= { o_wb_data[30:0], i_spi_miso };
		end

		if (cfg_user_mode)
			o_wb_data[31:8] <= { 19'h0, 1'b1, 4'h0 };
	end
	// }}}

	// CSN / o_spi_cs_n
	// {{{
	// 这是负逻辑芯片选择。
	//
	initial	o_spi_cs_n = 1'b1;
	always @(posedge i_clk)
	if (i_reset)
		// 复位时空闲
		o_spi_cs_n <= 1'b1;
	else if ((!i_wb_cyc)&&(!cfg_user_mode))
		// 在任何中止的事务之后，或任何我们离开配置模式时，
		// 返回空闲状态。
		o_spi_cs_n <= 1'b1;
	else if (bus_request)
		// 在任何总线读取请求时，选择设备以启动事务。
		o_spi_cs_n <= 1'b0;
	else if ((OPT_CFG)&&(i_cfg_stb)&&(!o_wb_stall)&&(i_wb_we))
		// 同样，在对配置端口的任何写入时，开始 8 位传输。
		o_spi_cs_n <= i_wb_data[8];
	else if (cfg_user_mode)
		// 即使传输完成，在配置模式下也保持 CS 线激活(低电平)
		o_spi_cs_n <= 1'b0;
	else if ((ack_delay == 1)&&(!cfg_user_mode))
		// 在所有其他情况下，事务应在 ack_delay == 1 之后的时钟
		// 结束，所以在这里结束它。
		o_spi_cs_n <= 1'b1;
	// }}}

	// o_spi_sck / SCK
	// {{{
	initial	o_spi_sck = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_spi_sck <= 1'b0;
	else if ((bus_request)||(user_request))
		// 在任何内存读取或配置端口写入请求后开始时钟
		o_spi_sck <= 1'b1;
	else if ((i_wb_cyc)&&(ack_delay > 2)) // 总线中止检查
		// 只要 CYC 保持高电平，就继续请求
		o_spi_sck <= 1'b1;
	else if ((next_request)&&(ack_delay == 2))
		// 在任何流水线读取请求时，保持时钟运行
		o_spi_sck <= 1'b1;
	else
		// 否则，关闭它
		o_spi_sck <= 1'b0;
	// }}}

	// o_wb_stall
	// {{{
	// WB-暂停
	//
	// WB 接口需要在我们忙于计算答案时暂停，因为此核心一次
	// 只能处理一个请求。
	initial	o_wb_stall = 1'b0;
	always @(posedge i_clk)
	if ((i_reset)||(!i_wb_cyc))
		// 在复位或总线中止时释放暂停线
		o_wb_stall <= 1'b0;
	else if ((bus_request)||(user_request))
		// 在任何 Flash 事务请求时，立即开始暂停总线
		o_wb_stall <= 1'b1;
	else if ((next_request)&&(ack_delay == 2))
		// 这个很棘手。如果有后续读取事务的请求，我们需要
		// 降低暂停线以接受它。这取决于总线请求在另一个
		// 时钟周期内保持稳定。
		o_wb_stall <= 1'b0;
	else
		o_wb_stall <= (ack_delay > 1);
	// }}}

	// next_addr
	// {{{
	generate if (OPT_PIPE)
	begin
		reg	[21:0]	r_next_addr;
		always @(posedge i_clk)
		if (!o_wb_stall)
			r_next_addr <= i_wb_addr + 1'b1;

		assign	next_addr = r_next_addr;

	end else begin

		assign next_addr = 0;

	end endgenerate
	// }}}

	// 让 Verilator 满意
	// {{{
	// verilator lint_off UNUSED
	wire	[22:0]	unused;
	assign	unused = i_wb_data[31:9];
	// verilator lint_on  UNUSED
	// }}}
////////////////////////////////////////////////////////////////////////////////
//
// 形式验证 (Formal) 部分
// {{{
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	parameter	[0:0]	F_OPT_COVER = 1'b0;

	reg	f_past_valid;

	initial	f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	////////
	//
	// 复位逻辑
	//
	////////
	always @(*)
	if (!f_past_valid)
		assume(i_reset);
`ifndef	VERIFIC
	initial	assume(i_reset);
`endif

	always @(posedge i_clk)
	if ((!f_past_valid)||($past(i_reset)))
	begin
		assert(o_spi_cs_n == 1'b1);
		assert(o_spi_sck  == 1'b0);
		//
		assert(ack_delay    ==  0);
		assert(cfg_user_mode == 0);
		assert(o_wb_stall == 1'b0);
		assert(o_wb_ack   == 1'b0);
	end

	localparam	F_LGDEPTH = 7;
	wire	[F_LGDEPTH-1:0]	f_nreqs, f_nacks, f_outstanding;

	fwb_slave #( .AW(22), .F_MAX_STALL(7'd66), .F_MAX_ACK_DELAY(7'd66),
			.F_LGDEPTH(F_LGDEPTH),
			.F_MAX_REQUESTS((OPT_PIPE) ? 0 : 1'b1),
			.F_OPT_MINCLOCK_DELAY(1'b1)
		) slavei(i_clk, (i_reset),
		i_wb_cyc, (i_wb_stb)||(i_cfg_stb), i_wb_we,
			i_wb_addr, i_wb_data, 4'hf,
			o_wb_ack, o_wb_stall, o_wb_data, 1'b0,
			f_nreqs, f_nacks, f_outstanding);

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))&&(i_wb_cyc)
		&&(($past(i_wb_stb))||($past(i_cfg_stb)))&&($past(o_wb_stall)))
		assume($stable({i_wb_stb,i_cfg_stb}));

	always @(*)
		assume((!i_cfg_stb)||(!i_wb_stb));

	always @(*)
	if (OPT_PIPE)
		assert(f_outstanding <= 2);
	else
		assert(f_outstanding <= 1);

	always @(posedge i_clk)
	if (ack_delay == 0)
		assert((o_wb_ack)||(f_outstanding == 0));


	always @(posedge i_clk)
	if ((f_past_valid)&&(!i_reset)&&(i_wb_cyc))
	begin
		if (((!OPT_PIPE)||($past(o_spi_cs_n)))
			&&($past(i_wb_stb))&&(!$past(o_wb_stall))&&(i_wb_cyc))
			assert(f_outstanding == 1);
		if (ack_delay > 0)
			assert((o_wb_ack)||(f_outstanding == 1));
	end

	always @(posedge i_clk)
	if ((f_past_valid)&&(o_wb_ack)&&($past(o_wb_ack)))
		assert(f_outstanding <= 1);

	always @(posedge i_clk)
	if (f_outstanding == 2)
		assert((OPT_PIPE)&&(o_wb_ack)&&(!o_spi_cs_n)&&(o_spi_sck)
			&&(ack_delay==7'd32));

	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_wb_stb))&&(!$past(o_wb_stall)))
	begin
		if ((i_wb_cyc)&&(!i_reset)
				&&(!$past(user_request))&&(!$past(bus_request)))
			assert((o_wb_ack)&&(f_outstanding == 1));
	end

	//
	// SPI 协议断言
	//
	always @(*)
	if (o_spi_cs_n)
		assert(!o_spi_sck);

	always @(*)
		assert((o_spi_sck||actual_sck) == (ack_delay > 0));

	always @(*)
	if (ack_delay == 0)
		assert(!o_wb_stall);
	else if (ack_delay > 1)
		assert(o_wb_stall);
	else if ((!OPT_PIPE)&&(ack_delay == 1))
		assert(o_wb_stall);

	always @(*)
		assert(ack_delay <= 7'd65);

	always @(*)
	if (cfg_user_mode)
		assert(ack_delay <= 7'd9);

	always @(*)
		assert(o_spi_cs_n != ((cfg_user_mode)||(ack_delay > 0)));

	generate if (F_OPT_COVER)
	begin

		always @(posedge i_clk)
			cover(o_wb_ack&&(!$past(bus_request))
				&&(!$past(user_request)));

		reg	f_pending_user_request, f_pending_bus_request;

		initial	f_pending_user_request = 1'b0;
		always @(posedge i_clk)
		if ((i_reset)||(!i_wb_cyc))
			f_pending_user_request <= 1'b0;
		else if (user_request)
			f_pending_user_request <= 1'b1;
		else if (o_wb_ack)
			f_pending_user_request <= 1'b0;

		initial	f_pending_bus_request = 1'b0;
		always @(posedge i_clk)
		if ((i_reset)||(!i_wb_cyc))
			f_pending_bus_request <= 1'b0;
		else if (bus_request)
			f_pending_bus_request <= 1'b1;
		else if (o_wb_ack)
			f_pending_bus_request <= 1'b0;

		always @(posedge i_clk)
			cover((o_wb_ack)&&(f_pending_user_request));

		always @(posedge i_clk)
			cover((o_wb_ack)&&(f_pending_bus_request));

		if (OPT_PIPE)
		begin

			always @(posedge i_clk)
				cover((f_pending_bus_request)
					&&(ack_delay == 7'h1)
					&&(bus_request)&&(o_spi_sck));
			always @(posedge i_clk)
				cover((next_request)&&(f_pending_bus_request)&&(ack_delay == 7'h2));
		end

	end endgenerate
`endif
`ifdef	VERIFIC
	// {{{
	reg	[21:0]	f_last_addr, f_next_addr;

	always @(posedge i_clk)
	if (bus_request)
		f_last_addr <= i_wb_addr[21:0];

	always @(*)
		f_next_addr <= f_last_addr + 1'b1;

	// 写入立即返回
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		((i_wb_stb)||(i_cfg_stb))&&(!o_wb_stall)
				&&(!user_request)&&(!bus_request)
		|=> (o_wb_ack)&&(!o_wb_stall));

	assert property (@(posedge i_clk)
		(i_wb_stb)&&(!o_wb_stall)&&(!o_spi_cs_n)&&(!i_wb_we)
			&&(!cfg_user_mode)
		|-> (OPT_PIPE)&&(i_wb_addr == f_next_addr)
		);

	sequence READ_COMMAND;
		// 发送命令 8'h03
		(f_last_addr == $past(i_wb_addr))
				&&(!o_spi_cs_n)&&(o_spi_sck)&&(!o_spi_mosi)
				&&(!actual_sck)
		##1 ( ((f_last_addr == $past(f_last_addr))
			&&(!o_spi_cs_n)&&(o_spi_sck)&&(actual_sck)) throughout
				(!o_spi_mosi)&&(ack_delay==7'd64)&&(actual_sck)
				##1 (!o_spi_mosi)&&(ack_delay==7'd63)
				##1 (!o_spi_mosi)&&(ack_delay==7'd62)
				##1 (!o_spi_mosi)&&(ack_delay==7'd61)
				##1 (!o_spi_mosi)&&(ack_delay==7'd60)
				##1 (!o_spi_mosi)&&(ack_delay==7'd59)
				##1 ( o_spi_mosi)&&(ack_delay==7'd58)
				##1 ( o_spi_mosi)&&(ack_delay==7'd57));
	endsequence

	sequence	SEND_ADDRESS;
		(((f_last_addr == $past(f_last_addr))&&(!o_spi_cs_n)&&(o_spi_sck)
			&&(actual_sck))
		throughout
			(o_spi_mosi == f_last_addr[21])&&(ack_delay==7'd56)
			##1 (o_spi_mosi == f_last_addr[20])&&(ack_delay==7'd55)
			##1 (o_spi_mosi == f_last_addr[19])&&(ack_delay==7'd54)
			##1 (o_spi_mosi == f_last_addr[18])&&(ack_delay==7'd53)
			##1 (o_spi_mosi == f_last_addr[17])&&(ack_delay==7'd52)
			##1 (o_spi_mosi == f_last_addr[16])&&(ack_delay==7'd51)
			##1 (o_spi_mosi == f_last_addr[15])&&(ack_delay==7'd50)
			##1 (o_spi_mosi == f_last_addr[14])&&(ack_delay==7'd49)
			##1 (o_spi_mosi == f_last_addr[13])&&(ack_delay==7'd48)
			##1 (o_spi_mosi == f_last_addr[12])&&(ack_delay==7'd47)
			##1 (o_spi_mosi == f_last_addr[11])&&(ack_delay==7'd46)
			##1 (o_spi_mosi == f_last_addr[10])&&(ack_delay==7'd45)
			##1 (o_spi_mosi == f_last_addr[ 9])&&(ack_delay==7'd44)
			##1 (o_spi_mosi == f_last_addr[ 8])&&(ack_delay==7'd43)
			##1 (o_spi_mosi == f_last_addr[ 7])&&(ack_delay==7'd42)
			##1 (o_spi_mosi == f_last_addr[ 6])&&(ack_delay==7'd41)
			##1 (o_spi_mosi == f_last_addr[ 5])&&(ack_delay==7'd40)
			##1 (o_spi_mosi == f_last_addr[ 4])&&(ack_delay==7'd39)
			##1 (o_spi_mosi == f_last_addr[ 3])&&(ack_delay==7'd38)
			##1 (o_spi_mosi == f_last_addr[ 2])&&(ack_delay==7'd37)
			##1 (o_spi_mosi == f_last_addr[ 1])&&(ack_delay==7'd36)
			##1 (o_spi_mosi == f_last_addr[ 0])&&(ack_delay==7'd35)
			##1 (o_spi_mosi == 1'b0)&&(ack_delay==7'd34)
			##1 (o_spi_mosi == 1'b0)&&(ack_delay==7'd33));
	endsequence

	sequence	READ_DATA;
		(((o_wb_stall)&&(!o_spi_cs_n)&&(o_spi_sck)
			&&(o_wb_data == $past({o_wb_data[30:0], i_spi_miso})))
		throughout
		(ack_delay <= 7'd32)&&(ack_delay >= 7'd25) [*8]
		##1 (ack_delay <= 7'd24)&&(ack_delay >= 7'd17) [*8]
		##1 (ack_delay <= 7'd16)&&(ack_delay >=  7'd9) [*8]
		##1 (ack_delay <=  7'd8)&&(ack_delay >=  7'd2) [*7])
		##1 ((!o_spi_cs_n)&&(actual_sck)&&(ack_delay == 7'd1)
			&&(((OPT_PIPE)&&(i_wb_stb)&&(!i_wb_we)&&(o_spi_sck))
				||((o_wb_stall)&&(!o_spi_sck)))
			&&(o_wb_data == $past({o_wb_data[30:0], i_spi_miso})))
		##1 (o_wb_ack)
			&&(o_wb_data == $past({o_wb_data[30:0], i_spi_miso}))
			&&((OPT_PIPE)||((o_spi_cs_n)
					&&(!o_spi_sck)&&(!actual_sck)));
	endsequence

	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		(i_wb_stb)&&(!o_wb_stall)&&(!i_wb_we)&&(o_spi_cs_n)
			&&(!cfg_user_mode)
		// 发送命令 8'h03
		|=> READ_COMMAND
		##1 ((f_last_addr == $past(f_last_addr)) throughout
				SEND_ADDRESS)
		##1 READ_DATA);


	//////////////
	//
	// 已知数据/地址约定
	//
	/////////////
	(* anyconst *) wire	[31:0]	f_data;

	sequence	DATA_BYTE(local input [7:0] B);
		(i_spi_miso == B[7])
		##1 (i_spi_miso == B[6])
		##1 (i_spi_miso == B[5])
		##1 (i_spi_miso == B[4])
		##1 (i_spi_miso == B[3])
		##1 (i_spi_miso == B[2])
		##1 (i_spi_miso == B[1])
		##1 (i_spi_miso == B[0]);
	endsequence

	sequence	THIS_DATA;
			DATA_BYTE(f_data[31:24])
			##1 DATA_BYTE(f_data[23:16])
			##1 DATA_BYTE(f_data[15: 8])
			##1 DATA_BYTE(f_data[ 7: 0]);
	endsequence

	assert property (@(posedge i_clk)
		(THIS_DATA and ((!i_reset)&&(i_wb_cyc)
			throughout
		((ack_delay == 7'd32)
			##1 (ack_delay == $past(ack_delay)-1) [*31])))
		|=> (o_wb_ack)&&(o_wb_data == f_data));

	generate if (OPT_CFG)
	begin
		// 现在进行配置写入
		assert property (@(posedge i_clk)
			disable iff ((i_reset)||(!i_wb_cyc))
			((i_cfg_stb)&&(!o_wb_stall)&&(i_wb_we)&&(i_wb_data[8]))
			|=> ((!cfg_user_mode)&&(o_spi_cs_n)&&(!o_spi_sck))
				&&(o_wb_ack)&&(!o_wb_stall));

		reg	[7:0]	f_wr_data;
		always @(posedge i_clk)
		if (user_request)
			f_wr_data <= i_wb_data[7:0];

		assert property (@(posedge i_clk)
			disable iff ((i_reset)||(!i_wb_cyc))
			((i_cfg_stb)&&(!o_wb_stall)&&(i_wb_we)&&(!i_wb_data[8]))
			|=> (((cfg_user_mode)&&(!o_spi_cs_n)&&(o_spi_sck)
				&&(o_wb_stall)) throughout
				(!o_spi_mosi)&&(ack_delay==7'd9)
				##1 (o_spi_mosi == f_wr_data[7])
							&&(ack_delay==7'd8)
				##1 (o_spi_mosi == f_wr_data[6])
							&&(ack_delay==7'd7)
				##1 (o_spi_mosi == f_wr_data[5])
							&&(ack_delay==7'd6)
				##1 (o_spi_mosi == f_wr_data[4])
							&&(ack_delay==7'd5)
				##1 (o_spi_mosi == f_wr_data[3])
							&&(ack_delay==7'd4)
				##1 (o_spi_mosi == f_wr_data[2])
							&&(ack_delay==7'd3)
				##1 (o_spi_mosi == f_wr_data[1])
							&&(ack_delay==7'd2))
			##1 ((cfg_user_mode)&&(!o_spi_cs_n)&&(!o_spi_sck)
				&&(actual_sck)&&(o_wb_stall)
				&&(o_spi_mosi == f_wr_data[0])
							&&(ack_delay==7'd1))
			##1 (o_wb_ack)&&(!o_wb_stall)&&(cfg_user_mode)
				&&(!o_spi_sck)&&(!actual_sck)&&(!o_wb_stall));

		// 然后是配置读取。首先写入需要
		// 充电 o_wb_data 缓冲区
		assert property (@(posedge i_clk)
			disable iff ((i_reset)||(!i_wb_cyc))
			((i_cfg_stb)&&(!o_wb_stall)&&(i_wb_we)&&(!i_wb_data[8]))
			##2 DATA_BYTE(f_data[7:0])
			|=> (o_wb_ack)&&(o_wb_data == { 24'h10,
				$past(i_spi_miso,8), $past(i_spi_miso,7),
				$past(i_spi_miso,6), $past(i_spi_miso,5),
				$past(i_spi_miso,4), $past(i_spi_miso,3),
				$past(i_spi_miso,2), $past(i_spi_miso,1)
				})
				&&(cfg_user_mode)&&(!o_wb_stall));

		// 然后它需要保持恒定直到另一个 SPI
		// 命令
		assert property (@(posedge i_clk)
			disable iff (i_reset)
			($past(!o_spi_sck))&&(!o_spi_sck)&&(cfg_user_mode)
			|=> $stable(o_wb_data)&&(o_wb_data[31:8]==5'h10));

	end endgenerate
	// }}}
`endif
// }}}
endmodule
// 在 iCE40 上的使用情况
// 		无配置	无流水线	配置/无流水线	流水线
// 单元数	133	168	226	259
// SB_CARRY	 16	 16	 36	 36
// SB_DFF	 10	 32	 10	 32
// SB_DFFE	 33	 10	 55	 32
// SB_DFFESR	  7	  9	  7	  9
// SB_DFFSR	 12	 12	 12	 12
// SB_DFFSS	  2	  2	  2	  2
// SB_LUT4	 53	 87	104	136
//
