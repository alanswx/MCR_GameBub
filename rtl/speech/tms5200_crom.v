module tms5200_crom(input        clk,
		    input	 clk_en,
		    input [8:0]	 addr,
		    input	 addr_en,
		    output [7:0] out);

   reg [5:0] clamped_addr = 0;
   reg [7:0] data [0:51];
   reg [7:0] compl_data = 0;
   reg	     data_en = 0;
   
   assign out = ~compl_data;

   initial begin
    data[0] = 8'hFF;
    data[1] = 8'hFC;
    data[2] = 8'hF0;
    data[3] = 8'hD7;
    data[4] = 8'hB3;
    data[5] = 8'h93;
    data[6] = 8'h8E;
    data[7] = 8'hAF;
    data[8] = 8'hDA;
    data[9] = 8'hD9;
    data[10] = 8'hB3;
    data[11] = 8'hBB;
    data[12] = 8'hE5;
    data[13] = 8'hCD;
    data[14] = 8'hC4;
    data[15] = 8'hEC;
    data[16] = 8'hC8;
    data[17] = 8'hE5;
    data[18] = 8'hDA;
    data[19] = 8'hE0;
    data[20] = 8'hE2;
    data[21] = 8'hFF;
    data[22] = 8'hFF;
    data[23] = 8'hFF;
    data[24] = 8'hFF;
    data[25] = 8'hFF;
    data[26] = 8'hFF;
    data[27] = 8'hFF;
    data[28] = 8'hFF;
    data[29] = 8'hFF;
    data[30] = 8'hFF;
    data[31] = 8'hFF;
    data[32] = 8'hFF;
    data[33] = 8'hFF;
    data[34] = 8'hFF;
    data[35] = 8'hFF;
    data[36] = 8'hFF;
    data[37] = 8'hFF;
    data[38] = 8'hFF;
    data[39] = 8'hFF;
    data[40] = 8'hFF;
    data[41] = 8'hFF;
    data[42] = 8'hFF;
    data[43] = 8'hFF;
    data[44] = 8'hFF;
    data[45] = 8'hFF;
    data[46] = 8'hFF;
    data[47] = 8'hFF;
    data[48] = 8'hFF;
    data[49] = 8'hFF;
    data[50] = 8'hFF;
    data[51] = 8'hFF;
end
   
   always @(posedge clk)
     if (clk_en) begin

	if (addr_en) begin
	   clamped_addr <= ( addr <= 9'd51 ? addr[5:0] : 9'd51 );
	   data_en <= 1'b1;
	end else
	  data_en <= 1'b0;
	if (data_en)
	  compl_data <= data[clamped_addr];
     end

endmodule // tms5200_crom
