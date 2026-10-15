`timescale 1ns/1ps
// Functional simulation clocks. The platform uses clk_sys only; the framework
// scanout/SPI are not instantiated here. Production MMCM is elaborated by lint
// and checked by Vivado implementation. Avoid its 1.2 GHz VCO event overhead.
module gb_clocks (
    input wire clk_in_50mhz,
    output reg clk_sys = 0,
    output wire clk_spi, clk_display, locked
);
    always #12.5 clk_sys = !clk_sys;
    assign clk_spi = 0;
    assign clk_display = 0;
    assign locked = 1;
endmodule
