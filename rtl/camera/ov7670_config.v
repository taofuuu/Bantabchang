`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// OV7670 SCCB Configuration (RGB565 / VGA 640x480 boot sequence)
//
// Eight register writes are enough to bring the camera up in RGB565 VGA mode:
// soft-reset, prescaler on, PLL stabilize, COM7 = RGB, RGB444 off, COM15 with
// the full-range RGB565 bit, TSLB, and the "magic" 0xB0 register that the
// OmniVision app-note flips before reliable RGB output.
//
// SCL is built as a 4-phase waveform (low/low/high/high) so SDA can change
// only while SCL is low - the I2C rule the camera enforces. After the soft
// reset we hold off ~1 ms before sending the rest. This driver is open-loop
// (no ACK read-back); the simpler protocol is what consistently leaves the
// camera in a known state.
//
// Top hooks: config_done goes high once all eight writes are out; sccb_busy
// reflects an active transaction; sccb_nak_seen is wired low because we do
// not sample ACK in this version.
//////////////////////////////////////////////////////////////////////////////////

module ov7670_config(
    input  wire clk,            // 100 MHz system clock
    input  wire reset,          // async, active-high
    output reg  sioc,           // SCCB clock line
    inout  wire siod,           // SCCB data line (open-drain)
    output wire config_done,
    output wire sccb_busy,
    output wire sccb_nak_seen
);

    // ---------------------------------------------------------------------
    // Phase tick: divide 100 MHz so each SCCB phase lasts ~2.5 us
    //   -> SCL period ~10 us  ->  ~100 kHz, comfortably inside SCCB spec.
    // ---------------------------------------------------------------------
    parameter [8:0] PHASE_TICKS = 9'd250;  // 100 MHz / 250 = 400 kHz tick

    reg [8:0] tick_div;
    reg       phase_tick;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tick_div   <= 9'd0;
            phase_tick <= 1'b0;
        end else if (tick_div == PHASE_TICKS - 1'b1) begin
            tick_div   <= 9'd0;
            phase_tick <= 1'b1;
        end else begin
            tick_div   <= tick_div + 1'b1;
            phase_tick <= 1'b0;
        end
    end

    // ---------------------------------------------------------------------
    // Register table - 8 entries, {sub-address, data}
    // ---------------------------------------------------------------------
    localparam integer NUM_CMDS  = 8;
    localparam [7:0]   CAM_WADDR = 8'h42;   // OV7670 slave write address

    reg  [7:0]  cmd_index;
    reg  [15:0] cmd_word;

    always @(*) begin
        case (cmd_index)
            8'd0: cmd_word = 16'h12_80;  // COM7  - software reset
            8'd1: cmd_word = 16'h11_01;  // CLKRC - enable internal prescaler
            8'd2: cmd_word = 16'h6B_4A;  // DBLV  - PLL stabilization
            8'd3: cmd_word = 16'h12_04;  // COM7  - select RGB output
            8'd4: cmd_word = 16'h8C_00;  // RGB444 disable -> use RGB565
            8'd5: cmd_word = 16'h40_D0;  // COM15 - RGB565, full output range
            8'd6: cmd_word = 16'h3A_04;  // TSLB
            8'd7: cmd_word = 16'hB0_84;  // (reserved register required for clean RGB)
            default: cmd_word = 16'h0000;
        endcase
    end

    // ---------------------------------------------------------------------
    // 4-phase SCCB FSM
    //   P0/P1 : SCL low  (P1 = drive SDA)
    //   P2/P3 : SCL high (SDA stable for slave)
    //
    // The 24-bit shift {slave, sub, data} is emitted MSB-first; after every
    // 8 data bits an extra phase pair generates the don't-care/ACK bit during
    // which we tristate SDA (no ACK sampling - open-loop).
    // ---------------------------------------------------------------------
    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_START      = 4'd1;
    localparam [3:0] ST_SCL_LO_A   = 4'd2;
    localparam [3:0] ST_DRIVE_DATA = 4'd3;
    localparam [3:0] ST_SCL_HI_A   = 4'd4;
    localparam [3:0] ST_HOLD_A     = 4'd5;
    localparam [3:0] ST_SCL_LO_B   = 4'd6;
    localparam [3:0] ST_RELEASE    = 4'd7;
    localparam [3:0] ST_SCL_HI_B   = 4'd8;
    localparam [3:0] ST_HOLD_B     = 4'd9;
    localparam [3:0] ST_STOP_LO    = 4'd10;
    localparam [3:0] ST_STOP_DRV   = 4'd11;
    localparam [3:0] ST_STOP_HI    = 4'd12;
    localparam [3:0] ST_NEXT_LO    = 4'd13;
    localparam [3:0] ST_NEXT_DRV   = 4'd14;
    localparam [3:0] ST_FINISH     = 4'd15;

    reg [3:0]  fsm_state;
    reg [5:0]  bit_idx;            // 23..0 across the 3-byte burst
    reg [23:0] tx_shift;
    reg        sda_q;
    reg        sda_oe;
    reg [10:0] post_reset_cnt;     // ~1 ms idle after soft reset

    // SCCB / open-drain: pull SDA low when we want a 0, otherwise Hi-Z.
    assign siod = (sda_oe && sda_q == 1'b0) ? 1'b0 : 1'bz;

    assign sccb_busy     = (fsm_state != ST_IDLE);
    assign sccb_nak_seen = 1'b0;
    assign config_done   = (cmd_index >= NUM_CMDS) && (fsm_state == ST_IDLE);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            fsm_state      <= ST_IDLE;
            bit_idx        <= 6'd0;
            tx_shift       <= 24'd0;
            cmd_index      <= 8'd0;
            sioc           <= 1'b1;
            sda_q          <= 1'b1;
            sda_oe         <= 1'b1;
            post_reset_cnt <= 11'd0;
        end else if (phase_tick) begin
            case (fsm_state)
                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (cmd_index < NUM_CMDS) begin
                        // Wait ~1 ms after the soft reset command before going on
                        if (cmd_index == 8'd1 && post_reset_cnt < 11'd400) begin
                            post_reset_cnt <= post_reset_cnt + 1'b1;
                        end else begin
                            tx_shift  <= {CAM_WADDR, cmd_word[15:8], cmd_word[7:0]};
                            sda_oe    <= 1'b1;
                            sioc      <= 1'b1;
                            sda_q     <= 1'b1;
                            fsm_state <= ST_START;
                        end
                    end
                end

                // START: SDA falls while SCL is high
                ST_START: begin
                    sda_q     <= 1'b0;
                    bit_idx   <= 6'd23;
                    fsm_state <= ST_SCL_LO_A;
                end

                // --- Send-bit phases ---
                ST_SCL_LO_A:   begin sioc <= 1'b0;                  fsm_state <= ST_DRIVE_DATA; end
                ST_DRIVE_DATA: begin sda_q <= tx_shift[bit_idx];    fsm_state <= ST_SCL_HI_A;   end
                ST_SCL_HI_A:   begin sioc <= 1'b1;                  fsm_state <= ST_HOLD_A;     end
                ST_HOLD_A: begin
                    if (bit_idx == 6'd16 || bit_idx == 6'd8 || bit_idx == 6'd0) begin
                        fsm_state <= ST_SCL_LO_B;        // last data bit of a byte -> ACK phase
                    end else begin
                        bit_idx   <= bit_idx - 1'b1;
                        fsm_state <= ST_SCL_LO_A;
                    end
                end

                // --- Don't-care / ACK phases (SDA tristated) ---
                ST_SCL_LO_B: begin sioc   <= 1'b0; fsm_state <= ST_RELEASE;   end
                ST_RELEASE:  begin sda_oe <= 1'b0; fsm_state <= ST_SCL_HI_B;  end
                ST_SCL_HI_B: begin sioc   <= 1'b1; fsm_state <= ST_HOLD_B;    end
                ST_HOLD_B: begin
                    if (bit_idx == 6'd0)
                        fsm_state <= ST_STOP_LO;          // burst complete, STOP next
                    else begin
                        bit_idx   <= bit_idx - 1'b1;
                        fsm_state <= ST_NEXT_LO;          // continue to next byte
                    end
                end
                ST_NEXT_LO:  begin sioc   <= 1'b0; fsm_state <= ST_NEXT_DRV;  end
                ST_NEXT_DRV: begin sda_oe <= 1'b1; fsm_state <= ST_DRIVE_DATA;end

                // --- STOP: SDA rises while SCL is high ---
                ST_STOP_LO:  begin sioc   <= 1'b0;             fsm_state <= ST_STOP_DRV; end
                ST_STOP_DRV: begin sda_oe <= 1'b1; sda_q <= 1'b0; fsm_state <= ST_STOP_HI;  end
                ST_STOP_HI:  begin sioc   <= 1'b1;             fsm_state <= ST_FINISH;   end
                ST_FINISH: begin
                    sda_q     <= 1'b1;
                    cmd_index <= cmd_index + 1'b1;
                    fsm_state <= ST_IDLE;
                end

                default: fsm_state <= ST_IDLE;
            endcase
        end
    end

endmodule
