`timescale 1ns/1ps
module tb_reset_families;
    reg clk=0,request=1;
    always #1 clk=!clk;
    wire m2,m3;
    gb_mcr_reset normal(.clk(clk),.request(request),.machine_reset(m3));
    gb_mcr_reset #(.RESTART_CYCLES(40000000)) long_delay(.clk(clk),.request(request),.machine_reset(m2));
    integer pass,cycle;
    initial begin
        for(pass=0;pass<2;pass++) begin
            request=1;
            repeat(4) @(negedge clk);
            if(!m2 || !m3) $fatal(1,"Reset request not held");
            request=0;
            for(cycle=1;cycle<=40000005;cycle++) begin
                @(negedge clk);
                if(m3 !== (cycle==65535)) $fatal(1,"MCR3 restart at %0d",cycle);
                if(m2 !== (cycle==40000000)) $fatal(1,"MCR2 restart at %0d",cycle);
            end
        end
        $display("FAMILY RESET PASS: exact MCR3 and one-second MCR2 restart, cold and manual");
        $finish;
    end
endmodule
