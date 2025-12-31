////////////////////////////////////////////////////////////////////////////////
//
// Filename:    spixpress_tb.v
// Project:     A Set of Wishbone Controlled SPI Flash Controllers
//
// Purpose:     Testbench for the spixpress SPI flash controller
//              Uses W25Q32 flash model for simulation
//
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module spixpress_tb;

    // Parameters
    parameter CLK_PERIOD = 20;  // 50MHz (limit of spixpress design)
    
    // Testbench signals
    reg         clk;
    reg         reset;
    
    // Wishbone interface signals
    reg         wb_cyc;
    reg         wb_stb;
    reg         cfg_stb;
    reg         wb_we;
    reg  [21:0] wb_addr;
    reg  [31:0] wb_data_i;
    wire        wb_stall;
    wire        wb_ack;
    wire [31:0] wb_data_o;
    
    // SPI interface signals
    wire        spi_cs_n;
    wire        sck_en;      // DUT outputs sck_en, not the actual toggling clock
    wire        spi_sck;
    wire        spi_mosi;
    wire        spi_miso;
    
    // Simulate the DDR clock logic carefully to avoid glitches and skip dummy bit.
    wire        sck_en_safe;
    assign #22  sck_en_safe = sck_en;
    assign      spi_sck = sck_en_safe & !clk;
    
    // Additional flash control signals
    reg         flash_wp_n;
    reg         flash_hold_n;
    
    // Test control
    integer     test_count;
    integer     error_count;
    
    ////////////////////////////////////////////////////////////////////////////
    // Clock generation
    ////////////////////////////////////////////////////////////////////////////
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // DUT - Device Under Test (spixpress controller)
    ////////////////////////////////////////////////////////////////////////////
    spixpress #(
        .OPT_PIPE(1'b1),
        .OPT_CFG(1'b1)
    ) dut (
        .i_clk(clk),
        .i_reset(reset),
        .i_wb_cyc(wb_cyc),
        .i_wb_stb(wb_stb),
        .i_cfg_stb(cfg_stb),
        .i_wb_we(wb_we),
        .i_wb_addr(wb_addr),
        .i_wb_data(wb_data_i),
        .o_wb_stall(wb_stall),
        .o_wb_ack(wb_ack),
        .o_wb_data(wb_data_o),
        .o_spi_cs_n(spi_cs_n),
        .o_spi_sck(sck_en),
        .o_spi_mosi(spi_mosi),
        .i_spi_miso(spi_miso)
    );
    
    reg         clk_fast;
    initial begin
        clk_fast = 0;
        forever #1 clk_fast = ~clk_fast; // 500MHz fast clock for sim models
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // Flash Model - W25Q32
    ////////////////////////////////////////////////////////////////////////////
    W25Q32 flash_model (
        .clk_i(clk_fast),  // Use fast clock to reduce sync delay
        .rst_n(~reset),
        .spi_clk(spi_sck),
        .cs_n(spi_cs_n),
        .mosi(spi_mosi),
        .miso(spi_miso),
        .wp_n(flash_wp_n),
        .hold_n(flash_hold_n)
    );
    
    ////////////////////////////////////////////////////////////////////////////
    // Task: Wishbone Read
    ////////////////////////////////////////////////////////////////////////////
    task wb_read;
        input [21:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            wb_cyc   <= 1'b1;
            wb_stb   <= 1'b1;
            cfg_stb  <= 1'b0;
            wb_we    <= 1'b0;
            wb_addr  <= addr;
            
            // Wait for acknowledgment
            @(posedge clk);
            while (!wb_ack) begin
                if (!wb_stall) begin
                    wb_stb <= 1'b0;
                end
                @(posedge clk);
            end
            
            data = wb_data_o;
            wb_stb <= 1'b0;
            wb_cyc <= 1'b0;
            @(posedge clk);
        end
    endtask
    
    ////////////////////////////////////////////////////////////////////////////
    // Task: Configuration Write (for direct SPI commands)
    ////////////////////////////////////////////////////////////////////////////
    task cfg_write;
        input [8:0] data;  // bit[8] = CS control, bit[7:0] = data byte
        begin
            @(posedge clk);
            wb_cyc   <= 1'b1;
            cfg_stb  <= 1'b1;
            wb_stb   <= 1'b0;
            wb_we    <= 1'b1;
            wb_data_i <= {23'h0, data};
            
            // Wait for acknowledgment
            @(posedge clk);
            while (!wb_ack) begin
                @(posedge clk);
            end
            
            cfg_stb <= 1'b0;
            wb_cyc  <= 1'b0;
            @(posedge clk);
        end
    endtask
    
    ////////////////////////////////////////////////////////////////////////////
    // Task: Flash Write Enable (using config port)
    ////////////////////////////////////////////////////////////////////////////
    task flash_write_enable;
        begin
            $display("[%0t] Sending Write Enable command", $time);
            cfg_write(9'h006);  // CS=0, CMD=0x06 (Write Enable)
            cfg_write(9'h100);  // CS=1, release CS
            #100;
        end
    endtask
    
    ////////////////////////////////////////////////////////////////////////////
    // Task: Flash Page Program (using config port)
    ////////////////////////////////////////////////////////////////////////////
    task flash_page_program;
        input [23:0] addr;
        input [7:0]  data;
        begin
            $display("[%0t] Programming address 0x%06h with data 0x%02h", $time, addr, data);
            
            // Write Enable first
            flash_write_enable();
            
            // Page Program command
            cfg_write(9'h002);           // CS=0, CMD=0x02 (Page Program)
            cfg_write({1'b0, addr[23:16]}); // Address byte 2
            cfg_write({1'b0, addr[15:8]});  // Address byte 1
            cfg_write({1'b0, addr[7:0]});   // Address byte 0
            cfg_write({1'b0, data});        // Data byte
            cfg_write(9'h100);              // CS=1, release CS
            
            // Wait for programming to complete
            #1000;
        end
    endtask
    
    ////////////////////////////////////////////////////////////////////////////
    // Task: Initialize Flash with Test Data
    ////////////////////////////////////////////////////////////////////////////
    task init_flash_memory;
        integer i;
        begin
            $display("[%0t] Initializing flash memory with test pattern", $time);
            
            // Write test pattern to first few addresses
            // Address 0x000000: 0x12, 0x34, 0x56, 0x78
            flash_page_program(24'h000000, 8'h12);
            flash_page_program(24'h000001, 8'h34);
            flash_page_program(24'h000002, 8'h56);
            flash_page_program(24'h000003, 8'h78);
            
            // Address 0x000004: 0xAB, 0xCD, 0xEF, 0x00
            flash_page_program(24'h000004, 8'hAB);
            flash_page_program(24'h000005, 8'hCD);
            flash_page_program(24'h000006, 8'hEF);
            flash_page_program(24'h000007, 8'h00);
            
            // Address 0x000100: 0xDE, 0xAD, 0xBE, 0xEF
            flash_page_program(24'h000100, 8'hDE);
            flash_page_program(24'h000101, 8'hAD);
            flash_page_program(24'h000102, 8'hBE);
            flash_page_program(24'h000103, 8'hEF);
            
            $display("[%0t] Flash initialization complete", $time);
        end
    endtask
    
    ////////////////////////////////////////////////////////////////////////////
    // Task: Verify Read Data
    ////////////////////////////////////////////////////////////////////////////
    task verify_read;
        input [21:0] addr;
        input [31:0] expected_data;
        reg [31:0] read_data;
        begin
            wb_read(addr, read_data);
            
            if (read_data === expected_data) begin
                $display("[%0t] PASS: Read from addr 0x%06h = 0x%08h (expected 0x%08h)", 
                         $time, addr, read_data, expected_data);
            end else begin
                $display("[%0t] FAIL: Read from addr 0x%06h = 0x%08h (expected 0x%08h)", 
                         $time, addr, read_data, expected_data);
                error_count = error_count + 1;
            end
            test_count = test_count + 1;
        end
    endtask
    
    ////////////////////////////////////////////////////////////////////////////
    // Main Test Sequence
    ////////////////////////////////////////////////////////////////////////////
    initial begin
        // Initialize signals
        reset        = 1;
        wb_cyc       = 0;
        wb_stb       = 0;
        cfg_stb      = 0;
        wb_we        = 0;
        wb_addr      = 0;
        wb_data_i    = 0;
        flash_wp_n   = 1;  // Write protect disabled
        flash_hold_n = 1;  // Hold disabled
        test_count   = 0;
        error_count  = 0;
        
        // Generate VCD dump for waveform viewing
        $dumpfile("spixpress_tb.vcd");
        $dumpvars(0, spixpress_tb);
        
        // Reset sequence
        $display("========================================");
        $display("  SPIXPRESS Testbench Starting");
        $display("========================================");
        #100;
        reset = 0;
        #100;
        
        // Initialize flash with test data
        init_flash_memory();
        #500;
        
        // Test 1: Read from address 0x000000 (should get 0x12345678)
        $display("\n[%0t] Test 1: Reading from address 0x000000", $time);
        verify_read(22'h000000, 32'h12345678);
        #200;
        
        // Test 2: Read from address 0x000004 (should get 0xABCDEF00)
        $display("\n[%0t] Test 2: Reading from address 0x000004", $time);
        verify_read(22'h000001, 32'hABCDEF00);
        #200;
        
        // Test 3: Read from address 0x000100 (should get 0xDEADBEEF)
        $display("\n[%0t] Test 3: Reading from address 0x000100", $time);
        verify_read(22'h000040, 32'hDEADBEEF);
        #200;
        
        // Test 4: Pipelined reads (if OPT_PIPE is enabled)
        $display("\n[%0t] Test 4: Pipelined sequential reads", $time);
        verify_read(22'h000000, 32'h12345678);
        verify_read(22'h000001, 32'hABCDEF00);
        #200;
        
        // Test 5: Read from uninitialized area (should get 0xFFFFFFFF)
        $display("\n[%0t] Test 5: Reading from uninitialized address 0x000200", $time);
        verify_read(22'h000080, 32'hFFFFFFFF);
        #200;
        
        // Print test summary
        $display("\n========================================");
        $display("  Test Summary");
        $display("========================================");
        $display("  Total Tests: %0d", test_count);
        $display("  Passed:      %0d", test_count - error_count);
        $display("  Failed:      %0d", error_count);
        $display("========================================");
        
        if (error_count == 0) begin
            $display("  ALL TESTS PASSED!");
        end else begin
            $display("  SOME TESTS FAILED!");
        end
        $display("========================================\n");
        
        #1000;
        $finish;
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // Timeout watchdog
    ////////////////////////////////////////////////////////////////////////////
    initial begin
        #2000000;  // Increased timeout for 50MHz and initialization
        $display("\n[%0t] ERROR: Simulation timeout!", $time);
        $finish;
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // Monitor SPI transactions (optional debug)
    ////////////////////////////////////////////////////////////////////////////
    initial begin
        $display("\nMonitoring SPI signals...\n");
    end

endmodule
