// Active-low ports from upstream's Tapper and Timber input maps.
// Timber is single-player here; its independent second joystick stays idle.
module gb_mcr_inputs (
    input wire timber, focus, service,
    input wire up, down, left, right, a, b, start, coin, start2,
    output wire [7:0] port0, port1, port2
);
    wire [3:0] directions = {up, down, left, right} & {4{focus}};
    assign port0 = ~{service, 3'b000, start2 && focus && !timber,
                      start && focus, 1'b0, coin && focus};
    assign port1 = timber ? ~{2'b00, a && focus, b && focus, directions}
                          : ~{3'b000, a && focus, directions};
    assign port2 = timber ? 8'hff : port1;
endmodule
