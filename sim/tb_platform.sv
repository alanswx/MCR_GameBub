`timescale 1ns/1ps
// Synthetic data only. Checks the MCU-to-ROM path, physical SRAM byte lanes,
// sprite deadlines for all schedule phases, and complete B/C video frames.
module tb_platform;
    reg clk = 0;
    always #12.5 clk = !clk;
    reg reset = 1;
    reg mem_enable = 0, mem_write = 0, cmd_request = 0;
    reg [31:0] mem_address = 0, mem_dataWrite = 0;
    wire [31:0] mem_dataRead;
    wire mem_done, cmd_busy, cmd_done, cmd_error;
    wire wr_req, wr_ack, wr_error, core_reset, act_reset, focus, aspect, service;
    wire [19:0] wr_addr;
    wire [7:0] wr_data, dips;
    wire [1:0] volume;
    wire [31:0] debug_status;
    gb_mcr_host host (.*);

    wire initialized;
    reg [15:0] cpu_addr = 0;
    reg [13:0] sound_addr = 0;
    reg [14:0] sprite_addr = 0;
    wire [7:0] cpu_data, sound_data, dl_data, prom_data;
    wire [31:0] sprite_data;
    wire [15:0] dl_addr;
    wire dl_wr, dl_nvram, dl_nvram_wr, prom_wr;
    wire [4:0] prom_addr;
    wire sram_ce_n, sram_we_n, sram_oe_n, sram_dq_oe;
    wire [1:0] sram_mask_n;
    wire [17:0] sram_a;
    wire [15:0] sram_dq_out, sram_dq_in;
    gb_mcr_memory memory (.*);
    reg [15:0] sram [0:262143];
    // 10 ns access delay; pins are sampled 25 ns after address issue.
    assign #10 sram_dq_in = !sram_ce_n && !sram_oe_n && sram_we_n ?
        {sram_mask_n[1] ? 8'hzz : sram[sram_a][15:8], sram_mask_n[0] ? 8'hzz : sram[sram_a][7:0]} : 16'hzzzz;
    always @(posedge sram_we_n) if (!sram_ce_n && sram_dq_oe) begin
        if (!sram_mask_n[0]) sram[sram_a][7:0] = sram_dq_out[7:0];
        if (!sram_mask_n[1]) sram[sram_a][15:8] = sram_dq_out[15:8];
    end
    always @(negedge clk) if (!reset && sram_dq_oe && !sram_oe_n)
        $fatal(1, "SRAM bus contention");
    reg [7:0] bg [0:32767];
    reg [7:0] prom [0:31];
    integer cleared = 0, bg_writes = 0;
    always @(posedge clk) if (!reset) begin
        if (dl_wr) begin bg[dl_addr[14:0]] = dl_data; bg_writes = bg_writes + 1; end
        if (dl_nvram_wr) begin
            if (!dl_nvram || dl_addr !== cleared || dl_data !== 0)
                $fatal(1, "NVRAM initialization at %0d", cleared);
            cleared = cleared + 1;
        end
    end
    always @(negedge clk) if (prom_wr) prom[prom_addr] = prom_data;

    function automatic [7:0] pattern(input integer address);
        pattern = 8'((address * 13) ^ (address >> 7) ^ (address >> 15) ^ 8'ha7);
    endfunction
    function automatic [31:0] expected_sprite(input integer address);
        expected_sprite = {pattern('h2a000 + address), pattern('h22000 + address),
                           pattern('h1a000 + address), pattern('h12000 + address)};
    endfunction
    task automatic write_word(input reg [31:0] address, input reg [31:0] data);
        integer timeout;
        begin
            @(negedge clk);
            mem_enable = 1; mem_write = 1; mem_address = address; mem_dataWrite = data;
            timeout = 0;
            do begin
                @(negedge clk); timeout = timeout + 1;
                if (timeout > 10000) $fatal(1, "Host write stalled at %h", address);
            end while (!mem_done);
            mem_enable = 0; mem_write = 0;
            @(negedge clk);
        end
    endtask
    task automatic command(input reg [15:0] opcode, input reg [31:0] id,
                           input reg [31:0] size, input bit expect_error);
        integer timeout;
        begin
            write_word(32'hf0000000, {16'd0, opcode});
            write_word(32'hf0000004, id);
            write_word(32'hf0000008, size);
            cmd_request = 1;
            timeout = 0;
            do begin
                @(negedge clk); timeout = timeout + 1;
                if (timeout > 100000) $fatal(1, "Command timeout %h", opcode);
            end while (!cmd_done && !cmd_error);
            if (cmd_error !== expect_error) $fatal(1, "Command %h unexpected error=%b", opcode, cmd_error);
            cmd_request = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    reg memory_finished = 0, video_finished = 0;
    integer i, phase, probe;
    initial begin
        repeat (8) @(negedge clk);
        reset = 0;
        command(16'h0100, 0, 0, 1); // Cannot run before required files.
        command(16'h0300, 0, 0, 0);
        for (i=0; i<'h3a000; i=i+4) begin
            write_word(32'h10000000 + i, {pattern(i+3),pattern(i+2),pattern(i+1),pattern(i)});
            // A 32-bit MCU word every >=64 system clocks (2.5 MB/s).
            repeat (58) @(negedge clk);
        end
        command(16'h0301, 0, 'h3a000, 0);
        if (cleared != 2048 || bg_writes != 32768) $fatal(1, "Clear/background byte count");
        for (i=0; i<'he000; i=i+1)
            if (memory.main_rom[i] !== pattern(i)) $fatal(1, "Main ROM byte %h", i);
        for (i=0; i<32768; i=i+1) begin
            if (bg[i] !== pattern('h32000+i)) $fatal(1, "Background byte %h", i);
            if ({sram['h10000+2*i+1],sram['h10000+2*i]} !== expected_sprite(i))
                $fatal(1, "Sprite packing %h", i);
        end
        for (i=0; i<'h2000; i=i+1)
            if (sram['h7000+i] !== {pattern('he001+2*i),pattern('he000+2*i)})
                $fatal(1, "Sound ROM word %h", i);
        command(16'h0102, 0, 0, 1); // Missing sound timing PROM.
        command(16'h0300, 1, 0, 0);
        for (i=0; i<32; i=i+4)
            write_word(32'h10040000+i, {pattern(i+3),pattern(i+2),pattern(i+1),pattern(i)});
        command(16'h0301, 1, 31, 1); // Reject wrong size.
        command(16'h0301, 1, 32, 0);
        for (i=0; i<32; i=i+1) if (prom[i] !== pattern(i)) $fatal(1, "PROM byte %0d", i);
        command(16'h0102, 0, 0, 0);
        command(16'h0100, 0, 0, 0);
        if (core_reset) $fatal(1, "Core did not run");
        for (phase=0; phase<3; phase=phase+1) begin
            repeat (phase) @(negedge clk);
            for (probe=0; probe<128; probe=probe+1) begin
                sprite_addr = 15'((probe * 277 + phase * 103) & 'h7fff);
                sound_addr = 14'((probe * 131 + phase) & 'h3fff);
                cpu_addr = 16'((probe * 379) % 'he000);
                // Upstream consumes each sprite address after eight clocks.
                repeat (8) @(negedge clk);
                if (sprite_data !== expected_sprite(sprite_addr)) $fatal(1, "Sprite deadline phase=%0d address=%h got=%h", phase, sprite_addr, sprite_data);
                if (sound_data !== pattern('he000+sound_addr)) $fatal(1, "Sound read %h", sound_addr);
                if (cpu_data !== pattern(cpu_addr)) $fatal(1, "CPU read %h", cpu_addr);
            end
        end
        command(16'h0101, 0, 0, 0);
        if (!core_reset) $fatal(1, "Halt did not reset core");
        write_word(32'h10050000, 32'h12345678); // Reject unmapped file writes.
        command(16'h0100, 0, 0, 1);
        memory_finished = 1;
        $display("HOST/MEMORY PASS: full ROM routing, PROM, drain, errors, sprite deadlines");
    end

    reg ce_pix = 0, in_hblank = 1, in_vblank = 1, video_aspect = 1;
    reg [2:0] in_r = 0, in_g = 0, in_b = 0;
    wire [2:0] out_r, out_g, out_b;
    wire out_de, out_hblank, out_vblank;
    gb_mcr_video video (.clk(clk), .reset(reset), .aspect(video_aspect), .*);
    integer pixels = 0, rows = 0;
    integer sx_expected;
    reg [8:0] expected_pixel;
    function automatic [8:0] color(input integer x, input integer y);
        color = {3'(x), 3'(y), 3'(x^y)};
    endfunction
    always @(posedge clk) begin
        #1;
        if (!reset) begin
            if (out_de) begin
                if (out_vblank || out_hblank) $fatal(1, "Blanking overlaps a pixel");
                sx_expected = video_aspect ? (pixels * 4 / 5) : pixels - 32;
                expected_pixel = (!video_aspect && (pixels < 32 || pixels >= 288)) ? 9'd0 : color(sx_expected, rows);
                if ({out_r,out_g,out_b} !== expected_pixel)
                    $fatal(1, "Video pixel row=%0d x=%0d got=%h expected=%h", rows, pixels, {out_r,out_g,out_b}, expected_pixel);
                pixels = pixels + 1;
            end
            if (out_hblank) begin
                if (pixels != 320) $fatal(1, "Line width %0d", pixels);
                pixels = 0; rows = rows + 1;
            end
        end
    end
    task automatic pixel(input bit hb, input bit vb, input reg [8:0] rgb);
        begin
            @(negedge clk); ce_pix = 1; in_hblank = hb; in_vblank = vb;
            {in_r,in_g,in_b} = rgb;
            @(negedge clk); ce_pix = 0;
        end
    endtask
    integer mode, x, y;
    initial begin
        wait (!reset);
        for (x=0; x<634; x=x+1) pixel(1,1,0);
        for (mode=0; mode<2; mode=mode+1) begin
            video_aspect = mode == 0;
            rows = 0; pixels = 0;
            for (y=0; y<480; y=y+1) begin
                for (x=0; x<511; x=x+1) pixel(0,0,color(x/2,y/2));
                for (x=0; x<123; x=x+1) pixel(1,0,0);
            end
            for (y=0; y<45; y=y+1)
                for (x=0; x<634; x=x+1) pixel(1,1,0);
            if (rows != 240 || pixels != 0 || !out_vblank) $fatal(1, "Frame dimensions rows=%0d pixels=%0d",rows,pixels);
        end
        video_finished = 1;
        $display("VIDEO PASS: 320x240, 4:3 and native width, pixels and blanking");
    end
    initial begin
        wait (memory_finished && video_finished);
        $display("PLATFORM PASS");
        $finish;
    end
    initial begin
        #200000000;
        $fatal(1, "Global test timeout");
    end
endmodule
