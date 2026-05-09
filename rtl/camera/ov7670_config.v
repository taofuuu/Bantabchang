`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// OV7670 SCCB Configuration Module
// 
// This module configures the OV7670 camera via SCCB (similar to I2C)
// Sends initialization register values to set up QVGA (320x240) RGB444 mode
//////////////////////////////////////////////////////////////////////////////////

module ov7670_config(
    input wire clk,              // System clock (100 MHz)
    input wire reset,
    output reg sioc,             // SCCB clock (max 400 kHz)
    inout wire siod,             // SCCB data (bidirectional)
    output reg config_done       // High when configuration complete
);

    // SCCB timing parameters (for 100MHz clock)
    parameter CLOCK_DIV = 250;   // Divide 100MHz to ~400kHz
    
    // Camera I2C address
    parameter CAM_ADDR = 8'h42;  // OV7670 write address (0x42)
    
    // State machine states
    localparam IDLE        = 0;
    localparam START       = 1;
    localparam ADDR_WRITE  = 2;
    localparam REG_WRITE   = 3;
    localparam DATA_WRITE  = 4;
    localparam STOP        = 5;
    localparam NEXT_REG    = 6;
    localparam DONE        = 7;
    
    reg [3:0] state;
    reg [7:0] clk_count;
    reg [7:0] bit_count;
    reg [7:0] reg_index;
    reg sda_out;
    reg sda_oe;  // Output enable for bidirectional pin
    
    assign siod = sda_oe ? sda_out : 1'bz;
    
    // Configuration registers (register address, data value)
    // These settings configure the camera for QVGA RGB444 output
    reg [15:0] config_regs [0:35];
    
    initial begin
        // Basic configuration for QVGA (320x240) RGB444
        config_regs[0]  = 16'h12_80;  // COM7: Reset all registers
        config_regs[1]  = 16'h12_04;  // COM7: QVGA + RGB
        config_regs[2]  = 16'h11_01;  // CLKRC: Use external clock directly
        config_regs[3]  = 16'h0C_00;  // COM3: Default
        config_regs[4]  = 16'h3E_00;  // COM14: Default
        config_regs[5]  = 16'h8C_00;  // RGB444
        config_regs[6]  = 16'h04_00;  // COM1: Default
        config_regs[7]  = 16'h40_D0;  // COM15: RGB444, full output range
        config_regs[8]  = 16'h3A_04;  // TSLB
        config_regs[9]  = 16'h14_18;  // COM9: AGC setting
        config_regs[10] = 16'h4F_B3;  // MTX1
        config_regs[11] = 16'h50_B3;  // MTX2
        config_regs[12] = 16'h51_00;  // MTX3
        config_regs[13] = 16'h52_3D;  // MTX4
        config_regs[14] = 16'h53_A7;  // MTX5
        config_regs[15] = 16'h54_E4;  // MTX6
        config_regs[16] = 16'h58_9E;  // MTXS
        config_regs[17] = 16'h3D_C0;  // COM13
        config_regs[18] = 16'h17_14;  // HSTART
        config_regs[19] = 16'h18_02;  // HSTOP
        config_regs[20] = 16'h32_80;  // HREF
        config_regs[21] = 16'h19_03;  // VSTART
        config_regs[22] = 16'h1A_7B;  // VSTOP
        config_regs[23] = 16'h03_0A;  // VREF
        config_regs[24] = 16'h0E_61;  // COM5
        config_regs[25] = 16'h0F_4B;  // COM6
        config_regs[26] = 16'h16_02;  // Reserved
        config_regs[27] = 16'h1E_07;  // MVFP: Mirror/VFlip
        config_regs[28] = 16'h21_02;  // ADCCTR1
        config_regs[29] = 16'h22_91;  // ADCCTR2
        config_regs[30] = 16'h29_07;  // RSVD
        config_regs[31] = 16'h33_0B;  // CHLF
        // --- ปรับปรุงความคมชัด (Edge Enhancement) ---
        config_regs[32] = 16'h3F_04;  // EDGE: ปรับ Threshold ของขอบภาพ
        config_regs[33] = 16'h75_E1;  // EDG1: เปิดใช้งาน Edge Enhancement และจูนค่า Gain
        config_regs[34] = 16'h76_E1;  // COM16: เปิดใช้งาน Edge Enhancement ในระดับระบบ

        // --- ปรับความสดของสี (Saturation) และ Contrast ---
        config_regs[35] = 16'h41_08;  // COM10: ช่วยเรื่อง Noise และความคมของสัญญาณ
        // หากต้องการเพิ่มความเข้มของสี (Saturation) ให้ลองปรับที่ Register 0x67 ถึง 0x69
    end
    
    reg [15:0] current_reg;
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    
    assign reg_addr = current_reg[15:8];
    assign reg_data = current_reg[7:0];
    
    // SCCB clock generation
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            clk_count <= 0;
            sioc <= 1;
        end else begin
            if (clk_count >= CLOCK_DIV - 1) begin
                clk_count <= 0;
                sioc <= ~sioc;
            end else begin
                clk_count <= clk_count + 1;
            end
        end
    end
    
    wire sccb_clk_edge = (clk_count == 0);
    
    // SCCB state machine
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            reg_index <= 0;
            config_done <= 0;
            sda_out <= 1;
            sda_oe <= 0;
            bit_count <= 0;
        end else if (sccb_clk_edge && sioc) begin  // Execute on SIOC high
            case (state)
                IDLE: begin
                    if (reg_index < 32) begin
                        current_reg <= config_regs[reg_index];
                        state <= START;
                        sda_oe <= 1;
                    end else begin
                        state <= DONE;
                    end
                end
                
                START: begin
                    sda_out <= 0;  // START condition: SDA goes low while SCL is high
                    bit_count <= 8;
                    state <= ADDR_WRITE;
                end
                
                ADDR_WRITE: begin
                    if (bit_count > 0) begin
                        sda_out <= CAM_ADDR[bit_count-1];
                        bit_count <= bit_count - 1;
                    end else begin
                        sda_oe <= 0;  // Release for ACK
                        bit_count <= 8;
                        state <= REG_WRITE;
                    end
                end
                
                REG_WRITE: begin
                    if (bit_count == 8) begin
                        sda_oe <= 1;  // Take back control after ACK
                    end
                    if (bit_count > 0) begin
                        sda_out <= reg_addr[bit_count-1];
                        bit_count <= bit_count - 1;
                    end else begin
                        sda_oe <= 0;  // Release for ACK
                        bit_count <= 8;
                        state <= DATA_WRITE;
                    end
                end
                
                DATA_WRITE: begin
                    if (bit_count == 8) begin
                        sda_oe <= 1;  // Take back control after ACK
                    end
                    if (bit_count > 0) begin
                        sda_out <= reg_data[bit_count-1];
                        bit_count <= bit_count - 1;
                    end else begin
                        sda_oe <= 1;
                        state <= STOP;
                    end
                end
                
                STOP: begin
                    sda_out <= 0;
                    state <= NEXT_REG;
                end
                
                NEXT_REG: begin
                    sda_out <= 1;  // STOP condition: SDA goes high while SCL is high
                    reg_index <= reg_index + 1;
                    state <= IDLE;
                end
                
                DONE: begin
                    config_done <= 1;
                    sda_oe <= 0;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
