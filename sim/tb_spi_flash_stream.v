`timescale 1ns / 1ns

module tb_spi_flash_stream;

    // ========================================================================
    // 参数定义
    // ========================================================================
    parameter ADDR_WIDTH = 24;
    parameter DATA_WIDTH = 8;
    
    // 时钟参数
    // DUT 时钟 50MHz (Period 20ns), SPI Sck 将为 25MHz
    parameter DUT_CLK_PERIOD = 20; 
    // Flash 模型时钟 200MHz (Period 5ns), 满足 > 4x SPI Clk 的要求
    parameter FLASH_CLK_PERIOD = 5; 

    // ========================================================================
    // 信号声明
    // ========================================================================
    
    // DUT 输入
    reg                     i_clk;
    reg                     i_reset;
    reg                     i_start_read;
    reg [ADDR_WIDTH-1:0]    i_addr;
    reg [ADDR_WIDTH-1:0]    i_length;
    
    // DUT 输出
    wire [DATA_WIDTH-1:0]   o_data;
    wire                    o_valid;
    wire                    o_done;
    
    // SPI 物理接口
    wire                    spi_cs_n;
    wire                    spi_sck;
    wire                    spi_mosi;
    wire                    spi_miso;

    // Flash 模型专用信号
    reg                     flash_clk;
    reg                     flash_rst_n;
    wire                    spi_wp_n   = 1'b1;
    wire                    spi_hold_n = 1'b1;

    // 仿真延迟信号：SCK 稍微滞后于数据和片选信号，确保采样窗口稳定
    wire                    spi_sck_delay;
    wire                    spi_cs_n_delay;
    wire                    spi_mosi_delay;
    
    assign #5 spi_sck_delay  = spi_sck;
    assign #1 spi_cs_n_delay = spi_cs_n;
    assign #1 spi_mosi_delay = spi_mosi;

    // 验证逻辑变量
    integer                 err_count = 0;
    reg [ADDR_WIDTH-1:0]    check_addr;
    reg [7:0]               expected_data;
    integer                 i;

    // ========================================================================
    // 模块实例化
    // ========================================================================

    // 1. 待测设计 (DUT)
    spi_flash_stream #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_dut (
        .i_clk          (i_clk),
        .i_reset        (i_reset),
        .i_start_read   (i_start_read),
        .i_check_id    (1'b1),
        .i_addr         (i_addr),
        .i_length       (i_length),
        .o_data         (o_data),
        .o_valid        (o_valid),
        .o_done         (o_done),
        .o_spi_cs_n     (spi_cs_n),
        .o_spi_sck      (spi_sck),
        .o_spi_mosi     (spi_mosi),
        .i_spi_miso     (spi_miso)
    );

    // 2. Flash 仿真模型 (W25Q128JVxIM)
    W25Q128JVxIM u_flash_model (
        .CSn            (spi_cs_n_delay),
        .CLK            (spi_sck_delay),
        .DIO            (spi_mosi_delay),
        .DO             (spi_miso),
        .WPn            (spi_wp_n),    // 写保护无效
        .HOLDn          (spi_hold_n)   // Hold 无效
    );

    // ========================================================================
    // 时钟生成
    // ========================================================================
    initial i_clk = 0;
    always #(DUT_CLK_PERIOD/2) i_clk = ~i_clk;

    initial flash_clk = 0;
    always #(FLASH_CLK_PERIOD/2) flash_clk = ~flash_clk;

    // ========================================================================
    // 测试流程
    // ========================================================================
    initial begin
        // 1. 初始化
        $display("------------------------------------------------");
        $display("Simulation Start");
        $display("------------------------------------------------");
        $dumpfile("spi_flash_stream.vcd");
        $dumpvars(0, tb_spi_flash_stream);

        // 信号初始化
        i_reset = 1;
        flash_rst_n = 0;
        i_start_read = 0;
        i_addr = 0;
        i_length = 0;
        
        // 2. 后门初始化 Flash 存储器内容
        // 填充模式：地址即数据 (memory[i] = i & 0xFF)
        // 注意：这里直接访问 Flash 实例内部的 memory 数组
        $display("[Testbench] Initializing Flash Memory via Backdoor...");
        for (i = 0; i < 4096; i = i + 1) begin
            u_flash_model.memory[i] = i[7:0]; 
        end

        // 3. 释放复位
        #100;
        i_reset = 0;
        flash_rst_n = 1;
        #100;

        // ------------------------------------------------------------
        // 测试用例 1: 从地址 0 读取 16 字节
        // ------------------------------------------------------------
        $display("[Test Case 1] Reading 16 bytes from Address 0x000000");
        run_read_test(24'h000000, 24'd16);

        #2000;

        // ------------------------------------------------------------
        // 测试用例 2: 从地址 0x000100 (0) 读取 32 字节
        // ------------------------------------------------------------
        $display("[Test Case 2] Reading 32 bytes from Address 0x000100");
        // 更改一下该区域的数据，确保不是读到默认值
        for (i = 0; i < 0+32; i = i + 1) begin
            u_flash_model.memory[i] = 8'hA5; // 填充 0xA5
        end
        run_read_test(24'h000100, 24'd32);

        #200;

        // ------------------------------------------------------------
        // 结束仿真
        // ------------------------------------------------------------
        if (err_count == 0) begin
            $display("------------------------------------------------");
            $display("TEST PASSED: All data matched expected values.");
            $display("------------------------------------------------");
        end else begin
            $display("------------------------------------------------");
            $display("TEST FAILED: Found %0d errors.", err_count);
            $display("------------------------------------------------");
        end
        $finish;
    end

    // ========================================================================
    // 任务定义：执行读取并等待完成
    // ========================================================================
    task run_read_test;
        input [ADDR_WIDTH-1:0] start_addr;
        input [ADDR_WIDTH-1:0] len;
    begin
        // 设置验证起始地址
        check_addr = start_addr;
        
        // 发送脉冲
        @(posedge i_clk);
        i_addr <= start_addr;
        i_length <= len;
        i_start_read <= 1'b1;
        
        @(posedge i_clk);
        i_start_read <= 1'b0;

        // 等待完成信号
        wait(o_done);
        @(posedge i_clk);
    end
    endtask

    // ========================================================================
    // 自动比对逻辑 (Monitor)
    // ========================================================================
    always @(posedge i_clk) begin
        if (o_valid) begin
            // 从 Flash 模型中获取预期数据
            expected_data = u_flash_model.memory[check_addr];
            
            if (o_data !== expected_data) begin
                $display("[ERROR] Time %t: Addr 0x%h - Expected 0x%h, Got 0x%h", 
                         $time, check_addr, expected_data, o_data);
                err_count = err_count + 1;
            end else begin
                // 可选：打印成功信息（数据量大时建议注释掉）
                // $display("[OK] Time %t: Addr 0x%h - Data 0x%h", $time, check_addr, o_data);
            end
            
            // 指向下一个预期地址
            check_addr = check_addr + 1;
        end
    end

    // ========================================================================
    // SPI 协议监视 (可选，用于调试波形)
    // ========================================================================
    // 如果需要查看发送的命令和地址是否正确，可以观察 waves 中的 wdata_pipe 
    // 或者在这里添加 MOSI 捕捉逻辑。

endmodule