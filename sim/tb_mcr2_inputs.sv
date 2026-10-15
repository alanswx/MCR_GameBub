`timescale 1ns/1ps
module tb_mcr2_inputs;
    reg shollow=1,sideways=0,focus=1,service=0;
    reg up=0,down=0,left=0,right=0,a=0,b=0,start=0,coin=0,start2=0;
    wire [7:0] port0,port1,port2;
    gb_mcr2_inputs dut(.*);
    initial begin
        #1; if({port0,port1,port2} !== 24'hffffff) $fatal(1,"Idle controls");
        left=1; #1; if(port1 !== 8'hee) $fatal(1,"Upright left");
        left=0; right=1; #1; if(port1 !== 8'hdd) $fatal(1,"Upright right");
        right=0; a=1; #1; if(port1 !== 8'h77 || port0 !== 8'hff) $fatal(1,"Fire");
        a=0;b=1; #1; if(port1 !== 8'hbb) $fatal(1,"Shield");
        b=0;sideways=1;down=1; #1; if(port1 !== 8'hee) $fatal(1,"Sideways left");
        down=0;up=1; #1; if(port1 !== 8'hdd) $fatal(1,"Sideways right");
        start=1;coin=1;start2=1; #1; if(port0 !== 8'hf2) $fatal(1,"Start/coin");
        service=1;focus=0; #1; if({port0,port1,port2} !== 24'h7fffff) $fatal(1,"Focus/service");
        shollow=0;sideways=0;focus=1;service=0;up=0;start=0;coin=0;start2=0;
        left=1;a=1; #1; if(port0 !== 8'hef || port1 !== 8'hfe || port2 !== 8'hee) $fatal(1,"Domino regression");
        $display("MCR2 INPUT PASS: fire, shield, upright/sideways, focus, Domino regression");
        $finish;
    end
endmodule
