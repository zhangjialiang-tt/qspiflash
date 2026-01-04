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
    parameter ADDR_WIDTH = 24,  // 地址位宽
    parameter DATA_WIDTH = 8,   // 数据位宽
    parameter CMD_WIDTH  = 8    // 命令位宽
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
    
    // 物理 SPI 接口
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
    localparam SHIFT_REG_W = CMD_WIDTH + ADDR_WIDTH;
    
    // 状态机状态定义
    localparam [2:0] SFS_IDLE       = 3'd0,
                     SFS_SEND_CMD   = 3'd1,
                     SFS_SEND_ADDR  = 3'd2,
                     SFS_READ_DATA  = 3'd3,
                     SFS_POST_READ  = 3'd4;
                     
    // 计数器位宽计算
    localparam BIT_CNT_W  = $clog2(DATA_WIDTH);
    localparam ADDR_CNT_W = $clog2(ADDR_WIDTH / DATA_WIDTH);

    // ========================================================================
    // 内部信号
    // ========================================================================
    
    reg [SHIFT_REG_W-1:0]    wdata_pipe;      // 发送移位寄存器
    reg                      actual_sck;      // 延迟的 SCK，用于边沿检测
    
    reg [2:0]                state;           // 主状态机
    reg [ADDR_WIDTH-1:0]     remaining_bytes; // 剩余读取字节数
    reg [BIT_CNT_W-1:0]      bit_count;       // 位计数 (0-7)
    reg [ADDR_CNT_W-1:0]     addr_byte_count; // 地址字节计数 (0-2)

    // ========================================================================
    // 边沿检测与输出逻辑
    // ========================================================================
    
    // 边沿检测
    wire sck_rising_edge  = (o_spi_sck && !actual_sck); // 0 -> 1
    wire sck_falling_edge = (!o_spi_sck && actual_sck); // 1 -> 0
    
    // MOSI 输出：始终连接到移位寄存器的最高位
    // 在 Mode 0 中，CS 拉低前数据就需要准备好，或者在第一个下降沿更新。
    // 这里 wdata_pipe 在 IDLE 加载时即准备好了最高位。
    always @(*) o_spi_mosi = wdata_pipe[SHIFT_REG_W-1];

    // ========================================================================
    // 1. SPI 时钟生成 (SCK)
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            o_spi_sck  <= 1'b0;
            actual_sck <= 1'b0;
        end else begin
            actual_sck <= o_spi_sck; // 打一拍用于检测边沿

            if (state == SFS_SEND_CMD || state == SFS_SEND_ADDR || state == SFS_READ_DATA) begin
                o_spi_sck <= ~o_spi_sck; // 传输状态下翻转
            end else begin
                o_spi_sck <= 1'b0;       // 空闲状态保持低电平
            end
        end
    end

    // ========================================================================
    // 2. 移位寄存器控制 (wdata_pipe)
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            wdata_pipe <= {SHIFT_REG_W{1'b0}};
        end else begin
            if (state == SFS_IDLE && i_start_read) begin
                // 加载命令(0x03)和地址。
                // 最高位是 0x03 的 MSB (0)，将直接呈现在 MOSI 上。
                wdata_pipe <= {8'h03, i_addr}; 
            end 
            else if (sck_falling_edge) begin
                // SPI Mode 0: 主机在下降沿更新数据 (Launch/Shift Out)
                // 仅在发送阶段移位。读取阶段 MOSI 保持不变即可。
                if (state == SFS_SEND_CMD || state == SFS_SEND_ADDR) begin
                    wdata_pipe <= {wdata_pipe[SHIFT_REG_W-2:0], 1'b0}; // 左移
                end
            end 
            else if (sck_rising_edge) begin
                // SPI Mode 0: 主机在上升沿采样数据 (Capture/Sample In)
                // 仅在读取阶段处理 MISO
                if (state == SFS_READ_DATA) begin
                    // 将 MISO 移入最低位。
                    // 注意：这里借用了 wdata_pipe 的低 8 位作为接收缓冲
                    wdata_pipe <= {wdata_pipe[SHIFT_REG_W-2:0], i_spi_miso};
                end
            end
        end
    end

    // ========================================================================
    // 3. 主状态机
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            state           <= SFS_IDLE;
            remaining_bytes <= 0;
            o_done          <= 1'b0;
            o_data          <= 0;
            o_valid         <= 1'b0;
            o_spi_cs_n      <= 1'b1;
            bit_count       <= 0;
            addr_byte_count <= 0;
        end else begin
            // 默认信号行为
            o_valid <= 1'b0; 
            o_done  <= 1'b0;

            case (state)
                SFS_IDLE: begin
                    o_spi_cs_n <= 1'b1;
                    if (i_start_read) begin
                        remaining_bytes <= i_length;
                        bit_count       <= 0;
                        addr_byte_count <= 0;
                        o_spi_cs_n      <= 1'b0; // 启动传输，拉低 CS
                        state           <= SFS_SEND_CMD;
                    end
                end

                SFS_SEND_CMD: begin
                    // 计数在上升沿进行（此时数据已被采样）
                    if (sck_rising_edge) begin
                        bit_count <= bit_count + 1'b1;
                        if (bit_count == 7) begin // 发送完 8 bit (0~7)
                            bit_count <= 0;
                            state     <= SFS_SEND_ADDR;
                        end
                    end
                end

                SFS_SEND_ADDR: begin
                    if (sck_rising_edge) begin
                        bit_count <= bit_count + 1'b1;
                        if (bit_count == 7) begin // 发送完 8 bit
                            bit_count <= 0;
                            addr_byte_count <= addr_byte_count + 1'b1;
                            
                            // 3字节地址发送完毕 (Count 0, 1, 2)
                            if (addr_byte_count == 2) begin 
                                state <= SFS_READ_DATA;
                            end
                        end
                    end
                end

                SFS_READ_DATA: begin
                    if (sck_rising_edge) begin
                        bit_count <= bit_count + 1'b1;
                        if (bit_count == 7) begin // 接收完 8 bit
                            // 数据组装输出：
                            // wdata_pipe[6:0] 包含前 7 位，i_spi_miso 是第 8 位
                            o_data  <= {wdata_pipe[6:0], i_spi_miso};
                            o_valid <= 1'b1;
                            
                            bit_count <= 0;
                            remaining_bytes <= remaining_bytes - 1'b1;

                            if (remaining_bytes <= 1) begin
                                // 所有请求字节读取完毕
                                state <= SFS_POST_READ;
                            end
                            // 否则保持状态，Flash 会自动递增地址继续输出
                        end
                    end
                end

                SFS_POST_READ: begin
                    o_spi_cs_n <= 1'b1; // 结束传输
                    o_done     <= 1'b1; // 发出完成信号
                    state      <= SFS_IDLE;
                end

                default: state <= SFS_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire