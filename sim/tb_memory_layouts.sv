`timescale 1ns/1ps
module tb_memory_layouts;
    reg clk=0;always #12.5 clk=!clk;
    reg reset=1,game_mcr2=0,game_sg=1,load_sg=1;
    reg game_speech=0;
    reg [13:0] speech_addr=0;
    wire [7:0] speech_data;
    reg [1:0] game_family=3,load_family=3;
    reg wr_req=0;reg[19:0]wr_addr=0;reg[7:0]wr_data=0;
    wire wr_ack,wr_error,initialized;
    reg[15:0]cpu_addr=0,sprite_addr=0;reg[17:0]sound_addr=0;
    wire[7:0]cpu_data,sound_data,dl_data,prom_data;
    wire[31:0]sprite_data;wire[15:0]dl_addr,mono_sound_data;
    wire[16:0]m2_dl_addr;wire[18:0]mono_dl_addr;
    wire dl_wr,dl_nvram,dl_nvram_wr,prom_wr,m2_dl_wr,mono_dl_wr;wire[4:0]prom_addr;
    wire sram_ce_n,sram_we_n,sram_oe_n,sram_dq_oe;wire[1:0]sram_mask_n;
    wire[17:0]sram_a;wire[15:0]sram_dq_in,sram_dq_out;
    gb_mcr_memory dut(.*);
    reg[15:0]ram[0:262143];
    assign #10 sram_dq_in = !sram_ce_n && !sram_oe_n && sram_we_n ? ram[sram_a] : 16'hzzzz;
    always @(posedge sram_we_n) if(!sram_ce_n && sram_dq_oe) begin
        if(!sram_mask_n[0])ram[sram_a][7:0]=sram_dq_out[7:0];
        if(!sram_mask_n[1])ram[sram_a][15:8]=sram_dq_out[15:8];
    end
    task write_byte(input[19:0]address,input[7:0]data);
        integer timeout;
        begin
            @(negedge clk);wr_addr=address;wr_data=data;wr_req=1;timeout=0;
            while(!wr_ack)begin @(negedge clk);timeout++;if(timeout>100)$fatal(1,"Write timeout");end
            if(wr_error)$fatal(1,"Write rejected %h",address);
            wr_req=0;repeat(4)@(negedge clk);
        end
    endtask
    integer sg,plane,probe,phase;
    reg[19:0]base,offset,sound_base;
    reg[15:0]address;
    initial begin
        repeat(4)@(negedge clk);reset=0;wait(initialized);
        for(sg=0;sg<2;sg++)begin
            load_sg=sg!=0;game_sg=sg!=0;sound_base=sg ? 'h60000 : 'h40000;
            for(probe=0;probe<4;probe++)begin
                case(probe)0:address=0;1:address='h1234;2:address=sg ? 'h8000 : 'h4000;3:address=sg ? 'hffff : 'h7fff;endcase
                for(plane=0;plane<4;plane++)
                    write_byte('h10000+plane*(sg ? 'h10000 : 'h8000)+address,8'h20+8'(plane*16+probe));
                if(sg)begin
                    write_byte(sound_base+address,8'h80+8'(probe));
                    write_byte(sound_base+'h10000+address,8'h90+8'(probe));
                end else begin
                    write_byte(sound_base+2*probe,8'h80+8'(probe));
                    write_byte(sound_base+2*probe+1,8'h90+8'(probe));
                end
            end
            for(phase=0;phase<3;phase++)begin
                for(probe=0;probe<4;probe++)begin
                    case(probe)0:address=0;1:address='h1234;2:address=sg ? 'h8000 : 'h4000;3:address=sg ? 'hffff : 'h7fff;endcase
                    repeat(phase+1)@(negedge clk);
                    sprite_addr=address;sound_addr=sg ? {address,1'b0} : 2*probe;
                    repeat(8)@(negedge clk);
                    if(sprite_data!=={8'h50+8'(probe),8'h40+8'(probe),8'h30+8'(probe),8'h20+8'(probe)})
                        $fatal(1,"Sprite planes sg=%d address=%h phase=%d got=%h",sg,address,phase,sprite_data);
                    if(mono_sound_data!=={8'h90+8'(probe),8'h80+8'(probe)})$fatal(1,"Sound word packing");
                end
            end
            @(negedge clk);wr_addr=sg ? 'h5ffff : 'h3ffff;wr_data=8'hc7;wr_req=1;#1;
            if(!mono_dl_wr || mono_dl_addr!==19'hffff)$fatal(1,"Mono BG end address");
            @(negedge clk);wr_req=0;repeat(4)@(negedge clk);
        end
        game_family=0;load_family=0;game_sg=0;load_sg=0;
        write_byte('h8000,8'hab);write_byte('h8001,8'hcd);
        sound_addr=0;repeat(12)@(negedge clk);if(sound_data!==8'hab)$fatal(1,"MCR1 sound base");
        sound_addr=1;repeat(12)@(negedge clk);if(sound_data!==8'hcd)$fatal(1,"MCR1 high byte");
        // Environmental speech ROM shares SRAM without changing other layouts.
        game_family=2;load_family=2;game_speech=1;
        for(probe=0;probe<4;probe++)begin
            case(probe)0:address=0;1:address='h1234;2:address='h2000;3:address='h3ffe;endcase
            write_byte('h3a000+address,8'h60+8'(probe));
            write_byte('h3a001+address,8'h70+8'(probe));
            for(plane=0;plane<4;plane++)write_byte('h12000+plane*'h8000+probe,8'h20+8'(plane*16+probe));
            write_byte('he000+2*probe,8'h80+8'(probe));
        end
        for(phase=0;phase<4;phase++)for(probe=0;probe<4;probe++)begin
            case(probe)0:address=0;1:address='h1234;2:address='h2000;3:address='h3ffe;endcase
            repeat(phase+1)@(negedge clk);
            speech_addr=address;sprite_addr=probe;sound_addr=2*probe;
            repeat(8)@(negedge clk);
            if(speech_data!==8'h60+8'(probe))$fatal(1,"Speech low byte/deadline %h",speech_addr);
            if(sound_data!==8'h80+8'(probe))$fatal(1,"Speech slot corrupted SSIO");
            if(sprite_data!=={8'h50+8'(probe),8'h40+8'(probe),8'h30+8'(probe),8'h20+8'(probe)})$fatal(1,"Speech slot sprite deadline");
            speech_addr=address+1;repeat(8)@(negedge clk);
            if(speech_data!==8'h70+8'(probe))$fatal(1,"Speech high byte/deadline");
        end
        $display("MEMORY LAYOUT PASS: SG/TCS planes, full address boundaries, sound word order/deadlines, MCR1 bank");
        $finish;
    end
endmodule
