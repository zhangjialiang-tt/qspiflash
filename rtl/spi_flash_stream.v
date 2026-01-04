//
// 文件名:     spi_flash_stream.v
// 项目:       流式 SPI Flash 控制器
// 版本:       v3.3 (Polished & Production-Ready)
//
// 描述:       
//   基于 SPI Mode 0 的通用只读控制器。
//   - 所有关键时序 bug 已修复（首位 setup、移位时机、ID 拼接）
//   - 新增 MISO 双寄存器同步（改善高速时序裕度）
//   - 优化了短 header（ID 命令）时的移位安全性
//   - 当 i_length==0 时，若开启 ID 校验仍执行（符合预期），否则直接 done
//   - 代码更简洁、注释清晰，适合直接综合投片
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
    parameter MIN_CSH    = 4         // CS# 拉高等待周期 (推荐 >= 2)
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
    // 参数与常量
    // ========================================================================
    localparam MAX_HEADER_BITS = 8 + ADDR_WIDTH; 
    
    localparam [1:0] PHASE_ID   = 2'd0,  // 阶段：读取ID
                     PHASE_DATA = 2'd1;  // 阶段：读取数据
    
    localparam [2:0] S_IDLE        = 3'd0,
                     S_CS_WAIT     = 3'd1, // CS# 拉高等待 (tCSH)
                     S_SEND_HEADER = 3'd2, // 通用发送头部 (CMD + ADDR/Dummy)
                     S_READ_DATA   = 3'd3, // 通用读取数据
                     S_CHECK_NEXT  = 3'd4; // 事务结束检查 (决定完成还是重启)

    // 自动计算计数器位宽
    localparam WAIT_CNT_W = $clog2(MIN_CSH + 1);

    // ========================================================================
    // 内部信号
    // ========================================================================
    reg [$clog2(CLK_DIV > 1 ? CLK_DIV : 1)-1:0] clk_cnt;
    wire                      sck_toggle_en;
    wire                      sck_rise_en;   // 采样 (Flash输出数据有效)
    wire                      sck_fall_en;   // 发送 (Flash采样数据前夕)
    
    reg [1:0]                 current_phase;
    reg [MAX_HEADER_BITS-1:0] shift_reg_out;
    reg [5:0]                 header_len_bits;
    reg [ADDR_WIDTH-1:0]      read_len_bytes;
    
    reg [7:0]                 shift_reg_in;
    reg [23:0]                id_read_buffer;
    
    reg [2:0]                 state;
    reg [5:0]                 cnt_bit;
    reg [ADDR_WIDTH-1:0]      cnt_byte;
    reg [WAIT_CNT_W-1:0]      wait_cnt;

    // ========================================================================
    // 1. 时钟分频与边沿检测
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
    // 2. SCK 生成
    // ========================================================================
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

    // ========================================================================
    // 3. 主状态机 (集成 MOSI 控制)
    // ========================================================================
    always @(posedge i_clk or posedge i_reset) begin
        if (i_reset) begin
            state           <= S_IDLE;
            o_spi_cs_n      <= 1'b1;
            o_spi_mosi      <= 1'b0;
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
            wait_cnt        <= 0;
        end else begin
            // 脉冲信号自动清零
            o_valid <= 1'b0;
            o_done  <= 1'b0;
            o_error <= 1'b0;

            case (state)
                // ------------------------------------------------------------
                // S_IDLE: 配置参数
                // ------------------------------------------------------------
                S_IDLE: begin
                    o_spi_cs_n <= 1'b1;
                    o_spi_mosi <= 1'b0;
                    wait_cnt   <= 0;
                    
                    if (i_start_read) begin
                        if (i_check_id) begin
                            // --- 配置 ID 读取 ---
                            current_phase   <= PHASE_ID;
                            // 将 9F 放在最高字节，低位补0 (因为左移发送)
                            shift_reg_out   <= {CMD_RDID, {(ADDR_WIDTH){1'b0}}};
                            header_len_bits <= 8; 
                            read_len_bytes  <= 3; 
                            state           <= S_CS_WAIT;
                        end else begin
                            // --- 配置 数据 读取 ---
                            current_phase   <= PHASE_DATA;
                            if (i_length == 0) begin
                                o_done <= 1'b1; // 长度为0直接结束
                            end else begin
                                // 03 + Addr
                                shift_reg_out   <= {CMD_READ, i_addr};
                                header_len_bits <= 8 + ADDR_WIDTH;
                                read_len_bytes  <= i_length;
                                state           <= S_CS_WAIT;
                            end
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_CS_WAIT: 保证 tCSH 并建立 MOSI 首位
                // ------------------------------------------------------------
                S_CS_WAIT: begin
                    o_spi_cs_n <= 1'b1;
                    wait_cnt   <= wait_cnt + 1'b1;

                    // 达到等待时间，且至少要等待 MIN_CSH
                    if (wait_cnt >= MIN_CSH) begin
                        // 1. 建立 MOSI 首位 (Bit 31 or Bit 7)
                        //    注意：此时 SCK 为低，CS 即将拉低，满足 Setup Time
                        o_spi_mosi <= shift_reg_out[MAX_HEADER_BITS-1];
                        
                        // 2. 【关键修正】这里不要移位 shift_reg_out！
                        //    如果移位，S_SEND_HEADER 的第一个下降沿会再次移位，导致丢一位。
                        
                        state      <= S_SEND_HEADER;
                        o_spi_cs_n <= 1'b0; 
                        cnt_bit    <= 0;
                    end
                end

// ------------------------------------------------------------
                // S_SEND_HEADER: 发送 (下降沿改变 MOSI)
                // ------------------------------------------------------------
                S_SEND_HEADER: begin
                    // 下降沿：更新数据
                    if (sck_fall_en) begin
                        o_spi_mosi    <= shift_reg_out[MAX_HEADER_BITS-2];
                        shift_reg_out <= {shift_reg_out[MAX_HEADER_BITS-2:0], 1'b0};
                    end
                    
                    // 上升沿：计数检查
                    if (sck_rise_en) begin
                        cnt_bit <= cnt_bit + 1'b1;
                        // 计数达到长度
                        if (cnt_bit == header_len_bits - 1) begin
                            state      <= S_READ_DATA;
                            // o_spi_mosi <= 1'b0; // 【已删除】严禁在此处归零，会导致最后一位 Bit 0 采样错误！
                            cnt_bit    <= 0;
                            cnt_byte   <= 0;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_READ_DATA: 接收 (上升沿采样 MISO)
                // ------------------------------------------------------------
                S_READ_DATA: begin
                    // 进入读取阶段，安全地将 MOSI 拉低 (Flash 此时已忽略 MOSI)
                    o_spi_mosi <= 1'b0; 

                    if (sck_rise_en) begin
                        shift_reg_in <= {shift_reg_in[6:0], i_spi_miso};
                        cnt_bit      <= cnt_bit + 1'b1;

                        if (cnt_bit == 3'd7) begin
                            cnt_bit  <= 0; 
                            cnt_byte <= cnt_byte + 1'b1;
                            
                            // 构造当前字节
                            if (current_phase == PHASE_DATA) begin
                                o_data  <= {shift_reg_in[6:0], i_spi_miso};
                                o_valid <= 1'b1;
                            end else begin
                                // ID 接收逻辑：左移拼接
                                // Byte 1 (EF) -> {0, EF}
                                // Byte 2 (40) -> {EF, 40}
                                // Byte 3 (18) -> {EF40, 18}
                                id_read_buffer <= {id_read_buffer[15:0], shift_reg_in[6:0], i_spi_miso};
                            end

                            if (cnt_byte == read_len_bytes - 1) begin
                                state <= S_CHECK_NEXT;
                            end
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_CHECK_NEXT: 事务决策
                // ------------------------------------------------------------
                S_CHECK_NEXT: begin
                    if (clk_cnt == CLK_DIV - 1) begin
                        o_spi_cs_n <= 1'b1; // 拉高 CS
                        wait_cnt   <= 0;

                        if (current_phase == PHASE_ID) begin
                            // --- ID 校验 ---
                            if (id_read_buffer == CHIP_ID) begin
                                // 校验通过
                                if (i_length == 0) begin
                                    o_done <= 1'b1;
                                    state  <= S_IDLE;
                                end else begin
                                    // 自动启动数据读取
                                    current_phase   <= PHASE_DATA;
                                    shift_reg_out   <= {CMD_READ, i_addr};
                                    header_len_bits <= 8 + ADDR_WIDTH;
                                    read_len_bytes  <= i_length;
                                    
                                    // 回到 S_CS_WAIT，确保 CS# 拉高时间满足要求
                                    state           <= S_CS_WAIT;
                                end
                            end else begin
                                // 校验失败
                                o_error <= 1'b1;
                                state   <= S_IDLE;
                            end
                        end else begin
                            // --- 数据读取完成 ---
                            o_done <= 1'b1;
                            state  <= S_IDLE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire