// Handheld maps follow the official MCR2/MCR3 wrappers. Button-driven counters
// substitute for their spinners/trackball, with the same per-frame increments.
module gb_mcr_controls (
    input wire clk, reset, vblank, mcr2, portrait, focus, service,
    input wire [2:0] mode,
    input wire [1:0] family, snd_stat,
    input wire [7:0] output5, output6,
    input wire [1:0] portrait_mode,
    input wire up, down, left, right, a, b, x, y, l, r, start, coin,
    input wire [7:0] dips,
    output reg [7:0] port0, port1, port2, port3, port4
);
    wire sideways_cw = portrait && portrait_mode == 1;
    wire sideways_ccw = portrait && portrait_mode == 2;
    wire u = focus && (sideways_cw ? left : sideways_ccw ? right : up);
    wire d = focus && (sideways_cw ? right : sideways_ccw ? left : down);
    wire lt = focus && (sideways_cw ? down : sideways_ccw ? up : left);
    wire rt = focus && (sideways_cw ? up : sideways_ccw ? down : right);
    wire fa = a && focus, fb = b && focus, fc = x && focus, fd = y && focus;
    wire spinner_game = family == 0 ? mode == 0 : family == 3 ? mode == 4 : mcr2 ? (mode == 1 || mode == 2 || mode == 4) : (mode == 2 || mode == 4);
    // R remains Start 2 on the existing games; spinner games use Start+R.
    wire s2 = focus && r && (!spinner_game || start);
    wire s1 = focus && start && !(spinner_game && r);
    wire ccw = focus && !start && (l || ((family == 0 || (family == 3 && mode == 4) || (mcr2 && mode == 2)) && lt));
    wire cw = focus && !start && (r || ((family == 0 || (family == 3 && mode == 4) || (mcr2 && mode == 2)) && rt));
    reg gear_button, gear_down_button, power_gear;
    reg [2:0] gear;
    reg [1:0] adc_select;
    reg derby_mux;
    function automatic [3:0] gear_code(input [2:0] value);
        case(value)
            1:gear_code=5; 2:gear_code=6; 3:gear_code=1; 4:gear_code=2;
            default:gear_code=0;
        endcase
    endfunction
    always @(posedge clk) begin
        if(reset) begin gear_button<=0;gear_down_button<=0;power_gear<=0;gear<=0;adc_select<=0;derby_mux<=0;end
        else begin
            gear_button<=fa;gear_down_button<=fb;
            if(family == 3 && mode == 2 && fa && !gear_button) power_gear<=!power_gear;
            if(family == 3 && mode == 3) begin
                if(s1) gear<=0;
                else if(fa && !gear_button && gear<4) gear<=gear+1'b1;
                else if(fb && !gear_down_button && gear>0) gear<=gear-1'b1;
            end
            if(!output6[6] && !output6[5]) adc_select<=output5[2:1];
            if(output6[7]) derby_mux<=0;
            if(output6[6]) derby_mux<=1;
        end
    end
    reg vb_last;
    reg [9:0] spin, track_x, track_y;
    wire [9:0] spin_step = family == 0 ? (fb ? 10'd8 : 10'd4) : family == 3 ? 10'd10 : mcr2 ? (mode == 2 ? 10'd55 : 10'd25) : 10'd10;
    always @(posedge clk) begin
        if (reset) begin vb_last <= 0; spin <= 0; track_x <= 0; track_y <= 0; end
        else begin
            vb_last <= vblank;
            if (vblank && !vb_last) begin
                if (cw != ccw) spin <= ccw ? spin - spin_step : spin + spin_step;
                if (lt != rt) track_x <= lt ? track_x - 10'd10 : track_x + 10'd10;
                // Up increments Y, matching the upstream Wacko spinner.
                if (u != d) track_y <= d ? track_y - 10'd10 : track_y + 10'd10;
            end
        end
    end
    wire [7:0] old0, old1, old2, m20, m21, m22;
    gb_mcr_inputs legacy_m3 (
        .timber(mode == 1), .focus(focus), .service(service),
        .up(u), .down(d), .left(lt), .right(rt), .a(a), .b(b),
        .start(s1), .coin(coin), .start2(s2), .port0(old0), .port1(old1), .port2(old2)
    );
    gb_mcr2_inputs legacy_m2 (
        .shollow(mode == 0), .portrait_mode(2'd0), .focus(focus), .service(service),
        .up(u), .down(d), .left(lt), .right(rt), .a(a), .b(b),
        .start(s1), .coin(coin), .start2(s2), .port0(m20), .port1(m21), .port2(m22)
    );
    always @* begin
        port0 = mcr2 ? m20 : old0;
        port1 = mcr2 ? m21 : old1;
        port2 = mcr2 ? m22 : old2;
        port3 = dips; port4 = 8'hff;
        if (mcr2) case (mode)
            1: begin // Tron, including the duplicate trigger/spinner inputs.
                port1 = ~{1'b0, spin[9:3]};
                port2 = ~{d,u,rt,lt,d,u,rt,lt};
                port3[7] = !fa;
                port4 = port1;
            end
            2: begin // Two Tigers conversion, player 1 only.
                port0 = ~{service,2'b00,fc,s2,s1,1'b0,coin && focus};
                port1 = ~{1'b0, spin[9:3]};
                port2 = ~{6'd0,fb,fa};
            end
            3: begin // Wacko: movement trackball and four firing directions.
                port0 = ~{service,3'b000,s2,s1,1'b0,coin && focus};
                port1 = track_x[9:2]; port2 = track_y[9:2];
                port4 = ~{fc,fb,fd,fa,fc,fb,fd,fa};
            end
            4: begin // Kozmik Krooz'r: ship stick and turret spinner.
                port1 = ~{fb,spin[9],3'b111,spin[8:6]};
                port2 = lt ? 8'd37 : rt ? 8'd163 : 8'd100;
                port4 = u ? 8'd37 : d ? 8'd163 : 8'd100;
            end
            default: ;
        endcase
        else case (mode)
            2,4: begin // Discs of Tron: movement, toss/deflect, aim up/down.
                port0 = ~{service,2'b00,fa,s2,s1,1'b0,coin && focus};
                port1 = ~{1'b0,spin[9:3]};
                port2 = ~{(mode == 4),fb,fc,fd,d,u,rt,lt};
            end
            3: begin // Journey's MCR2.5 input map.
                port0 = ~{service,2'b00,fa,s2,s1,1'b0,coin && focus};
                port1 = ~{4'd0,d,u,rt,lt};
                port2 = ~{3'd0,fa,d,u,rt,lt};
            end
            default: ;
        endcase
        if (family == 0) begin
            port0 = ~{service,2'b00,fa,s2,s1,1'b0,coin && focus};
            port1 = ~{4'd0,spin[5:2]}; port2 = 8'hff; port3=dips; port4=8'hff;
            if(mode == 1) begin
                port0 = ~{service,2'b00,fa,fb,fb,1'b0,coin && focus};
                port1 = ~{u,d,lt,rt,u,d,lt,rt}; port2=~{7'd0,fa};
            end
        end
        if (family == 3) begin
            port0=~{2'b00,service,1'b0,s2,s1,1'b0,coin && focus};
            port1=8'hff;port2=8'hff;port3=dips;port4=8'hff;
            case(mode)
                0: begin // Rampage, player 1; third-player port carries sound status.
                    port0=~{2'b00,service,4'd0,coin && focus};
                    port1=~{2'd0,fb,fa,lt,d,rt,u}; port4=~{snd_stat[0],7'd0};
                end
                1: port1=~{fb,fb,fa,fa,(d|rt),(u|lt),(d|lt),(u|rt)}; // Sarge single-stick steering
                2: begin // Power Drive: L/R wheels, B wheelie, A toggles drive gear.
                    port0=~{2'b00,service,4'd0,coin && focus};
                    port1=~{4'd0,(r && focus),(l && focus),power_gear,fb};
                    port2=~{snd_stat[0],7'd0};
                end
                3: begin // Max RPM ADC channel selected by the game.
                    port0=~{service,3'd0,s1,s2,(coin && focus),1'b0};
                    case(adc_select)
                        0:port1=8'hff; // P2 throttle released
                        1:port1=u ? 8'h30 : 8'hff;
                        2:port1=8'h74; // P2 steering centered
                        3:port1=lt ? 8'hb4 : rt ? 8'h34 : 8'h74;
                    endcase
                    port2=~{gear_code(gear),4'd0};
                end
                4: port1=~{(derby_mux ? 6'd0 : spin[7:2]),fb,fa}; // Derby wheel mux; other players idle
                5: begin // Star Guards, four firing directions.
                    port0=~{service,2'd0,snd_stat[0],1'b0,s1,1'b0,(coin && focus)};
                    port1=~{rt,lt,d,u,fa,fd,fb,fc};
                end
                default: ;
            endcase
        end
    end
endmodule
