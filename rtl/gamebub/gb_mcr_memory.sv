// MCR3 ROM routing and SRAM schedule, all on clk_sys=40 MHz.
// Main CPU: 64 KiB BRAM. Backgrounds: upstream BRAM through dl_*.
// SRAM sound at word 0x7000..0x8fff; sprites at word 0x10000..0x1ffff.
// Four 32 KiB sprite planes become one 32-bit word per graphics address.
// Repeating SRAM read slots: sprite low, sprite high, sound. Both sprite
// halves use the same latched address. Worst-case response is <8 clocks.
module gb_mcr_memory (
    input wire clk, reset,
    input wire game_mcr2,
    input wire [1:0] game_family, load_family,
    input wire game_sg, load_sg,
    output wire [18:0] mono_dl_addr,
    output wire mono_dl_wr,
    output wire [15:0] mono_sound_data,
    output wire [16:0] m2_dl_addr,
    output wire m2_dl_wr,
    input wire wr_req,
    input wire [19:0] wr_addr,
    input wire [7:0] wr_data,
    output reg wr_ack, wr_error,
    output reg initialized,
    input wire [15:0] cpu_addr,
    output reg [7:0] cpu_data,
    input wire [17:0] sound_addr,
    output wire [7:0] sound_data,
    input wire [15:0] sprite_addr,
    output reg [31:0] sprite_data,
    output wire [15:0] dl_addr,
    output wire [7:0] dl_data,
    output wire dl_wr, dl_nvram, dl_nvram_wr,
    output wire [4:0] prom_addr,
    output wire [7:0] prom_data,
    output wire prom_wr,
    output wire sram_ce_n, sram_we_n, sram_oe_n,
    output wire [1:0] sram_mask_n,
    output wire [17:0] sram_a,
    input wire [15:0] sram_dq_in,
    output wire [15:0] sram_dq_out,
    output wire sram_dq_oe
);
    reg [7:0] main_rom [0:65535];
    reg [10:0] clear_addr;
    wire loading_mono = load_family == 3;
    wire [19:0] mono_bg_base = load_sg ? 20'h50000 : 20'h30000;
    wire [19:0] mono_sound_base = load_sg ? 20'h60000 : 20'h40000;
    wire main_sel = wr_addr < (loading_mono ? 20'h10000 : 20'h0e000);
    wire sound_sel = loading_mono ? wr_addr >= mono_sound_base && wr_addr < 20'h80000 :
        wr_addr >= (load_family == 0 ? 20'h08000 : 20'h0c000) && wr_addr < 20'h12000;
    wire sprite_sel = loading_mono ? wr_addr >= 20'h10000 && wr_addr < mono_bg_base :
        wr_addr >= 20'h12000 && wr_addr < 20'h32000;
    wire bg_sel = !loading_mono && wr_addr >= 20'h32000 && wr_addr < 20'h3a000;
    wire mono_bg_sel = loading_mono && wr_addr >= mono_bg_base && wr_addr < mono_sound_base;
    wire prom_sel = wr_addr >= 20'hf0000 && wr_addr < 20'hf0020;
    wire start_write = wr_req && !wr_ack && initialized;
    wire [19:0] sprite_offset = wr_addr - (loading_mono ? 20'h10000 : 20'h12000);
    wire [19:0] bg_offset = wr_addr - 20'h32000;
    wire [19:0] mono_sound_offset = wr_addr - mono_sound_base;
    wire [17:0] mono_sprite_write = load_sg ?
        {1'b0,sprite_offset[15:0],sprite_offset[17]} : {2'b00,sprite_offset[14:0],sprite_offset[16]};
    wire [17:0] mono_sound_write = 18'h20000 + (load_sg ?
        {1'b0,mono_sound_offset[17],mono_sound_offset[15:0]} : {1'b0,mono_sound_offset[17:1]});
    wire [17:0] sram_wr_addr = loading_mono ? (sprite_sel ? mono_sprite_write : mono_sound_write) :
        sprite_sel ? {2'b01,sprite_offset[14:0],sprite_offset[16]} : wr_addr[18:1];
    wire high_byte = loading_mono ?
        (sprite_sel ? (load_sg ? sprite_offset[16] : sprite_offset[15]) : (load_sg ? mono_sound_offset[16] : wr_addr[0])) :
        sprite_sel ? sprite_offset[15] : wr_addr[0];
    wire sram_req = start_write && (sound_sel || sprite_sel);
    wire sram_ack;
    assign m2_dl_addr = !initialized ? {6'd0, clear_addr} : wr_addr[16:0];
    assign m2_dl_wr = start_write && wr_addr >= 20'h10000 && wr_addr < 20'h1c000;
    assign mono_dl_addr = !initialized ? {8'd0,clear_addr} : (wr_addr - mono_bg_base);
    assign mono_dl_wr = start_write && mono_bg_sel;
    assign dl_addr = !initialized ? {5'd0, clear_addr} : bg_offset[15:0];
    assign dl_data = !initialized ? 8'd0 : wr_data;
    assign dl_wr = start_write && bg_sel;
    assign dl_nvram = !initialized;
    assign dl_nvram_wr = !initialized && !reset;
    assign prom_addr = wr_addr[4:0];
    assign prom_data = wr_data;
    // PROM writes clock on the falling edge inside the upstream sound board.
    // wr_req stays asserted through that edge before host sees wr_ack.
    assign prom_wr = wr_req && initialized && prom_sel;

    reg [1:0] slot;
    reg [15:0] sprite_latched;
    wire [17:0] mono_sprite_read = game_sg ? {1'b0,sprite_addr,1'b0} : {2'b00,sprite_addr[14:0],1'b0};
    wire [17:0] mono_sprite_saved = game_sg ? {1'b0,sprite_latched,1'b1} : {2'b00,sprite_latched[14:0],1'b1};
    wire [17:0] read_addr = game_family == 3 ?
        (slot == 0 ? mono_sprite_read : slot == 1 ? mono_sprite_saved : 18'h20000 + {1'b0,sound_addr[17:1]}) :
        slot == 0 ? {2'b01,sprite_addr[14:0],1'b0} :
        slot == 1 ? {2'b01,sprite_latched[14:0],1'b1} :
        (game_family == 0 ? 18'h04000 : game_mcr2 ? 18'h06000 : 18'h07000) + {5'd0,sound_addr[13:1]};
    wire [15:0] q;
    wire [17:0] q_addr;
    wire q_valid;
    reg [15:0] sprite_low, sound_word;
    assign mono_sound_data = sound_word;
    assign sound_data = sound_addr[0] ? sound_word[15:8] : sound_word[7:0];
    gb_sram sram (
        .clk(clk), .reset(reset), .wr_req(sram_req),
        .wr_addr(sram_wr_addr), .wr_data({wr_data, wr_data}),
        .wr_mask_n({!high_byte, high_byte}), .wr_ack(sram_ack),
        .rd_addr(read_addr), .q(q), .q_addr(q_addr), .q_valid(q_valid),
        .sram_ce_n(sram_ce_n), .sram_we_n(sram_we_n), .sram_oe_n(sram_oe_n),
        .sram_mask_n(sram_mask_n), .sram_a(sram_a), .sram_dq_in(sram_dq_in),
        .sram_dq_out(sram_dq_out), .sram_dq_oe(sram_dq_oe)
    );
    always @(posedge clk) begin
        cpu_data <= main_rom[cpu_addr];
        if (start_write && main_sel) main_rom[wr_addr[15:0]] <= wr_data;
        if (reset) begin
            initialized <= 0; clear_addr <= 0; wr_ack <= 0; wr_error <= 0;
            slot <= 0; sprite_latched <= 0; sprite_low <= 0;
            sprite_data <= 0; sound_word <= 0;
        end else begin
            if (!initialized) begin
                if (clear_addr == 2047) initialized <= 1;
                else clear_addr <= clear_addr + 1'b1;
            end
            if (!wr_req) begin wr_ack <= 0; wr_error <= 0; end
            else if (start_write) begin
                wr_ack <= (sound_sel || sprite_sel) ? sram_ack : 1'b1;
                wr_error <= !(main_sel || sound_sel || sprite_sel || bg_sel || mono_bg_sel || prom_sel);
            end
            if (wr_req || !initialized) slot <= 0;
            else begin
                slot <= slot == 2 ? 2'd0 : slot + 1'b1;
                if (slot == 0) sprite_latched <= sprite_addr;
            end
            if (q_valid) begin
                if (game_family == 3 ? !q_addr[17] : q_addr[17:16] == 2'b01) begin
                    if (!q_addr[0]) sprite_low <= q;
                    else sprite_data <= {q, sprite_low};
                end else sound_word <= q;
            end
        end
    end
endmodule
