// 50 MHz * 24 / 30 = 40 MHz system; /42 LCD; /6 SPI.
// Adapted from ColecoVision_GameBub (GPL-3.0).
`default_nettype none

module gb_clocks (
	input  wire clk_in_50mhz,
	output wire clk_sys,
	output wire clk_spi,
	output wire clk_display,
	output wire locked
);

	wire clk_fb;
	wire clk_sys_u, clk_spi_u;
	// Vivado names the MMCM output clock after this net, and the framework's
	// common.xdc declares a clock called "clk_dpi" physically exclusive with
	// its HDMI clock (both feed one BUFGMUX). Any other name leaves the two
	// timed against each other (MacLC_GameBub, FRAMEWORK_ISSUES #4).
	wire clk_dpi;

	MMCME2_BASE #(
		.BANDWIDTH          ("OPTIMIZED"),
		.CLKIN1_PERIOD      (20.000),
		.CLKFBOUT_MULT_F    (24.000),
		.DIVCLK_DIVIDE      (1),
		.CLKOUT0_DIVIDE_F   (30.000),
		.CLKOUT1_DIVIDE     (42),
		.CLKOUT2_DIVIDE     (6),
		.CLKOUT0_PHASE      (0.0),
		.CLKOUT1_PHASE      (0.0),
		.CLKOUT2_PHASE      (0.0),
		.CLKOUT0_DUTY_CYCLE (0.5),
		.CLKOUT1_DUTY_CYCLE (0.5),
		.CLKOUT2_DUTY_CYCLE (0.5),
		.STARTUP_WAIT       ("FALSE")
	) mmcm (
		.CLKIN1   (clk_in_50mhz),
		.CLKFBIN  (clk_fb),
		.CLKFBOUT (clk_fb),
		.CLKFBOUTB(),
		.CLKOUT0  (clk_sys_u),
		.CLKOUT0B (),
		.CLKOUT1  (clk_dpi),
		.CLKOUT1B (),
		.CLKOUT2  (clk_spi_u),
		.CLKOUT2B (),
		.CLKOUT3  (),
		.CLKOUT3B (),
		.CLKOUT4  (),
		.CLKOUT5  (),
		.CLKOUT6  (),
		.LOCKED   (locked),
		.PWRDWN   (1'b0),
		.RST      (1'b0)
	);

	BUFG bufg_sys     (.I(clk_sys_u), .O(clk_sys));
	BUFG bufg_spi     (.I(clk_spi_u), .O(clk_spi));
	BUFG bufg_display (.I(clk_dpi),   .O(clk_display));

endmodule

`default_nettype wire
