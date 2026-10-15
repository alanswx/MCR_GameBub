// Unsigned SSIO level to signed AudioV0, with DC removal at ~48 kHz.
module gb_mcr_audio (
    input wire clk, reset,
    input wire [15:0] sample,
    input wire [1:0] volume,
    output reg [15:0] out
);
    reg [9:0] tick;
    reg [25:0] average;
    wire signed [26:0] delta = $signed({1'b0, sample, 10'd0}) - $signed({1'b0, average});
    wire signed [16:0] centered = $signed({1'b0, sample}) - $signed({1'b0, average[25:10]});
    wire signed [19:0] scaled = 20'(centered) <<< volume;
    always @(posedge clk) begin
        if (reset) begin
            tick <= 0; average <= 0; out <= 0;
        end else begin
            if (tick == 832) begin
                tick <= 0;
                average <= average + 26'(delta >>> 10);
            end else tick <= tick + 1'b1;
            out <= scaled > 32767 ? 16'h7fff : scaled < -32768 ? 16'h8000 : scaled[15:0];
        end
    end
endmodule
