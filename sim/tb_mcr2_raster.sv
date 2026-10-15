`timescale 1ns/1ps
// Regression for RGB pipeline compensation: one complete progressive frame.
// This checks the board's real blanking outputs against the capture contract.
module tb_mcr2_raster;
    reg clk = 0, reset = 1;
    always #12.5 clk = !clk;
    wire hb, vb, ce;
    mcr2 board (
        .clock_40(clk), .reset(reset), .tv15Khz_mode(1'b0),
        .video_r(), .video_g(), .video_b(), .video_csync(),
        .video_hblank(hb), .video_vblank(vb), .video_hs(), .video_vs(), .video_ce(ce),
        .separate_audio(1'b0), .audio_out_l(), .audio_out_r(),
        .input_0(8'hff), .input_1(8'hff), .input_2(8'hff), .input_3(8'hff), .input_4(8'hff),
        .cpu_rom_addr(), .cpu_rom_do(8'd0), .cpu_rom_rd(),
        .snd_rom_addr(), .snd_rom_do(8'd0),
        .dl_addr(17'd0), .dl_data(8'd0), .dl_wr(1'b0), .dl_din(),
        .dl_nvram(1'b0), .dl_nvram_wr(1'b0), .flip_out(),
        .prom_addr(5'd0), .prom_data(8'd0), .prom_wr(1'b0)
    );
    initial begin
        repeat (16) @(negedge clk);
        reset = 0;
    end
    integer x = 0, y = 0, active_pixels = 0;
    always @(posedge clk) if (!reset && ce) begin
        #1;
        if (hb !== !(x >= 18 && x < 530))
            $fatal(1, "MCR2 horizontal window x=%0d y=%0d blank=%b", x,y,hb);
        if (vb !== !(y < 480))
            $fatal(1, "MCR2 vertical window x=%0d y=%0d blank=%b", x,y,vb);
        if (!hb && !vb) active_pixels++;
        if (x == 633) begin
            x = 0;
            if (y == 524) begin
                if (active_pixels != 512*480) $fatal(1, "Incomplete capture window");
                $display("MCR2 RASTER PASS: 18-pixel delay, 512x480 active, 634x525 total");
                $finish;
            end
            y++;
        end else x++;
    end
    initial begin
        #20000000;
        $fatal(1, "MCR2 raster timeout");
    end
endmodule
