////////////////////////////////////////////////////////////////////////////////
//
// 文件名:     spi_flash_stream.v
// 项目:       流式 SPI Flash 控制器
// 版本:       v2.0 (Fixed & Optimized)
//
// 描述:       
//   基于 SPI Mode 0 (CPOL=0, CPHA=0) 的只读控制器。
//   - SCK 空闲为低电平
//   - 数据在下降沿发送 (MOSI)，在上升沿采样 (MISO)
//   - 修复了此前版本中存在的移位寄存器填充位导致的协议错误
//
// 限制:
//   - 仅支持标准 SPI (非 Quad/Dual)
//   - 仅支持 3 字节地址模式 (24-bit Address)
//   - SCK 频率为 i_clk 频率的 1/2
//
////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module spi_flash_stream #(
    parameter ADDR_WIDTH = 24,       // 地址位宽
    parameter DATA_WIDTH = 8,        // 数据位宽
    parameter CMD_READ   = 8'h03,    // 可配置命令字，不再硬编码
    parameter CLK_DIV    = 1         // 分频系数: SCK_Freq = i_clk / (2 * CLK_DIV)
                                     // 1=1/2 freq (最快), 2=1/4 freq, 4=1/8 freq 等
) (
    input  wire                     i_clk,
    input  wire                     i_reset,
    
    // 用户控制接口
    input  wire                     i_start_read,
    input  wire [ADDR_WIDTH-1:0]    i_addr,
    input  wire [ADDR_WIDTH-1:0]    i_length,
    
    // 流式数据输出
    output reg  [DATA_WIDTH-1:0]    o_data,
    output reg                      o_valid,
    output reg                      o_done,
    
    // 物理 SPI 接口 (均为寄存器输出，时序更好)
    output reg                      o_spi_cs_n,
    output reg                      o_spi_sck,
    output reg                      o_spi_mosi,
    input  wire                     i_spi_miso
);

    // ========================================================================
    // 参数定义
    // ========================================================================
    
    // 移位寄存器位宽: 命令(8) + 地址(24) = 32位
    // 注意：不需要额外的填充位，否则会导致发送数据错位
    localparam TOTAL_HEADER_BITS = 8 + ADDR_WIDTH; // 32 bits
    localparam CNT_W             = $clog2(TOTAL_HEADER_BITS);
    
    localparam [1:0] S_IDLE       = 2'd0,
                     S_SEND_HEADER= 2'd1, // 合并 CMD 和 ADDR
                     S_READ_DATA  = 2'd2,
                     S_FINISH     = 2'd3;

    // ========================================================================
    // 内部信号
    // ========================================================================
    reg [$clog2(CLK_DIV > 1 ? CLK_DIV : 1)-1:0] clk_cnt;
    wire                      sck_toggle_en; // SCK 翻转使能脉冲
    wire                      sck_rise_en;   // SCK 上升沿使能（采样）
    wire                      sck_fall_en;   // SCK 下降沿使能（数据改变）
    
    // 完整的命令+地址向量，用于预计算最高位
    wire [TOTAL_HEADER_BITS-1:0] cmd_addr_vector; 
    
    reg [TOTAL_HEADER_BITS-1:0]  header_shift_reg; 
    reg [7:0]                    data_shift_reg;
    
    reg [1:0]                    state;
    reg [CNT_W-1:0]              header_cnt;
    reg [2:0]                    bit_cnt;
    reg [ADDR_WIDTH-1:0]         byte_cnt;

    // 组合逻辑预组包：方便提取 MSB
    assign cmd_addr_vector = {CMD_READ, i_addr};

    // ========================================================================
    // 1. 时钟分频逻辑
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            clk_cnt <= 0;
        end else begin
            // 只要不是 IDLE，就运行计数器 (包含 S_FINISH)
            if (state != S_IDLE) begin
                if (clk_cnt == CLK_DIV - 1) 
                    clk_cnt <= 0;
                else 
                    clk_cnt <= clk_cnt + 1'b1;
            end else begin
                clk_cnt <= 0;
            end
        end
    end

    // 生成脉冲信号，用于同步逻辑
    assign sck_toggle_en = (clk_cnt == CLK_DIV - 1);
    assign sck_rise_en   = sck_toggle_en && (o_spi_sck == 1'b0); // 即将变为高
    assign sck_fall_en   = sck_toggle_en && (o_spi_sck == 1'b1); // 即将变为低

    // ========================================================================
    // 2. SCK 输出 (Glitch-free)
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            o_spi_sck <= 1'b0;
        end else if (sck_toggle_en) begin
            // 仅在数据传输阶段允许翻转
            if (state == S_SEND_HEADER || state == S_READ_DATA) begin
                o_spi_sck <= ~o_spi_sck;
            end else begin
                // S_FINISH 期间强制归零
                o_spi_sck <= 1'b0;
            end
        end else if (state == S_IDLE) begin
            o_spi_sck <= 1'b0;
        end
    end

    // ========================================================================
    // 3. MOSI 输出逻辑 (通用化 & 优化)
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            o_spi_mosi <= 1'b0;
        end else begin
            // 阶段 1: IDLE 预加载
            if (state == S_IDLE && i_start_read && i_length > 0) begin
                // 【优化点】：不再硬编码 1'b0，而是取实际 CMD 的 MSB
                o_spi_mosi <= cmd_addr_vector[TOTAL_HEADER_BITS-1];
            end 
            // 阶段 2: 发送头数据
            else if (state == S_SEND_HEADER && sck_fall_en) begin
                // 下降沿更新下一位。header_shift_reg 此时已包含了下一位的数据。
                // 注意：这里取最高位是因为我们在 IDLE 存入的是 << 1 之后的值
                //      或者是下面的移位逻辑配合。
                // 让我们看 header_shift_reg 的逻辑：
                // IDLE 时存入: vector << 1. 此时 [MSB] 是 Bit 30.
                // 所以这里取 [MSB] 是正确的。
                o_spi_mosi <= header_shift_reg[TOTAL_HEADER_BITS-1]; 
            end
            // 阶段 3: 读取数据阶段，MOSI 归零
            else if (state == S_READ_DATA && sck_fall_en) begin
                o_spi_mosi <= 1'b0;
            end
        end
    end

    // ========================================================================
    // 4. 主状态机与数据流
    // ========================================================================

    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            state            <= S_IDLE;
            o_spi_cs_n       <= 1'b1;
            o_valid          <= 1'b0;
            o_data           <= 0;
            o_done           <= 1'b0;
            header_shift_reg <= 0;
            data_shift_reg   <= 0;
            header_cnt       <= 0;
            bit_cnt          <= 0;
            byte_cnt         <= 0;
        end else begin
            o_valid <= 1'b0;
            o_done  <= 1'b0;

            case (state)
                S_IDLE: begin
                    o_spi_cs_n <= 1'b1;
                    if (i_start_read) begin
                        // 【优化点】：长度为 0 直接完成，不启动 SPI
                        if (i_length == 0) begin
                            o_done <= 1'b1;
                        end else begin
                            // 预加载移位寄存器
                            // 【优化点】：通用左移，不再预判 MSB 为 0
                            // 我们已经把 Bit 31 发给 MOSI 了，所以寄存器存 Bit 30~0 + 0
                            header_shift_reg <= {cmd_addr_vector[TOTAL_HEADER_BITS-2:0], 1'b0};
                            
                            byte_cnt   <= i_length;
                            header_cnt <= 0;
                            o_spi_cs_n <= 1'b0;
                            state      <= S_SEND_HEADER;
                        end
                    end
                end

                S_SEND_HEADER: begin
                    // 在下降沿移位数据，为下一次 MOSI 更新做准备
                    if (sck_fall_en) begin
                        // 【优化点】：低位补 0，避免垃圾数据
                        header_shift_reg <= {header_shift_reg[TOTAL_HEADER_BITS-2:0], 1'b0};
                    end

                    // 在上升沿计数 (Flash 采样时刻)
                    if (sck_rise_en) begin
                        header_cnt <= header_cnt + 1'b1;
                        if (header_cnt == TOTAL_HEADER_BITS - 1) begin
                            state   <= S_READ_DATA;
                            bit_cnt <= 0;
                        end
                    end
                end

                S_READ_DATA: begin
                    // 上升沿采样 MISO (Capture edge)
                    if (sck_rise_en) begin
                        // 修复：直接采样 i_spi_miso，避免 CLK_DIV=1 时的时序错位
                        // 之前的 miso_sync 会导致 1 个时钟周期的滞后，在高速模式下会读错位
                        data_shift_reg <= {data_shift_reg[6:0], i_spi_miso}; 
                        bit_cnt        <= bit_cnt + 1'b1;

                        if (bit_cnt == 3'd7) begin
                            // 一个字节接收完毕
                            o_data   <= {data_shift_reg[6:0], i_spi_miso};
                            o_valid  <= 1'b1;
                            byte_cnt <= byte_cnt - 1'b1;
                            
                            if (byte_cnt == 1) begin
                                state <= S_FINISH;
                            end
                        end
                    end
                end

                S_FINISH: begin
                    // 等待半个周期 (falling edge)，确保 SCK 已拉低 (由 SCK 逻辑保证)
                    // 再等待半个周期 (toggle_en)，Hold time 满足，拉高 CS
                    if (clk_cnt == CLK_DIV - 1) begin 
                         o_spi_cs_n <= 1'b1;
                         o_done     <= 1'b1;
                         state      <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
`default_nettype wire