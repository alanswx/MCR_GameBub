/*  This file is part of JTCORES.
    JTCORES program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCORES program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCORES.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 22-11-2023 */
/* verilator coverage_off */
// 6800 has an 8-bit ALU
// 6801 might have used an 8-bit ALU
// 6301 seems to have a 16-bit ALU
module jt680x_alu(
    input          rst,
    input          clk,
    input          cen,
    input          alu16,
    input   [ 1:0] carry_sel,
    input   [ 3:0] alu_sel,
    input          cin,
    input          hin,
    input   [15:0] op0, op1,

    output reg        ho,
    output reg [15:0] rslt,
    output     [ 3:0] rslt_cc
);

/*  This file is part of JTCORES.
    JTCORES program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCORES program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCORES.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 12-04-2026 */

// Control signals
localparam [4:0] // JSR
         DIR_JSR = 5'd1,
       DIR16_JSR = 5'd2,
        DIRA_JSR = 5'd3,
         EXT_JSR = 5'd4,
       EXT16_JSR = 5'd5,
        EXTA_JSR = 5'd6,
       IDLE4_JSR = 5'd7,
       IDLE6_JSR = 5'd8,
         IDX_JSR = 5'd9,
       IDX16_JSR = 5'd10,
        IDXA_JSR = 5'd11,
         IMM_JSR = 5'd12,
       IMM16_JSR = 5'd13,
        IVRD_JSR = 5'd14,
       PSH16_JSR = 5'd15,
        PSH8_JSR = 5'd16,
       PUL16_JSR = 5'd17,
        PUL8_JSR = 5'd18,
         RET_JSR = 5'd19,
        RTI8_JSR = 5'd20;

localparam [1:0] // CARRY
       CIN_CARRY = 2'd1,
       SHL_CARRY = 2'd2,
       SHR_CARRY = 2'd3;

localparam [1:0] // EA
            M_EA = 2'd1,
            S_EA = 2'd2;

localparam [3:0] // ALU
         ADD_ALU = 4'd1,
         AND_ALU = 4'd2,
         ASR_ALU = 4'd3,
         DAA_ALU = 4'd4,
         EOR_ALU = 4'd5,
         LSL_ALU = 4'd6,
         LSR_ALU = 4'd7,
         MUL_ALU = 4'd8,
          OR_ALU = 4'd9,
         SUB_ALU = 4'd10;

localparam [4:0] // CC
            C_CC = 5'd1,
           C0_CC = 5'd2,
           C1_CC = 5'd3,
        HNZVC_CC = 5'd4,
           I0_CC = 5'd5,
           I1_CC = 5'd6,
     N0Z1V0C0_CC = 5'd7,
        N0ZVC_CC = 5'd8,
          NZV_CC = 5'd9,
         NZV0_CC = 5'd10,
       NZV0C0_CC = 5'd11,
       NZV0C1_CC = 5'd12,
         NZVC_CC = 5'd13,
           V0_CC = 5'd14,
           V1_CC = 5'd15,
            Z_CC = 5'd16;

localparam [3:0] // LD
            A_LD = 4'd1,
            B_LD = 4'd2,
           CC_LD = 4'd3,
            D_LD = 4'd4,
           EA_LD = 4'd5,
           MD_LD = 4'd6,
           PC_LD = 4'd7,
            S_LD = 4'd8,
            X_LD = 4'd9;

localparam [1:0] // OPND
        LD0_OPND = 2'd1,
        LD1_OPND = 2'd2;

localparam [3:0] // RMUX
          A_RMUX = 4'd1,
          B_RMUX = 4'd2,
         CC_RMUX = 4'd3,
          D_RMUX = 4'd4,
         EA_RMUX = 4'd5,
         IV_RMUX = 4'd6,
         MD_RMUX = 4'd7,
        ONE_RMUX = 4'd8,
         PC_RMUX = 4'd9,
          S_RMUX = 4'd10,
          X_RMUX = 4'd11,
       ZERO_RMUX = 4'd12;

// entry points for ucode procedures
localparam DIR_SEQA             = 12'h140;
localparam DIR16_SEQA           = 12'h150;
localparam DIRA_SEQA            = 12'h450;
localparam EXT_SEQA             = 12'h1C0;
localparam EXT16_SEQA           = 12'h1D0;
localparam EXTA_SEQA            = 12'h550;
localparam IDLE4_SEQA           = 12'h870;
localparam IDLE6_SEQA           = 12'h420;
localparam IDX_SEQA             = 12'h1E0;
localparam IDX16_SEQA           = 12'h1F0;
localparam IDXA_SEQA            = 12'h4B0;
localparam IMM_SEQA             = 12'h8F0;
localparam IMM16_SEQA           = 12'hCF0;
localparam ISRV_SEQA            = 12'hC70;
localparam IVRD_SEQA            = 12'h0;
localparam PSH16_SEQA           = 12'h20;
localparam PSH8_SEQA            = 12'h4E0;
localparam PUL16_SEQA           = 12'h410;
localparam PUL8_SEQA            = 12'h30;
localparam RTI16_SEQA           = 12'h520;
localparam RTI8_SEQA            = 12'h510;

