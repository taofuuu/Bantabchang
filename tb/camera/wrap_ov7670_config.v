`timescale 1ns / 1ps
// wrapper to pull siod high and expose it as a regular output for cocotb.
// cocotb cannot drive inout ports directly; this shim adds the pullup and
// routes the open-drain value to a readable output wire.
module wrap_ov7670_config(
    input  wire clk,
    input  wire reset,
    output wire sioc,
    output wire siod_out,      // driven value on the open-drain bus (with pullup)
    output wire config_done,
    output wire sccb_busy,
    output wire sccb_nak_seen
);
    wire siod_bus;

    // pullup: bus reads 1 when no driver is pulling it low
    assign siod_bus = (siod_bus === 1'bz) ? 1'b1 : siod_bus;
    assign siod_out = (siod_bus === 1'bz) ? 1'b1 : siod_bus;

    ov7670_config #(.PHASE_TICKS(9'd4)) dut (
        .clk          (clk),
        .reset        (reset),
        .sioc         (sioc),
        .siod         (siod_bus),
        .config_done  (config_done),
        .sccb_busy    (sccb_busy),
        .sccb_nak_seen(sccb_nak_seen)
    );

endmodule
