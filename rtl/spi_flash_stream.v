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
    parameter CLK_DIV    = 2         // 分频系数: SCK_Freq = i_clk / (2 * CLK_DIV)
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
    // 状态机状态定义
    localparam [1:0] S_IDLE       = 2'd0,
                     S_SEND_HEADER= 2'd1, // 合并 CMD 和 ADDR
                     S_READ_DATA  = 2'd2,
                     S_FINISH     = 2'd3;

    // ========================================================================
    // 内部信号
    // ========================================================================
    
    // 时钟生成相关
    reg [$clog2(CLK_DIV)-1:0] clk_cnt;
    wire                      sck_toggle_en; // SCK 翻转使能脉冲
    wire                      sck_rise_en;   // SCK 上升沿使能（采样）
    wire                      sck_fall_en;   // SCK 下降沿使能（数据改变）
    
    // 数据通路
    reg [TOTAL_HEADER_BITS-1:0] header_shift_reg; // 专用于发送的移位寄存器
    reg [7:0]                   data_shift_reg;   // 专用于接收的移位寄存器
    reg                         miso_sync;        // MISO 同步/寄存
    
    // 状态机计数
    reg [1:0]                   state;
    reg [5:0]                   header_cnt;       // 0~31
    reg [2:0]                   bit_cnt;          // 0~7
    reg [ADDR_WIDTH-1:0]        byte_cnt;         // 剩余字节

    // ========================================================================
    // 1. 时钟分频逻辑
    // ========================================================================
    // 生成 SCK 翻转的使能信号，实现灵活分频
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            clk_cnt <= 0;
        end else begin
            // 修正：只要不是 IDLE 状态，都需要计数器工作
            // S_FINISH 状态也需要计数来维持最后的 Hold Time
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
    // SCK 输出逻辑 (修复 Glitch 版)
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            o_spi_sck <= 1'b0;
        end else if (sck_toggle_en) begin
            // 只有在真正传输数据的状态下才允许翻转
            if (state == S_SEND_HEADER || state == S_READ_DATA) begin
                o_spi_sck <= ~o_spi_sck;
            end 
            // 在 S_FINISH 或 IDLE 状态下，Toggle 时刻强制拉低
            // 1. 如果当前是高（刚读完最后一位），这里会变成低（产生最后一个下降沿）
            // 2. 如果当前是低，保持低
            else begin
                o_spi_sck <= 1'b0;
            end
        end else if (state == S_IDLE) begin
            o_spi_sck <= 1'b0;
        end
    end

    // ========================================================================
    // 2. 输入信号寄存 (改善时序)
    // ========================================================================
    always @(posedge i_clk) begin
        miso_sync <= i_spi_miso;
    end

    // ========================================================================
    // 3. MOSI 输出逻辑 (改善时序)
    // ========================================================================
    // 提前计算 MOSI，使其直接从寄存器输出
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            o_spi_mosi <= 1'b0;
        end else begin
            if (state == S_IDLE && i_start_read) begin
                // IDLE 状态直接加载最高位，准备好 setup time
                o_spi_mosi <= 1'b0; // CMD 0x03 (0000_0011) 的最高位是 0
            end 
            else if (state == S_SEND_HEADER && sck_fall_en) begin
                // 在下降沿时刻更新下一位数据 (Launch edge)
                // header_shift_reg 此时已经移位过了，直接取最高位
                o_spi_mosi <= header_shift_reg[TOTAL_HEADER_BITS-1]; 
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
                        // 载入 CMD (0x03) 和 Address
                        // 注意：这里左移一位，因为最高位已经在 MOSI 逻辑中被预取了
                        // 或者更简单的逻辑：shift reg 保存 {CMD, ADDR}，MOSI 取 [MSB]
                        // 此处为了配合 MOSI 的 fall_en 更新逻辑：
                        // 我们载入完整数据，MOSI 逻辑会在下一个 fall_en 取出新的一位
                        // 这里的 header_shift_reg 用于存储 *下一位* 之后的数据
                        header_shift_reg <= {8'h03, i_addr} << 1; 
                        
                        byte_cnt   <= i_length;
                        header_cnt <= 0;
                        o_spi_cs_n <= 1'b0;
                        state      <= S_SEND_HEADER;
                    end
                end

                S_SEND_HEADER: begin
                    // 在下降沿移位数据，为下一次 MOSI 更新做准备
                    if (sck_fall_en) begin
                        header_shift_reg <= header_shift_reg << 1;
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
                        // 移入数据
                        data_shift_reg <= {data_shift_reg[6:0], miso_sync};
                        bit_cnt        <= bit_cnt + 1'b1;

                        if (bit_cnt == 3'd7) begin
                            // 一个字节接收完毕
                            o_data   <= {data_shift_reg[6:0], miso_sync};
                            o_valid  <= 1'b1;
                            byte_cnt <= byte_cnt - 1'b1;
                            
                            if (byte_cnt == 1) begin
                                state <= S_FINISH;
                            end
                        end
                    end
                end

                S_FINISH: begin
                    // 确保 SCK 回到低电平后再拉高 CS，保持至少半个周期的 hold time
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