// SRAM pin timing from ColecoVision_GameBub gb_cart_sram (GPL-3.0).
// 40 MHz: registered address, one cycle (25 ns) access; masked byte writes.
`default_nettype none

module gb_sram (
	input  wire        clk,
	input  wire        reset,

	// ---- writes: 16-bit word address, held until wr_ack ----
	input  wire        wr_req,
	input  wire [17:0] wr_addr,
	input  wire [15:0] wr_data,
	input wire [1:0] wr_mask_n,
	output reg         wr_ack,

	// ---- reads: the word at rd_addr, continuously ----
	input  wire [17:0] rd_addr,
	output reg  [15:0] q,
	output reg  [17:0] q_addr,
	output reg         q_valid,

	// ---- SRAM pins (framework SramV0) ----
	output reg         sram_ce_n   = 1'b1,
	output reg         sram_we_n   = 1'b1,
	output reg         sram_oe_n   = 1'b1,
	output reg   [1:0] sram_mask_n = 2'b11,    // {UB#, LB#}
	output reg  [17:0] sram_a      = 18'd0,
	input  wire [15:0] sram_dq_in,
	output reg  [15:0] sram_dq_out = 16'd0,
	output reg         sram_dq_oe  = 1'b0
);

	localparam [1:0] P_IDLE = 2'd0, P_W1 = 2'd1, P_W2 = 2'd2, P_W3 = 2'd3;
	reg  [1:0] ph = P_IDLE;
	reg        turn = 1'b0;            // the cycle after a write
	reg        rd_issued = 1'b0;       // a read address is on the pins now
	reg [17:0] a_issued = 18'd0;       // ... and which (sram_a stays in the I/O blocks)

	always @(posedge clk) begin
		// read data: the address issued last cycle is answered now
		q       <= sram_dq_in;
		q_addr  <= a_issued;
		q_valid <= rd_issued;

		wr_ack    <= 1'b0;
		rd_issued <= 1'b0;
		turn      <= 1'b0;
		if (reset) begin
			ph          <= P_IDLE;
			sram_ce_n   <= 1'b1;
			sram_we_n   <= 1'b1;
			sram_oe_n   <= 1'b1;
			sram_mask_n <= 2'b11;
			sram_dq_oe  <= 1'b0;
			q_valid     <= 1'b0;
		end else begin
			sram_ce_n <= 1'b0;
			case (ph)
			P_IDLE: begin
				sram_we_n  <= 1'b1;
				sram_dq_oe <= 1'b0;
				if (wr_req && !turn) begin
					// W1: address, data and both byte lanes, outputs off
					sram_a      <= wr_addr;
					sram_dq_out <= wr_data;
					sram_mask_n <= wr_mask_n;
					sram_oe_n   <= 1'b1;
					ph          <= P_W1;
				end else if (!wr_req) begin
					sram_a      <= rd_addr;
					a_issued    <= rd_addr;
					sram_mask_n <= 2'b00;
					sram_oe_n   <= 1'b0;
					rd_issued   <= !turn;   // the bus is still turning round
				end
			end
			P_W1: begin
				// W2: drive data, WE low
				sram_dq_oe <= 1'b1;
				sram_we_n  <= 1'b0;
				ph         <= P_W2;
			end
			P_W2: begin
				// W3: WE high, data and address still held
				sram_we_n <= 1'b1;
				ph        <= P_W3;
			end
			default: begin
				// turnaround: stop driving, tell the writer
				sram_dq_oe <= 1'b0;
				wr_ack     <= 1'b1;
				turn       <= 1'b1;
				ph         <= P_IDLE;
			end
			endcase
		end
	end

endmodule

`default_nettype wire
