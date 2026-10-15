// Release the board, then issue upstream's delayed one-cycle restart.
// MCR3 uses 65535 clocks; MCR2 uses 40000000 (one second at 40 MHz).
// Holding reset throughout that interval would lose the second reset edge.
module gb_mcr_reset #(
    parameter integer RESTART_CYCLES = 65535,
    parameter integer COUNT_BITS = $clog2(RESTART_CYCLES + 1)
) (
    input wire clk,
    input wire request,
    output reg machine_reset = 1'b1
);
    localparam [COUNT_BITS-1:0] INITIAL_COUNT = RESTART_CYCLES;
    reg [COUNT_BITS-1:0] restart_count = INITIAL_COUNT;
    always @(posedge clk) begin
        if (request) restart_count <= INITIAL_COUNT;
        else if (restart_count != 0) restart_count <= restart_count - 1'b1;
        machine_reset <= request || restart_count == 1;
    end
endmodule
