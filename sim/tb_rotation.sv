`timescale 1ns/1ps
module tb_rotation;
    reg clock=0, reset=1, boundary=0;
    reg [11:0] x=0,y=0;
    reg [1:0] requested=0;
    wire [1:0] rotation;
    wire [16:0] lcd_address, hdmi_address;
    wire lcd_bounds, hdmi_bounds;
    RotationTestTop dut (.clock(clock),.reset(reset),.io_x(x),.io_y(y),
        .io_requested(requested),.io_boundary(boundary),.io_rotation(rotation),
        .io_lcdAddress(lcd_address),.io_lcdInBounds(lcd_bounds),
        .io_hdmiAddress(hdmi_address),.io_hdmiInBounds(hdmi_bounds));
    task tick;
        #1; clock=1; #1; clock=0; #1;
    endtask
    // Independent destination rectangle -> inverse rotation reference.
    function automatic integer source_address(input integer px,py,turn,screen_width,offset);
        integer vw,vh,dw,dh,ox,oy,rx,ry,sx,sy;
        begin
            vw=(turn%2) ? 240 : 320;
            vh=(turn%2) ? 320 : 240;
            if (turn%2) begin dw=360; dh=480; end
            else begin dw=640; dh=480; end
            ox=(screen_width-dw)/2+offset; oy=(480-dh)/2;
            if (px<ox || px>=ox+dw || py<oy || py>=oy+dh) source_address=-1;
            else begin
                rx=(px-ox)*vw/dw; ry=(py-oy)*vh/dh;
                case(turn)
                    0: begin sx=rx; sy=ry; end
                    1: begin sx=ry; sy=239-rx; end
                    2: begin sx=319-rx; sy=239-ry; end
                    3: begin sx=319-ry; sy=rx; end
                endcase
                source_address=sy*320+sx;
            end
        end
    endfunction
    integer turn,px,py,expected,checks=0;
    initial begin
        tick(); reset=0; tick();
        for(turn=0;turn<4;turn++) begin
            requested=2'(turn);
            tick();
            if(rotation !== 2'((turn+3)%4) && turn!=0) $fatal(1,"Rotation changed mid-frame");
            boundary=1; tick(); boundary=0;
            if(rotation !== 2'(turn)) $fatal(1,"Rotation not latched at blanking");
            // Change requests mid-frame while holding the selected orientation.
            requested=2'((turn+1)%4);
            repeat(4) tick();
            if(rotation !== 2'(turn)) $fatal(1,"Mid-frame request was applied");
            // LCD scans logical Y (portrait-mounted panel); HDMI scans X.
            for(py=-8;py<488;py++) for(px=-8;px<808;px++) begin
                x=12'(px); y=12'(py); #1;
                expected=source_address(px,py,turn,800,-28);
                if(lcd_bounds !== (expected>=0)) $fatal(1,"LCD border mode=%0d x=%0d y=%0d",turn,px,py);
                expected=source_address(px,py+3,turn,800,-28);
                if(expected>=0 && lcd_address !== 17'(expected)) $fatal(1,"LCD rotation/latency mode=%0d x=%0d y=%0d got=%0d expected=%0d",turn,px,py,lcd_address,expected);
                if(px<728) begin
                    expected=source_address(px,py,turn,720,0);
                    if(hdmi_bounds !== (expected>=0)) $fatal(1,"HDMI border");
                    expected=source_address(px+3,py,turn,720,0);
                    if(expected>=0 && hdmi_address !== 17'(expected)) $fatal(1,"HDMI rotation/latency mode=%0d x=%0d y=%0d",turn,px,py);
                end
                checks++;
            end
        end
        $display("ROTATION PASS: %0d coordinates, four turns, both scan axes, borders, latency, frame latch",checks);
        $finish;
    end
endmodule