reg  c8, c16, cx,
     v8, v16,
     n8, n16,
     z8, z16;

reg [7:0] daa;
reg       valid_hi, valid_lo;

assign rslt_cc  = alu16 ? {n16,z16,v16,c16} : {n8,z8,v8,c8};

always @* begin
    case( carry_sel )
        CIN_CARRY: cx = cin;
        SHL_CARRY: cx = op1[7];
        SHR_CARRY: cx = op0[0];
        default:   cx = 0;
    endcase

    rslt = op0;
    c8   = 0;
    c16  = 0;
    v8   = 0;
    v16  = 0;
    ho   = 0;
    case( alu_sel )
        ADD_ALU: begin
            {ho,  rslt[ 3:0]} = {1'b0, op0[ 3:0]}+{1'b0, op1[ 3:0]}+{4'd0,cx};
            {c8,  rslt[ 7:4]} = {1'b0, op0[ 7:4]}+{1'b0, op1[ 7:4]}+{4'd0,ho};
            {c16, rslt[15:8]} = {1'b0, op0[15:8]}+{1'b0, op1[15:8]}+{8'd0,c8};
            v8  = &{op0[ 7],op1[ 7],~rslt[ 7]}|&{~op0[ 7],~op1[ 7],rslt[ 7]};
            v16 = &{op0[15],op1[15],~rslt[15]}|&{~op0[15],~op1[15],rslt[15]};
        end
        DAA_ALU: begin
            rslt = {op0[15:8],op0[7:0]+daa}; // output daa so the ucode can use it as an operand
            v8  = ^{op0[ 7],op1[ 7],~rslt[ 7]}; // manual defines it as undefined, so leaving it as ADD_ALU makes sense
            c8   = cin || daa[6]; // 6801 reference manual, page 103
        end
        AND_ALU: rslt = op0 & op1;
         OR_ALU: rslt = op0 | op1;
        EOR_ALU: rslt = op0 ^ op1;
        MUL_ALU: begin
            rslt = op0[7:0]*op1[7:0];  // Use a hardware multiplier
            c8 = rslt[7];
        end
        ASR_ALU, LSR_ALU: begin
            rslt[15:8] = {1'b0, op0[7:1]};
            rslt[ 7:0] = {cx,op1[7:1]};
            c8  = op1[0];
            c16 = op1[0];
            v8  = rslt[ 7] ^ c8; // result of N^C (after shift execution)
            v16 = rslt[15] ^ c16;
        end
        LSL_ALU: begin
            {c16, rslt[15:8]}= {op0[7:0],op1[7]};
            { c8, rslt[ 7:0]}= {op1[7:0],cx};
            v8  = rslt[ 7] ^ c8;
            v16 = rslt[15] ^ c16;
        end
        SUB_ALU: begin
            {c8,  rslt[ 7:0]} = {1'b0, op0[ 7:0]}-{1'b0,op1[ 7:0]}-{8'b0,cx};
            {c16, rslt[15:8]} = {1'b0, op0[15:8]}-{1'b0,op1[15:8]}-{8'b0,c8};
            v8  = &{op0[ 7],~op1[ 7],~rslt[ 7]}|&{~op0[ 7],op1[ 7],rslt[ 7]};
            v16 = &{op0[15],~op1[15],~rslt[15]}|&{~op0[15],op1[15],rslt[15]};
        end
        default: rslt = op0;
    endcase

    z8  = rslt[ 7:0]==0;
    z16 = rslt[15:0]==0;
    n8  = rslt[7];
    n16 = rslt[15];
end

always @* begin
    valid_lo = (op0[3:0] <= 9);
    valid_hi = (op0[7:4] <= 9);

    daa = cin?(hin?8'h66:  valid_lo ? 8'h60 : 8'h66) :
          hin           ? (valid_hi ? 8'h06 : 8'h66) :
          valid_lo      ? (valid_hi ? 8'h00 : 8'h60) :
          op0[7:4] <= 8 ? 8'h06 : 8'h66;
end

endmodule