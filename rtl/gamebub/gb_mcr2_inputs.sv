// Active-low input maps from the official MCR2 wrapper.
module gb_mcr2_inputs (
    input wire shollow, sideways, focus, service,
    input wire up, down, left, right, a, b, start, coin, start2,
    output wire [7:0] port0, port1, port2
);
    // Sideways play means holding the Bub clockwise, matching the game's
    // required clockwise picture rotation. The physical down key then points left.
    wire move_left = (sideways ? down : left) && focus;
    wire move_right = (sideways ? up : right) && focus;
    wire fire = a && focus, shield = b && focus;
    wire [3:0] directions = {down, up, right, left} & {4{focus}};
    assign port0 = ~{service, 2'b00, fire && !shollow,
        start2 && focus, start && focus, 1'b0, coin && focus};
    assign port1 = shollow ? ~{fire, shield, move_right, move_left,
                              fire, shield, move_right, move_left}
                           : ~{4'b0000, directions};
    assign port2 = shollow ? 8'hff : ~{3'b000, fire, directions};
endmodule
