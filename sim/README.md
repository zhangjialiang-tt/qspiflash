# SPIXPRESS Testbench 使用说明

## 概述

这是为 `spixpress.v` SPI Flash 控制器创建的testbench，使用 W25Q32 SPI Flash 仿真模型进行功能验证。

## 文件说明

- **spixpress_tb.v** - 主testbench文件
- **Makefile** - Linux/Unix环境下的编译脚本
- **run_sim.bat** - Windows环境下的批处理脚本
- **model/** - SPI Flash仿真模型目录
  - `w25q32.v` - W25Q32 Flash模型
  - `SPI_Slave.v` - SPI从设备接口模块

## 仿真环境要求

### Windows环境
需要安装 Icarus Verilog:
- 下载地址: http://bleyer.org/icarus/
- 安装后确保 `iverilog` 和 `vvp` 在系统PATH中

### Linux/Unix环境
```bash
# Ubuntu/Debian
sudo apt-get install iverilog

# CentOS/RHEL
sudo yum install iverilog

# macOS
brew install icarus-verilog
```

## 运行仿真

### Windows环境
双击运行或在命令行执行:
```cmd
run_sim.bat
```

### Linux/Unix环境
```bash
make sim
```

## 查看波形

仿真完成后会生成 `spixpress_tb.vcd` 波形文件。

### 使用GTKWave查看
```bash
# Linux/Unix
make wave

# Windows
gtkwave spixpress_tb.vcd
```

## Testbench功能说明

### 测试内容

1. **Flash初始化** - 通过配置端口向Flash写入测试数据
2. **基本读取** - 从不同地址读取数据并验证
3. **流水线读取** - 测试连续地址的流水线读取功能
4. **边界测试** - 读取未初始化区域（应返回0xFF）

### 测试数据

Testbench会在Flash中写入以下测试数据:

| 地址 (24位) | 数据 (32位) | 说明 |
|-------------|-------------|------|
| 0x000000    | 0x12345678  | 测试模式1 |
| 0x000004    | 0xABCDEF00  | 测试模式2 |
| 0x000100    | 0xDEADBEEF  | 测试模式3 |

### 关键任务 (Tasks)

- `wb_read(addr, data)` - Wishbone读操作
- `cfg_write(data)` - 配置端口写操作
- `flash_write_enable()` - Flash写使能
- `flash_page_program(addr, data)` - Flash页编程
- `verify_read(addr, expected)` - 读取并验证数据

## 仿真参数

### DUT参数配置
```verilog
spixpress #(
    .OPT_PIPE(1'b1),    // 启用流水线模式
    .OPT_CFG(1'b1)      // 启用配置端口
) dut (
    ...
);
```

### 时钟配置
- 系统时钟: 100MHz (10ns周期)
- SPI时钟: 由spixpress控制器生成

## 调试技巧

### 1. 增加调试信息
在testbench中已包含详细的 `$display` 语句，显示:
- 测试步骤
- 读写操作
- 数据比对结果

### 2. 波形分析
重点关注以下信号:
- `spi_cs_n` - 片选信号
- `spi_sck` - SPI时钟
- `spi_mosi` - 主机输出数据
- `spi_miso` - 从机输入数据
- `wb_ack` - Wishbone应答
- `wb_data_o` - 读取的数据

### 3. 修改测试用例
可以在 `initial` 块中添加更多测试:
```verilog
// 添加自定义测试
verify_read(22'h000008, 32'hYOUR_DATA);
```

## 常见问题

### Q1: 编译错误 "unknown module"
**A:** 检查文件路径是否正确，确保所有源文件都在正确位置。

### Q2: 仿真超时
**A:** 检查Flash初始化是否成功，可能需要增加等待时间。

### Q3: 读取数据不匹配
**A:** 
- 检查Flash编程是否成功
- 验证地址对齐（spixpress使用字对齐）
- 查看波形确认SPI时序

### Q4: Windows下找不到iverilog
**A:** 
- 确认已安装Icarus Verilog
- 将安装目录添加到系统PATH
- 重启命令行窗口

## 扩展测试

### 添加更多测试场景

1. **擦除测试**
```verilog
// 添加扇区擦除测试
task flash_sector_erase;
    // 实现擦除功能
endtask
```

2. **状态寄存器读取**
```verilog
// 读取Flash状态
cfg_write(9'h005);  // Read Status Register
```

3. **制造商ID读取**
```verilog
// 读取制造商ID
cfg_write(9'h090);  // Read Manufacturer ID
```

## 参考文档

- `rtl/spixpress.v` - 控制器RTL源码及注释
- W25Q32 Datasheet - Flash芯片规格书
- Wishbone B4 Specification - 总线协议规范

## 版本历史

- v1.0 (2025-12-31) - 初始版本
  - 基本读写测试
  - W25Q32模型集成
  - 流水线读取测试

## 联系方式

如有问题或建议，请参考项目主README文件。
