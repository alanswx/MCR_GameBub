// Bally Midway MCR3 for Game Bub. Tapper baseline; see docs/PORT_PLAN.md.
module mcr3_gamebub (
	input  wire         clock,
	input  wire         reset,
	input  wire         clocks_clockIn50M,
	output logic        clocks_clockOutSystem,
	output logic        clocks_clockOutDisplay,
	output logic        clocks_clockOutSpi,
	output logic        clocks_locked,
	output logic [2:0]  video_data_r,
	output logic [2:0]  video_data_g,
	output logic [2:0]  video_data_b,
	output logic        video_dataEnable,
	output logic        video_vblank,
	output logic        video_hblank,
	output logic [15:0] audio_left,
	output logic [15:0] audio_right,
	input  wire         host_mem_enable,
	input  wire         host_mem_write,
	output logic        host_mem_done,
	input  wire  [31:0] host_mem_address,
	output logic [31:0] host_mem_dataRead,
	input  wire  [31:0] host_mem_dataWrite,
	input  wire         host_commandHost_request,
	output logic        host_commandHost_busy,
	output logic        host_commandHost_done,
	output logic        host_commandHost_error,
	output logic        host_commandCore_request,
	input  wire         host_commandCore_busy,
	input  wire         host_commandCore_done,
	input  wire         host_commandCore_error,
	input  wire         input_buttons_a,
	input  wire         input_buttons_b,
	input  wire         input_buttons_x,
	input  wire         input_buttons_y,
	input  wire         input_buttons_up,
	input  wire         input_buttons_down,
	input  wire         input_buttons_left,
	input  wire         input_buttons_right,
	input  wire         input_buttons_l,
	input  wire         input_buttons_r,
	input  wire         input_buttons_start,
	input  wire         input_buttons_select,
	output logic        sram_ceN,
	output logic        sram_weN,
	output logic        sram_oeN,
	output logic [1:0]  sram_writeMaskN,
	output logic [17:0] sram_address,
	input  wire  [15:0] sram_dataIn,
	output logic [15:0] sram_dataOut,
	output logic        sram_dataDir
);

    wire clk_sys;
    gb_clocks clocks (
        .clk_in_50mhz(clocks_clockIn50M), .clk_sys(clk_sys),
        .clk_spi(clocks_clockOutSpi), .clk_display(clocks_clockOutDisplay),
        .locked(clocks_locked)
    );
    assign clocks_clockOutSystem = clk_sys;
    assign host_commandCore_request = 0;
    wire core_reset, act_reset, focus, aspect, service;
    wire [1:0] volume;
    wire [7:0] dips;
    wire wr_req, wr_ack, wr_error, initialized;
    wire [19:0] wr_addr;
    wire [7:0] wr_data;
    wire [31:0] debug_status;
    gb_mcr_host host (
        .clk(clk_sys), .reset(reset),
        .mem_enable(host_mem_enable), .mem_write(host_mem_write),
        .mem_address(host_mem_address), .mem_dataWrite(host_mem_dataWrite),
        .mem_dataRead(host_mem_dataRead), .mem_done(host_mem_done),
        .cmd_request(host_commandHost_request), .cmd_busy(host_commandHost_busy),
        .cmd_done(host_commandHost_done), .cmd_error(host_commandHost_error),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data),
        .wr_ack(wr_ack), .wr_error(wr_error),
        .core_reset(core_reset), .act_reset(act_reset), .focus(focus),
        .aspect(aspect), .volume(volume), .service(service), .dips(dips),
        .debug_status(debug_status)
    );
    wire machine_reset;
    gb_mcr_reset reset_sequence (
        .clk(clk_sys),
        .request(reset || core_reset || act_reset || !initialized),
        .machine_reset(machine_reset)
    );

    wire [15:0] cpu_addr, dl_addr;
    wire [13:0] sound_addr;
    wire [14:0] sprite_addr;
    wire [7:0] cpu_data, sound_data, dl_data, prom_data;
    wire [31:0] sprite_data;
    wire [4:0] prom_addr;
    wire dl_wr, dl_nvram, dl_nvram_wr, prom_wr;
    gb_mcr_memory memory (
        .clk(clk_sys), .reset(reset), .wr_req(wr_req), .wr_addr(wr_addr),
        .wr_data(wr_data), .wr_ack(wr_ack), .wr_error(wr_error), .initialized(initialized),
        .cpu_addr(cpu_addr), .cpu_data(cpu_data),
        .sound_addr(sound_addr), .sound_data(sound_data),
        .sprite_addr(sprite_addr), .sprite_data(sprite_data),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_wr(dl_wr),
        .dl_nvram(dl_nvram), .dl_nvram_wr(dl_nvram_wr),
        .prom_addr(prom_addr), .prom_data(prom_data), .prom_wr(prom_wr),
        .sram_ce_n(sram_ceN), .sram_we_n(sram_weN), .sram_oe_n(sram_oeN),
        .sram_mask_n(sram_writeMaskN), .sram_a(sram_address),
        .sram_dq_in(sram_dataIn), .sram_dq_out(sram_dataOut), .sram_dq_oe(sram_dataDir)
    );

    // Tapper's active-low ports, matching upstream's mod=0. Focus suppresses
    // gameplay buttons while the firmware menu is open. R starts player 2.
    wire [7:0] input_0 = ~{service, 3'b000, input_buttons_r && focus,
                           input_buttons_start && focus, 1'b0, input_buttons_select && focus};
    wire [7:0] input_1 = ~{3'b000, input_buttons_a && focus,
                           input_buttons_up && focus, input_buttons_down && focus,
                           input_buttons_left && focus, input_buttons_right && focus};
    wire [2:0] r, g, b;
    wire hb, vb, ce;
    wire [15:0] left, right;
    mcr3 machine (
        .clock_40(clk_sys), .reset(machine_reset), .tv15Khz_mode(1'b0),
        .video_r(r), .video_g(g), .video_b(b), .video_csync(),
        .video_hblank(hb), .video_vblank(vb), .video_hs(), .video_vs(),
        .video_ce(ce), .video_hflip(1'b0), .video_vflip(1'b0),
        .separate_audio(1'b0), .audio_out_l(left), .audio_out_r(right),
        .input_0(input_0), .input_1(input_1), .input_2(input_1),
        .input_3(dips), .input_4(8'hff), .output_4(), .mcr2p5(1'b0), .hcntout(),
        .cpu_rom_addr(cpu_addr), .cpu_rom_do(cpu_data),
        .snd_rom_addr(sound_addr), .snd_rom_do(sound_data),
        .sp_addr(sprite_addr), .sp_graphx32_do(sprite_data),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_wr(dl_wr), .dl_din(),
        .dl_nvram(dl_nvram), .dl_nvram_wr(dl_nvram_wr),
        .prom_addr(prom_addr), .prom_data(prom_data), .prom_wr(prom_wr)
    );
    gb_mcr_video video (
        .clk(clk_sys), .reset(machine_reset), .ce_pix(ce),
        .in_r(r), .in_g(g), .in_b(b), .in_hblank(hb), .in_vblank(vb), .aspect(aspect),
        .out_r(video_data_r), .out_g(video_data_g), .out_b(video_data_b),
        .out_de(video_dataEnable), .out_hblank(video_hblank), .out_vblank(video_vblank)
    );
    gb_mcr_audio audio_l (.clk(clk_sys), .reset(machine_reset), .sample(left), .volume(volume), .out(audio_left));
    gb_mcr_audio audio_r (.clk(clk_sys), .reset(machine_reset), .sample(right), .volume(volume), .out(audio_right));
    wire unused = &{1'b0, clock, host_commandCore_busy, host_commandCore_done,
                    host_commandCore_error, input_buttons_b, input_buttons_x,
                    input_buttons_y, input_buttons_l, debug_status};
endmodule
