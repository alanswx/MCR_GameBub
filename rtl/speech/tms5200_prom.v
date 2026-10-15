module tms5200_prom(input            clk,
		    input	     clk_en,
		    input [9:0]	     addr,
		    input	     output_transfer,
		    output reg [9:0] out);

   reg [9:0] data [0:271];

   reg [6:0] ydecode = 0;
   reg [1:0] xdecode = 0;

   initial begin
    data[0] = 10'h000;
    data[1] = 10'h001;
    data[2] = 10'h002;
    data[3] = 10'h003;
    data[4] = 10'h004;
    data[5] = 10'h006;
    data[6] = 10'h008;
    data[7] = 10'h00B;
    data[8] = 10'h010;
    data[9] = 10'h017;
    data[10] = 10'h021;
    data[11] = 10'h02F;
    data[12] = 10'h03F;
    data[13] = 10'h055;
    data[14] = 10'h072;
    data[15] = 10'h000;
    data[16] = 10'h000;
    data[17] = 10'h00E;
    data[18] = 10'h00F;
    data[19] = 10'h010;
    data[20] = 10'h011;
    data[21] = 10'h012;
    data[22] = 10'h013;
    data[23] = 10'h014;
    data[24] = 10'h015;
    data[25] = 10'h016;
    data[26] = 10'h017;
    data[27] = 10'h018;
    data[28] = 10'h019;
    data[29] = 10'h01A;
    data[30] = 10'h01B;
    data[31] = 10'h01C;
    data[32] = 10'h01D;
    data[33] = 10'h01E;
    data[34] = 10'h01F;
    data[35] = 10'h020;
    data[36] = 10'h022;
    data[37] = 10'h024;
    data[38] = 10'h026;
    data[39] = 10'h028;
    data[40] = 10'h029;
    data[41] = 10'h02B;
    data[42] = 10'h02D;
    data[43] = 10'h030;
    data[44] = 10'h031;
    data[45] = 10'h033;
    data[46] = 10'h036;
    data[47] = 10'h037;
    data[48] = 10'h039;
    data[49] = 10'h03C;
    data[50] = 10'h03E;
    data[51] = 10'h040;
    data[52] = 10'h044;
    data[53] = 10'h048;
    data[54] = 10'h04A;
    data[55] = 10'h04C;
    data[56] = 10'h051;
    data[57] = 10'h055;
    data[58] = 10'h057;
    data[59] = 10'h05A;
    data[60] = 10'h060;
    data[61] = 10'h063;
    data[62] = 10'h067;
    data[63] = 10'h06B;
    data[64] = 10'h070;
    data[65] = 10'h075;
    data[66] = 10'h07A;
    data[67] = 10'h07F;
    data[68] = 10'h085;
    data[69] = 10'h08B;
    data[70] = 10'h091;
    data[71] = 10'h097;
    data[72] = 10'h09D;
    data[73] = 10'h0A4;
    data[74] = 10'h0AB;
    data[75] = 10'h0B2;
    data[76] = 10'h0BA;
    data[77] = 10'h0C2;
    data[78] = 10'h0CA;
    data[79] = 10'h0D3;
    data[80] = 10'h202;
    data[81] = 10'h20A;
    data[82] = 10'h139;
    data[83] = 10'h13E;
    data[84] = 10'h20B;
    data[85] = 10'h20E;
    data[86] = 10'h211;
    data[87] = 10'h216;
    data[88] = 10'h21B;
    data[89] = 10'h222;
    data[90] = 10'h22B;
    data[91] = 10'h235;
    data[92] = 10'h242;
    data[93] = 10'h251;
    data[94] = 10'h264;
    data[95] = 10'h27B;
    data[96] = 10'h296;
    data[97] = 10'h2B5;
    data[98] = 10'h2D9;
    data[99] = 10'h303;
    data[100] = 10'h331;
    data[101] = 10'h364;
    data[102] = 10'h39A;
    data[103] = 10'h3D3;
    data[104] = 10'h00D;
    data[105] = 10'h046;
    data[106] = 10'h07E;
    data[107] = 10'h0B3;
    data[108] = 10'h0E4;
    data[109] = 10'h110;
    data[110] = 10'h137;
    data[111] = 10'h159;
    data[112] = 10'h176;
    data[113] = 10'h18F;
    data[114] = 10'h1A4;
    data[115] = 10'h1B5;
    data[116] = 10'h202;
    data[117] = 10'h20A;
    data[118] = 10'h139;
    data[119] = 10'h13E;
    data[120] = 10'h288;
    data[121] = 10'h29B;
    data[122] = 10'h2B1;
    data[123] = 10'h2C8;
    data[124] = 10'h2E2;
    data[125] = 10'h2FE;
    data[126] = 10'h31D;
    data[127] = 10'h33D;
    data[128] = 10'h35F;
    data[129] = 10'h384;
    data[130] = 10'h3A9;
    data[131] = 10'h3CF;
    data[132] = 10'h3F6;
    data[133] = 10'h01D;
    data[134] = 10'h044;
    data[135] = 10'h06A;
    data[136] = 10'h08F;
    data[137] = 10'h0B2;
    data[138] = 10'h0D4;
    data[139] = 10'h0F3;
    data[140] = 10'h110;
    data[141] = 10'h12B;
    data[142] = 10'h144;
    data[143] = 10'h15A;
    data[144] = 10'h16E;
    data[145] = 10'h180;
    data[146] = 10'h190;
    data[147] = 10'h19E;
    data[148] = 10'h1AB;
    data[149] = 10'h1B6;
    data[150] = 10'h1C0;
    data[151] = 10'h1FA;
    data[152] = 10'h202;
    data[153] = 10'h20A;
    data[154] = 10'h139;
    data[155] = 10'h13E;
    data[156] = 10'h269;
    data[157] = 10'h283;
    data[158] = 10'h2A3;
    data[159] = 10'h2C9;
    data[160] = 10'h2F4;
    data[161] = 10'h326;
    data[162] = 10'h35E;
    data[163] = 10'h39A;
    data[164] = 10'h3D9;
    data[165] = 10'h019;
    data[166] = 10'h059;
    data[167] = 10'h095;
    data[168] = 10'h0CE;
    data[169] = 10'h101;
    data[170] = 10'h12E;
    data[171] = 10'h155;
    data[172] = 10'h202;
    data[173] = 10'h20A;
    data[174] = 10'h139;
    data[175] = 10'h13E;
    data[176] = 10'h2DE;
    data[177] = 10'h304;
    data[178] = 10'h32F;
    data[179] = 10'h35D;
    data[180] = 10'h38E;
    data[181] = 10'h3C2;
    data[182] = 10'h3F7;
    data[183] = 10'h02C;
    data[184] = 10'h061;
    data[185] = 10'h093;
    data[186] = 10'h0C2;
    data[187] = 10'h0EE;
    data[188] = 10'h116;
    data[189] = 10'h139;
    data[190] = 10'h158;
    data[191] = 10'h173;
    data[192] = 10'h202;
    data[193] = 10'h20A;
    data[194] = 10'h139;
    data[195] = 10'h13E;
    data[196] = 10'h2C2;
    data[197] = 10'h2E5;
    data[198] = 10'h30B;
    data[199] = 10'h336;
    data[200] = 10'h364;
    data[201] = 10'h395;
    data[202] = 10'h3C8;
    data[203] = 10'h3FD;
    data[204] = 10'h031;
    data[205] = 10'h065;
    data[206] = 10'h096;
    data[207] = 10'h0C4;
    data[208] = 10'h0EF;
    data[209] = 10'h116;
    data[210] = 10'h139;
    data[211] = 10'h158;
    data[212] = 10'h202;
    data[213] = 10'h20A;
    data[214] = 10'h139;
    data[215] = 10'h13E;
    data[216] = 10'h33F;
    data[217] = 10'h368;
    data[218] = 10'h393;
    data[219] = 10'h3BF;
    data[220] = 10'h3EC;
    data[221] = 10'h01A;
    data[222] = 10'h047;
    data[223] = 10'h073;
    data[224] = 10'h09E;
    data[225] = 10'h0C6;
    data[226] = 10'h0EB;
    data[227] = 10'h10E;
    data[228] = 10'h12D;
    data[229] = 10'h14A;
    data[230] = 10'h163;
    data[231] = 10'h179;
    data[232] = 10'h302;
    data[233] = 10'h326;
    data[234] = 10'h34C;
    data[235] = 10'h374;
    data[236] = 10'h39F;
    data[237] = 10'h3CB;
    data[238] = 10'h3F8;
    data[239] = 10'h024;
    data[240] = 10'h051;
    data[241] = 10'h07C;
    data[242] = 10'h0A5;
    data[243] = 10'h0CC;
    data[244] = 10'h0F0;
    data[245] = 10'h112;
    data[246] = 10'h130;
    data[247] = 10'h14C;
    data[248] = 10'h333;
    data[249] = 10'h390;
    data[250] = 10'h3F6;
    data[251] = 10'h05C;
    data[252] = 10'h0BB;
    data[253] = 10'h10D;
    data[254] = 10'h150;
    data[255] = 10'h183;
    data[256] = 10'h307;
    data[257] = 10'h349;
    data[258] = 10'h392;
    data[259] = 10'h3E0;
    data[260] = 10'h030;
    data[261] = 10'h07E;
    data[262] = 10'h0C6;
    data[263] = 10'h105;
    data[264] = 10'h342;
    data[265] = 10'h37B;
    data[266] = 10'h3B7;
    data[267] = 10'h3F6;
    data[268] = 10'h035;
    data[269] = 10'h073;
    data[270] = 10'h0AD;
    data[271] = 10'h0E3;
