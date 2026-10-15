// MCR progressive RGB -> 320x240 VideoV0. Two line banks let capture and
// output run independently. Sample alternate source pixels/lines; stretch
// 256 -> 320 with nearest-neighbour or centre 256 pixels in black borders.
// The upstream active window is 511 pixels; sampling x=0,2,...510 gives 256.
module gb_mcr_video (
    input wire clk, reset, ce_pix,
    input wire [2:0] in_r, in_g, in_b,
    input wire in_hblank, in_vblank, aspect,
    output reg [2:0] out_r, out_g, out_b,
    output reg out_de, out_hblank, out_vblank
);
    reg [8:0] lines [0:511];
    reg [9:0] x;
    reg [8:0] y;
    reg hb_q, synced, bank, line_seen;
    reg active, read_bank, aspect_line;
    reg [8:0] ox;
    reg [7:0] sx;
    reg [2:0] frac;
    reg [8:0] pixel;
    reg valid_q, black_q, last_q, blank_q;
    wire black = !aspect_line && (ox < 32 || ox >= 288);
    wire [7:0] source_x = aspect_line ? sx : 8'(ox - 9'd32);

    always @(posedge clk) begin
        out_de <= valid_q;
        out_hblank <= blank_q;
        blank_q <= last_q;
        {out_r, out_g, out_b} <= black_q ? 9'd0 : pixel;
        valid_q <= active;
        black_q <= black;
        last_q <= active && ox == 319;
        // Synchronous RAM read, with matching data-enable and blanking delay.
        pixel <= lines[{read_bank, source_x}];
        if (active) begin
            if (ox == 319) active <= 0;
            else ox <= ox + 1'b1;
            if (frac >= 1) begin
                frac <= frac - 1'b1;
                sx <= sx + 1'b1;
            end else frac <= 4;
        end
        if (reset) begin
            x <= 0; y <= 0; hb_q <= 1; synced <= 0; bank <= 0;
            line_seen <= 0; active <= 0; valid_q <= 0; last_q <= 0; blank_q <= 0;
            out_de <= 0; out_hblank <= 0; out_vblank <= 1;
            ox <= 0; sx <= 0; frac <= 0; read_bank <= 0;
            aspect_line <= 1; black_q <= 1;
        end else if (ce_pix) begin
            hb_q <= in_hblank;
            if (in_vblank) begin
                x <= 0; y <= 0; line_seen <= 0; synced <= 1;
                if (!active && !valid_q && !last_q) out_vblank <= 1;
            end else if (in_hblank) begin
                x <= 0;
                if (!hb_q && line_seen) begin
                    y <= y + 1'b1;
                    line_seen <= 0;
                    if (!y[0] && y < 480) begin
                        read_bank <= bank; bank <= !bank;
                        ox <= 0; sx <= 0; frac <= 0;
                        active <= 1; aspect_line <= aspect; out_vblank <= 0;
                    end
                end
            end else if (synced) begin
                line_seen <= 1;
                x <= x + 1'b1;
                if (!y[0] && y < 480 && !x[0] && x < 512)
                    lines[{bank, x[8:1]}] <= {in_r, in_g, in_b};
            end
        end
    end
endmodule
