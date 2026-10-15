`timescale 1ns/1ps
module tb_mcr_controls;
    reg clk=0; always #5 clk=!clk;
    reg reset=1,vblank=0,mcr2=1,portrait=0,focus=1,service=0;
    reg [2:0] mode=1;
    reg [1:0] portrait_mode=0;
    reg up=0,down=0,left=0,right=0,a=0,b=0,x=0,y=0,l=0,r=0,start=0,coin=0;
    reg [7:0] dips=8'hf8;
    wire [7:0] port0,port1,port2,port3,port4;
    gb_mcr_controls dut(.*);
    task tick_frame;
        begin @(negedge clk);vblank=0;@(negedge clk);vblank=1;
            repeat(5) @(negedge clk);vblank=0;@(negedge clk); end
    endtask
    initial begin
        repeat(2) @(negedge clk);reset=0;
        a=1;left=1;#1;
        if(port0!==8'hef || port2!==8'hee || port3!==8'h78 || port4!==8'hff) $fatal(1,"Tron trigger/directions");
        a=0;left=0;r=1;tick_frame();
        if(port1!==8'hfc || port4!==8'hfc) $fatal(1,"Tron spinner increment");
        l=1;tick_frame();if(port1!==8'hfc) $fatal(1,"Opposed spinner keys");
        r=0;tick_frame();if(port1!==8'hff) $fatal(1,"Tron reverse spinner");
        l=0;portrait=1;portrait_mode=2;up=1;#1;
        if(port2!==8'hee) $fatal(1,"Portrait CCW movement");
        up=0;portrait=0;portrait_mode=0;mode=2;a=1;b=1;x=1;left=1;#1;
        if(port2!==8'hfc || port0!==8'hef) $fatal(1,"Two Tigers shoot/bomb/dogfight");
        tick_frame();if(port1!==8'h86) $fatal(1,"Two Tigers turn wraps backward");
        left=0;a=0;b=0;x=0;mode=3;right=1;up=1;tick_frame();
        if(port1!==8'd0 || port2!==8'd2) $fatal(1,"Wacko trackball axes");
        right=0;up=0;a=1;#1;if(port4!==8'hee) $fatal(1,"Wacko right zap");
        a=0;b=1;#1;if(port4!==8'hbb) $fatal(1,"Wacko down zap");
        b=0;x=1;#1;if(port4!==8'h77) $fatal(1,"Wacko up zap");
        x=0;y=1;#1;if(port4!==8'hdd) $fatal(1,"Wacko left zap");
        y=0;mode=4;left=1;up=1;#1;
        if(port2!==37 || port4!==37) $fatal(1,"Kroozr analog minima");
        left=0;up=0;right=1;down=1;#1;
        if(port2!==163 || port4!==163) $fatal(1,"Kroozr analog maxima");
        focus=0;#1;if(port2!==100 || port4!==100 || port0!==8'hff) $fatal(1,"Focus analog neutral");
        focus=1;right=0;down=0;mcr2=0;mode=2;a=1;b=1;x=1;y=1;#1;
        if(port0!==8'hef || port2!==8'h8f) $fatal(1,"Discs toss/deflect/aim");
        a=0;b=0;x=0;y=0;r=1;start=1;#1;
        if(port0!==8'hf7) $fatal(1,"Spinner Start 2 chord");
        tick_frame();if(port1!==8'h86) $fatal(1,"Start chord must not spin");
        r=0;start=0;mode=3;portrait=1;portrait_mode=1;down=1;a=1;#1;
        if(port0!==8'hef || port1!==8'hfe || port2!==8'hee) $fatal(1,"Journey portrait directions/fire");
        focus=0;service=1;#1;
        if({port0,port1,port2}!==24'h7fffff) $fatal(1,"Service/focus");
        $display("MCR CONTROLS PASS: all new maps, spinner wrap/rate/chords, trackball, analog, portrait, focus");
        $finish;
    end
endmodule