end

   always @(posedge clk)
     if (clk_en) begin

	if (output_transfer)
	  out <= data[{ ydecode, xdecode }];
	   
	xdecode <= addr[1:0];
	ydecode <= 7'd0;
	case (addr[9:6])
	  4'd0: ydecode <= 7'd0 + addr[3:2]; // E
	  4'd1: ydecode <= 7'd4 + addr[5:2]; // P
	  4'd2: // K1
	    if (addr[5])
	      ydecode <= (addr[4:2] == 3'b000 ? 7'd20 : 7'd0);
	    else
	      ydecode <= 7'd21 + addr[4:2];
	  4'd3: // K2
	    if (addr[5])
	      ydecode <= (addr[4:2] == 3'b000 ? 7'd29 : 7'd0);
	    else
	      ydecode <= 7'd30 + addr[4:2];
	  4'd4: // K3
	    if (addr[4])
	      ydecode <= (addr[3:2] == 2'b00 ? 7'd38 : 7'd0);
	    else
	      ydecode <= 7'd39 + addr[3:2];
	  4'd5: // K4
	    if (addr[4])
	      ydecode <= (addr[3:2] == 2'b00 ? 7'd43 : 7'd0);
	    else
	      ydecode <= 7'd44 + addr[3:2];
	  4'd6: // K5
	    if (addr[4])
	      ydecode <= (addr[3:2] == 2'b00 ? 7'd48 : 7'd0);
	    else
	      ydecode <= 7'd49 + addr[3:2];
	  4'd7: // K6
	    if (addr[4])
	      ydecode <= (addr[3:2] == 2'b00 ? 7'd53 : 7'd0);
	    else
	      ydecode <= 7'd54 + addr[3:2];
	  4'd8: ydecode <= 7'd58 + addr[3:2]; // K7
	  4'd9: ydecode <= 7'd62 + addr[2:2]; // K8
	  4'd10: ydecode <= 7'd64 + addr[2:2]; // K9
	  4'd11: ydecode <= 7'd66 + addr[2:2]; // K10
	  default: ydecode <= 7'd0;
	endcase // case (addr[9:6])
     end
   
endmodule // tms5200_prom
