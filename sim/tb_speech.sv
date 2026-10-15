`timescale 1ns/1ps
// Real speech firmware, MC6802, PIAs and TMS5200. Compare the production
// four-slot SRAM path against the source board's one-clock ROM interface.
module tb_speech;
    reg clk=0;always #12.5 clk=!clk;
    reg reset=1,board_reset=1;
    reg [7:0] op4=0;
    wire [13:0] speech_addr,reference_addr;
    wire [7:0] speech_data;
    reg [7:0] reference_data;
    wire signed [15:0] audio,reference_audio;
    wire [15:0] cpu_address,reference_cpu;
    wire ws,rs,streaming,nonzero;
    wire [2:0] progress;
    squawk_n_talk dut(.clk(clk),.reset(board_reset),
        .sound_select(op4[3:0]),.sound_int(op4[4]),.dbg_in2(8'h7f),.dbg_op4(op4),
        .rom_addr(speech_addr),.rom_do(speech_data),.audio_out(audio),
        .active(),.seen(),.cpu_run(),.progress(progress),.pia_loose(streaming),
        .tms_audio_nz(nonzero),.dac_written(),.dbg_dac(),.dbg_cpu_addr(cpu_address),
        .dbg_tms_wsn(ws),.dbg_tms_rsn(rs));
    squawk_n_talk reference_board(.clk(clk),.reset(board_reset),
        .sound_select(op4[3:0]),.sound_int(op4[4]),.dbg_in2(8'h7f),.dbg_op4(op4),
        .rom_addr(reference_addr),.rom_do(reference_data),.audio_out(reference_audio),
        .active(),.seen(),.cpu_run(),.progress(),.pia_loose(),.tms_audio_nz(),
        .dac_written(),.dbg_dac(),.dbg_cpu_addr(reference_cpu),.dbg_tms_wsn(),.dbg_tms_rsn());
    reg wr_req=0;reg [19:0] wr_addr=0;reg[7:0]wr_data=0;
    wire initialized,wr_ack,wr_error;
    wire sram_ce_n,sram_we_n,sram_oe_n,sram_dq_oe;
    wire [1:0]sram_mask_n;wire[17:0]sram_a;
    wire[15:0]sram_dq_in,sram_dq_out;
    gb_mcr_memory memory(.clk(clk),.reset(reset),.game_mcr2(1'b0),
        .game_family(2'd2),.load_family(2'd2),.game_sg(1'b0),.load_sg(1'b0),
        .game_speech(1'b1),.speech_addr(speech_addr),.speech_data(speech_data),
        .mono_dl_addr(),.mono_dl_wr(),.mono_sound_data(),.m2_dl_addr(),.m2_dl_wr(),
        .wr_req(wr_req),.wr_addr(wr_addr),.wr_data(wr_data),.wr_ack(wr_ack),.wr_error(wr_error),
        .initialized(initialized),.cpu_addr(16'd0),.cpu_data(),.sound_addr(18'd0),.sound_data(),
        .sprite_addr(16'd0),.sprite_data(),.dl_addr(),.dl_data(),.dl_wr(),.dl_nvram(),.dl_nvram_wr(),
        .prom_addr(),.prom_data(),.prom_wr(),.sram_ce_n(sram_ce_n),.sram_we_n(sram_we_n),
        .sram_oe_n(sram_oe_n),.sram_mask_n(sram_mask_n),.sram_a(sram_a),
        .sram_dq_in(sram_dq_in),.sram_dq_out(sram_dq_out),.sram_dq_oe(sram_dq_oe));
    reg[15:0]sram[0:262143];reg[7:0]rom[0:253951];
    assign #10 sram_dq_in=!sram_ce_n&&!sram_oe_n&&sram_we_n ? sram[sram_a] : 16'hzzzz;
    always @(posedge sram_we_n)if(!sram_ce_n&&sram_dq_oe)begin
        if(!sram_mask_n[0])sram[sram_a][7:0]=sram_dq_out[7:0];
        if(!sram_mask_n[1])sram[sram_a][15:8]=sram_dq_out[15:8];
    end
    always @(posedge clk)reference_data<=rom['h3a000+reference_addr];
    integer writes=0,changes=0,samples=0,tick=0,output_file;
    reg [15:0]last_audio=0;
    reg monitor=0;
    reg last_irq=0;
    always @(posedge clk)begin
        #1;
        if(monitor&&!board_reset)begin
            if(dut.cpu_irq&&!last_irq)$display("SPEECH IRQ at %0t CPU=%h",$time,cpu_address);
            last_irq=dut.cpu_irq;
            if(dut.cen&&dut.pia2_cs&&dut.cpu_rw&&dut.cpu_addr[1:0]==0)
                $display("SPEECH HOST READ at %0t data=%h",$time,dut.pia2_porta);
            if(cpu_address!==reference_cpu)$fatal(1,"SRAM changed CPU execution: %h vs %h",cpu_address,reference_cpu);
            if($isunknown(audio))$fatal(1,"Undefined speech audio: DAC=%h TMS=%h lp1=%h lp2=%h clamp=%h t11=%b io=%b",dut.dac_val,dut.tms_audio,dut.tms_lp1,dut.tms_lp2,dut.u_tms_dac.clamped,dut.tms_t11,dut.tms_io);
            if(audio!==reference_audio)$fatal(1,"Speech audio differs from source ROM interface");
            if(audio!=last_audio)changes++;
            last_audio=audio;
            if(!ws)writes++;
            if(tick==832)begin
                tick=0;samples++;
                $fwrite(output_file,"%c%c",audio[7:0],audio[15:8]);
            end else tick++;
        end
    end
    task write_byte(input[19:0]address,input[7:0]data);
        integer timeout;
        begin
            @(negedge clk);wr_addr=address;wr_data=data;wr_req=1;timeout=0;
            while(!wr_ack)begin @(negedge clk);timeout++;if(timeout>100)$fatal(1,"SRAM upload timeout");end
            if(wr_error)$fatal(1,"Speech upload rejected %h",address);
            wr_req=0;repeat(4)@(negedge clk);
        end
    endtask
    string path,out;integer fd,count,i;
    initial begin
        if(!$value$plusargs("rom=%s",path)||!$value$plusargs("audio=%s",out))$fatal(1,"Supply local Environmental ROM and audio output path");
        fd=$fopen(path,"rb");if(!fd)$fatal(1,"Missing ROM");count=$fread(rom,fd);$fclose(fd);
        if(count!=253952||{rom[253950],rom[253951]}!==16'hf983)$fatal(1,"Wrong speech ROM/vector");
        output_file=$fopen(out,"wb");if(!output_file)$fatal(1,"Cannot open audio output");
        for(i=0;i<262144;i++)sram[i]=0;
        repeat(4)@(negedge clk);reset=0;wait(initialized);
        for(i=0;i<16384;i++)write_byte('h3a000+i,rom['h3a000+i]);
        repeat(50000)@(negedge clk);board_reset=0;monitor=1;
        // Firmware exhaustively tests every byte of internal RAM with all
        // 256 values. Wait for its CLI, rather than sending a cue during
        // the long startup self-test while interrupts are still masked.
        wait(dut.u_cpu.u_regs.i===1'b0);
        repeat(80000)@(negedge clk);
        $display("SPEECH READY: CPU=%h progress=%h",cpu_address,progress);$fflush();
        // The game presents the low nibble, strobes, then presents the high
        // nibble 1255 us later. $2B is the MASTER CONTROL phrase.
        op4=8'h1b;repeat(50200)@(negedge clk);op4=8'h02;
        repeat(80000)@(negedge clk);
        $display("COMMAND STATUS CPU=%h progress=%h IRQ edges=%h reads=%h command=%h ws=%h",cpu_address,progress,dut.irq_edges,dut.pia2_rd,dut.cmd_at_read,dut.ws_count8);$fflush();
        repeat(8000000)@(negedge clk);
        if(!streaming||!nonzero||changes<100||writes<100)$fatal(1,"Speech did not play: stream=%b nonzero=%b changes=%d",streaming,nonzero,changes);
        $fclose(output_file);
        $display("SPEECH PASS: real firmware/TMS5200, four-slot SRAM CPU/audio identical to source ROM, changes=%0d samples=%0d",changes,samples);
        $finish;
    end
    initial begin
        #5000000000.0;
        $fatal(1,"Speech boot/playback timeout PC=%h A=%h B=%h X=%h I=%b",dut.u_cpu.u_regs.pc,dut.u_cpu.u_regs.a,dut.u_cpu.u_regs.b,dut.u_cpu.u_regs.x,dut.u_cpu.u_regs.i);
    end
    initial repeat(5) begin
        #500000000.0;
        $display("SPEECH BOOT PC=%h A=%h B=%h X=%h I=%b",dut.u_cpu.u_regs.pc,dut.u_cpu.u_regs.a,dut.u_cpu.u_regs.b,dut.u_cpu.u_regs.x,dut.u_cpu.u_regs.i);$fflush();
    end
endmodule
