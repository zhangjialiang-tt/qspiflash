//
// 文件名:     spi_flash_stream.v
// 项目:       流式 SPI Flash 控制器
// 版本:       v3.0 (Refactored & Robust)
//
// 描述:       
//   基于 SPI Mode 0 的通用只读控制器。
//   - 采用通用状态机架构，复用“发送头-读取数据”流程。
//   - 支持先读ID校验，校验通过后自动重启事务读取数据。
//   - 修复了 MOSI 首位竞争风险，确保 CS# 高电平间隔。
//
////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module spi_flash_stream #(
    parameter ADDR_WIDTH = 24,       // 地址位宽
    parameter DATA_WIDTH = 8,        // 数据位宽
    parameter CMD_READ   = 8'h03,    // 读数据命令
    parameter CMD_RDID   = 8'h9F,    // 读ID命令
    parameter CHIP_ID    = 24'hEF4018, // W25Q128 ID
    parameter CLK_DIV    = 1,        // 分频系数
    parameter MIN_CSH    = 2         // CS# 拉高后的最小等待周期 (tCSH)
) (
    input  wire                     i_clk,
    input  wire                     i_reset,
    
    // 用户控制接口
    input  wire                     i_start_read,
    input  wire                     i_check_id,     // 1=开启ID校验
    input  wire [ADDR_WIDTH-1:0]    i_addr,
    input  wire [ADDR_WIDTH-1:0]    i_length,
    
    // 输出接口
    output reg  [DATA_WIDTH-1:0]    o_data,
    output reg                      o_valid,
    output reg                      o_done,
    output reg                      o_error,        // ID校验失败脉冲
    
    // 物理 SPI 接口
    output reg                      o_spi_cs_n,
    output reg                      o_spi_sck,
    output reg                      o_spi_mosi,
    input  wire                     i_spi_miso
);

    // ========================================================================
    // 参数与状态定义
    // ========================================================================
    
    // 最大头部长度: 8(CMD) + 24(ADDR) = 32
    localparam MAX_HEADER_BITS = 8 + ADDR_WIDTH; 
    
    localparam [1:0] PHASE_ID   = 2'd0,  // 阶段：读取ID
                     PHASE_DATA = 2'd1;  // 阶段：读取数据
    
    localparam [2:0] S_IDLE        = 3'd0,
                     S_CS_WAIT     = 3'd1, // CS# 拉高等待 (tCSH)
                     S_SEND_HEADER = 3'd2, // 通用发送头部 (CMD + ADDR/Dummy)
                     S_READ_DATA   = 3'd3, // 通用读取数据
                     S_CHECK_NEXT  = 3'd4; // 事务结束检查 (决定完成还是重启)

    // ========================================================================
    // 内部信号
    // ========================================================================
    reg [$clog2(CLK_DIV > 1 ? CLK_DIV : 1)-1:0] clk_cnt;
    wire                      sck_toggle_en;
    wire                      sck_rise_en;   // 采样
    wire                      sck_fall_en;   // 发送
    
    // 事务上下文寄存器 (用于复用状态机)
    reg [1:0]                 current_phase;    // 当前是读ID还是读数据
    reg [MAX_HEADER_BITS-1:0] shift_reg_out;    // 发送移位寄存器
    reg [5:0]                 header_len_bits;  // 需要发送的头部位数
    reg [ADDR_WIDTH-1:0]      read_len_bytes;   // 需要读取的字节数
    
    // 接收移位寄存器
    reg [7:0]                 shift_reg_in;
    reg [23:0]                id_read_buffer;
    
    // 计数器
    reg [2:0]                 state;
    reg [5:0]                 cnt_bit;
    reg [ADDR_WIDTH-1:0]      cnt_byte;
    reg [3:0]                 wait_cnt;         // CS# 等待计数器

    // 辅助信号
    reg                       internal_start;   // 内部触发信号 (用于ID校验后的自动重启)

    // ========================================================================
    // 1. 时钟分频
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) clk_cnt <= 0;
        else if (state != S_IDLE && state != S_CS_WAIT) begin
            clk_cnt <= (clk_cnt == CLK_DIV - 1) ? 0 : clk_cnt + 1'b1;
        end else begin
            clk_cnt <= 0;
        end
    end

    assign sck_toggle_en = (clk_cnt == CLK_DIV - 1);
    assign sck_rise_en   = sck_toggle_en && (o_spi_sck == 1'b0);
    assign sck_fall_en   = sck_toggle_en && (o_spi_sck == 1'b1);

    // ========================================================================
    // 2. SPI 物理层输出 (SCK & MOSI)
    // ========================================================================
    
    // SCK 生成
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) o_spi_sck <= 1'b0;
        else if (sck_toggle_en) begin
            if (state == S_SEND_HEADER || state == S_READ_DATA)
                o_spi_sck <= ~o_spi_sck;
            else
                o_spi_sck <= 1'b0;
        end else if (state == S_IDLE || state == S_CS_WAIT || state == S_CHECK_NEXT) begin
            o_spi_sck <= 1'b0;
        end
    end

    // MOSI 生成 (改进：统一移位逻辑，消除竞争)
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) o_spi_mosi <= 1'b0;
        else begin
            // 策略：总是输出 shift_reg_out 的最高位
            // 在 S_IDLE 或 S_CHECK_NEXT 准备跳转时，shift_reg_out 会被预加载
            if (state == S_SEND_HEADER) begin
                // 发送过程中：在下降沿更新数据
                if (sck_fall_en) begin
                    // 注意：这里的 shift_reg_out 已经在下降沿逻辑中左移了
                    // 所以这里取的是移位后的新 MSB
                    // 这种写法需要配合 shift_reg_out 的逻辑
                    // 更好的方式是组合逻辑 mux，或者这里直接输出 shift_reg_out[MSB]
                end
            end
            
            // 为了简化时序，我们在 MOSI 上使用一个简单的 Mux 逻辑：
            // 1. 当状态为 SEND_HEADER 且 fall_en 时，输出 shift_reg_out[MSB] (下一位)
            // 2. 当状态刚进入 SEND_HEADER (CS拉低瞬间)，输出 shift_reg_out[MSB] (首位)
            
            if (state == S_IDLE || state == S_CS_WAIT || state == S_CHECK_NEXT) begin
                // 空闲时保持 0，或者保持上一位，不重要
                // 关键是：在进入 SEND_HEADER 的那一瞬间，MOSI 必须是首位
                // 下面通过状态机的预加载逻辑保证 shift_reg_out 已经准备好
                // 并在 CS 拉低的同时更新 MOSI
                if (internal_start || (i_start_read && state == S_IDLE)) begin
                    // 这里不做操作，依靠下文的统一赋值
                end else begin
                    o_spi_mosi <= 1'b0;
                end
            end else if (state == S_SEND_HEADER) begin
                // 这里的逻辑稍微 tricky：我们需要在 CS 拉低时 MOSI 就位
                // 见状态机逻辑：我们在跳转到 SEND_HEADER 的同时，将 shift_reg_out[MSB] 赋给 MOSI
                // 所以这里只需要处理后续的位
                if (sck_fall_en) 
                    o_spi_mosi <= shift_reg_out[MAX_HEADER_BITS-1];
            end else begin
                o_spi_mosi <= 1'b0; // 读数据阶段 MOSI 为 0
            end
        end
    end

    // ========================================================================
    // 3. 主状态机 (通用化设计)
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            state           <= S_IDLE;
            o_spi_cs_n      <= 1'b1;
            o_valid         <= 1'b0;
            o_done          <= 1'b0;
            o_error         <= 1'b0;
            o_data          <= 0;
            
            shift_reg_out   <= 0;
            shift_reg_in    <= 0;
            id_read_buffer  <= 0;
            
            cnt_bit         <= 0;
            cnt_byte        <= 0;
            header_len_bits <= 0;
            read_len_bytes  <= 0;
            
            current_phase   <= PHASE_DATA;
            internal_start  <= 1'b0;
            wait_cnt        <= 0;
        end else begin
            // 脉冲信号自动清零
            o_valid <= 1'b0;
            o_done  <= 1'b0;
            o_error <= 1'b0;
            internal_start <= 1'b0; 

            case (state)
                // ------------------------------------------------------------
                // S_IDLE: 等待用户触发
                // ------------------------------------------------------------
                S_IDLE: begin
                    o_spi_cs_n <= 1'b1;
                    wait_cnt   <= 0;
                    
                    if (i_start_read) begin
                        if (i_check_id) begin
                            // 路径 A: 开启校验，先执行 ID 阶段
                            current_phase   <= PHASE_ID;
                            // 准备 ID 命令 (9Fh + 24bit 0 padding)
                            // 注意：放在高位，因为我们总是左移
                            shift_reg_out   <= {CMD_RDID, {(ADDR_WIDTH){1'b0}}};
                            header_len_bits <= 8;  // 只发 8 bit CMD
                            read_len_bytes  <= 3;  // 读 3 byte ID
                        end else begin
                            // 路径 B: 无校验，直接执行 DATA 阶段
                            current_phase   <= PHASE_DATA;
                            if (i_length == 0) begin
                                o_done <= 1'b1; // 零长度直接完成
                            end else begin
                                // 准备 READ 命令 (03h + ADDR)
                                shift_reg_out   <= {CMD_READ, i_addr};
                                header_len_bits <= 8 + ADDR_WIDTH; // 32 bits
                                read_len_bytes  <= i_length;
                            end
                        end

                        // 只有在非零长度(或读ID)时才启动
                        if (!(!i_check_id && i_length == 0)) begin
                            internal_start <= 1'b1; // 触发 S_CS_WAIT 跳转
                            state          <= S_CS_WAIT;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_CS_WAIT: 确保 CS# 拉高时间 (tCSH) & 准备 MOSI 首位
                // ------------------------------------------------------------
                S_CS_WAIT: begin
                    o_spi_cs_n <= 1'b1;
                    wait_cnt   <= wait_cnt + 1'b1;

                    // 预备 MOSI 首位 (组合逻辑/Look-ahead)
                    // 当我们即将拉低 CS 时，MOSI 必须已经稳定
                    // 在本状态的最后一个周期，更新 MOSI 寄存器
                    if (wait_cnt >= MIN_CSH) begin
                        // 1. 更新 MOSI 为 shift_reg_out 的最高位 (首位)
                        // 这解决了“首位竞争”问题，因为 CS 还没拉低
                        o_spi_mosi <= shift_reg_out[MAX_HEADER_BITS-1];
                        
                        // 2. 移位寄存器左移一次，为下一个 bit 做准备
                        shift_reg_out <= {shift_reg_out[MAX_HEADER_BITS-2:0], 1'b0};
                        
                        // 3. 启动事务
                        state      <= S_SEND_HEADER;
                        o_spi_cs_n <= 1'b0; // 拉低 CS
                        cnt_bit    <= 0;
                    end
                end

                // ------------------------------------------------------------
                // S_SEND_HEADER: 发送命令和地址 (通用)
                // ------------------------------------------------------------
                S_SEND_HEADER: begin
                    if (sck_fall_en) begin
                        // 移位寄存器更新 (MOSI 逻辑会取新 MSB)
                        shift_reg_out <= {shift_reg_out[MAX_HEADER_BITS-2:0], 1'b0};
                    end
                    
                    if (sck_rise_en) begin
                        cnt_bit <= cnt_bit + 1'b1;
                        // 检查是否发送完毕
                        if (cnt_bit == header_len_bits - 1) begin
                            state    <= S_READ_DATA;
                            cnt_bit  <= 0;
                            cnt_byte <= 0;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_READ_DATA: 读取数据 (通用)
                // ------------------------------------------------------------
                S_READ_DATA: begin
                    if (sck_rise_en) begin
                        // 采样 MISO
                        shift_reg_in <= {shift_reg_in[6:0], i_spi_miso};
                        cnt_bit      <= cnt_bit + 1'b1;

                        if (cnt_bit == 3'd7) begin
                            // 【修复关键点】：必须清零 bit 计数器
                            cnt_bit  <= 0; 
                            
                            // 字节结束
                            cnt_byte <= cnt_byte + 1'b1;
                            
                            if (current_phase == PHASE_DATA) begin
                                // 输出用户数据
                                o_data  <= {shift_reg_in[6:0], i_spi_miso};
                                o_valid <= 1'b1;
                            end else begin
                                // 缓存 ID 数据
                                id_read_buffer <= {id_read_buffer[15:0], shift_reg_in[6:0], i_spi_miso};
                            end

                            if (cnt_byte == read_len_bytes - 1) begin
                                state <= S_CHECK_NEXT;
                            end
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_CHECK_NEXT: 事务结束，判断下一步 (校验或完成)
                // ------------------------------------------------------------
                S_CHECK_NEXT: begin
                    // 等待 SCK 最后一个下降沿完成 (Mode 0)
                    if (clk_cnt == CLK_DIV - 1) begin
                        o_spi_cs_n <= 1'b1; // 拉高 CS
                        wait_cnt   <= 0;    // 重置等待计数器

                        if (current_phase == PHASE_ID) begin
                            // --- ID 阶段结束 ---
                            if (id_read_buffer == CHIP_ID) begin
                                // ID 匹配 -> 配置参数进行 DATA 阶段
                                if (i_length == 0) begin
                                    o_done <= 1'b1;
                                    state  <= S_IDLE;
                                end else begin
                                    current_phase   <= PHASE_DATA;
                                    // 重新装载 READ 命令
                                    shift_reg_out   <= {CMD_READ, i_addr};
                                    header_len_bits <= 8 + ADDR_WIDTH;
                                    read_len_bytes  <= i_length;
                                    
                                    // 转到 CS_WAIT 状态，利用它产生 tCSH 延迟并自动启动
                                    state <= S_CS_WAIT; 
                                end
                            end else begin
                                // ID 不匹配
                                o_error <= 1'b1;
                                state   <= S_IDLE;
                            end
                        end else begin
                            // --- DATA 阶段结束 ---
                            o_done <= 1'b1;
                            state  <= S_IDLE;
                        end
                    end
                end

            endcase
        end
    end

endmodule
`default_nettype wire