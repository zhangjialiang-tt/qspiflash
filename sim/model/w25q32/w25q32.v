module W25Q32 (
    input  wire        clk_i,     
    input  wire        rst_n,     
    input  wire        spi_clk,   
    input  wire        cs_n,      
    input  wire        mosi,       
    output wire        miso,
    input  wire        wp_n,      
    input  wire        hold_n  
);

    // W25Q32 Parameters
    localparam MEMORY_SIZE = 4*1024;       // 4KB (changes due to large array size) 
    localparam PAGE_SIZE   = 64;           // 64 bytes per page
    localparam SECTOR_SIZE = 512;          // 512 bytes per block (was 1024)
    localparam ADDR_WIDTH  = 24;           // Keep 24-bit addressing
    localparam DEVICE_ID   = 8'h15;        // Device ID for W25Q32
    localparam MANUFACTURER = 8'hEF;       // Manufacturer ID for Winbond

    // Instruction Opcodes
    localparam CMD_WRITE_ENABLE  = 8'h06;  // Write Enable
    localparam CMD_PAGE_PROGRAM  = 8'h02;  // Page Program
    localparam CMD_READ_DATA     = 8'h03;  // Read Data
    localparam CMD_WRITE_DISABLE = 8'h04;  // Write Disable
    localparam CMD_SECTOR_ERASE  = 8'h20;  // Sector Erase
    localparam CMD_CHIP_ERASE    = 8'hC7;  // Chip Erase
    localparam CMD_CHIP_ERASE2   = 8'h60;  // Chip Erase (same as the above)
    localparam CMD_READ_STATUS   = 8'h05;  // Read Status Register
    localparam CMD_READ_MFG_ID   = 8'h90;  // Read Manufacturer/Device ID

    // Status Register Bits
    localparam BUSY_BIT = 0;  // S0
    localparam WEL_BIT  = 1;  // S1

    // SPI Slave interface wires
    wire       spi_rx_dv;
    wire [7:0] spi_rx_byte;
    reg        spi_tx_dv;
    reg  [7:0] spi_tx_byte;
    wire       spi_miso;

    reg        write_enable;      // Write enable flag

    // Tie physical wires
    assign miso = spi_miso;

    // Instantiate SPI_Slave
    SPI_Slave #(
        .SPI_MODE(0)
    ) spi_slave_inst (
        .i_Rst_L   (rst_n),
        .i_Clk     (clk_i),
        .o_RX_DV   (spi_rx_dv),
        .o_RX_Byte (spi_rx_byte),
        .i_TX_DV   (spi_tx_dv),
        .i_TX_Byte (spi_tx_byte),
        .i_SPI_Clk (spi_clk),
        .o_SPI_MISO(spi_miso),
        .i_SPI_MOSI(mosi),
        .i_SPI_CS_n(cs_n)
    );

    // State Machine States
    localparam STATE_IDLE         = 4'b0000;
    localparam STATE_CMD          = 4'b0001;
    localparam STATE_ADDR         = 4'b0010;
    localparam STATE_READ_DATA    = 4'b0011;
    localparam STATE_PAGE_PROGRAM = 4'b0100;
    localparam STATE_READ_STATUS  = 4'b0101;
    localparam STATE_READ_MFG_ID  = 4'b0110;

    // Internal Registers
    reg [3:0]  state;
    reg [7:0]  status_reg;        
    reg [7:0]  command_reg;     
    reg [23:0] address_reg;     
    reg [4:0]  byte_counter;
    reg [1:0]  mfg_id_counter;    // Counter for manufacturer/device ID output

    // Erase operation states
    localparam ERASE_IDLE    = 2'b00;
    localparam ERASE_CHIP    = 2'b01;
    localparam ERASE_SECTOR  = 2'b10;

    // Erase operation registers 
    reg [1:0]  erase_state;
    reg [23:0] erase_addr;
    reg [15:0] erase_counter;    // Counter for erase timing
    reg [7:0]  erase_data_count; // Counter for writing erase data

    // Memory array 
    reg [7:0] memory [0:MEMORY_SIZE-1];

    integer i;
    // Initialize memory
    initial begin
        for (i = 0; i < MEMORY_SIZE; i = i + 1) begin
            memory[i] = 8'hFF;  //Default erased state
        end
        status_reg = 8'h00;
        write_enable = 1'b0;
        erase_state = ERASE_IDLE;
        mfg_id_counter = 2'b00;
    end

    // Main SPI State Machine
    always @(posedge clk_i) begin
        if (!rst_n) begin
            state       <= STATE_IDLE;
            command_reg <= 8'h00;
            address_reg <= 24'h000000;
            status_reg[BUSY_BIT] <= 1'b0;
            status_reg[WEL_BIT]  <= 1'b0;
            byte_counter<= 5'h00;
            spi_tx_dv   <= 1'b0;
            spi_tx_byte <= 8'h00;
            mfg_id_counter <= 2'b00;
            erase_state <= ERASE_IDLE;
            erase_addr <= 24'h000000;
            erase_counter <= 16'h0000;
            erase_data_count <= 8'h00;
            write_enable <= 1'b0;
        end else begin
            // Default: Don't transmit unless specifically set below
            spi_tx_dv <= 1'b0;
            
            // Main SPI State Machine Logic
            case (state)
                STATE_IDLE: begin
                    if (spi_rx_dv && !cs_n) begin
                        command_reg <= spi_rx_byte;
                        byte_counter<= 0;
                        mfg_id_counter <= 2'b00;
                        state <= STATE_CMD;
                    end
                end

                STATE_CMD: begin
                    if (cs_n) begin
                        state <= STATE_IDLE;
                        // Handle commands that complete on CS deassertion
                        if (command_reg == CMD_WRITE_ENABLE) begin
                            write_enable <= 1'b1;
                            status_reg[WEL_BIT] <= 1'b1;
                        end else if (command_reg == CMD_WRITE_DISABLE) begin
                            write_enable <= 1'b0;
                            status_reg[WEL_BIT] <= 1'b0;
                        end else if ((command_reg == CMD_CHIP_ERASE || command_reg == CMD_CHIP_ERASE2) && write_enable) begin
                            erase_state <= ERASE_CHIP;
                            erase_addr <= 24'h000000;
                            status_reg[BUSY_BIT] <= 1'b1;
                            erase_counter <= 16'h1000;
                            erase_data_count <= 8'h00;
                            write_enable <= 1'b0;
                            status_reg[WEL_BIT] <= 1'b0;
                        end else if (command_reg == CMD_SECTOR_ERASE && write_enable) begin
                            erase_state <= ERASE_SECTOR;
                            erase_addr <= (address_reg / SECTOR_SIZE) * SECTOR_SIZE;
                            status_reg[BUSY_BIT] <= 1'b1;
                            erase_counter <= 16'h0100;
                            erase_data_count <= 8'h00;
                            write_enable <= 1'b0;
                            status_reg[WEL_BIT] <= 1'b0;
                        end else if (command_reg == CMD_PAGE_PROGRAM && write_enable) begin
                            status_reg[BUSY_BIT] <= 1'b0;
                            write_enable <= 1'b0;
                            status_reg[WEL_BIT] <= 1'b0;
                        end
                    end else begin
                        // Handle commands that need address
                        if ((command_reg == CMD_READ_DATA || command_reg == CMD_PAGE_PROGRAM || 
                             command_reg == CMD_SECTOR_ERASE || command_reg == CMD_READ_MFG_ID) && spi_rx_dv) begin
                            address_reg[23:16] <= spi_rx_byte;
                            byte_counter <= 1;
                            state <= STATE_ADDR;
                            if (command_reg == CMD_PAGE_PROGRAM) begin
                                status_reg[BUSY_BIT] <= 1'b1;
                            end
                        end
                        // Handle commands without address
                        else if (command_reg == CMD_READ_STATUS) begin
                            state <= STATE_READ_STATUS;
                        end
                    end
                end

                STATE_ADDR: begin
                    if (cs_n) begin
                        state <= STATE_IDLE;
                    end else if (spi_rx_dv) begin
                        if (byte_counter == 1) begin
                            address_reg[15:8] <= spi_rx_byte;
                            byte_counter <= 2;
                        end else if (byte_counter == 2) begin
                            address_reg[7:0] <= spi_rx_byte;
                            // Transition to appropriate data state
                            if (command_reg == CMD_READ_DATA) begin
                                state <= STATE_READ_DATA;
                            end else if (command_reg == CMD_PAGE_PROGRAM && write_enable) begin
                                state <= STATE_PAGE_PROGRAM;
                            end else if (command_reg == CMD_READ_MFG_ID) begin
                                state <= STATE_READ_MFG_ID;
                                mfg_id_counter <= 2'b00;
                            end
                        end
                    end
                end

                STATE_READ_DATA: begin
                    if (cs_n) begin
                        state <= STATE_IDLE;
                    end else begin
                        // Always output current memory data
                        if (address_reg < MEMORY_SIZE) begin
                            spi_tx_byte <= memory[address_reg];
                        end else begin
                            spi_tx_byte <= 8'hFF; // Out of bounds
                        end
                        spi_tx_dv <= 1'b1;

                        // Increment address for next byte when current byte is read
                        if (spi_rx_dv) begin
                            address_reg <= (address_reg + 1) % MEMORY_SIZE; // Wrap around
                        end
                    end
                end

                STATE_PAGE_PROGRAM: begin
                    if (cs_n) begin
                        state <= STATE_IDLE;
                        status_reg[BUSY_BIT] <= 1'b0;
                    end else if (spi_rx_dv && write_enable && address_reg < MEMORY_SIZE) begin
                        // MEMORY WRITE - PAGE PROGRAM
                        memory[address_reg] <= spi_rx_byte;

                        if ((address_reg & (PAGE_SIZE-1)) == (PAGE_SIZE-1)) begin
                            address_reg <= address_reg & ~(PAGE_SIZE-1);
                        end else begin
                            address_reg <= address_reg + 1;
                        end
                    end
                end

                STATE_READ_STATUS: begin
                    if (cs_n) begin
                        state <= STATE_IDLE;
                    end else begin
                        spi_tx_byte <= status_reg;
                        spi_tx_dv <= 1'b1;
                    end
                end

                STATE_READ_MFG_ID: begin
                    if (cs_n) begin
                        state <= STATE_IDLE;
                    end else begin
                        // Output manufacturer ID first, then device ID, then repeat
                        case (mfg_id_counter[0])
                            1'b0: begin
                                spi_tx_byte <= MANUFACTURER;  // EFh
                                spi_tx_dv <= 1'b1;
                            end
                            1'b1: begin
                                spi_tx_byte <= DEVICE_ID;     // 15h
                                spi_tx_dv <= 1'b1;
                            end
                        endcase

                        // Increment counter when data is clocked out
                        if (spi_rx_dv) begin
                            mfg_id_counter <= mfg_id_counter + 1;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase

            // Erase Operation Logic (now integrated in single always block)
            case (erase_state)
                ERASE_CHIP: begin
                    if (erase_counter > 0) begin
                        erase_counter <= erase_counter - 1;
                    end else if (erase_addr < MEMORY_SIZE) begin
                        // MEMORY WRITE - CHIP ERASE
                        // Write one location per clock cycle for better synthesis
                        memory[erase_addr] <= 8'hFF;
                        erase_addr <= erase_addr + 1;
                        
                        // Add small delay every 256 bytes for more realistic timing
                        if (erase_addr[7:0] == 8'hFF) begin
                            erase_counter <= 16'h0010;
                        end
                    end else begin
                        erase_state <= ERASE_IDLE;
                        status_reg[BUSY_BIT] <= 1'b0;
                    end
                end

                ERASE_SECTOR: begin
                    if (erase_counter > 0) begin
                        erase_counter <= erase_counter - 1;
                    end else if (erase_data_count < SECTOR_SIZE) begin
                        // MEMORY WRITE - SECTOR ERASE
                        // Write one location per clock cycle
                        memory[erase_addr + erase_data_count] <= 8'hFF;
                        erase_data_count <= erase_data_count + 1;
                    end else begin
                        erase_state <= ERASE_IDLE;
                        status_reg[BUSY_BIT] <= 1'b0;
                    end
                end

                default: ; // ERASE_IDLE - do nothing
            endcase
        end
    end

endmodule