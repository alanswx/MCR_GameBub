`timescale 1ns/1ps
// Full mixed-language core, functional 40 MHz clock, 10 ns SRAM, MCU file protocol.
// ROM data stays in scratch/. Run through sim/run_tb.py.
module tb_gamebub;
    reg clk_in = 0;
    always #10 clk_in = !clk_in;
    wire clk_sys, locked;
    reg fw_reset = 1;
    reg h_en = 0, h_wr = 0, c_req = 0;
    reg [31:0] h_addr = 0, h_wdata = 0;
    wire [31:0] h_rdata;
    wire h_done, c_busy, c_done, c_error;
    wire [2:0] v_r, v_g, v_b;
    wire v_de, v_vblank, v_hblank;
    wire [15:0] a_left, a_right;
    wire sr_ce_n, sr_we_n, sr_oe_n, sr_dir;
    wire [1:0] sr_mask_n;
    wire [17:0] sr_a;
    wire [15:0] sr_din, sr_dout;
    reg [11:0] btn = 0;
	mcr3_gamebub dut (
		.clock                    (clk_sys),
		.reset                    (fw_reset),
		.clocks_clockIn50M        (clk_in),
		.clocks_clockOutSystem    (clk_sys),
		.clocks_clockOutDisplay   (),
		.clocks_clockOutSpi       (),
		.clocks_locked            (locked),
		.video_data_r             (v_r),
		.video_data_g             (v_g),
		.video_data_b             (v_b),
		.video_dataEnable         (v_de),
		.video_vblank             (v_vblank),
		.video_hblank             (v_hblank),
		.audio_left               (a_left),
		.audio_right              (a_right),
		.host_mem_enable          (h_en),
		.host_mem_write           (h_wr),
		.host_mem_done            (h_done),
		.host_mem_address         (h_addr),
		.host_mem_dataRead        (h_rdata),
		.host_mem_dataWrite       (h_wdata),
		.host_commandHost_request (c_req),
		.host_commandHost_busy    (c_busy),
		.host_commandHost_done    (c_done),
		.host_commandHost_error   (c_error),
		.host_commandCore_request (),
		.host_commandCore_busy    (1'b0),
		.host_commandCore_done    (1'b0),
		.host_commandCore_error   (1'b0),
		.input_buttons_up         (btn[0]),
		.input_buttons_down       (btn[1]),
		.input_buttons_left       (btn[2]),
		.input_buttons_right      (btn[3]),
		.input_buttons_a          (btn[4]),
		.input_buttons_b          (btn[5]),
		.input_buttons_x          (btn[6]),
		.input_buttons_y          (btn[7]),
		.input_buttons_l          (btn[8]),
		.input_buttons_r          (btn[9]),
		.input_buttons_select     (btn[10]),
		.input_buttons_start      (btn[11]),
		.sram_ceN                 (sr_ce_n),
		.sram_weN                 (sr_we_n),
		.sram_oeN                 (sr_oe_n),
		.sram_writeMaskN          (sr_mask_n),
		.sram_address             (sr_a),
		.sram_dataIn              (sr_din),
		.sram_dataOut             (sr_dout),
		.sram_dataDir             (sr_dir)
	);
    reg [15:0] sram [0:262143];
    assign #10 sr_din = !sr_ce_n && !sr_oe_n && sr_we_n ?
        {sr_mask_n[1] ? 8'hzz : sram[sr_a][15:8],
         sr_mask_n[0] ? 8'hzz : sram[sr_a][7:0]} : 16'hzzzz;
    always @(posedge sr_we_n) if (!sr_ce_n && sr_dir) begin
        if (!sr_mask_n[0]) sram[sr_a][7:0] = sr_dout[7:0];
        if (!sr_mask_n[1]) sram[sr_a][15:8] = sr_dout[15:8];
    end
    task automatic write_word(input reg [31:0] address, data);
        integer timeout;
        begin
            @(negedge clk_sys);
            h_en = 1; h_wr = 1; h_addr = address; h_wdata = data;
            timeout = 0;
            do begin
                @(negedge clk_sys); timeout++;
                if (timeout > 10000) $fatal(1, "Host stalled at %h", address);
            end while (!h_done);
            h_en = 0; h_wr = 0;
            @(negedge clk_sys);
        end
    endtask
    task automatic command(input reg [15:0] opcode, input reg [31:0] id, size);
        integer timeout;
        begin
            write_word(32'hf0000000, {16'd0, opcode});
            write_word(32'hf0000004, id);
            write_word(32'hf0000008, size);
            c_req = 1; timeout = 0;
            do begin
                @(negedge clk_sys); timeout++;
                if (timeout > 100000) $fatal(1, "Command timeout %h", opcode);
            end while (!c_done && !c_error);
            if (c_error) $fatal(1, "Command error %h", opcode);
            c_req = 0;
            repeat (2) @(negedge clk_sys);
        end
    endtask
    task automatic load_file(input string path, input integer id, address, size);
        integer fd, count, i;
        reg [7:0] data [0:524288]; // Extra byte detects an oversized input.
        begin
            fd = $fopen(path, "rb");
            if (!fd) $fatal(1, "Cannot open %s", path);
            count = $fread(data, fd, 0, size);
            if ($fgetc(fd) != -1) $fatal(1, "Oversized file %s", path);
            $fclose(fd);
            if (count != size) $fatal(1, "Wrong size %s: %0d", path, count);
            command(16'h0300, id, 0);
            for (i=0; i<size; i=i+4) begin
                write_word(address+i, {data[i+3],data[i+2],data[i+1],data[i]});
                repeat (58) @(negedge clk_sys);
            end
            command(16'h0301, id, size);
            $display("Loaded %s (%0d bytes)", path, size);
        end
    endtask
    string rom_path, prom_path, out_path;
    integer frames = 120, dump = 30, aspect = 2;
    integer expected_game = 0, expected_family = 2, portrait_mode = 0;
    integer orientation_probe, expected_portrait=0, expected_dips=255, expected_size=237568, expected_sg=0;
    integer speech_fd,speech_index,speech_expected;
    reg [31:0] expected_crc;
    integer coin_frame = -1, start_frame = -1;
    bit running = 0;
`ifdef VERILATOR
    // Same software request used by the feature branch's MAME reference
    // script: the real game CPU/SSIO still generates the OP4 nibble timing.
    initial if($test$plusargs("request_speech"))begin
        wait(running && dut.speech.u_cpu.u_regs.i===1'b0);
        repeat(80000)@(negedge clk_sys);
        @(negedge clk_sys);
        #1;
        dut.machine.wram.ram[11'h4d6]=8'h2b;
        dut.machine.wram.ram[11'h420]=dut.machine.wram.ram[11'h420]|8'h10;
        $display("GAME SOFTWARE SPEECH REQUEST: $2B through Environmental ROM handler");$fflush();
    end
`endif
    initial begin
        if (!$value$plusargs("rom=%s", rom_path)) $fatal(1, "Missing +rom");
        if (!$value$plusargs("prom=%s", prom_path)) $fatal(1, "Missing +prom");
        if (!$value$plusargs("out=%s", out_path)) $fatal(1, "Missing +out");
        if ($value$plusargs("frames=%d", frames)) begin end
        if ($value$plusargs("dump=%d", dump)) begin end
        if ($value$plusargs("aspect=%d", aspect)) begin end
        if ($value$plusargs("portrait_mode=%d", portrait_mode)) begin end
        if ($value$plusargs("coin=%d", coin_frame)) begin end
        if ($value$plusargs("start=%d", start_frame)) begin end
        if (frames < 1 || dump < 1) $fatal(1, "frames and dump must be positive");
        if (!$value$plusargs("expected_family=%d", expected_family)) $fatal(1, "Missing expected family");
        if (!$value$plusargs("expected_game=%d", expected_game)) $fatal(1, "Missing expected game");
        if (!$value$plusargs("expected_crc=%h", expected_crc)) $fatal(1, "Missing expected CRC");
        if ($value$plusargs("expected_portrait=%d", expected_portrait)) begin end
        if ($value$plusargs("expected_dips=%d", expected_dips)) begin end
        if ($value$plusargs("expected_size=%d", expected_size)) begin end
        if ($value$plusargs("expected_sg=%d", expected_sg)) begin end
        wait (locked);
        repeat (32) @(negedge clk_sys);
        fw_reset = 0;
        load_file(rom_path, 0, 'h10000000, expected_size);
        load_file(prom_path, 1, 'h100f0000, 32);
        if (dut.game_family !== expected_family[1:0] || dut.load_family !== expected_family[1:0] || dut.game_sg !== expected_sg[0] || dut.load_sg !== expected_sg[0] || dut.game_shollow !== (expected_family == 1 && expected_game == 0) || dut.game_mcr2 !== (expected_family == 1) || dut.game_timber !== (expected_family == 2 && expected_game == 1) || dut.game_mod !== expected_game || dut.game_portrait !== expected_portrait[0] || dut.dips !== expected_dips[7:0] || dut.host.rom_crc !== expected_crc)
            $fatal(1, "Automatic ROM recognition failed: game=%b CRC=%h", dut.game_timber, dut.host.rom_crc);
        $display("GAME IDENTIFIED: mod=%0d CRC=%h", expected_game, expected_crc);
        if(expected_family==2 && expected_game==4)begin
            speech_fd=$fopen(rom_path,"rb");
            if($fseek(speech_fd,'h3a000,0)!=0)$fatal(1,"Speech ROM seek failed");
            for(speech_index=0;speech_index<16384;speech_index++)begin
                speech_expected=$fgetc(speech_fd);
                if((speech_index[0] ? sram['ha000+speech_index/2][15:8] : sram['ha000+speech_index/2][7:0])!==speech_expected[7:0])
                    $fatal(1,"Host speech ROM upload mismatch at %h",speech_index);
            end
            $fclose(speech_fd);
            $display("SPEECH ROM UPLOAD PASS: all 16384 bytes through MCU host and SRAM");
        end
        write_word('h200, aspect);
        if(dut.aspect !== (aspect == 0 || (aspect == 2 && expected_family == 0) ? 1'b0 : 1'b1))
            $fatal(1,"Wrong automatic game aspect");
        for (orientation_probe=0; orientation_probe<3; orientation_probe=orientation_probe+1) begin
            write_word('h210, orientation_probe);
            if (dut.videoTransform_rotation !== ((expected_portrait != 0) ?
                (orientation_probe == 0 ? 2'd1 : orientation_probe == 1 ? 2'd0 : 2'd2) : 2'd0))
                $fatal(1, "Wrong orientation for grip %0d", orientation_probe);
        end
        $display("ORIENTATION PASS: upright and both sideways grips");
        if ($test$plusargs("orientation_only")) $finish;
        write_word('h210, portrait_mode);
        if (dut.videoTransform_rotation !== ((expected_portrait != 0) ? (portrait_mode == 1 ? 2'd0 : portrait_mode == 2 ? 2'd2 : 2'd1) : 2'd0))
            $fatal(1, "Wrong game orientation request");
        command(16'h0102, 0, 0);
        command(16'h0200, 1, 0);
        command(16'h0100, 0, 0);
        running = 1;
    end
    reg [8:0] frame [0:76799];
    integer unknown_pixels = 0, audio_unknown_cycles = 0;
    integer x = 0, y = 0, number = 0, colored = 0, audio_changes = 0;
    bit defined_visible_frame = 0;
    reg vb_q = 1;
    reg [15:0] audio_q = 0;
    integer fd, i;
    bit trace_cpu = 0;
    reg [15:0] trace_count = 0;
    initial trace_cpu = $test$plusargs("trace_cpu");
    always @(posedge clk_sys) if (running && trace_cpu) begin
        trace_count <= trace_count + 1'b1;
        if (trace_count == 0) begin
            $display("CPU BUS frame=%0d addr=%h data=%h reset=%b", number,dut.cpu_addr,dut.cpu_data,dut.machine_reset);
            $fflush();
        end
    end
    always @(posedge clk_sys) begin
        #1;
        if (running && dut.machine_reset) begin
            x=0; y=0; colored=0; unknown_pixels=0; vb_q=1;
        end else if (running) begin
            vb_q <= v_vblank;
            if(number > 1 && $isunknown({a_left,a_right})) audio_unknown_cycles++;
            if (a_left !== audio_q) audio_changes++;
            audio_q = a_left;
            if (v_de) begin
                if (x >= 320 || y >= 240) $fatal(1, "Frame overflow %0d,%0d vb=%b prev=%b source_vb=%b source_y=%d",x,y,v_vblank,vb_q,dut.vb,dut.video.y);
                if ($isunknown({v_r,v_g,v_b})) unknown_pixels++;
                frame[y*320+x] = {v_r,v_g,v_b};
                if ({v_r,v_g,v_b} != 0) colored++;
                x++;
            end
            if (v_hblank) begin
                if (x != 320) $fatal(1, "Line width %0d", x);
                x = 0; y++;
            end
            if (v_vblank && !vb_q) begin
                if (y != 240 || x != 0) $fatal(1, "Frame size %0d,%0d", x,y);
                number++;
                if (unknown_pixels == 0 && colored > 0) defined_visible_frame = 1;
                if (number % dump == 0 || number == frames) begin
                    fd = $fopen($sformatf("%s/frame_%04d.ppm",out_path,number), "wb");
                    if (!fd) $fatal(1, "Cannot write frame");
                    $fwrite(fd, "P6\n320 240\n255\n");
                    for (i=0;i<76800;i++)
                        $fwrite(fd,"%c%c%c",8'(frame[i][8:6]*255/7),
                            8'(frame[i][5:3]*255/7),8'(frame[i][2:0]*255/7));
                    $fclose(fd);
                    $display("FRAME %0d: colored=%0d unknown=%0d audio_changes=%0d speech_commands=%0d speech_stream=%0d speech_audio=%0d speech_cpu=%h op4=%h", number,colored,unknown_pixels,audio_changes,dut.speech.cmd_count,dut.speech.pia_loose,dut.speech.tms_audio_nz,dut.speech.dbg_cpu_addr,dut.m3_output4);
                end
                $fflush();
                btn[10] = number >= coin_frame && number < coin_frame+6 && coin_frame >= 0;
                btn[11] = number >= start_frame && number < start_frame+6 && start_frame >= 0;
                if (number == frames || ($test$plusargs("request_speech") && dut.speech.cmd_count!=0 && dut.speech.tms_audio_nz && dut.speech.pia_loose)) begin
                    if($test$plusargs("require_speech")) begin
                        // The source's `seen` debug indicator saturates a
                        // two-bit edge counter (3 edges), so it stays low for
                        // one complete command pulse. Count real commands.
                        if(!dut.game_speech || dut.speech.cmd_count==0 || !dut.speech.tms_audio_nz || !dut.speech.pia_loose)
                            $fatal(1,"Game did not issue audible Environmental speech");
                        $display("IN-GAME SPEECH PASS: Environmental ROM issued commands and TMS5200 produced audio");
                    end
                    if(audio_unknown_cycles != 0) $fatal(1,"Undefined audio after startup: %0d cycles",audio_unknown_cycles);
                    if (unknown_pixels != 0) $fatal(1, "Final frame has %0d unknown pixels", unknown_pixels);
                    if (!defined_visible_frame) $fatal(1, "No fully defined visible frame during startup");
                    $display("GAMEBUB PASS: %0d complete frames",number);
                    $finish;
                end
                y = 0; colored = 0; unknown_pixels = 0;
            end
        end
    end
    initial begin
        #100000000;
        wait (running);
        #(frames * 20000000.0);
        $fatal(1, "Simulation timeout");
    end
endmodule
