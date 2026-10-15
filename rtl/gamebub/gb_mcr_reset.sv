// Match Arcade-MCR3.sv: release the board, then pulse reset once more after
// 65535 system clocks. Holding reset throughout that interval is not
// equivalent: board state must clock before the second reset edge.
module gb_mcr_reset (
    input wire clk,
    input wire request,
    output reg machine_reset = 1'b1
);
    reg [15:0] restart_count = 16'hffff;
    always @(posedge clk) begin
        if (request) restart_count <= 16'hffff;
        else if (restart_count != 0) restart_count <= restart_count - 1'b1;
        machine_reset <= request || restart_count == 16'd1;
    end
endmodule
