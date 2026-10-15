// Bally Midway MCR3 for Game Bub. Tapper baseline; see docs/PORT_PLAN.md.
module mcr3_gamebub (
	input  wire         clock,
	input  wire         reset,
	input  wire         clocks_clockIn50M,
	output logic        clocks_clockOutSystem,
	output logic        clocks_clockOutDisplay,
	output logic        clocks_clockOutSpi,
	output logic        clocks_locked,
	output logic [1:0]  videoTransform_rotation,
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
    wire game_timber, game_mcr2, game_shollow, game_portrait, game_sg, load_sg;
    wire [1:0] game_family, load_family;
    wire [2:0] game_mod;
    wire game_speech = game_family == 2 && game_mod == 4;
    wire [13:0] speech_addr;
    wire [7:0] speech_data, m3_output4;
    wire signed [15:0] speech_audio;
    wire [1:0] portrait_mode;
    // Grip CW uses the raw raster; the opposite grip needs a half-turn.
    assign videoTransform_rotation = !game_portrait ? 2'd0 :
        portrait_mode == 2'd1 ? 2'd0 : portrait_mode == 2'd2 ? 2'd2 : 2'd1;
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
        .aspect(aspect), .volume(volume), .service(service), .dips(dips), .game_timber(game_timber), .game_mcr2(game_mcr2),
        .game_family(game_family), .game_sg(game_sg), .load_family(load_family), .load_sg(load_sg),
        .game_shollow(game_shollow), .game_mod(game_mod), .game_portrait(game_portrait), .portrait_mode(portrait_mode),
        .debug_status(debug_status)
    );
    wire machine_reset, m2_reset_sequence, m3_reset_sequence;
    assign machine_reset = game_mcr2 ? m2_reset_sequence : m3_reset_sequence;
    gb_mcr_reset reset_sequence (
        .clk(clk_sys),
        .request(reset || core_reset || act_reset || !initialized),
        .machine_reset(m3_reset_sequence)
    );
    gb_mcr_reset #(.RESTART_CYCLES(40000000)) reset_sequence_mcr2 (
        .clk(clk_sys),
        .request(reset || core_reset || act_reset || !initialized),
        .machine_reset(m2_reset_sequence)
    );

    wire [17:0] sound_addr, mono_sound_addr;
    wire [15:0] cpu_addr, dl_addr, m2_cpu_addr, m3_cpu_addr, mono_cpu_addr;
    wire [14:0] m1_cpu_addr;
    wire [13:0] m1_sound_addr;
    wire [18:0] mono_dl_addr;
    wire mono_dl_wr;
    wire [15:0] mono_sound_data;
    wire [13:0] m2_sound_addr, m3_sound_addr;
    wire [16:0] m2_dl_addr;
    wire m2_dl_wr;
    assign cpu_addr = game_family == 0 ? {1'b0,m1_cpu_addr} : game_family == 3 ? mono_cpu_addr : game_mcr2 ? m2_cpu_addr : m3_cpu_addr;
    assign sound_addr = game_family == 3 ? mono_sound_addr : {4'd0,game_family == 0 ? m1_sound_addr : game_mcr2 ? m2_sound_addr : m3_sound_addr};
    wire [15:0] sprite_addr, mono_sprite_addr;
    wire [14:0] m3_sprite_addr;
    assign sprite_addr = game_family == 3 ? mono_sprite_addr : {1'b0,m3_sprite_addr};
    wire [7:0] cpu_data, sound_data, dl_data, prom_data;
    wire [31:0] sprite_data;
    wire [4:0] prom_addr;
    wire dl_wr, dl_nvram, dl_nvram_wr, prom_wr;
    gb_mcr_memory memory (
        .game_speech(game_speech), .speech_addr(speech_addr), .speech_data(speech_data),
        .game_family(game_family), .load_family(load_family), .game_sg(game_sg), .load_sg(load_sg),
        .mono_dl_addr(mono_dl_addr), .mono_dl_wr(mono_dl_wr), .mono_sound_data(mono_sound_data),
        .game_mcr2(game_mcr2), .m2_dl_addr(m2_dl_addr), .m2_dl_wr(m2_dl_wr),
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

    wire [1:0] mono_sound_status;
    wire [7:0] mono_output5,mono_output6;
    wire hb, vb, ce;
    wire [7:0] input_0, input_1, input_2, input_3, input_4;
    gb_mcr_controls inputs (
        .clk(clk_sys), .reset(machine_reset), .vblank(vb),
        .family(game_family), .snd_stat(mono_sound_status), .output5(mono_output5), .output6(mono_output6),
        .mcr2(game_mcr2), .mode(game_mod), .portrait(game_portrait),
        .portrait_mode(portrait_mode), .focus(focus), .service(service), .dips(dips),
        .up(input_buttons_up), .down(input_buttons_down),
        .left(input_buttons_left), .right(input_buttons_right),
        .a(input_buttons_a), .b(input_buttons_b), .x(input_buttons_x), .y(input_buttons_y),
        .l(input_buttons_l), .r(input_buttons_r), .start(input_buttons_start),
        .coin(input_buttons_select), .port0(input_0), .port1(input_1),
        .port2(input_2), .port3(input_3), .port4(input_4)
    );
    wire [15:0] left, right;
    wire [2:0] r, g, b, m2_r, m2_g, m2_b, m3_r, m3_g, m3_b, mono_r, mono_g, mono_b;
    wire [3:0] m1_r,m1_g,m1_b;
    wire m1_hb,m1_vb,m1_ce,mono_hb,mono_vb,mono_ce;
    wire [15:0] m1_left,m1_right;
    wire [9:0] mono_audio;
    wire m2_hb, m2_vb, m2_ce, m3_hb, m3_vb, m3_ce;
    wire [15:0] m2_left, m2_right, m3_left, m3_right;
    wire signed [17:0] speech_mix_l = $signed({2'b00,m3_left}) + $signed({{2{speech_audio[15]}},speech_audio});
    wire signed [17:0] speech_mix_r = $signed({2'b00,m3_right}) + $signed({{2{speech_audio[15]}},speech_audio});
    wire [15:0] m3_mixed_l = !game_speech ? m3_left : speech_mix_l[17] ? 16'h0000 : speech_mix_l[16] ? 16'hffff : speech_mix_l[15:0];
    wire [15:0] m3_mixed_r = !game_speech ? m3_right : speech_mix_r[17] ? 16'h0000 : speech_mix_r[16] ? 16'hffff : speech_mix_r[15:0];
    assign {r,g,b,hb,vb,ce,left,right} = game_family == 0 ?
        {m1_r[3:1],m1_g[3:1],m1_b[3:1],m1_hb,m1_vb,m1_ce,m1_left,m1_right} : game_family == 3 ?
        {mono_r,mono_g,mono_b,mono_hb,mono_vb,mono_ce,mono_audio,6'd0,mono_audio,6'd0} : game_mcr2 ?
        {m2_r,m2_g,m2_b,m2_hb,m2_vb,m2_ce,m2_left,m2_right} :
        {m3_r,m3_g,m3_b,m3_hb,m3_vb,m3_ce,m3_mixed_l,m3_mixed_r};
    squawk_n_talk speech (
        .clk(clk_sys), .reset(machine_reset || !game_speech),
        .sound_select(m3_output4[3:0]), .sound_int(m3_output4[4]),
        .dbg_in2(input_2), .dbg_op4(m3_output4),
        .rom_addr(speech_addr), .rom_do(speech_data), .audio_out(speech_audio),
        .active(), .seen(), .cpu_run(), .progress(), .pia_loose(),
        .tms_audio_nz(), .dac_written(), .dbg_dac(), .dbg_cpu_addr(),
        .dbg_tms_wsn(), .dbg_tms_rsn()
    );
    mcr3 machine (
        .clock_40(clk_sys), .reset(machine_reset || game_family != 2), .tv15Khz_mode(1'b0),
        .video_r(m3_r), .video_g(m3_g), .video_b(m3_b), .video_csync(),
        .video_hblank(m3_hb), .video_vblank(m3_vb), .video_hs(), .video_vs(),
        .video_ce(m3_ce), .video_hflip(game_mod == 2 || game_mod == 4), .video_vflip(1'b0),
        .separate_audio(1'b0), .audio_out_l(m3_left), .audio_out_r(m3_right),
        .input_0(input_0), .input_1(input_1), .input_2(input_2),
        .input_3(input_3), .input_4(input_4), .output_4(m3_output4), .mcr2p5(game_mod == 3), .hcntout(),
        .cpu_rom_addr(m3_cpu_addr), .cpu_rom_do(cpu_data),
        .snd_rom_addr(m3_sound_addr), .snd_rom_do(sound_data),
        .sp_addr(m3_sprite_addr), .sp_graphx32_do(sprite_data),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_wr(dl_wr), .dl_din(),
        .dl_nvram(dl_nvram), .dl_nvram_wr(dl_nvram_wr),
        .prom_addr(prom_addr), .prom_data(prom_data), .prom_wr(prom_wr)
    );
    mcr2 machine_mcr2 (
        .clock_40(clk_sys), .reset(machine_reset || game_family != 1), .tv15Khz_mode(1'b0),
        .video_r(m2_r), .video_g(m2_g), .video_b(m2_b), .video_csync(),
        .video_hblank(m2_hb), .video_vblank(m2_vb), .video_hs(), .video_vs(), .video_ce(m2_ce),
        .separate_audio(1'b0), .audio_out_l(m2_left), .audio_out_r(m2_right),
        .input_0(input_0), .input_1(input_1), .input_2(input_2),
        .input_3(input_3), .input_4(input_4), .flip_out(),
        .cpu_rom_addr(m2_cpu_addr), .cpu_rom_do(cpu_data), .cpu_rom_rd(),
        .snd_rom_addr(m2_sound_addr), .snd_rom_do(sound_data),
        .dl_addr(m2_dl_addr), .dl_data(dl_data), .dl_wr(m2_dl_wr), .dl_din(),
        .dl_nvram(dl_nvram), .dl_nvram_wr(dl_nvram_wr),
        .prom_addr(prom_addr), .prom_data(prom_data), .prom_wr(prom_wr)
    );
    mcr1 machine_mcr1 (
        .clock_40(clk_sys), .reset(machine_reset || game_family != 0), .tv15Khz_mode(1'b0),
        .video_r(m1_r), .video_g(m1_g), .video_b(m1_b), .video_csync(),
        .video_hblank(m1_hb), .video_vblank(m1_vb), .video_hs(), .video_vs(), .video_ce(m1_ce),
        .separate_audio(1'b0), .audio_out_l(m1_left), .audio_out_r(m1_right),
        .input_0(input_0), .input_1(input_1), .input_2(input_2), .input_3(input_3), .input_4(input_4),
        .cpu_rom_addr(m1_cpu_addr), .cpu_rom_do(cpu_data), .cpu_rom_rd(),
        .snd_rom_addr(m1_sound_addr), .snd_rom_do(sound_data), .pause(1'b0), .flip(1'b0),
        .dl_addr(m2_dl_addr), .dl_data(dl_data), .dl_wr(m2_dl_wr), .dl_din(),
        .dl_nvram(dl_nvram), .dl_nvram_wr(dl_nvram_wr),
        .prom_addr(prom_addr), .prom_data(prom_data), .prom_wr(prom_wr)
    );
    mcr3mono machine_mono (
        .clock_40(clk_sys), .reset(machine_reset || game_family != 3), .tv15Khz_mode(1'b0),
        .video_r(mono_r), .video_g(mono_g), .video_b(mono_b), .video_csync(),
        .video_hblank(mono_hb), .video_vblank(mono_vb), .video_hs(), .video_vs(), .video_ce(mono_ce),
        .soundsgood(game_sg), .snd_stat(mono_sound_status), .audio_out(mono_audio),
        .mod_stargrds(game_mod == 5), .input_0(input_0), .input_1(input_1), .input_2(input_2),
        .input_3(input_3), .input_4(input_4), .output_5(mono_output5), .output_6(mono_output6),
        .cpu_rom_addr(mono_cpu_addr), .cpu_rom_do(cpu_data), .snd_rom_addr(mono_sound_addr),
        .snd_rom_do(mono_sound_data), .sp_addr(mono_sprite_addr), .sp_graphx32_do(sprite_data),
        .dl_addr(mono_dl_addr), .dl_data(dl_data), .dl_wr(mono_dl_wr), .dl_din(),
        .dl_nvram(dl_nvram), .dl_nvram_wr(dl_nvram_wr)
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
                    host_commandCore_error, game_timber, game_shollow, debug_status};
endmodule
