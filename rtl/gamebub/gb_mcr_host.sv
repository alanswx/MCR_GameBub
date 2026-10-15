// HostV0 command protocol and posted ROM writes. Queue/handshake pattern from
// ColecoVision_GameBub gb_host (GPL-3.0-or-later). Byte order is little endian.
// File 0: 0x10000000, MCR3 .rom (0x3a000 bytes).
// File 1: 0x10040000, SSIO timing PROM (32 bytes).
// No writable files are advertised until NVRAM persistence is implemented.
module gb_mcr_host #(
    // CRC32/ISO-HDLC of the complete stock MRA index-0 ROM, no header.
    parameter [31:0] TAPPER_CRC32 = 32'h0f584827,
    parameter [31:0] TIMBER_CRC32 = 32'h3f49e94e
) (
    input wire clk, reset,
    input wire mem_enable, mem_write,
    input wire [31:0] mem_address, mem_dataWrite,
    output reg [31:0] mem_dataRead,
    output reg mem_done,
    input wire cmd_request,
    output wire cmd_busy, cmd_done, cmd_error,
    output reg wr_req,
    output reg [19:0] wr_addr,
    output reg [7:0] wr_data,
    input wire wr_ack, wr_error,
    output wire core_reset,
    output reg act_reset, focus,
    output reg aspect,
    output reg [1:0] volume,
    output reg service,
    output reg [7:0] dips,
    output reg game_timber,
    output wire [31:0] debug_status
);
    reg [31:0] command [0:7];
    reg [1:0] command_state;
    reg setup_done, run;
    reg [1:0] present;
    reg load_error;
    reg [31:0] crc_state;
    reg [19:0] rom_bytes;
    reg rom_loading;
    wire [31:0] rom_crc = ~crc_state;
    wire game_known = rom_crc == TAPPER_CRC32 || rom_crc == TIMBER_CRC32;
    function automatic [31:0] crc_byte(input [31:0] previous, input [7:0] data);
        reg [31:0] value;
        integer bit_index;
        begin
            value = previous ^ {24'd0, data};
            for (bit_index=0; bit_index<8; bit_index=bit_index+1)
                value = (value >> 1) ^ (value[0] ? 32'hedb88320 : 32'd0);
            crc_byte = value;
        end
    endfunction
    reg [31:0] file_size [0:1];
    reg response_pending;
    wire is_file = mem_address[31:20] == 12'h100;
    wire is_command = mem_address[31:5] == (32'hf0000000 >> 5);
    wire is_local = mem_address[31:12] == 0;
    wire [15:0] opcode = command[0][15:0];
    wire id_ok = command[1] < 2;
    wire id = command[1][0];
    assign cmd_busy = 0;
    assign cmd_done = command_state == 1;
    assign cmd_error = command_state == 2;
    assign core_reset = !(setup_done && run && (&present)) || load_error;

    reg [49:0] queue [0:511];
    reg [49:0] head;
    reg [9:0] wp, rp;
    wire empty = wp == rp;
    wire full = wp[8:0] == rp[8:0] && wp[9] != rp[9];
    wire accept = mem_enable && !mem_done && !response_pending;
    wire push = accept && is_file && mem_write && !full && !reset;
    always @(posedge clk) begin
        if (push) queue[wp[8:0]] <= {mem_address[19:2], mem_dataWrite};
        head <= queue[rp[8:0]];
    end
    reg [2:0] engine;
    reg [1:0] lane;
    reg [31:0] word_data;
    wire drained = empty && engine == 0;
    assign debug_status = {24'd0, load_error, present, focus, drained, run, setup_done, core_reset};
    integer i;
    always @(posedge clk) begin
        mem_done <= 0;
        act_reset <= 0;
        if (reset) begin
            mem_dataRead <= 0; response_pending <= 0;
            wp <= 0; rp <= 0; engine <= 0; wr_req <= 0;
            wr_addr <= 0; wr_data <= 0; lane <= 0; word_data <= 0;
            command_state <= 0; setup_done <= 0; run <= 0;
            present <= 0; load_error <= 0; focus <= 0;
            crc_state <= 32'hffffffff; rom_bytes <= 0;
            rom_loading <= 0; game_timber <= 0;
            aspect <= 1; volume <= 0; service <= 0; dips <= 8'hff;
            for (i=0; i<8; i=i+1) command[i] <= 0;
            for (i=0; i<2; i=i+1) file_size[i] <= 0;
        end else begin
            if (response_pending) begin
                mem_done <= 1; response_pending <= 0;
            end else if (accept) begin
                if (is_file && mem_write) begin
                    if (!full) begin wp <= wp + 1'b1; response_pending <= 1; end
                end else begin
                    response_pending <= 1;
                    if (mem_write) begin
                        if (is_command) command[mem_address[4:2]] <= mem_dataWrite;
                        else if (is_local) case (mem_address[11:0])
                            12'h100: if (!core_reset && mem_dataWrite != 0) act_reset <= 1;
                            12'h200: aspect <= mem_dataWrite[0];
                            12'h204: volume <= mem_dataWrite[1:0];
                            12'h208: service <= mem_dataWrite[0];
                            12'h20c: dips <= mem_dataWrite[7:0];
                            default: ;
                        endcase
                    end else begin
                        mem_dataRead <= 0;
                        if (is_command) mem_dataRead <= command[mem_address[4:2]];
                        else if (is_local) case (mem_address[11:0])
                            12'h200: mem_dataRead <= {31'd0, aspect};
                            12'h204: mem_dataRead <= {30'd0, volume};
                            12'h208: mem_dataRead <= {31'd0, service};
                            12'h20c: mem_dataRead <= {24'd0, dips};
                            12'h800: mem_dataRead <= 32'h4d435233;
                            12'h804: mem_dataRead <= debug_status;
                            12'h810: mem_dataRead <= file_size[0];
                            12'h814: mem_dataRead <= file_size[1];
                            12'h818: mem_dataRead <= rom_crc;
                            12'h81c: mem_dataRead <= {30'd0, game_known, game_timber};
                            default: ;
                        endcase
                    end
                end
            end
            case (engine)
                0: if (!empty) engine <= 1;
                1: begin
                    wr_addr <= {head[49:32], 2'b00};
                    word_data <= head[31:0]; wr_data <= head[7:0];
                    wr_req <= 1; lane <= 0; engine <= 2;
                end
                2: if (wr_ack) begin
                    wr_req <= 0; engine <= 3;
                    if (wr_error) load_error <= 1;
                    if (wr_addr < 20'h3a000) begin
                        if (!rom_loading || wr_addr != rom_bytes) load_error <= 1;
                        else begin
                            crc_state <= crc_byte(crc_state, wr_data);
                            rom_bytes <= rom_bytes + 1'b1;
                        end
                    end
                end
                3: if (!wr_ack) begin
                    if (lane == 3) begin rp <= rp + 1'b1; engine <= 0; end
                    else begin
                        lane <= lane + 1'b1; wr_addr <= wr_addr + 1'b1;
                        word_data <= {8'd0, word_data[31:8]};
                        wr_data <= word_data[15:8]; wr_req <= 1; engine <= 2;
                    end
                end
                default: engine <= 0;
            endcase
            if (!cmd_request) command_state <= 0;
            else if (command_state == 0 && drained && !push) begin
                command_state <= 1;
                command[0] <= 0;
                case (opcode)
                    16'h0000: command[0] <= !setup_done ? 2 : run ? 4 : 3;
                    16'h0100: if (setup_done && (&present) && !load_error) run <= 1;
                              else command_state <= 2;
                    16'h0101: run <= 0;
                    16'h0102: if ((&present) && !load_error) setup_done <= 1;
                              else command_state <= 2;
                    16'h0200: focus <= command[1][0];
                    16'h0300: if (!id_ok) command_state <= 2;
                              else begin
                                  run <= 0; setup_done <= 0; present[id] <= 0;
                                  if (id == 0) begin
                                      load_error <= 0; crc_state <= 32'hffffffff;
                                      rom_bytes <= 0; rom_loading <= 1; game_timber <= 0;
                                  end
                              end
                    16'h0301: if (!id_ok || load_error ||
                                  command[2] != (id ? 32'd32 : 32'h3a000) ||
                                  (!id && (!rom_loading || rom_bytes != 20'h3a000 || !game_known))) command_state <= 2;
                              else begin
                                  present[id] <= 1; file_size[id] <= command[2];
                                  if (!id) begin
                                      game_timber <= rom_crc == TIMBER_CRC32;
                                      rom_loading <= 0;
                                      dips <= 8'hff; // Both supported MRAs default to FF 00.
                                  end
                              end
                    // These files are read-only; reject unsupported readback.
                    default: command_state <= 2;
                endcase
            end
        end
    end
endmodule
