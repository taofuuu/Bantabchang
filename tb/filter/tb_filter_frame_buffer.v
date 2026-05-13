`timescale 1ns / 1ps
// testbench for filter_frame_buffer: write 256 entries via port A, read back via port B
module tb_filter_frame_buffer;

    // clocks: port A ~24 MHz, port B ~25 MHz (intentionally different)
    reg clka = 0;
    reg clkb = 0;
    always #21 clka = ~clka;   // 42 ns period
    always #20 clkb = ~clkb;   // 40 ns period

    reg         wea   = 0;
    reg  [16:0] addra = 0;
    reg  [11:0] dina  = 0;
    reg  [16:0] addrb = 0;
    wire [11:0] doutb;

    filter_frame_buffer dut (
        .clka  (clka),
        .wea   (wea),
        .addra (addra),
        .dina  (dina),
        .clkb  (clkb),
        .addrb (addrb),
        .doutb (doutb)
    );

    integer i;
    integer fail = 0;

    task write_pixel;
        input [16:0] addr;
        input [11:0] data;
        begin
            @(posedge clka);
            addra = addr;
            dina  = data;
            wea   = 1;
            @(posedge clka);
            wea   = 0;
        end
    endtask

    task read_pixel;
        input  [16:0] addr;
        output [11:0] data;
        begin
            @(posedge clkb);
            addrb = addr;
            @(posedge clkb);  // registered read: data appears on next cycle
            data = doutb;
        end
    endtask

    reg [11:0] got;

    initial begin
        $display("-- filter_frame_buffer tb start --");

        // write 256 entries: data = addr[11:0] for easy verification
        for (i = 0; i < 256; i = i + 1) begin
            write_pixel(i[16:0], i[11:0]);
        end

        // wait a few cycles for any in-flight writes to settle
        repeat (4) @(posedge clkb);

        // read back and verify
        for (i = 0; i < 256; i = i + 1) begin
            read_pixel(i[16:0], got);
            if (got !== i[11:0]) begin
                $display("FAIL addr=%0d: expected %03h, got %03h", i, i[11:0], got);
                fail = fail + 1;
            end
        end

        // spot-check a high address to confirm depth
        write_pixel(17'd76799, 12'hABC);
        repeat (4) @(posedge clkb);
        read_pixel(17'd76799, got);
        if (got !== 12'hABC) begin
            $display("FAIL addr=76799: expected ABC, got %03h", got);
            fail = fail + 1;
        end

        // verify unwritten address 300 is still zero (initialized to black)
        read_pixel(17'd300, got);
        if (got !== 12'h000) begin
            $display("FAIL addr=300: expected 000, got %03h", got);
            fail = fail + 1;
        end

        if (fail == 0)
            $display("PASS: all checks passed");
        else
            $display("FAIL: %0d errors", fail);

        $finish;
    end

    // timeout guard
    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
