//
// FX68K
//
// M68000 cycle accurate, fully synchronous
// Copyright (c) 2018 by Jorge Cwik
// 
// TODO:
// - Everything except bus retry already implemented.

// altera message_off 10030
// altera message_off 10230

`timescale 1 ns / 1 ns

// Define this to run a self contained compilation test build
// `define FX68K_TEST

localparam CF = 0, VF = 1, ZF = 2, NF = 3, XF = 4, SF = 13;

localparam UADDR_WIDTH = 10;
localparam UROM_WIDTH = 17;
localparam UROM_DEPTH = 1024;

localparam NADDR_WIDTH = 9;
localparam NANO_WIDTH = 68;
localparam NANO_DEPTH = 336;

localparam BSER1_NMA = 'h003;
localparam RSTP0_NMA = 'h002;
localparam HALT1_NMA = 'h001;
localparam TRAC1_NMA = 'h1C0;
localparam ITLX1_NMA = 'h1C4;

localparam TVN_SPURIOUS = 12;
localparam TVN_AUTOVEC = 13;
localparam TVN_INTERRUPT = 15;

localparam NANO_DOB_DBD = 2'b01;
localparam NANO_DOB_ADB = 2'b10;
localparam NANO_DOB_ALU = 2'b11;


// Clocks, phases and resets
typedef struct {
	logic clk;
	logic extReset;			// External sync reset on emulated system
	logic pwrUp;			// Asserted together with reset on emulated system coldstart
	logic enPhi1, enPhi2;	// Clock enables. Next cycle is PHI1 or PHI2
} s_clks;

// IRD decoded signals
typedef struct {
	logic isPcRel;
	logic isTas;
	logic implicitSp;
	logic toCcr;
	logic rxIsDt, ryIsDt;
	logic rxIsUsp, rxIsMovem, movemPreDecr;
	logic isByte;
	logic isMovep;
	logic [2:0] rx, ry;
	logic rxIsAreg, ryIsAreg;
	logic [15:0] ftuConst;
	logic [5:0] macroTvn;
	logic inhibitCcr;
} s_irdecod;

// Nano code decoded signals
typedef struct {
	logic permStart;
	logic waitBusFinish;
	logic isWrite;
	logic busByte;
	logic isRmc;
	logic noLowByte, noHighByte;
	
	logic updTpend, clrTpend;
	logic tvn2Ftu, const2Ftu;
	logic ftu2Dbl, ftu2Abl;
	logic abl2Pren, updPren;
	logic inl2psw, ftu2Sr, sr2Ftu, ftu2Ccr, pswIToFtu;
	logic ird2Ftu, ssw2Ftu;
	logic initST;
	logic Ir2Ird;
	
	logic auClkEn, noSpAlign;
	logic [2:0] auCntrl;
	logic todbin, toIrc;
	logic dbl2Atl, abl2Atl, atl2Abl, atl2Dbl;
	logic abh2Ath, dbh2Ath;
	logic ath2Dbh, ath2Abh;
	
	logic db2Aob, ab2Aob, au2Aob;
	logic aob2Ab, updSsw;
	// logic adb2Dob, dbd2Dob, alu2Dob;
	logic [1:0] dobCtrl;
	
	logic abh2reg, abl2reg;
	logic reg2abl, reg2abh;
	logic dbh2reg, dbl2reg;
	logic reg2dbl, reg2dbh;
	logic ssp, pchdbh, pcldbl, pclabl, pchabh;
	
	logic rxh2dbh, rxh2abh;
	logic dbl2rxl, dbh2rxh;
	logic rxl2db, rxl2ab;
	logic abl2rxl, abh2rxh;
	logic dbh2ryh, abh2ryh;
	logic ryl2db, ryl2ab;
	logic ryh2dbh, ryh2abh;
	logic dbl2ryl, abl2ryl;
	logic rz;
	logic rxlDbl;
	
	logic [2:0] aluColumn;
	logic [1:0] aluDctrl;
	logic aluActrl;
	logic aluInit, aluFinish;
	logic abd2Dcr, dcr2Dbd;
	logic dbd2Alue, alue2Dbd;
	logic dbd2Alub, abd2Alub;
	
	logic alu2Dbd, alu2Abd;
	logic au2Db, au2Ab, au2Pc;
	logic dbin2Abd, dbin2Dbd;
	logic extDbh, extAbh;
	logic ablAbd, ablAbh;
	logic dblDbd, dblDbh;
	logic abdIsByte;
} s_nanod;

module fx68k(
	input clk,
	
	// These two signals don't need to be registered. They are not async reset.
	input extReset,			// External sync reset on emulated system
	input pwrUp,			// Asserted together with reset on emulated system coldstart	
	input enPhi1, enPhi2,	// Clock enables. Next cycle is PHI1 or PHI2

	output eRWn, output ASn, output LDSn, output UDSn,
	output logic E, output VMAn,	
	output FC0, output FC1, output FC2,
	output BGn,
	output oRESETn, output oHALTEDn,
	input DTACKn, input VPAn,
	input BERRn,
	input BRn, BGACKn,
	input IPL0n, input IPL1n, input IPL2n,
	input [15:0] iEdb, output [15:0] oEdb,
	output [23:1] eab
	);
	
	// wire clock = Clks.clk;
	s_clks Clks;
	
	assign Clks.clk = clk;	
	assign Clks.extReset = extReset;
	assign Clks.pwrUp = pwrUp;	
	assign Clks.enPhi1 = enPhi1;
	assign Clks.enPhi2 = enPhi2;
	
	wire wClk;
	
	// Internal sub clocks T1-T4
	enum int unsigned { T0 = 0, T1, T2, T3, T4} tState;
	wire enT1 = Clks.enPhi1 & (tState == T4) & ~wClk;
	wire enT2 = Clks.enPhi2 & (tState == T1);
	wire enT3 = Clks.enPhi1 & (tState == T2);
	wire enT4 = Clks.enPhi2 & ((tState == T0) | (tState == T3));
	
	// T4 continues ticking during reset and group0 exception.
	// We also need it to erase ucode output latched on T4.
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp)
			tState <= T0;
		else begin
		case( tState)
		T0: if( Clks.enPhi2) tState <= T4;
		T1: if( Clks.enPhi2) tState <= T2;
		T2: if( Clks.enPhi1) tState <= T3;
		T3: if( Clks.enPhi2) tState <= T4;
		T4: if( Clks.enPhi1) tState <= wClk ? T0 : T1;
		endcase
		end
	end
	
	// The following signals are synchronized with 3 couplers, phi1-phi2-phi1.
	// Will be valid internally one cycle later if changed at the rasing edge of the clock.
	//
	// DTACK, BERR
		
	// DTACK valid at S6 if changed at the rasing edge of S4 to avoid wait states.
	// SNC (sncClkEn) is deasserted together (unless DTACK asserted too early).
	//	
	// We synchronize some signals half clock earlier. We compensate later
	reg rDtack, rBerr;
	reg [2:0] rIpl, iIpl;
	reg Vpai, BeI, BRi, BgackI, BeiDelay;
	// reg rBR;
	wire BeDebounced = ~( BeI | BeiDelay);

	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp) begin
			rBerr <= 1'b0;
			BeI <= 1'b0;
		end
		else if( Clks.enPhi2) begin
			rDtack <= DTACKn;
			rBerr <= BERRn;
			rIpl <= ~{ IPL2n, IPL1n, IPL0n};
			iIpl <= rIpl;
			
			// rBR <= BRn;			// Needed for cycle accuracy but only if BR is changed on the wrong edge of the clock
		end
		else if( Clks.enPhi1) begin
			Vpai <= VPAn;
			BeI <= rBerr;
			BeiDelay <= BeI;
			
			BRi <= BRn;
			BgackI <= BGACKn;
			// BRi <= rBR;
		end	
	end

	// Instantiate micro and nano rom
	logic [NANO_WIDTH-1:0] nanoLatch;
	logic [NANO_WIDTH-1:0] nanoOutput;
	logic [UROM_WIDTH-1:0] microLatch;
	logic [UROM_WIDTH-1:0] microOutput;
	
	logic [UADDR_WIDTH-1:0] microAddr, nma; 
	logic [NADDR_WIDTH-1:0] nanoAddr, orgAddr;
	wire rstUrom;

	// For the time being, address translation is done for nanorom only. 
	microToNanoAddr microToNanoAddr( .uAddr( nma), .orgAddr);
	
	// Output of these modules will be updated at T2 at the latest (depending on clock division)
	
	nanoRom nanoRom( .clk( Clks.clk), .nanoAddr, .nanoOutput);
	uRom uRom( .clk( Clks.clk), .microAddr, .microOutput);
	
	always_ff @( posedge Clks.clk) begin
		// uaddr originally latched on T1, except bits 6 & 7, the conditional bits, on T2
		// Seems we can latch whole address at either T1 or T2

		// Originally it's invalid on hardware reset, and forced later when coming out of reset
		if( Clks.pwrUp) begin
			microAddr <= RSTP0_NMA;
			nanoAddr <= RSTP0_NMA;
		end
		else if( enT1) begin
			microAddr <= nma;
			nanoAddr <= orgAddr;				// Register translated uaddr to naddr
		end
			
		if( Clks.extReset) begin
			microLatch <= '0;
			nanoLatch <= '0;
		end
		else if( rstUrom) begin
			// Originally reset these bits only. Not strictly needed like this.
			// Can reset the whole register if it is important.
			{ microLatch[16], microLatch[15], microLatch[0]} <= '0;
			nanoLatch <= '0;
		end
		else if( enT3) begin
			microLatch <= microOutput;
			nanoLatch <= nanoOutput;
		end
					
	end
	

	// Decoded nanocode signals
	s_nanod Nanod;
	// IRD decoded control signals
	s_irdecod Irdecod;

	//	
	reg Tpend;
	reg intPend;											// Interrupt pending
	reg pswT, pswS;
	reg [ 2:0] pswI;
	wire [7:0] ccr;
	
	wire [15:0] psw = { pswT, 1'b0, pswS, 2'b00, pswI, ccr};

	reg [15:0] ftu;
	reg [15:0] Irc, Ir, Ird;
	
	wire [15:0] alue;
	wire [15:0] Abl;
	wire prenEmpty, au05z, dcr4, ze;
	
	wire [UADDR_WIDTH-1:0] a1, a2, a3;
	wire isPriv, isIllegal, isLineA, isLineF;
	

	// IR & IRD forwarding
	always_ff @( posedge Clks.clk) begin
		if( enT1) begin
			if( Nanod.Ir2Ird)
				Ird <= Ir;
			else if(microLatch[0])		// prevented by IR => IRD !
				Ir <= Irc;
		end
	end
	
	wire [3:0] tvn;
	wire waitBusCycle, busStarting;
	wire BusRetry = 1'b0;
	wire busAddrErr;
	wire bciWrite;						// Last bus cycle was write
	wire bgBlock, busAvail;
	wire addrOe;

	wire busIsByte = Nanod.busByte & (Irdecod.isByte | Irdecod.isMovep);
	wire aob0;
	
	reg iStop;								// Internal signal for ending bus cycle
	reg A0Err;								// Force bus/address error ucode
	reg excRst;								// Signal reset exception to sequencer
	reg BerrA;
	reg Spuria, Avia;
	wire Iac;
	
	reg rAddrErr, iBusErr, Err6591;
	wire iAddrErr = rAddrErr & addrOe;		// To simulate async reset
	wire enErrClk;

	// Reset micro/nano latch after T4 of the current ublock.
	assign rstUrom = Clks.enPhi1 & enErrClk;

	uaddrDecode uaddrDecode( .opcode( Ir), .a1, .a2, .a3, .isPriv, .isIllegal, .isLineA, .isLineF, .lineBmap());

	sequencer sequencer( .Clks, .enT3, .microLatch, .Ird,
		.A0Err, .excRst, .BerrA, .busAddrErr, .Spuria, .Avia,
		.Tpend, .intPend, .isIllegal, .isPriv, .isLineA, .isLineF,
		.nma, .a1, .a2, .a3, .tvn,
		.psw, .prenEmpty, .au05z, .dcr4, .ze, .alue01( alue[1:0]), .i11( Irc[ 11]) );

	excUnit excUnit( .Clks, .Nanod, .Irdecod, .enT1, .enT2, .enT3, .enT4,
		.Ird, .ftu, .iEdb, .pswS,
		.prenEmpty, .au05z, .dcr4, .ze, .AblOut( Abl), .eab, .aob0, .Irc, .oEdb,
		.alue, .ccr);

	nDecoder3 nDecoder( .Clks, .Nanod, .Irdecod, .enT2, .enT4, .microLatch, .nanoLatch);
	
	irdDecode irdDecode( .ird( Ird), .Irdecod);
	
	busControl busControl( .Clks, .enT1, .enT4, .permStart( Nanod.permStart), .permStop( Nanod.waitBusFinish), .iStop,
		.aob0, .isWrite( Nanod.isWrite), .isRmc( Nanod.isRmc), .isByte( busIsByte), .busAvail,
		.bciWrite, .addrOe, .bgBlock, .waitBusCycle, .busStarting, .busAddrErr,
		.rDtack, .BeDebounced, .Vpai,
		.ASn, .LDSn, .UDSn, .eRWn);
		
	busArbiter busArbiter( .Clks, .BRi, .BgackI, .Halti( 1'b1), .bgBlock, .busAvail, .BGn);
		
		
	// Output reset & halt control
	wire [1:0] uFc = microLatch[ 16:15];
	logic oReset, oHalted;
	assign oRESETn = !oReset;
	assign oHALTEDn = !oHalted;
	
	// FC without permStart is special, either reset or halt
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp) begin
			oReset <= 1'b0;
			oHalted <= 1'b0;
		end
		else if( enT1) begin
			oReset <= (uFc == 2'b01) & !Nanod.permStart;
			oHalted <= (uFc == 2'b10) & !Nanod.permStart;
		end
	end
		
	logic [2:0] rFC;
	assign { FC2, FC1, FC0} = rFC;					// ~rFC;
	assign Iac = {rFC == 3'b111};					// & Control output enable !!

	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset)
			rFC <= '0;
		else if( enT1 & Nanod.permStart) begin		// S0 phase of bus cycle
			rFC[2] <= pswS;
			// If FC is type 'n' (0) at ucode, access type depends on PC relative mode		
			// We don't care about RZ in this case. Those uinstructions with RZ don't start a bus cycle.
			rFC[1] <= microLatch[ 16] | ( ~microLatch[ 15] & Irdecod.isPcRel);
			rFC[0] <= microLatch[ 15] | ( ~microLatch[ 16] & ~Irdecod.isPcRel);
		end
	end
	
		
	// IPL interface
	reg [2:0] inl;							// Int level latch
	reg updIll;
	reg prevNmi;
	
	wire nmi = (iIpl == 3'b111);
	wire iplStable = (iIpl == rIpl);
	wire iplComp = iIpl > pswI;

	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			intPend <= 1'b0;
			prevNmi <= 1'b0;
		end
		else begin
			if( Clks.enPhi2)
				prevNmi <= nmi;
				
			// Originally async RS-Latch on PHI2, followed by a transparent latch on T2
			// Tricky because they might change simultaneously
			// Syncronous on PHI2 is equivalent as long as the output is read on T3!
			
			// Set on stable & NMI edge or compare
			// Clear on: NMI Iack or (stable & !NMI & !Compare)

			if( Clks.enPhi2) begin
				if( iplStable & ((nmi & ~prevNmi) | iplComp) )
					intPend <= 1'b1;
				else if( ((inl == 3'b111) & Iac) | (iplStable & !nmi & !iplComp) )
					intPend <= 1'b0;
			end			
		end
		
		if( Clks.extReset) begin
			inl <= '1;
			updIll <= 1'b0;
		end
		else if( enT4)
			updIll <= microLatch[0];		// Update on any IRC->IR
		else if( enT1 & updIll)
			inl <= iIpl;					// Timing is correct.
			
		// Spurious interrupt, BERR on Interrupt Ack.
		// Autovector interrupt. VPA on IACK.
		// Timing is tight. Spuria is deasserted just after exception exception is recorded.
		if( enT4) begin
			Spuria <= ~BeiDelay & Iac;
			Avia <= ~Vpai & Iac;
		end
			
	end
		
	assign enErrClk = iAddrErr | iBusErr;
	assign wClk = waitBusCycle | ~BeI | iAddrErr | Err6591;
	
	// E clock and counter, VMA
	reg [3:0] eCntr;
	reg rVma;
	
	assign VMAn = rVma;
	
	// Internal stop just one cycle before E falling edge
	wire xVma = ~rVma & (eCntr == 8);
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp) begin
			E <= 1'b0;
			eCntr <='0;
			rVma <= 1'b1;
		end
		if( Clks.enPhi2) begin
			if( eCntr == 9)
				E <= 1'b0;
			else if( eCntr == 5)
				E <= 1'b1;

			if( eCntr == 9)
				eCntr <= '0;
			else
				eCntr <= eCntr + 1'b1;
		end
		
		if( Clks.enPhi2 & addrOe & ~Vpai & (eCntr == 3))
			rVma <= 1'b0;
		else if( Clks.enPhi1 & eCntr == '0)
			rVma <= 1'b1;
	end
		
	always_ff @( posedge Clks.clk) begin
	
		// This timing is critical to stop the clock phases at the exact point on bus/addr error.
		// Timing should be such that current ublock completes (up to T3 or T4).
		// But T1 for the next ublock shouldn't happen. Next T1 only after resetting ucode and ncode latches.
		
		if( Clks.extReset)
			rAddrErr <= 1'b0;
		else if( Clks.enPhi1) begin
			if( busAddrErr & addrOe)		// Not on T1 ?!
				rAddrErr <= 1'b1;
			else if( ~addrOe)				// Actually async reset!
				rAddrErr <= 1'b0;
		end
		
		if( Clks.extReset)
			iBusErr <= 1'b0;
		else if( Clks.enPhi1) begin
			iBusErr <= ( BerrA & ~BeI & ~Iac & !BusRetry);
		end

		if( Clks.extReset)
			BerrA <= 1'b0;
		else if( Clks.enPhi2) begin
			if( ~BeI & ~Iac & addrOe)
				BerrA <= 1'b1;
			// else if( BeI & addrOe)			// Bad, async reset since addrOe raising edge
			else if( BeI & busStarting)			// So replaced with this that raises one cycle earlier
				BerrA <= 1'b0;
		end

		// Signal reset exception to sequencer.
		// Originally cleared on 1st T2 after permstart. Must keep it until TVN latched.
		if( Clks.extReset)
			excRst <= 1'b1;
		else if( enT2 & Nanod.permStart)
			excRst <= 1'b0;
		
		if( Clks.extReset)
			A0Err <= 1'b1;								// A0 Reset
		else if( enT3)									// Keep set until new urom words are being latched
			A0Err <= 1'b0;
		else if( Clks.enPhi1 & enErrClk & (busAddrErr | BerrA))		// Check bus error timing
			A0Err <= 1'b1;
		
		if( Clks.extReset) begin
			iStop <= 1'b0;
			Err6591 <= 1'b0;
		end
		else if( Clks.enPhi1)
			Err6591 <= enErrClk;
		else if( Clks.enPhi2)
			iStop <= xVma | (Vpai & (iAddrErr | ~rBerr));
	end
	
	// PSW
	logic irdToCcr_t4;
	always_ff @( posedge Clks.clk) begin				
		if( Clks.pwrUp) begin
			Tpend <= 1'b0;
			{pswT, pswS, pswI } <= '0;
			irdToCcr_t4 <= '0;
		end
		
		else if( enT4) begin
			irdToCcr_t4 <= Irdecod.toCcr;
		end
		
		else if( enT3) begin
		
			// UNIQUE IF !!	
			if( Nanod.updTpend)
				Tpend <= pswT;
			else if( Nanod.clrTpend)
				Tpend <= 1'b0;
			
			// UNIQUE IF !!	
			if( Nanod.ftu2Sr & !irdToCcr_t4)
				{pswT, pswS, pswI } <= { ftu[ 15], ftu[13], ftu[10:8]};
			else begin
				if( Nanod.initST) begin
					pswS <= 1'b1;
					pswT <= 1'b0;
				end
				if( Nanod.inl2psw)
					pswI <= inl;
			end
				
		end
	end
		
	// FTU
	reg [4:0] ssw;
	reg [3:0] tvnLatch;
	logic [15:0] tvnMux;
	reg inExcept01;
	
	// Seems CPU has a buglet here.
	// Flagging group 0 exceptions from TVN might not work because some bus cycles happen before TVN is updated.
	// But doesn't matter because a group 0 exception inside another one will halt the CPU anyway and won't save the SSW.
		
	always_ff @( posedge Clks.clk) begin
	
		// Updated at the start of the exception ucode
		if( Nanod.updSsw & enT3) begin
			ssw <= { ~bciWrite, inExcept01, rFC};
		end
	
		// Update TVN on T1 & IR=>IRD
		if( enT1 & Nanod.Ir2Ird) begin
			tvnLatch <= tvn;
			inExcept01 <= (tvn != 1);
		end
			
		if( Clks.pwrUp)
			ftu <= '0;
		else if( enT3) begin
			unique case( 1'b1)
			Nanod.tvn2Ftu:				ftu <= tvnMux;
			
			// 0 on unused bits seem to come from ftuConst PLA previously clearing FBUS
			Nanod.sr2Ftu:				ftu <= {pswT, 1'b0, pswS, 2'b00, pswI, 3'b000, ccr[4:0] };
			
			Nanod.ird2Ftu:				ftu <= Ird;
			Nanod.ssw2Ftu:				ftu[4:0] <= ssw;						// Undoc. Other bits must be preserved from IRD saved above!
			Nanod.pswIToFtu:			ftu <= { 12'hFFF, pswI, 1'b0};			// Interrupt level shifted
			Nanod.const2Ftu:			ftu <= Irdecod.ftuConst;
			Nanod.abl2Pren:				ftu <= Abl;								// From ALU or datareg. Used for SR modify
			default:					ftu <= ftu;
			endcase
		end
	end
	
	always_comb begin
		if( inExcept01) begin
			// Unique IF !!!
			if( tvnLatch == TVN_SPURIOUS)
				tvnMux = {9'b0, 5'd24, 2'b00};
			else if( tvnLatch == TVN_AUTOVEC)
				tvnMux = {9'b0, 2'b11, pswI, 2'b00};				// Set TVN PLA decoder
			else if( tvnLatch == TVN_INTERRUPT)
				tvnMux = {6'b0, Ird[7:0], 2'b00};					// Interrupt vector was read and transferred to IRD
			else
				tvnMux = {10'b0, tvnLatch, 2'b00};
		end
		else
			tvnMux = { 8'h0, Irdecod.macroTvn, 2'b00};
	end
				
endmodule

// Nanorom (plus) decoder for die nanocode
module nDecoder3( input s_clks Clks, input s_irdecod Irdecod, output s_nanod Nanod,
	input enT2, enT4,
	input [UROM_WIDTH-1:0] microLatch,
	input [NANO_WIDTH-1:0] nanoLatch);

localparam NANO_IR2IRD = 67;
localparam NANO_TOIRC = 66;
localparam NANO_ALU_COL = 63;		// ALU operator column order is 63-64-65 !
localparam NANO_ALU_FI = 61;	// ALU finish-init 62-61
localparam NANO_TODBIN = 60;
localparam NANO_ALUE = 57;			// 57-59 shared with DCR control
localparam NANO_DCR = 57;			// 57-59 shared with ALUE control
localparam NANO_DOBCTRL_1 = 56;		// Input to control and permwrite
localparam NANO_LOWBYTE = 55;		// Used by MOVEP
localparam NANO_HIGHBYTE = 54;
localparam NANO_DOBCTRL_0 = 53;		// Input to control and permwrite
localparam NANO_ALU_DCTRL = 51;	// 52-51 databus input mux control
localparam NANO_ALU_ACTRL = 50;	// addrbus input mux control
localparam NANO_DBD2ALUB = 49;
localparam NANO_ABD2ALUB = 48;
localparam NANO_DBIN2DBD = 47;
localparam NANO_DBIN2ABD = 46;
localparam NANO_ALU2ABD = 45;
localparam NANO_ALU2DBD = 44;
localparam NANO_RZ = 43;
localparam NANO_BUSBYTE = 42;		// If *both* this set and instruction is byte sized, then bus cycle is byte sized.
localparam NANO_PCLABL = 41;
localparam NANO_RXL_DBL = 40;		// Switches RXL/RYL on DBL/ABL buses
localparam NANO_PCLDBL = 39;
localparam NANO_ABDHRECHARGE = 38;
localparam NANO_REG2ABL = 37;		// register to ABL
localparam NANO_ABL2REG = 36;		// ABL to register
localparam NANO_ABLABD = 35;
localparam NANO_DBLDBD = 34;
localparam NANO_DBL2REG = 33;		// DBL to register
localparam NANO_REG2DBL = 32;		// register to DBL
localparam NANO_ATLCTRL = 29;		// 31-29
localparam NANO_FTUCONTROL = 25;
localparam NANO_SSP = 24;
localparam NANO_RXH_DBH = 22;		// Switches RXH/RYH on DBH/ABH buses
localparam NANO_AUOUT = 20;			// 21-20
localparam NANO_AUCLKEN = 19;
localparam NANO_AUCTRL = 16;		// 18-16
localparam NANO_DBLDBH = 15;
localparam NANO_ABLABH = 14;
localparam NANO_EXT_ABH = 13;
localparam NANO_EXT_DBH = 12;
localparam NANO_ATHCTRL = 9;		// 11-9
localparam NANO_REG2ABH = 8;		// register to ABH
localparam NANO_ABH2REG = 7;		// ABH to register
localparam NANO_REG2DBH = 6;		// register to DBH
localparam NANO_DBH2REG = 5;		// DBH to register
localparam NANO_AOBCTRL = 3;		// 4-3
localparam NANO_PCH = 0;			// 1-0 PchDbh PchAbh
localparam NANO_NO_SP_ALGN = 0;		// Same bits as above when both set

localparam NANO_FTU_UPDTPEND = 1;		// Also loads FTU constant according to IRD !
localparam NANO_FTU_INIT_ST = 15;		// Set S, clear T (but not TPEND)
localparam NANO_FTU_CLRTPEND = 14;
localparam NANO_FTU_TVN = 13;
localparam NANO_FTU_ABL2PREN = 12;		// ABL => FTU & ABL => PREN. Both transfers enabled, but only one will be used depending on uroutine.
localparam NANO_FTU_SSW = 11;
localparam NANO_FTU_RSTPREN = 10;
localparam NANO_FTU_IRD = 9;
localparam NANO_FTU_2ABL = 8;
localparam NANO_FTU_RDSR = 7;
localparam NANO_FTU_INL = 6;
localparam NANO_FTU_PSWI = 5;		// Read Int Mask into FTU
localparam NANO_FTU_DBL = 4;
localparam NANO_FTU_2SR = 2;
localparam NANO_FTU_CONST = 1;

	reg [3:0] ftuCtrl;	
	
	logic [2:0] athCtrl, atlCtrl;
	assign athCtrl = nanoLatch[ NANO_ATHCTRL+2: NANO_ATHCTRL];
	assign atlCtrl = nanoLatch[ NANO_ATLCTRL+2: NANO_ATLCTRL];
	wire [1:0] aobCtrl = nanoLatch[ NANO_AOBCTRL+1:NANO_AOBCTRL];
	wire [1:0] dobCtrl = {nanoLatch[ NANO_DOBCTRL_1], nanoLatch[NANO_DOBCTRL_0]};
	
	always_ff @( posedge Clks.clk) begin
		if( enT4) begin
			// Reverse order!
			ftuCtrl <= { nanoLatch[ NANO_FTUCONTROL+0], nanoLatch[ NANO_FTUCONTROL+1], nanoLatch[ NANO_FTUCONTROL+2], nanoLatch[ NANO_FTUCONTROL+3]} ;
				
			Nanod.auClkEn <= !nanoLatch[ NANO_AUCLKEN];
			Nanod.auCntrl <= nanoLatch[ NANO_AUCTRL+2 : NANO_AUCTRL+0];
			Nanod.noSpAlign <= (nanoLatch[ NANO_NO_SP_ALGN + 1:NANO_NO_SP_ALGN] == 2'b11);			
			Nanod.extDbh <= nanoLatch[ NANO_EXT_DBH];
			Nanod.extAbh <= nanoLatch[ NANO_EXT_ABH];
			Nanod.todbin <= nanoLatch[ NANO_TODBIN];
			Nanod.toIrc <=  nanoLatch[ NANO_TOIRC];
			
			// ablAbd is disabled on byte transfers (adbhCharge plus irdIsByte). Not sure the combination makes much sense.
			// It happens in a few cases but I don't see anything enabled on abL (or abH) section anyway.
			
			Nanod.ablAbd <= nanoLatch[ NANO_ABLABD];
			Nanod.ablAbh <= nanoLatch[ NANO_ABLABH];
			Nanod.dblDbd <= nanoLatch[ NANO_DBLDBD];
			Nanod.dblDbh <= nanoLatch[ NANO_DBLDBH];
			
			Nanod.dbl2Atl <= (atlCtrl == 3'b010);
			Nanod.atl2Dbl <= (atlCtrl == 3'b011);
			Nanod.abl2Atl <= (atlCtrl == 3'b100);
			Nanod.atl2Abl <= (atlCtrl == 3'b101);

			Nanod.aob2Ab <= (athCtrl == 3'b101);		// Used on BSER1 only
			
			Nanod.abh2Ath <= (athCtrl == 3'b001) | (athCtrl == 3'b101);
			Nanod.dbh2Ath <= (athCtrl == 3'b100);
			Nanod.ath2Dbh <= (athCtrl == 3'b110);
			Nanod.ath2Abh <= (athCtrl == 3'b011);			

			Nanod.alu2Dbd <= nanoLatch[ NANO_ALU2DBD];
			Nanod.alu2Abd <= nanoLatch[ NANO_ALU2ABD];
			
			Nanod.abd2Dcr <= (nanoLatch[ NANO_DCR+1:NANO_DCR] == 2'b11);
			Nanod.dcr2Dbd <= (nanoLatch[ NANO_DCR+2:NANO_DCR+1] == 2'b11);
			Nanod.dbd2Alue <= (nanoLatch[ NANO_ALUE+2:NANO_ALUE+1] == 2'b10);
			Nanod.alue2Dbd <= (nanoLatch[ NANO_ALUE+1:NANO_ALUE] == 2'b01);

			Nanod.dbd2Alub <= nanoLatch[ NANO_DBD2ALUB];
			Nanod.abd2Alub <= nanoLatch[ NANO_ABD2ALUB];			
			
			// Originally not latched. We better should because we transfer one cycle later, T3 instead of T1.
			Nanod.dobCtrl <= dobCtrl;
			// Nanod.adb2Dob <= (dobCtrl == 2'b10);			Nanod.dbd2Dob <= (dobCtrl == 2'b01);			Nanod.alu2Dob <= (dobCtrl == 2'b11);
							
		end
	end
	
	// Update SSW at the start of Bus/Addr error ucode
	assign Nanod.updSsw = Nanod.aob2Ab;

	assign Nanod.updTpend = (ftuCtrl == NANO_FTU_UPDTPEND);
	assign Nanod.clrTpend = (ftuCtrl == NANO_FTU_CLRTPEND);
	assign Nanod.tvn2Ftu = (ftuCtrl == NANO_FTU_TVN);
	assign Nanod.const2Ftu = (ftuCtrl == NANO_FTU_CONST);
	assign Nanod.ftu2Dbl = (ftuCtrl == NANO_FTU_DBL) | ( ftuCtrl == NANO_FTU_INL);	
	assign Nanod.ftu2Abl = (ftuCtrl == NANO_FTU_2ABL);	
	assign Nanod.inl2psw = (ftuCtrl == NANO_FTU_INL);
	assign Nanod.pswIToFtu = (ftuCtrl == NANO_FTU_PSWI);
	assign Nanod.ftu2Sr = (ftuCtrl == NANO_FTU_2SR);
	assign Nanod.sr2Ftu = (ftuCtrl == NANO_FTU_RDSR);
	assign Nanod.ird2Ftu = (ftuCtrl == NANO_FTU_IRD);		// Used on bus/addr error
	assign Nanod.ssw2Ftu = (ftuCtrl == NANO_FTU_SSW);
	assign Nanod.initST = (ftuCtrl == NANO_FTU_INL) | (ftuCtrl == NANO_FTU_CLRTPEND) | (ftuCtrl == NANO_FTU_INIT_ST);
	assign Nanod.abl2Pren = (ftuCtrl == NANO_FTU_ABL2PREN);
	assign Nanod.updPren = (ftuCtrl == NANO_FTU_RSTPREN);
	
	assign Nanod.Ir2Ird = nanoLatch[ NANO_IR2IRD];

	// ALU control better latched later after combining with IRD decoding
		
	assign Nanod.aluDctrl = nanoLatch[ NANO_ALU_DCTRL+1 : NANO_ALU_DCTRL];
	assign Nanod.aluActrl = nanoLatch[ NANO_ALU_ACTRL];
	assign Nanod.aluColumn = { nanoLatch[ NANO_ALU_COL], nanoLatch[ NANO_ALU_COL+1], nanoLatch[ NANO_ALU_COL+2]};
	wire [1:0] aluFinInit = nanoLatch[ NANO_ALU_FI+1:NANO_ALU_FI];
	assign Nanod.aluFinish = (aluFinInit == 2'b10);
	assign Nanod.aluInit = (aluFinInit == 2'b01);

	// FTU 2 CCR encoded as both ALU Init and ALU Finish set.
	// In theory this encoding allows writes to CCR without writing to SR
	// But FTU 2 CCR and to SR are both set together at nanorom.
	assign Nanod.ftu2Ccr = ( aluFinInit == 2'b11);

	assign Nanod.abdIsByte = nanoLatch[ NANO_ABDHRECHARGE];
	
	// Not being latched on T4 creates non unique case warning!
	assign Nanod.au2Db = (nanoLatch[ NANO_AUOUT + 1: NANO_AUOUT] == 2'b01);
	assign Nanod.au2Ab = (nanoLatch[ NANO_AUOUT + 1: NANO_AUOUT] == 2'b10);
	assign Nanod.au2Pc = (nanoLatch[ NANO_AUOUT + 1: NANO_AUOUT] == 2'b11);
	
	assign Nanod.db2Aob = (aobCtrl == 2'b10);
	assign Nanod.ab2Aob = (aobCtrl == 2'b01);
	assign Nanod.au2Aob = (aobCtrl == 2'b11);
	
	assign Nanod.dbin2Abd = nanoLatch[ NANO_DBIN2ABD];
	assign Nanod.dbin2Dbd = nanoLatch[ NANO_DBIN2DBD];
	
	assign Nanod.permStart = (| aobCtrl);
	assign Nanod.isWrite  = ( | dobCtrl);
	assign Nanod.waitBusFinish = nanoLatch[ NANO_TOIRC] | nanoLatch[ NANO_TODBIN] | Nanod.isWrite;
	assign Nanod.busByte = nanoLatch[ NANO_BUSBYTE];
	
	assign Nanod.noLowByte = nanoLatch[ NANO_LOWBYTE];
	assign Nanod.noHighByte = nanoLatch[ NANO_HIGHBYTE];	
			
	// Not registered. Register at T4 after combining
	// Might be better to remove all those and combine here instead of at execution unit !!
	assign Nanod.abl2reg = nanoLatch[ NANO_ABL2REG];
	assign Nanod.abh2reg = nanoLatch[ NANO_ABH2REG];
	assign Nanod.dbl2reg = nanoLatch[ NANO_DBL2REG];
	assign Nanod.dbh2reg = nanoLatch[ NANO_DBH2REG];
	assign Nanod.reg2dbl = nanoLatch[ NANO_REG2DBL];
	assign Nanod.reg2dbh = nanoLatch[ NANO_REG2DBH];
	assign Nanod.reg2abl = nanoLatch[ NANO_REG2ABL];
	assign Nanod.reg2abh = nanoLatch[ NANO_REG2ABH];
	
	assign Nanod.ssp = nanoLatch[ NANO_SSP];
	
	assign Nanod.rz = nanoLatch[ NANO_RZ];
	
	// Actually DTL can't happen on PC relative mode. See IR decoder.
	
	wire dtldbd = 1'b0;
	wire dthdbh = 1'b0;
	wire dtlabd = 1'b0;
	wire dthabh = 1'b0;
	
	wire dblSpecial = Nanod.pcldbl | dtldbd;
	wire dbhSpecial = Nanod.pchdbh | dthdbh;
	wire ablSpecial = Nanod.pclabl | dtlabd;
	wire abhSpecial = Nanod.pchabh | dthabh;
			
	//
	// Combine with IRD decoding
	// Careful that IRD is updated only on T1! All output depending on IRD must be latched on T4!
	//
	
	// PC used instead of RY on PC relative instuctions
	
	assign Nanod.rxlDbl = nanoLatch[ NANO_RXL_DBL];
	wire isPcRel = Irdecod.isPcRel & !Nanod.rz;
	wire pcRelDbl = isPcRel & !nanoLatch[ NANO_RXL_DBL];
	wire pcRelDbh = isPcRel & !nanoLatch[ NANO_RXH_DBH];
	wire pcRelAbl = isPcRel & nanoLatch[ NANO_RXL_DBL];
	wire pcRelAbh = isPcRel & nanoLatch[ NANO_RXH_DBH];
	
	assign Nanod.pcldbl = nanoLatch[ NANO_PCLDBL] | pcRelDbl;
	assign Nanod.pchdbh = (nanoLatch[ NANO_PCH+1:NANO_PCH] == 2'b01) | pcRelDbh;
	
	assign Nanod.pclabl = nanoLatch[ NANO_PCLABL] | pcRelAbl;
	assign Nanod.pchabh = (nanoLatch[ NANO_PCH+1:NANO_PCH] == 2'b10) | pcRelAbh;

	// Might be better not to register these signals to allow latching RX/RY mux earlier!
	// But then must latch Irdecod.isPcRel on T3!

	always_ff @( posedge Clks.clk) begin
		if( enT4) begin
			Nanod.rxl2db <= Nanod.reg2dbl & !dblSpecial & nanoLatch[ NANO_RXL_DBL];
			Nanod.rxl2ab <= Nanod.reg2abl & !ablSpecial & !nanoLatch[ NANO_RXL_DBL];
			
			Nanod.dbl2rxl <= Nanod.dbl2reg & !dblSpecial & nanoLatch[ NANO_RXL_DBL];	
			Nanod.abl2rxl <= Nanod.abl2reg & !ablSpecial & !nanoLatch[ NANO_RXL_DBL];	

			Nanod.rxh2dbh <= Nanod.reg2dbh & !dbhSpecial & nanoLatch[ NANO_RXH_DBH];			
			Nanod.rxh2abh <= Nanod.reg2abh & !abhSpecial & !nanoLatch[ NANO_RXH_DBH];			
				
			Nanod.dbh2rxh <= Nanod.dbh2reg & !dbhSpecial & nanoLatch[ NANO_RXH_DBH];
			Nanod.abh2rxh <= Nanod.abh2reg & !abhSpecial & !nanoLatch[ NANO_RXH_DBH];	

			Nanod.dbh2ryh <= Nanod.dbh2reg & !dbhSpecial & !nanoLatch[ NANO_RXH_DBH];
			Nanod.abh2ryh <= Nanod.abh2reg & !abhSpecial & nanoLatch[ NANO_RXH_DBH];	

			Nanod.dbl2ryl <= Nanod.dbl2reg & !dblSpecial & !nanoLatch[ NANO_RXL_DBL];	
			Nanod.abl2ryl <= Nanod.abl2reg & !ablSpecial & nanoLatch[ NANO_RXL_DBL];	

			Nanod.ryl2db <= Nanod.reg2dbl & !dblSpecial & !nanoLatch[ NANO_RXL_DBL];
			Nanod.ryl2ab <= Nanod.reg2abl & !ablSpecial & nanoLatch[ NANO_RXL_DBL];

			Nanod.ryh2dbh <= Nanod.reg2dbh & !dbhSpecial & !nanoLatch[ NANO_RXH_DBH];			
			Nanod.ryh2abh <= Nanod.reg2abh & !abhSpecial & nanoLatch[ NANO_RXH_DBH];					
		end
		
		// Originally isTas only delayed on T2 (and seems only a late mask rev fix)
		// Better latch the combination on T4
		if( enT4)
			Nanod.isRmc <= Irdecod.isTas & nanoLatch[ NANO_BUSBYTE];
	end
			
	
endmodule

//
// IRD execution decoder. Complements nano code decoder
//
// IRD updated on T1, while ncode still executing. To avoid using the next IRD,
// decoded signals must be registered on T3, or T4 before using them.
//
module irdDecode( input [15:0] ird,
			output s_irdecod Irdecod);

	wire [3:0] line = ird[15:12];
	logic [15:0] lineOnehot;

	// This can be registered and pipelined from the IR decoder !
	onehotEncoder4 irdLines( line, lineOnehot);
	
	wire isRegShift = (lineOnehot['he]) & (ird[7:6] != 2'b11);
	wire isDynShift = isRegShift & ird[5];
					
	assign Irdecod.isPcRel = (& ird[ 5:3]) & ~isDynShift & !ird[2] & ird[1];		
	assign Irdecod.isTas = lineOnehot[4] & (ird[11:6] == 6'b101011);
	
	assign Irdecod.rx = ird[11:9];
	assign Irdecod.ry = ird[ 2:0];

	wire isPreDecr = (ird[ 5:3] == 3'b100);
	wire eaAreg = (ird[5:3] == 3'b001);
		
	// rx is A or D
	// movem
	always_comb begin
		unique case( 1'b1)
		lineOnehot[1],
		lineOnehot[2],
		lineOnehot[3]:
					// MOVE: RX always Areg except if dest mode is Dn 000
					Irdecod.rxIsAreg = (| ird[8:6]);

		lineOnehot[4]:		Irdecod.rxIsAreg = (& ird[8:6]);		// not CHK (LEA)

		lineOnehot['h8]:	Irdecod.rxIsAreg = eaAreg & ird[8] & ~ird[7];	// SBCD
		lineOnehot['hc]:	Irdecod.rxIsAreg = eaAreg & ird[8] & ~ird[7];	// ABCD/EXG An,An				
		
		lineOnehot['h9],
		lineOnehot['hb],
		lineOnehot['hd]:	Irdecod.rxIsAreg =
							(ird[7] & ird[6]) |								// SUBA/CMPA/ADDA
							(eaAreg & ird[8] & (ird[7:6] != 2'b11));		// SUBX/CMPM/ADDX		
		default:
				Irdecod.rxIsAreg = Irdecod.implicitSp;
		endcase
	end	

	// RX is movem
	always_comb begin
		Irdecod.rxIsMovem = lineOnehot[4] & ~ird[8] & ~Irdecod.implicitSp;
	end
	assign Irdecod.movemPreDecr = Irdecod.rxIsMovem & isPreDecr;
	
	// RX is DT.
	// but SSP explicit or pc explicit has higher priority!
	// addq/subq (scc & dbcc also, but don't use rx)
	// Immediate including static bit
	assign Irdecod.rxIsDt = lineOnehot[5] | (lineOnehot[0] & ~ird[8]);
	
	// RX is USP
	assign Irdecod.rxIsUsp = lineOnehot[4] & (ird[ 11:4] == 8'he6);
	
	// RY is DT
	// rz or PC explicit has higher priority
	
	wire eaImmOrAbs = (ird[5:3] == 3'b111) & ~ird[1];
	assign Irdecod.ryIsDt = eaImmOrAbs & ~isRegShift;
		
	// RY is Address register
	always_comb begin
		logic eaIsAreg;
		
		// On most cases RY is Areg expect if mode is 000 (DATA REG) or 111 (IMM, ABS,PC REL)
		eaIsAreg = (ird[5:3] != 3'b000) & (ird[5:3] != 3'b111);
		
		unique case( 1'b1)
				// MOVE: RY always Areg expect if mode is 000 (DATA REG) or 111 (IMM, ABS,PC REL)
				// Most lines, including misc line 4, also.
		default:		Irdecod.ryIsAreg = eaIsAreg;

		lineOnehot[5]:	// DBcc is an exception
						Irdecod.ryIsAreg = eaIsAreg & (ird[7:3] != 5'b11001);

		lineOnehot[6],
		lineOnehot[7]:	Irdecod.ryIsAreg = 1'b0;

		lineOnehot['he]:
						Irdecod.ryIsAreg = ~isRegShift;
		endcase
	end	

	// Byte sized instruction
		
	// Original implementation sets this for some instructions that aren't really byte size
	// but doesn't matter because they don't have a byte transfer enabled at nanocode, such as MOVEQ
		
	wire xIsScc = (ird[7:6] == 2'b11) & (ird[5:3] != 3'b001); 
	wire xStaticMem = (ird[11:8] == 4'b1000) & (ird[5:4] == 2'b00);		// Static bit to mem
	always_comb begin
		unique case( 1'b1)
		lineOnehot[0]:
				Irdecod.isByte = 
				( ird[8] & (ird[5:4] != 2'b00)					) |	// Dynamic bit to mem
				( (ird[11:8] == 4'b1000) & (ird[5:4] != 2'b00)	) |	// Static bit to mem
				( (ird[8:7] == 2'b10) & (ird[5:3] == 3'b001)	) |	// Movep from mem only! For byte mux
				( (ird[8:6] == 3'b000) & !xStaticMem );				// Immediate byte
								
		lineOnehot[1]:			Irdecod.isByte = 1'b1;		// MOVE.B
	
		
		lineOnehot[4]:			Irdecod.isByte = (ird[7:6] == 2'b00) | Irdecod.isTas;		
		lineOnehot[5]:			Irdecod.isByte = (ird[7:6] == 2'b00) | xIsScc;
		
		lineOnehot[8],
		lineOnehot[9],
		lineOnehot['hb],
		lineOnehot['hc],
		lineOnehot['hd],
		lineOnehot['he]:		Irdecod.isByte = (ird[7:6] == 2'b00);
		
		default:				Irdecod.isByte = 1'b0;
		endcase
	end	
	
	// Need it for special byte size. Bus is byte, but whole register word is modified.
	assign Irdecod.isMovep = lineOnehot[0] & ird[8] & eaAreg;
	
	
	// rxIsSP implicit use of RX for actual SP transfer
	//
	// This logic is simple and will include some instructions that don't actually reference SP.
	// But doesn't matter as long as they don't perform any RX transfer.
	
	always_comb begin
		unique case( 1'b1)
		lineOnehot[6]:		Irdecod.implicitSp = (ird[11:8] == 4'b0001);		// BSR
		lineOnehot[4]:
			// Misc like RTS, JSR, etc
			Irdecod.implicitSp = (ird[11:8] == 4'b1110) | (ird[11:6] == 6'b1000_01);
		default:			Irdecod.implicitSp = 1'b0;
		endcase
	end
	
	// Modify CCR (and not SR)
	// Probably overkill !! Only needs to distinguish SR vs CCR
	// RTR, MOVE to CCR, xxxI to CCR
	assign Irdecod.toCcr =	( lineOnehot[4] & ((ird[11:0] == 12'he77) | (ird[11:6] == 6'b010011)) ) |
							( lineOnehot[0] & (ird[8:6] == 3'b000));
	
	// FTU constants
	// This should not be latched on T3/T4. Latch on T2 or not at all. FTU needs it on next T3.
	// Note: Reset instruction gets constant from ALU not from FTU!
	logic [15:0] ftuConst;
	wire [3:0] zero28 = (ird[11:9] == 0) ? 4'h8 : { 1'b0, ird[11:9]};		// xltate 0,1-7 into 8,1-7

	always_comb begin
		unique case( 1'b1)
		lineOnehot[6],														// Bcc short
		lineOnehot[7]:		ftuConst = { { 8{ ird[ 7]}}, ird[ 7:0] };		// MOVEQ
		
		lineOnehot['h5],													// addq/subq/static shift double check this
		lineOnehot['he]:	ftuConst = { 12'b0, zero28};
		
		// MULU/MULS DIVU/DIVS
		lineOnehot['h8],
		lineOnehot['hc]:	ftuConst = 16'h0f;

		lineOnehot[4]:		ftuConst = 16'h80;								// TAS

		default:			ftuConst = '0;
		endcase	
	end	
	assign Irdecod.ftuConst = ftuConst;
	
	//
	// TRAP Vector # for group 2 exceptions
	//
	
	always_comb begin
		if( lineOnehot[4]) begin
			case ( ird[6:5])
			2'b00,2'b01:	Irdecod.macroTvn = 6;					// CHK
			2'b11:			Irdecod.macroTvn = 7;					// TRAPV
			2'b10:			Irdecod.macroTvn = {2'b10, ird[3:0]};	// TRAP
			endcase
		end
		else
							Irdecod.macroTvn = 5;					// Division by zero
	end
	
	
	wire eaAdir = (ird[ 5:3] == 3'b001);
	wire size11 = ird[7] & ird[6];
	
	// Opcodes variants that don't affect flags
	// ADDA/SUBA ADDQ/SUBQ MOVEA

	assign Irdecod.inhibitCcr =
		( (lineOnehot[9] | lineOnehot['hd]) & size11) |				// ADDA/SUBA
		( lineOnehot[5] & eaAdir) |									// ADDQ/SUBQ to An (originally checks for line[4] as well !?)
		( (lineOnehot[2] | lineOnehot[3]) & ird[8:6] == 3'b001);	// MOVEA
		
endmodule

/*
 Execution unit

 Executes register transfers set by the microcode. Originally through a set of bidirectional buses.
 Most sources are available at T3, but DBIN only at T4! CCR also might be updated at T4, but it is not connected to these buses.
 We mux at T1 and T2, then transfer to the destination at T3. The exception is AOB that need to be updated earlier.

*/

module excUnit( input s_clks Clks,
	input enT1, enT2, enT3, enT4,
	input s_nanod Nanod, input s_irdecod Irdecod,
	input [15:0] Ird,			// ALU row (and others) decoder needs it	
	input pswS,
	input [15:0] ftu,
	input [15:0] iEdb,
	
	output logic [7:0] ccr,
	output [15:0] alue,
	
	output prenEmpty, au05z,
	output logic dcr4, ze,
	output logic aob0,
	output [15:0] AblOut,
	output logic [15:0] Irc,
	output logic [15:0] oEdb,
	output logic [23:1] eab);

localparam REG_USP = 15;
localparam REG_SSP = 16;
localparam REG_DT = 17;

	// Register file
	reg [15:0] regs68L[ 18];
	reg [15:0] regs68H[ 18];

// synthesis translate off
	/*
		It is bad practice to initialize simulation registers that the hardware doesn't.
		There is risk that simulation would be different than the real hardware. But in this case is the other way around.
		Some ROM uses something like sub.l An,An at powerup which clears the register
		Simulator power ups the registers with 'X, as they are really undetermined at the real hardware.
		But the simulator doesn't realize (it can't) that the same value is substracting from itself,
		and that the result should be zero even when it's 'X - 'X.
	*/
	
	initial begin
		for( int i = 0; i < 18; i++) begin
			regs68L[i] <= '0;
			regs68H[i] <= '0;
		end
	end
	
	// For simulation display only
	wire [31:0] SSP = { regs68H[REG_SSP], regs68L[REG_SSP]};
	
// synthesis translate on
	

	wire [15:0] aluOut;
	wire [15:0] dbin;
	logic [15:0] dcrOutput;

	reg [15:0] PcL, PcH;

	reg [31:0] auReg, aob;

	reg [15:0] Ath, Atl;

	// Bus execution
	reg [15:0] Dbl, Dbh;
	reg [15:0] Abh, Abl;
	reg [15:0] Abd, Dbd;
	
	assign AblOut = Abl;
	assign au05z = (~| auReg[5:0]);
	
	logic [15:0] dblMux, dbhMux;
	logic [15:0] abhMux, ablMux;
	logic [15:0] abdMux, dbdMux;
	
	logic abdIsByte;
		
	logic Pcl2Dbl, Pch2Dbh;
	logic Pcl2Abl, Pch2Abh;
	
	
	// RX RY muxes	
	// RX and RY actual registers
	logic [4:0] actualRx, actualRy;
	logic [3:0] movemRx;
	logic byteNotSpAlign;			// Byte instruction and no sp word align
	
	// IRD decoded signals must be latched. See comments on decoder
	// But nanostore decoding can't be latched before T4.
	//
	// If we need this earlier we can register IRD decode on T3 and use nano async

	logic [4:0] rxMux, ryMux;
	logic [3:0] rxReg, ryReg;
	logic rxIsSp, ryIsSp;
	logic rxIsAreg, ryIsAreg;
	
	always_comb begin
	
		// Unique IF !!
		if( Nanod.ssp) begin
			rxMux = REG_SSP;
			rxIsSp = 1'b1;
			rxReg = 1'bX;
		end
		else if( Irdecod.rxIsUsp) begin
			rxMux = REG_USP;
			rxIsSp = 1'b1;
			rxReg = 1'bX;
		end
		else if( Irdecod.rxIsDt & !Irdecod.implicitSp) begin
			rxMux = REG_DT;
			rxIsSp = 1'b0;
			rxReg = 1'bX;
		end
		else begin
			if( Irdecod.implicitSp)
				rxReg = 15;
			else if( Irdecod.rxIsMovem)
				rxReg = movemRx;
			else
				rxReg = { Irdecod.rxIsAreg, Irdecod.rx};
				
			if( (& rxReg)) begin
				rxMux = pswS ? REG_SSP : 15;
				rxIsSp = 1'b1;
			end
			else begin
				rxMux = { 1'b0, rxReg};
				rxIsSp = 1'b0;
			end
		end

		// RZ has higher priority!		
		if( Irdecod.ryIsDt & !Nanod.rz) begin
			ryMux = REG_DT;
			ryIsSp = 1'b0;
			ryReg = 'X;
		end
		else begin
			ryReg = Nanod.rz ? Irc[15:12] : {Irdecod.ryIsAreg, Irdecod.ry};
			ryIsSp = (& ryReg);
			if( ryIsSp & pswS)			// No implicit SP on RY
				ryMux = REG_SSP;
			else
				ryMux = { 1'b0, ryReg};
		end
					
	end	
	
	always_ff @( posedge Clks.clk) begin
		if( enT4) begin
			byteNotSpAlign <= Irdecod.isByte & ~(Nanod.rxlDbl ? rxIsSp : ryIsSp);
				
			actualRx <= rxMux;
			actualRy <= ryMux;
			
			rxIsAreg <= rxIsSp | rxMux[3];
			ryIsAreg <= ryIsSp | ryMux[3];			
		end
		
		if( enT4)
			abdIsByte <= Nanod.abdIsByte & Irdecod.isByte;
	end
			
	// Set RX/RY low word to which bus segment is connected.
		
	wire ryl2Abl = Nanod.ryl2ab & (ryIsAreg | Nanod.ablAbd);
	wire ryl2Abd = Nanod.ryl2ab & (~ryIsAreg | Nanod.ablAbd);
	wire ryl2Dbl = Nanod.ryl2db & (ryIsAreg | Nanod.dblDbd);
	wire ryl2Dbd = Nanod.ryl2db & (~ryIsAreg | Nanod.dblDbd);

	wire rxl2Abl = Nanod.rxl2ab & (rxIsAreg | Nanod.ablAbd);
	wire rxl2Abd = Nanod.rxl2ab & (~rxIsAreg | Nanod.ablAbd);
	wire rxl2Dbl = Nanod.rxl2db & (rxIsAreg | Nanod.dblDbd);
	wire rxl2Dbd = Nanod.rxl2db & (~rxIsAreg | Nanod.dblDbd);
	
	// Buses. Main mux
	
	logic abhIdle, ablIdle, abdIdle;
	logic dbhIdle, dblIdle, dbdIdle;
	
	always_comb begin
		{abhIdle, ablIdle, abdIdle} = '0;
		{dbhIdle, dblIdle, dbdIdle} = '0;

		unique case( 1'b1)
		ryl2Dbd:				dbdMux = regs68L[ actualRy];
		rxl2Dbd:				dbdMux = regs68L[ actualRx];
		Nanod.alue2Dbd:			dbdMux = alue;
		Nanod.dbin2Dbd:			dbdMux = dbin;
		Nanod.alu2Dbd:			dbdMux = aluOut;
		Nanod.dcr2Dbd:			dbdMux = dcrOutput;
		default: begin			dbdMux = 'X;	dbdIdle = 1'b1;				end
		endcase
	
		unique case( 1'b1)
		rxl2Dbl:				dblMux = regs68L[ actualRx];
		ryl2Dbl:				dblMux = regs68L[ actualRy];
		Nanod.ftu2Dbl:			dblMux = ftu;
		Nanod.au2Db:			dblMux = auReg[15:0];
		Nanod.atl2Dbl:			dblMux = Atl;
		Pcl2Dbl:				dblMux = PcL;
		default: begin			dblMux = 'X;	dblIdle = 1'b1;				end
		endcase
			
		unique case( 1'b1)
		Nanod.rxh2dbh:			dbhMux = regs68H[ actualRx];
		Nanod.ryh2dbh:			dbhMux = regs68H[ actualRy];
		Nanod.au2Db:			dbhMux = auReg[31:16];
		Nanod.ath2Dbh:			dbhMux = Ath;
		Pch2Dbh:				dbhMux = PcH;
		default: begin			dbhMux = 'X;	dbhIdle = 1'b1;				end
		endcase

		unique case( 1'b1)
		ryl2Abd:				abdMux = regs68L[ actualRy];
		rxl2Abd:				abdMux = regs68L[ actualRx];
		Nanod.dbin2Abd:			abdMux = dbin;
		Nanod.alu2Abd:			abdMux = aluOut;
		default: begin			abdMux = 'X;	abdIdle = 1'b1;				end
		endcase

		unique case( 1'b1)
		Pcl2Abl:				ablMux = PcL;
		rxl2Abl:				ablMux = regs68L[ actualRx];
		ryl2Abl:				ablMux = regs68L[ actualRy];
		Nanod.ftu2Abl:			ablMux = ftu;
		Nanod.au2Ab:			ablMux = auReg[15:0];
		Nanod.aob2Ab:			ablMux = aob[15:0];
		Nanod.atl2Abl:			ablMux = Atl;
		default: begin			ablMux = 'X;	ablIdle = 1'b1;				end
		endcase
			
		unique case( 1'b1)		
		Pch2Abh:				abhMux = PcH;
		Nanod.rxh2abh:			abhMux = regs68H[ actualRx];
		Nanod.ryh2abh:			abhMux = regs68H[ actualRy];
		Nanod.au2Ab:			abhMux = auReg[31:16];
		Nanod.aob2Ab:			abhMux = aob[31:16];
		Nanod.ath2Abh:			abhMux = Ath;
		default: begin			abhMux = 'X;	abhIdle = 1'b1;				end
		endcase
			
	end
	
	// Source starts driving the bus on T1. Bus holds data until end of T3. Destination latches at T3.

	// These registers store the first level mux, without bus interconnections.
	// Even when this uses almost to 100 registers, it saves a lot of comb muxing and it is much faster.
	reg [15:0] preAbh, preAbl, preAbd;
	reg [15:0] preDbh, preDbl, preDbd;
	
	always_ff @( posedge Clks.clk) begin

		// Register first level mux at T1		
		if( enT1) begin
			{preAbh, preAbl, preAbd} <= { abhMux, ablMux, abdMux};
			{preDbh, preDbl, preDbd} <= { dbhMux, dblMux, dbdMux};			
		end
		
		// Process bus interconnection at T2. Many combinations only used on DIV
		// We use a simple method. If a specific bus segment is not driven we know that it should get data from a neighbour segment.
		// In some cases this is not true and the segment is really idle without any destination. But then it doesn't matter.
		
		if( enT2) begin
			if( Nanod.extAbh)
				Abh <= { 16{ ablIdle ? preAbd[ 15] : preAbl[ 15] }};
			else if( abhIdle)
				Abh <= ablIdle ? preAbd : preAbl;
			else
				Abh <= preAbh;

			if( ~ablIdle)
				Abl <= preAbl;
			else
				Abl <= Nanod.ablAbh ? preAbh : preAbd;

			Abd <= ~abdIdle ? preAbd : ablIdle ? preAbh : preAbl;

			if( Nanod.extDbh)
				Dbh <= { 16{ dblIdle ? preDbd[ 15] : preDbl[ 15] }};
			else if( dbhIdle)
				Dbh <= dblIdle ? preDbd : preDbl;
			else
				Dbh <= preDbh;

			if( ~dblIdle)
				Dbl <= preDbl;
			else
				Dbl <= Nanod.dblDbh ? preDbh : preDbd;

			Dbd <= ~dbdIdle ? preDbd: dblIdle ? preDbh : preDbl;
			
			/*
			Dbl <= dblMux;			Dbh <= dbhMux;
			Abd <= abdMux;			Dbd <= dbdMux;
			Abh <= abhMux;			Abl <= ablMux; */
		end
	end

	// AOB
	//
	// Originally change on T1. We do on T2, only then the output is enabled anyway.
	//
	// AOB[0] is used for address error. But even when raises on T1, seems not actually used until T2 or possibly T3.
	// It is used on T1 when deasserted at the BSER exception ucode. Probably deassertion timing is not critical. 
	// But in that case (at BSER), AOB is loaded from AU, so we can safely transfer on T1.

	// We need to take directly from first level muxes that are updated and T1
			
	wire au2Aob = Nanod.au2Aob | (Nanod.au2Db & Nanod.db2Aob);
	
	always_ff @( posedge Clks.clk) begin
		// UNIQUE IF !
		
		if( enT1 & au2Aob)		// From AU we do can on T1
			aob <= auReg;
		else if( enT2) begin
			if( Nanod.db2Aob)
				aob <= { preDbh, ~dblIdle ? preDbl : preDbd};
			else if( Nanod.ab2Aob)
				aob <= { preAbh, ~ablIdle ? preAbl : preAbd};
		end
	end

	assign eab = aob[23:1];
	assign aob0 = aob[0];
				
	// AU
	logic [31:0] auInpMux;

	// `ifdef ALW_COMB_BUG
	// Old Modelsim bug. Doesn't update ouput always. Need excplicit sensitivity list !?
	// always @( Nanod.auCntrl) begin
	
	always_comb begin
		unique case( Nanod.auCntrl)
		3'b000:		auInpMux = 0;
		3'b001:		auInpMux = byteNotSpAlign | Nanod.noSpAlign ? 1 : 2;		// +1/+2
		3'b010:		auInpMux = -4;
		3'b011:		auInpMux = { Abh, Abl};
		3'b100:		auInpMux = 2;
		3'b101:		auInpMux = 4;
		3'b110:		auInpMux = -2;
		3'b111:		auInpMux = byteNotSpAlign | Nanod.noSpAlign ? -1 : -2;	// -1/-2
		default:	auInpMux = 'X;
		endcase
	end

	// Simulation problem
	// Sometimes (like in MULM1) DBH is not set. AU is used in these cases just as a 6 bits counter testing if bits 5-0 are zero.
	// But when adding something like 32'hXXXX0000, the simulator (incorrectly) will set *all the 32 bits* of the result as X.

// synthesis translate_off 

	wire [16:0] aulow = Dbl + auInpMux[15:0];
	wire [31:0] auResult = {Dbh + auInpMux[31:16] + aulow[16], aulow[15:0]};
// synthesis translate_on

	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp)
			auReg <= '0;
		else if( enT3 & Nanod.auClkEn)
			begin
				auReg <= { Dbh, Dbl } + auInpMux;
// synthesis translate_off
				auReg <= auResult;
// synthesis translate_on
			end
	end
	
	
	// Main A/D registers
	
	always_ff @( posedge Clks.clk) begin
		if( enT3) begin
			if( Nanod.dbl2rxl | Nanod.abl2rxl) begin
				if( ~rxIsAreg) begin
					if( Nanod.dbl2rxl)			regs68L[ actualRx] <= Dbd;
					else if( abdIsByte)			regs68L[ actualRx][7:0] <= Abd[7:0];
					else						regs68L[ actualRx] <= Abd;
				end
				else
					regs68L[ actualRx] <= Nanod.dbl2rxl ? Dbl : Abl;
			end
				
			if( Nanod.dbl2ryl | Nanod.abl2ryl) begin
				if( ~ryIsAreg) begin
					if( Nanod.dbl2ryl)			regs68L[ actualRy] <= Dbd;
					else if( abdIsByte)			regs68L[ actualRy][7:0] <= Abd[7:0];
					else						regs68L[ actualRy] <= Abd;				
				end
				else
					regs68L[ actualRy] <= Nanod.dbl2ryl ? Dbl : Abl;
			end
			
			// High registers are easier. Both A & D on the same buses, and not byte ops.
			if( Nanod.dbh2rxh | Nanod.abh2rxh)
				regs68H[ actualRx] <= Nanod.dbh2rxh ? Dbh : Abh;
			if( Nanod.dbh2ryh | Nanod.abh2ryh)
				regs68H[ actualRy] <= Nanod.dbh2ryh ? Dbh : Abh;
				
		end	
	end
		
	// PC & AT
	reg dbl2Pcl, dbh2Pch, abh2Pch, abl2Pcl;
		
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			{ dbl2Pcl, dbh2Pch, abh2Pch, abl2Pcl } <= '0;
			
			Pcl2Dbl <= 1'b0;
			Pch2Dbh <= 1'b0;
			Pcl2Abl <= 1'b0;
			Pch2Abh <= 1'b0;
		end
		else if( enT4) begin				// Must latch on T4 !
			dbl2Pcl <= Nanod.dbl2reg & Nanod.pcldbl;
			dbh2Pch <= Nanod.dbh2reg & Nanod.pchdbh;
			abh2Pch <= Nanod.abh2reg & Nanod.pchabh;
			abl2Pcl <= Nanod.abl2reg & Nanod.pclabl;
			
			Pcl2Dbl <= Nanod.reg2dbl & Nanod.pcldbl;
			Pch2Dbh <= Nanod.reg2dbh & Nanod.pchdbh;
			Pcl2Abl <= Nanod.reg2abl & Nanod.pclabl;
			Pch2Abh <= Nanod.reg2abh & Nanod.pchabh;
		end
		
		// Unique IF !!!
		if( enT1 & Nanod.au2Pc)
			PcL <= auReg[15:0];
		else if( enT3) begin
			if( dbl2Pcl)
				PcL <= Dbl;
			else if( abl2Pcl)
				PcL <= Abl;
		end
			
		// Unique IF !!!
		if( enT1 & Nanod.au2Pc)
			PcH <= auReg[31:16];
		else if( enT3) begin
			if( dbh2Pch)
				PcH <= Dbh;
			else if( abh2Pch)
				PcH <= Abh;
		end

		// Unique IF !!!
		if( enT3) begin
			if( Nanod.dbl2Atl)
				Atl <= Dbl;
			else if( Nanod.abl2Atl)
				Atl <= Abl;
		end

		// Unique IF !!!
		if( enT3) begin
			if( Nanod.abh2Ath)
				Ath <= Abh;
			else if( Nanod.dbh2Ath)
				Ath <= Dbh;
		end

	end

	// Movem reg mask priority encoder
	
	wire rmIdle;
	logic [3:0] prHbit;
	logic [15:0] prenLatch;
	
	// Invert reg order for predecrement mode
	assign prenEmpty = (~| prenLatch);	
	pren rmPren( .mask( prenLatch), .hbit (prHbit));

	always_ff @( posedge Clks.clk) begin
		// Cheating: PREN always loaded from DBIN
		// Must be on T1 to branch earlier if reg mask is empty!
		if( enT1 & Nanod.abl2Pren)
			prenLatch <= dbin;
		else if( enT3 & Nanod.updPren) begin
			prenLatch [prHbit] <= 1'b0;
			movemRx <= Irdecod.movemPreDecr ? ~prHbit : prHbit;
		end
	end
	
	// DCR
	wire [15:0] dcrCode;

	wire [3:0] dcrInput = abdIsByte ? { 1'b0, Abd[ 2:0]} : Abd[ 3:0];
	onehotEncoder4 dcrDecoder( .bin( dcrInput), .bitMap( dcrCode));
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp)
			dcr4 <= '0;
		else if( enT3 & Nanod.abd2Dcr) begin
			dcrOutput <= dcrCode;
			dcr4 <= Abd[4];
		end
	end
	
	// ALUB
	reg [15:0] alub;
	
	always_ff @( posedge Clks.clk) begin
		if( enT3) begin
			// UNIQUE IF !!
			if( Nanod.dbd2Alub)
				alub <= Dbd;
			else if( Nanod.abd2Alub)
				alub <= Abd;				// abdIsByte affects this !!??
		end
	end
	
	wire alueClkEn = enT3 & Nanod.dbd2Alue;

	// DOB/DBIN/IRC
	
	logic [15:0] dobInput;
	wire dobIdle = (~| Nanod.dobCtrl);
	
	always_comb begin
		unique case (Nanod.dobCtrl)
		NANO_DOB_ADB:		dobInput = Abd;
		NANO_DOB_DBD:		dobInput = Dbd;
		NANO_DOB_ALU:		dobInput = aluOut;
		default:			dobInput = 'X;
		endcase
	end

	dataIo dataIo( .Clks, .enT1, .enT2, .enT3, .enT4, .Nanod, .Irdecod,
			.iEdb, .dobIdle, .dobInput, .aob0,
			.Irc, .dbin, .oEdb);

	fx68kAlu alu(
		.clk( Clks.clk), .pwrUp( Clks.pwrUp), .enT1, .enT3, .enT4,
		.ird( Ird),
		.aluColumn( Nanod.aluColumn), .aluAddrCtrl( Nanod.aluActrl),
		.init( Nanod.aluInit), .finish( Nanod.aluFinish), .aluIsByte( Irdecod.isByte),
		.ftu2Ccr( Nanod.ftu2Ccr),
		.alub, .ftu, .alueClkEn, .alue,
		.aluDataCtrl( Nanod.aluDctrl), .iDataBus( Dbd), .iAddrBus(Abd),
		.ze, .aluOut, .ccr);

endmodule

//
// Data bus I/O
// At a separate module because it is a bit complicated and the timing is special.
// Here we do the low/high byte mux and the special case of MOVEP.
//
// Original implementation is rather complex because both the internal and external buses are bidirectional.
// Input is latched async at the EDB register.
// We capture directly from the external data bus to the internal registers (IRC & DBIN) on PHI2, starting the external S7 phase, at a T4 internal period.

module dataIo( input s_clks Clks,
	input enT1, enT2, enT3, enT4,
	input s_nanod Nanod, input s_irdecod Irdecod,
	input [15:0] iEdb,
	input aob0,

	input dobIdle,
	input [15:0] dobInput,
	
	output logic [15:0] Irc,	
	output logic [15:0] dbin,
	output logic [15:0] oEdb
	);

	reg [15:0] dob;
	
	// DBIN/IRC
	
	// Timing is different than any other register. We can latch only on the next T4 (bus phase S7).
	// We need to register all control signals correctly because the next ublock will already be started.
	// Can't latch control on T4 because if there are wait states there might be multiple T4 before we latch.
	
	reg xToDbin, xToIrc;
	reg dbinNoLow, dbinNoHigh;
	reg byteMux, isByte_T4;
	
	always_ff @( posedge Clks.clk) begin
	
		// Byte mux control. Can't latch at T1. AOB might be not ready yet.
		// Must latch IRD decode at T1 (or T4). Then combine and latch only at T3.

		// Can't latch at T3, a new IRD might be loaded already at T1.	
		// Ok to latch at T4 if combination latched then at T3
		if( enT4)
			isByte_T4 <= Irdecod.isByte;	// Includes MOVEP from mem, we could OR it here

		if( enT3) begin
			dbinNoHigh <= Nanod.noHighByte;
			dbinNoLow <= Nanod.noLowByte;
			byteMux <= Nanod.busByte & isByte_T4 & ~aob0;
		end
		
		if( enT1) begin
			// If on wait states, we continue latching until next T1
			xToDbin <= 1'b0;
			xToIrc <= 1'b0;			
		end
		else if( enT3) begin
			xToDbin <= Nanod.todbin;
			xToIrc <= Nanod.toIrc;
		end

		// Capture on T4 of the next ucycle
		// If there are wait states, we keep capturing every PHI2 until the next T1
		
		if( xToIrc & Clks.enPhi2)
			Irc <= iEdb;
		if( xToDbin & Clks.enPhi2) begin
			// Original connects both halves of EDB.
			if( ~dbinNoLow)
				dbin[ 7:0] <= byteMux ? iEdb[ 15:8] : iEdb[7:0];
			if( ~dbinNoHigh)
				dbin[ 15:8] <= ~byteMux & dbinNoLow ? iEdb[ 7:0] : iEdb[ 15:8];
		end
	end
	
	// DOB
	logic byteCycle;	
	
	always_ff @( posedge Clks.clk) begin
		// Originaly on T1. Transfer to internal EDB also on T1 (stays enabled upto the next T1). But only on T4 (S3) output enables.
		// It is safe to do on T3, then, but control signals if derived from IRD must be registered.
		// Originally control signals are not registered.
		
		// Wait states don't affect DOB operation that is done at the start of the bus cycle. 

		if( enT4)
			byteCycle <= Nanod.busByte & Irdecod.isByte;		// busIsByte but not MOVEP
		
		// Originally byte low/high interconnect is done at EDB, not at DOB.
		if( enT3 & ~dobIdle) begin
			dob[7:0] <= Nanod.noLowByte ? dobInput[15:8] : dobInput[ 7:0];
			dob[15:8] <= (byteCycle | Nanod.noHighByte) ? dobInput[ 7:0] : dobInput[15:8];
		end
	end
	assign oEdb = dob;

endmodule


// Provides ucode routine entries (A1/A3) for each opcode
// Also checks for illegal opcode and priv violation

// This is one of the slowest part of the processor.
// But no need to optimize or pipeline because the result is not needed until at least 4 cycles.
// IR updated at the least one microinstruction earlier.
// Just need to configure the timing analizer correctly.

module uaddrDecode( 
	input [15:0] opcode,
	output [UADDR_WIDTH-1:0] a1, a2, a3,
	output logic isPriv, isIllegal, isLineA, isLineF,
	output [15:0] lineBmap);
	
	wire [3:0] line = opcode[15:12];
	logic [3:0] eaCol, movEa;

	onehotEncoder4 irLineDecod( line, lineBmap);
	
	assign isLineA = lineBmap[ 'hA];
	assign isLineF = lineBmap[ 'hF];
	
	pla_lined pla_lined( .movEa( movEa), .col( eaCol),
		.opcode( opcode), .lineBmap( lineBmap),
		.palIll( isIllegal), .plaA1( a1), .plaA2( a2), .plaA3( a3) );
	
	// ea decoding   
	assign eaCol = eaDecode( opcode[ 5:0]);
	assign movEa = eaDecode( {opcode[ 8:6], opcode[ 11:9]} );

	// EA decode
	function [3:0] eaDecode;
	input [5:0] eaBits;
	begin
	unique case( eaBits[ 5:3])
	3'b111:
		case( eaBits[ 2:0])
		3'b000:   eaDecode = 7;            // Absolute short
		3'b001:   eaDecode = 8;            // Absolute long
		3'b010:   eaDecode = 9;            // PC displacement
		3'b011:   eaDecode = 10;           // PC offset
		3'b100:   eaDecode = 11;           // Immediate
		default:  eaDecode = 12;           // Invalid
		endcase
         
	default:   eaDecode = eaBits[5:3];      // Register based EAs
	endcase
	end
	endfunction
	
	
	/*
	Privileged instructions:

	ANDI/EORI/ORI SR
	MOVE to SR
	MOVE to/from USP
	RESET
	RTE
	STOP
	*/
	
	always_comb begin
		unique case( lineBmap)
           
		// ori/andi/eori SR      
		'h01:   isPriv = ((opcode & 16'hf5ff) == 16'h007c);
      
		'h10:
			begin
			// No priority !!!
				if( (opcode & 16'hffc0) == 16'h46c0)        // move to sr
					isPriv = 1'b1;
				
				else if( (opcode & 16'hfff0) == 16'h4e60)   // move usp
					isPriv = 1'b1;
		
				else if(	opcode == 16'h4e70 ||			// reset
							opcode == 16'h4e73 ||			// rte
							opcode == 16'h4e72)				// stop
					isPriv = 1'b1;
				else
					isPriv = 1'b0;
			end
         
		default:   isPriv = 1'b0;
		endcase
	end

	
endmodule

// bin to one-hot, 4 bits to 16-bit bitmap
module onehotEncoder4( input [3:0] bin, output reg [15:0] bitMap);
	always_comb begin
	case( bin)
		'b0000:   bitMap = 16'h0001;
		'b0001:   bitMap = 16'h0002;
		'b0010:   bitMap = 16'h0004;
		'b0011:   bitMap = 16'h0008;
		'b0100:   bitMap = 16'h0010;
		'b0101:   bitMap = 16'h0020;
		'b0110:   bitMap = 16'h0040;
		'b0111:   bitMap = 16'h0080;
		'b1000:   bitMap = 16'h0100;
		'b1001:   bitMap = 16'h0200;
		'b1010:   bitMap = 16'h0400;
		'b1011:   bitMap = 16'h0800;
		'b1100:   bitMap = 16'h1000;
		'b1101:   bitMap = 16'h2000;
		'b1110:   bitMap = 16'h4000;
		'b1111:   bitMap = 16'h8000;
	endcase
	end
endmodule

// priority encoder
// used by MOVEM regmask
// this might benefit from device specific features
// MOVEM doesn't need speed, will read the result 2 CPU cycles after each update.
module pren( mask, hbit);
   parameter size = 16;
   parameter outbits = 4;

   input [size-1:0] mask;
   output reg [outbits-1:0] hbit;
   // output reg idle;
   
   always @( mask) begin
      integer i;
      hbit = 0;
      // idle = 1;
      for( i = size-1; i >= 0; i = i - 1) begin
          if( mask[ i]) begin
             hbit = i;
             // idle = 0;
         end
      end
   end

endmodule

// Microcode sequencer

module sequencer( input s_clks Clks, input enT3,
	input [UROM_WIDTH-1:0] microLatch,
	input A0Err, BerrA, busAddrErr, Spuria, Avia,
	input Tpend, intPend, isIllegal, isPriv, excRst, isLineA, isLineF,
	input [15:0] psw,
	input prenEmpty, au05z, dcr4, ze, i11,
	input [1:0] alue01,
	input [15:0] Ird,
	input [UADDR_WIDTH-1:0] a1, a2, a3,
	output logic [3:0] tvn,
	output logic [UADDR_WIDTH-1:0] nma);
	
	logic [UADDR_WIDTH-1:0] uNma;
	logic [UADDR_WIDTH-1:0] grp1Nma;	
	logic [1:0] c0c1;
	reg a0Rst;
	wire A0Sel;
	wire inGrp0Exc;
	
	// assign nma = Clks.extReset ? RSTP0_NMA : (A0Err ? BSER1_NMA : uNma);
	// assign nma = A0Err ? (a0Rst ? RSTP0_NMA : BSER1_NMA) : uNma;
	
    // word type I: 16 15 14 13 12 11 10 09 08 07 06 05 04 03 02 01 00
    // NMA :        .. .. 09 08 01 00 05 04 03 02 07 06 .. .. .. .. ..
	
	wire [UADDR_WIDTH-1:0] dbNma = { microLatch[ 14:13], microLatch[ 6:5], microLatch[ 10:7], microLatch[ 12:11]};

	// Group 0 exception.
	// Separated block from regular NMA. Otherwise simulation might depend on order of assigments.
	always_comb begin
		if( A0Err) begin
			if( a0Rst)					// Reset
				nma = RSTP0_NMA;
			else if( inGrp0Exc)			// Double fault
				nma = HALT1_NMA;
			else						// Bus or address error
				nma = BSER1_NMA;
		end
		else
			nma = uNma;
	end

	always_comb begin
		// Format II (conditional) or I (direct branch)
		if( microLatch[1])
			uNma = { microLatch[ 14:13], c0c1, microLatch[ 10:7], microLatch[ 12:11]};		
		else
			case( microLatch[ 3:2])
			0:   uNma = dbNma;   // DB
			1:   uNma = A0Sel ? grp1Nma : a1;
			2:   uNma = a2;
			3:   uNma = a3;
			endcase			
	end

	// Format II, conditional, NMA decoding
	wire [1:0] enl = { Ird[6], prenEmpty};		// Updated on T3
	
	wire [1:0] ms0 = { Ird[8], alue01[0]};
	wire [3:0] m01 = { au05z, Ird[8], alue01};
	wire [1:0] nz1 = { psw[ NF], psw[ ZF]};
	wire [1:0] nv  = { psw[ NF], psw[ VF]};
	
	logic ccTest;
	wire [4:0] cbc = microLatch[ 6:2];			// CBC bits
	
	always_comb begin
		unique case( cbc)
		'h0:    c0c1 = {i11, i11};						// W/L offset EA, from IRC

		'h1:    c0c1 = (au05z) ? 2'b01 : 2'b11;			// Updated on T3
		'h11:   c0c1 = (au05z) ? 2'b00 : 2'b11;

		'h02:   c0c1 = { 1'b0, ~psw[ CF]};				// C used in DIV
		'h12:   c0c1 = { 1'b1, ~psw[ CF]};

		'h03:   c0c1 = {psw[ ZF], psw[ ZF]};			// Z used in DIVU
		
		'h04:											// nz1, used in DIVS
			case( nz1)
               'b00:         c0c1 = 2'b10;
               'b10:         c0c1 = 2'b01;
               'b01,'b11:    c0c1 = 2'b11;
            endcase		

		'h05:   c0c1 = {psw[ NF], 1'b1};				// N used in CHK and DIV
		'h15:   c0c1 = {1'b1, psw[ NF]};
		
		// nz2, used in DIVS (same combination as nz1)
		'h06:   c0c1 = { ~nz1[1] & ~nz1[0], 1'b1};
		
		'h07:											// ms0 used in MUL
		case( ms0)
		 'b10, 'b00: c0c1 = 2'b11;
		 'b01: c0c1 = 2'b01;
		 'b11: c0c1 = 2'b10;
		endcase		
		
		'h08:											// m01 used in MUL
		case( m01)
		'b0000,'b0001,'b0100,'b0111:  c0c1 = 2'b11;
		'b0010,'b0011,'b0101:         c0c1 = 2'b01;
		'b0110:                       c0c1 = 2'b10;
		default:                      c0c1 = 2'b00;
		endcase

		// Conditional		
		'h09:   c0c1 = (ccTest) ? 2'b11 : 2'b01;
		'h19:   c0c1 = (ccTest) ? 2'b11 : 2'b10;
		
		// DCR bit 4 (high or low word)
		'h0c:   c0c1 = dcr4 ? 2'b01: 2'b11;
		'h1c:   c0c1 = dcr4 ? 2'b10: 2'b11;		
		
		// DBcc done
		'h0a:   c0c1 = ze ? 2'b11 : 2'b00;
		
		// nv, used in CHK
		'h0b:   c0c1 = (nv == 2'b00) ? 2'b00 : 2'b11;
		
		// V, used in trapv
		'h0d:   c0c1 = { ~psw[ VF], ~psw[VF]};		
		
		// enl, combination of pren idle and word/long on IRD
		'h0e,'h1e:
			case( enl)
			2'b00:	c0c1 = 'b10;
			2'b10:	c0c1 = 'b11;
			// 'hx1 result 00/01 depending on condition 0e/1e
			2'b01,2'b11:
					c0c1 = { 1'b0, microLatch[ 6]};
			endcase
			
		default: 				c0c1 = 'X;
		endcase
	end
	
	// CCR conditional
	always_comb begin
		unique case( Ird[ 11:8])		
		'h0: ccTest = 1'b1;						// T
		'h1: ccTest = 1'b0;						// F
		'h2: ccTest = ~psw[ CF] & ~psw[ ZF];	// HI
		'h3: ccTest = psw[ CF] | psw[ZF];		// LS
		'h4: ccTest = ~psw[ CF];				// CC (HS)
		'h5: ccTest = psw[ CF];					// CS (LO)
		'h6: ccTest = ~psw[ ZF];				// NE
		'h7: ccTest = psw[ ZF];					// EQ
		'h8: ccTest = ~psw[ VF];				// VC
		'h9: ccTest = psw[ VF];					// VS
		'ha: ccTest = ~psw[ NF];				// PL
		'hb: ccTest = psw[ NF];					// MI
		'hc: ccTest = (psw[ NF] & psw[ VF]) | (~psw[ NF] & ~psw[ VF]);				// GE
		'hd: ccTest = (psw[ NF] & ~psw[ VF]) | (~psw[ NF] & psw[ VF]);				// LT
		'he: ccTest = (psw[ NF] & psw[ VF] & ~psw[ ZF]) |
				 (~psw[ NF] & ~psw[ VF] & ~psw[ ZF]);								// GT
		'hf: ccTest = psw[ ZF] | (psw[ NF] & ~psw[VF]) | (~psw[ NF] & psw[VF]);		// LE
		endcase
	end
	
	// Exception logic
	logic rTrace, rInterrupt;
	logic rIllegal, rPriv, rLineA, rLineF;
	logic rExcRst, rExcAdrErr, rExcBusErr;
	logic rSpurious, rAutovec;
	wire grp1LatchEn, grp0LatchEn;
			
	// Originally control signals latched on T4. Then exception latches updated on T3
	assign grp1LatchEn = microLatch[0] & (microLatch[1] | !microLatch[4]);
	assign grp0LatchEn = microLatch[4] & !microLatch[1];
	
	assign inGrp0Exc = rExcRst | rExcBusErr | rExcAdrErr;
	
	always_ff @( posedge Clks.clk) begin
		if( grp0LatchEn & enT3) begin
			rExcRst <= excRst;
			rExcBusErr <= BerrA;
			rExcAdrErr <= busAddrErr;
			rSpurious <= Spuria;
			rAutovec <= Avia;
		end
		
		// Update group 1 exception latches
		// Inputs from IR decoder updated on T1 as soon as IR loaded
		// Trace pending updated on T3 at the start of the instruction
		// Interrupt pending on T2
		if( grp1LatchEn & enT3) begin
			rTrace <= Tpend;
			rInterrupt <= intPend;
			rIllegal <= isIllegal & ~isLineA & ~isLineF;
			rLineA <= isLineA;
			rLineF <= isLineF;
			rPriv <= isPriv & !psw[ SF];
		end
	end

	// exception priority
	always_comb begin
		grp1Nma = TRAC1_NMA;
		if( rExcRst)
			tvn = '0;							// Might need to change that to signal in exception
		else if( rExcBusErr | rExcAdrErr)
			tvn = { 1'b1, rExcAdrErr};
			
		// Seudo group 0 exceptions. Just for updating TVN
		else if( rSpurious | rAutovec)
			tvn = rSpurious ? TVN_SPURIOUS : TVN_AUTOVEC;
		
		else if( rTrace)
			tvn = 9;
		else if( rInterrupt) begin
			tvn = TVN_INTERRUPT;
			grp1Nma = ITLX1_NMA;
		end
		else begin
			unique case( 1'b1)					// Can't happen more than one of these
			rIllegal:			tvn = 4;
			rPriv:				tvn = 8;
			rLineA:				tvn = 10;
			rLineF:				tvn = 11;
			default:			tvn = 1;		// Signal no group 0/1 exception
			endcase
		end
	end
	
	assign A0Sel = rIllegal | rLineF | rLineA | rPriv | rTrace | rInterrupt;
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset)
			a0Rst <= 1'b1;
		else if( enT3)
			a0Rst <= 1'b0;
	end
	
endmodule


//
// DMA/BUS Arbitration
//

module busArbiter( input s_clks Clks,
		input BRi, BgackI, Halti, bgBlock,
		output busAvail,
		output logic BGn);
		
	enum int unsigned { DRESET = 0, DIDLE, D1, D_BR, D_BA, D_BRA, D3, D2} dmaPhase, next;

	always_comb begin
		case(dmaPhase)
		DRESET:	next = DIDLE;
		DIDLE:	begin
				if( bgBlock)
					next = DIDLE;
				else if( ~BgackI)
					next = D_BA;
				else if( ~BRi)
					next = D1;
				else
					next = DIDLE;
				end

		D_BA:	begin							// Loop while only BGACK asserted, BG negated here
				if( ~BRi & !bgBlock)
					next = D3;
				else if( ~BgackI & !bgBlock)
					next = D_BA;
				else
					next = DIDLE;
				end
				
		D1:		next = D_BR;							// Loop while only BR asserted
		D_BR:	next = ~BRi & BgackI ? D_BR : D_BA;		// No direct path to IDLE !
		
		D3:		next = D_BRA;
		D_BRA:	begin						// Loop while both BR and BGACK asserted
				case( {BgackI, BRi} )
				2'b11:	next = DIDLE;		// Both deasserted
				2'b10:	next = D_BR;		// BR asserted only
				2'b01:	next = D2;			// BGACK asserted only
				2'b00:	next = D_BRA;		// Stay here while both asserted
				endcase
				end
				
		// Might loop here if both deasserted, should normally don't arrive here anyway?
		// D2:		next = (BgackI & BRi) | bgBlock ? D2: D_BA;

		D2:		next = D_BA;
		
		default:	next = DIDLE;			// Should not reach here normally		
		endcase
	end
		
	logic granting;
	always_comb begin
		unique case( next)
		D1, D3, D_BR, D_BRA:	granting = 1'b1;
		default:				granting = 1'b0;
		endcase
	end
	
	reg rGranted;
	assign busAvail = Halti & BRi & BgackI & ~rGranted;
		
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			dmaPhase <= DRESET;
			rGranted <= 1'b0;
		end
		else if( Clks.enPhi2) begin
			dmaPhase <= next;
			// Internal signal changed on PHI2
			rGranted <= granting;
		end

		// External Output changed on PHI1
		if( Clks.extReset)
			BGn <= 1'b1;
		else if( Clks.enPhi1)
			BGn <= ~rGranted;
		
	end
			
endmodule

module busControl( input s_clks Clks, input enT1, input enT4,
		input permStart, permStop, iStop,
		input aob0,
		input isWrite, isByte, isRmc,
		input busAvail,
		output bgBlock,
		output busAddrErr,
		output waitBusCycle,
		output busStarting,			// Asserted during S0
		output logic addrOe,		// Asserted from S1 to the end, whole bus cycle except S0
		output bciWrite,			// Used for SSW on bus/addr error
		
		input rDtack, BeDebounced, Vpai,
		output ASn, output LDSn, output UDSn, eRWn);

	reg rAS, rLDS, rUDS, rRWn;
	assign ASn = rAS;
	assign LDSn = rLDS;
	assign UDSn = rUDS;
	assign eRWn = rRWn;

	//reg dataOe;
		
	reg bcPend;
	reg isWriteReg, bciByte, isRmcReg, wendReg;
	assign bciWrite = isWriteReg;
	reg addrOeDelay;
	reg isByteT4;

	wire canStart, busEnd;
	wire bcComplete, bcReset;
	
	wire isRcmReset = bcComplete & bcReset & isRmcReg;
	
	assign busAddrErr = aob0 & ~bciByte;
	
	// Bus retry not really supported.
	// It's BERR and HALT and not address error, and not read-modify cycle.
	wire busRetry = ~busAddrErr & 1'b0;
	
	enum int unsigned { SRESET = 0, SIDLE, S0, S2, S4, S6, SRMC_RES} busPhase, next;

	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset)
			busPhase <= SRESET;
		else if( Clks.enPhi1)
			busPhase <= next;
	end
	
	always_comb begin
		case( busPhase)
		SRESET:		next = SIDLE;
		SRMC_RES:	next = SIDLE;			// Single cycle special state when read phase of RMC reset
		S0:			next = S2;
		S2:			next = S4;
		S4:			next = busEnd ? S6 : S4;
		S6:			next = isRcmReset ? SRMC_RES : (canStart ? S0 : SIDLE);
		SIDLE:		next = canStart ? S0 : SIDLE;
		default:	next = SIDLE;
		endcase
	end	
	
	// Idle phase of RMC bus cycle. Might be better to just add a new state
	wire rmcIdle = (busPhase == SIDLE) & ~ASn & isRmcReg;
		
	assign canStart = (busAvail | rmcIdle) & (bcPend | permStart) & !busRetry & !bcReset;
		
	wire busEnding = (next == SIDLE) | (next == S0);
	
	assign busStarting = (busPhase == S0);
		
	// term signal (DTACK, BERR, VPA, adress error)
	assign busEnd = ~rDtack | iStop;
				
	// bcComplete asserted on raising edge of S6 (together with SNC).
	assign bcComplete = (busPhase == S6);
	
	// Clear bus info latch on completion (regular or aborted) and no bus retry (and not PHI1).
	// bciClear asserted half clock later on PHI2, and bci latches cleared async concurrently
	wire bciClear = bcComplete & ~busRetry;
	
	// Reset on reset or (berr & berrDelay & (not halt or rmc) & not 6800 & in bus cycle) (and not PHI1)
	assign bcReset = Clks.extReset | (addrOeDelay & BeDebounced & Vpai);
		
	// Enable uclock only on S6 (S8 on Bus Error) or not bciPermStop
	assign waitBusCycle = wendReg & !bcComplete;
	
	// Block Bus Grant when starting new bus cycle. But No need if AS already asserted (read phase of RMC)
	// Except that when that RMC phase aborted on bus error, it's asserted one cycle later!
	assign bgBlock = ((busPhase == S0) & ASn) | (busPhase == SRMC_RES);
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			addrOe <= 1'b0;
		end
		else if( Clks.enPhi2 & ( busPhase == S0))			// From S1, whole bus cycle except S0
				addrOe <= 1'b1;
		else if( Clks.enPhi1 & (busPhase == SRMC_RES))
			addrOe <= 1'b0;
		else if( Clks.enPhi1 & ~isRmcReg & busEnding)
			addrOe <= 1'b0;
			
		if( Clks.enPhi1)
			addrOeDelay <= addrOe;
		
		if( Clks.extReset) begin
			rAS <= 1'b1;
			rUDS <= 1'b1;
			rLDS <= 1'b1;
			rRWn <= 1'b1;
			//dataOe <= '0;
		end
		else begin
/*
			if( Clks.enPhi2 & isWriteReg & (busPhase == S2))
				dataOe <= 1'b1;
			else if( Clks.enPhi1 & (busEnding | (busPhase == SIDLE)) )
				dataOe <= 1'b0;
*/						
			if( Clks.enPhi1 & busEnding)
				rRWn <= 1'b1;
			else if( Clks.enPhi1 & isWriteReg) begin
				// Unlike LDS/UDS Asserted even in address error
				if( (busPhase == S0) & isWriteReg)
					rRWn <= 1'b0;
			end

			// AS. Actually follows addrOe half cycle later!
			if( Clks.enPhi1 & (busPhase == S0))
				rAS <= 1'b0;
			else if( Clks.enPhi2 & (busPhase == SRMC_RES))		// Bus error on read phase of RMC. Deasserted one cycle later
				rAS <= 1'b1;			
			else if( Clks.enPhi2 & bcComplete & ~SRMC_RES)
				if( ~isRmcReg)									// Keep AS asserted on the IDLE phase of RMC
					rAS <= 1'b1;
			
			if( Clks.enPhi1 & (busPhase == S0)) begin
				if( ~isWriteReg & !busAddrErr) begin
					rUDS <= ~(~bciByte | ~aob0);
					rLDS <= ~(~bciByte | aob0);
				end
			end
			else if( Clks.enPhi1 & isWriteReg & (busPhase == S2) & !busAddrErr) begin
					rUDS <= ~(~bciByte | ~aob0);
					rLDS <= ~(~bciByte | aob0);
			end		
			else if( Clks.enPhi2 & bcComplete) begin
				rUDS <= 1'b1;
				rLDS <= 1'b1;
			end
			
		end
		
	end
	
	// Bus cycle info latch. Needed because uinstr might change if the bus is busy and we must wait.
	// Note that urom advances even on wait states. It waits *after* updating urom and nanorom latches.
	// Even without wait states, ublocks of type ir (init reading) will not wait for bus completion.
	// Originally latched on (permStart AND T1).
	
	// Bus cycle info latch: isRead, isByte, read-modify-cycle, and permStart (bus cycle pending). Some previously latched on T4?
	// permStop also latched, but unconditionally on T1
	
	// Might make more sense to register this outside this module
	always_ff @( posedge Clks.clk) begin
		if( enT4) begin
			isByteT4 <= isByte;
		end
	end
	
	// Bus Cycle Info Latch
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp) begin
			bcPend <= 1'b0;
			wendReg <= 1'b0;	
			isWriteReg <= 1'b0;
			bciByte <= 1'b0;
			isRmcReg <= 1'b0;		
		end
		
		else if( Clks.enPhi2 & (bciClear | bcReset)) begin
			bcPend <= 1'b0;
			wendReg <= 1'b0;
		end
		else begin
			if( enT1 & permStart) begin
				isWriteReg <= isWrite;
				bciByte <= isByteT4;
				isRmcReg <= isRmc & ~isWrite;	// We need special case the end of the read phase only.
				bcPend <= 1'b1;
			end
			if( enT1)
				wendReg <= permStop;
		end
	end
			
endmodule

//
// microrom and nanorom instantiation
//
// There is bit of wasting of resources here. An extra registering pipeline happens that is not needed.
// This is just for the purpose of helping inferring block RAM using pure generic code. Inferring RAM is important for performance.
// Might be more efficient to use vendor specific features such as clock enable.
//

module uRom( input clk, input [UADDR_WIDTH-1:0] microAddr, output logic [UROM_WIDTH-1:0] microOutput);
	reg [UROM_WIDTH-1:0] uRam[ UROM_DEPTH];		
	initial begin
		uRam[0] = 17'b10010000101100000;
uRam[1] = 17'b10000100000000000;
uRam[2] = 17'b00101001011010000;
uRam[3] = 17'b00111110011000000;
uRam[4] = 17'b01000000000001100;
uRam[5] = 17'b01000000000001100;
uRam[6] = 17'b01000010010000000;
uRam[7] = 17'b10001100011100000;
uRam[8] = 17'b01000100010000000;
uRam[9] = 17'b10000000010000000;
uRam[10] = 17'b10000000010000000;
uRam[11] = 17'b01000100010000000;
uRam[12] = 17'b00001010010000000;
uRam[13] = 17'b10000000100000000;
uRam[14] = 17'b10000000100000000;
uRam[15] = 17'b01101001100000000;
uRam[16] = 17'b00000000000000000;
uRam[17] = 17'b00000000000000000;
uRam[18] = 17'b00000000000000000;
uRam[19] = 17'b00000000000000000;
uRam[20] = 17'b00000000000000000;
uRam[21] = 17'b00000000000000000;
uRam[22] = 17'b00000000000000000;
uRam[23] = 17'b00000000000000000;
uRam[24] = 17'b00000000000000000;
uRam[25] = 17'b00000000000000000;
uRam[26] = 17'b00000000000000000;
uRam[27] = 17'b00000000000000000;
uRam[28] = 17'b00000000000000000;
uRam[29] = 17'b00000000000000000;
uRam[30] = 17'b00000000000000000;
uRam[31] = 17'b00000000000000000;
uRam[32] = 17'b00000000000000100;
uRam[33] = 17'b00001010110000000;
uRam[34] = 17'b00111000001100000;
uRam[35] = 17'b00100101001001010;
uRam[36] = 17'b00000000000001100;
uRam[37] = 17'b10110000110100001;
uRam[38] = 17'b00000000000001100;
uRam[39] = 17'b00001110100000000;
uRam[40] = 17'b00110100101000000;
uRam[41] = 17'b00100011010100000;
uRam[42] = 17'b00000010010000000;
uRam[43] = 17'b10000110000000010;
uRam[44] = 17'b00111110110000000;
uRam[45] = 17'b00000100011100000;
uRam[46] = 17'b00101111010100000;
uRam[47] = 17'b10010011100000010;
uRam[48] = 17'b00000000000000000;
uRam[49] = 17'b00000000000000000;
uRam[50] = 17'b00000000000000000;
uRam[51] = 17'b00000000000000000;
uRam[52] = 17'b00000000000000000;
uRam[53] = 17'b00000000000000000;
uRam[54] = 17'b00000000000000000;
uRam[55] = 17'b00000000000000000;
uRam[56] = 17'b00000000000000000;
uRam[57] = 17'b00000000000000000;
uRam[58] = 17'b00000000000000000;
uRam[59] = 17'b00000000000000000;
uRam[60] = 17'b00000000000000000;
uRam[61] = 17'b00000000000000000;
uRam[62] = 17'b00000000000000000;
uRam[63] = 17'b00000000000000000;
uRam[64] = 17'b10011101000000000;
uRam[65] = 17'b00000100110010110;
uRam[66] = 17'b00101001010000000;
uRam[67] = 17'b10110000110100001;
uRam[68] = 17'b00000000000000100;
uRam[69] = 17'b00111110000100000;
uRam[70] = 17'b10010111010100000;
uRam[71] = 17'b01000110000100000;
uRam[72] = 17'b01010111100000000;
uRam[73] = 17'b10001010010011010;
uRam[74] = 17'b01000110010100001;
uRam[75] = 17'b00000110010111010;
uRam[76] = 17'b01001100010100000;
uRam[77] = 17'b10001010010010111;
uRam[78] = 17'b01000000000100001;
uRam[79] = 17'b00110100111000000;
uRam[80] = 17'b00000000000000000;
uRam[81] = 17'b00000000000000000;
uRam[82] = 17'b00000000000000000;
uRam[83] = 17'b00000000000000000;
uRam[84] = 17'b00000000000000000;
uRam[85] = 17'b00000000000000000;
uRam[86] = 17'b00000000000000000;
uRam[87] = 17'b00000000000000000;
uRam[88] = 17'b00000000000000000;
uRam[89] = 17'b00000000000000000;
uRam[90] = 17'b00000000000000000;
uRam[91] = 17'b00000000000000000;
uRam[92] = 17'b00000000000000000;
uRam[93] = 17'b00000000000000000;
uRam[94] = 17'b00000000000000000;
uRam[95] = 17'b00000000000000000;
uRam[96] = 17'b00000010001100000;
uRam[97] = 17'b01001010000100001;
uRam[98] = 17'b10110100111000000;
uRam[99] = 17'b00011011010100000;
uRam[100] = 17'b10000000000000100;
uRam[101] = 17'b10110100111000000;
uRam[102] = 17'b00000000000000100;
uRam[103] = 17'b00001000001000000;
uRam[104] = 17'b00000100011100110;
uRam[105] = 17'b10001110010100001;
uRam[106] = 17'b00000000011110010;
uRam[107] = 17'b01001000011000000;
uRam[108] = 17'b00001000010100110;
uRam[109] = 17'b10001010000110111;
uRam[110] = 17'b00000000111110010;
uRam[111] = 17'b01001000111000000;
uRam[112] = 17'b00000000000000000;
uRam[113] = 17'b00000000000000000;
uRam[114] = 17'b00000000000000000;
uRam[115] = 17'b00000000000000000;
uRam[116] = 17'b00000000000000000;
uRam[117] = 17'b00000000000000000;
uRam[118] = 17'b00000000000000000;
uRam[119] = 17'b00000000000000000;
uRam[120] = 17'b00000000000000000;
uRam[121] = 17'b00000000000000000;
uRam[122] = 17'b00000000000000000;
uRam[123] = 17'b00000000000000000;
uRam[124] = 17'b00000000000000000;
uRam[125] = 17'b00000000000000000;
uRam[126] = 17'b00000000000000000;
uRam[127] = 17'b00000000000000000;
uRam[128] = 17'b10101001000000001;
uRam[129] = 17'b10001000001000001;
uRam[130] = 17'b01000000000000100;
uRam[131] = 17'b01001100001111010;
uRam[132] = 17'b00000110001000000;
uRam[133] = 17'b00010110001100000;
uRam[134] = 17'b00011010000000000;
uRam[135] = 17'b10110000110100001;
uRam[136] = 17'b01111000001100000;
uRam[137] = 17'b00011000000000000;
uRam[138] = 17'b00000100100100001;
uRam[139] = 17'b00000000000000100;
uRam[140] = 17'b00000000101100000;
uRam[141] = 17'b00000000000000100;
uRam[142] = 17'b00010001010100000;
uRam[143] = 17'b10010111000100001;
uRam[144] = 17'b00000000000000000;
uRam[145] = 17'b00000000000000000;
uRam[146] = 17'b00000000000000000;
uRam[147] = 17'b00000000000000000;
uRam[148] = 17'b00000000000000000;
uRam[149] = 17'b00000000000000000;
uRam[150] = 17'b00000000000000000;
uRam[151] = 17'b00000000000000000;
uRam[152] = 17'b00000000000000000;
uRam[153] = 17'b00000000000000000;
uRam[154] = 17'b00000000000000000;
uRam[155] = 17'b00000000000000000;
uRam[156] = 17'b00000000000000000;
uRam[157] = 17'b00000000000000000;
uRam[158] = 17'b00000000000000000;
uRam[159] = 17'b00000000000000000;
uRam[160] = 17'b00000010001100000;
uRam[161] = 17'b00000000000000100;
uRam[162] = 17'b01111000011100000;
uRam[163] = 17'b00011011010100000;
uRam[164] = 17'b00101101000000000;
uRam[165] = 17'b01000110010111010;
uRam[166] = 17'b00101101000000000;
uRam[167] = 17'b10001010101100000;
uRam[168] = 17'b01010110001100000;
uRam[169] = 17'b00011000110000000;
uRam[170] = 17'b01010110001100000;
uRam[171] = 17'b10001110011100001;
uRam[172] = 17'b00000100101100000;
uRam[173] = 17'b01000110010111010;
uRam[174] = 17'b00000100101100000;
uRam[175] = 17'b10001010111100000;
uRam[176] = 17'b00000000000000000;
uRam[177] = 17'b00000000000000000;
uRam[178] = 17'b00000000000000000;
uRam[179] = 17'b00000000000000000;
uRam[180] = 17'b00000000000000000;
uRam[181] = 17'b00000000000000000;
uRam[182] = 17'b00000000000000000;
uRam[183] = 17'b00000000000000000;
uRam[184] = 17'b00000000000000000;
uRam[185] = 17'b00000000000000000;
uRam[186] = 17'b00000000000000000;
uRam[187] = 17'b00000000000000000;
uRam[188] = 17'b00000000000000000;
uRam[189] = 17'b00000000000000000;
uRam[190] = 17'b00000000000000000;
uRam[191] = 17'b00000000000000000;
uRam[192] = 17'b10101001000000001;
uRam[193] = 17'b00001000101010110;
uRam[194] = 17'b00011111010100000;
uRam[195] = 17'b01101101110000000;
uRam[196] = 17'b00000000000000100;
uRam[197] = 17'b10111110000100000;
uRam[198] = 17'b00000100011100000;
uRam[199] = 17'b10001100101000001;
uRam[200] = 17'b00000110001000000;
uRam[201] = 17'b00001110000010010;
uRam[202] = 17'b00100101000010110;
uRam[203] = 17'b00101101000100000;
uRam[204] = 17'b00000000011100000;
uRam[205] = 17'b00001000111100000;
uRam[206] = 17'b00100101000011010;
uRam[207] = 17'b00110100111000000;
uRam[208] = 17'b00000000000000000;
uRam[209] = 17'b00000000000000000;
uRam[210] = 17'b00000000000000000;
uRam[211] = 17'b00000000000000000;
uRam[212] = 17'b00000000000000000;
uRam[213] = 17'b00000000000000000;
uRam[214] = 17'b00000000000000000;
uRam[215] = 17'b00000000000000000;
uRam[216] = 17'b00000000000000000;
uRam[217] = 17'b00000000000000000;
uRam[218] = 17'b00000000000000000;
uRam[219] = 17'b00000000000000000;
uRam[220] = 17'b00000000000000000;
uRam[221] = 17'b00000000000000000;
uRam[222] = 17'b00000000000000000;
uRam[223] = 17'b00000000000000000;
uRam[224] = 17'b00000010000100010;
uRam[225] = 17'b00001010110000000;
uRam[226] = 17'b00000000000000100;
uRam[227] = 17'b00101101010000000;
uRam[228] = 17'b01010001010000000;
uRam[229] = 17'b01000110111000000;
uRam[230] = 17'b00000000000000100;
uRam[231] = 17'b00000000010110010;
uRam[232] = 17'b00110100101000000;
uRam[233] = 17'b00100011010100000;
uRam[234] = 17'b10000000000001000;
uRam[235] = 17'b01101011010000000;
uRam[236] = 17'b00111110110000000;
uRam[237] = 17'b00000100011100000;
uRam[238] = 17'b10010101000000000;
uRam[239] = 17'b01111110010100000;
uRam[240] = 17'b00000000000000000;
uRam[241] = 17'b00000000000000000;
uRam[242] = 17'b00000000000000000;
uRam[243] = 17'b00000000000000000;
uRam[244] = 17'b00000000000000000;
uRam[245] = 17'b00000000000000000;
uRam[246] = 17'b00000000000000000;
uRam[247] = 17'b00000000000000000;
uRam[248] = 17'b00000000000000000;
uRam[249] = 17'b00000000000000000;
uRam[250] = 17'b00000000000000000;
uRam[251] = 17'b00000000000000000;
uRam[252] = 17'b00000000000000000;
uRam[253] = 17'b00000000000000000;
uRam[254] = 17'b00000000000000000;
uRam[255] = 17'b00000000000000000;
uRam[256] = 17'b10001100101000001;
uRam[257] = 17'b10000010100000010;
uRam[258] = 17'b01000010101000000;
uRam[259] = 17'b00011111100100000;
uRam[260] = 17'b10100111100000001;
uRam[261] = 17'b10010010110000010;
uRam[262] = 17'b01110100111000000;
uRam[263] = 17'b00010111010000000;
uRam[264] = 17'b10101011100000001;
uRam[265] = 17'b10010010100000010;
uRam[266] = 17'b01110000100100000;
uRam[267] = 17'b00000000100100000;
uRam[268] = 17'b10100101100100001;
uRam[269] = 17'b10000010110000010;
uRam[270] = 17'b01001010101000000;
uRam[271] = 17'b00010111000000000;
uRam[272] = 17'b00010001000010110;
uRam[273] = 17'b01110010100111010;
uRam[274] = 17'b10110100010000000;
uRam[275] = 17'b00110100111000000;
uRam[276] = 17'b01000010010000110;
uRam[277] = 17'b01110010110111011;
uRam[278] = 17'b01111100000000000;
uRam[279] = 17'b00101101000100000;
uRam[280] = 17'b00101001001010001;
uRam[281] = 17'b01011011111100000;
uRam[282] = 17'b01101111011000000;
uRam[283] = 17'b00100011100000000;
uRam[284] = 17'b00111110000110000;
uRam[285] = 17'b00000000000000000;
uRam[286] = 17'b10101111011000000;
uRam[287] = 17'b00000000000000000;
uRam[288] = 17'b00001010100000000;
uRam[289] = 17'b10101011100100001;
uRam[290] = 17'b01010011000100001;
uRam[291] = 17'b10010101010000000;
uRam[292] = 17'b00000000110000000;
uRam[293] = 17'b10111010000100001;
uRam[294] = 17'b01011001010000000;
uRam[295] = 17'b10010101000000000;
uRam[296] = 17'b00101101101100000;
uRam[297] = 17'b10100011100100001;
uRam[298] = 17'b01011110100000000;
uRam[299] = 17'b01110100011100000;
uRam[300] = 17'b00101011111000000;
uRam[301] = 17'b10110000110100001;
uRam[302] = 17'b01010101010100001;
uRam[303] = 17'b00000000000000000;
uRam[304] = 17'b00111000100000000;
uRam[305] = 17'b01011011000000000;
uRam[306] = 17'b00001000100100000;
uRam[307] = 17'b10001100101000001;
uRam[308] = 17'b00100001100000000;
uRam[309] = 17'b01011011010000000;
uRam[310] = 17'b00001000110100000;
uRam[311] = 17'b10011001110100001;
uRam[312] = 17'b00000110010111010;
uRam[313] = 17'b01011011100000000;
uRam[314] = 17'b00000000110100000;
uRam[315] = 17'b10011101010000001;
uRam[316] = 17'b00000000000000000;
uRam[317] = 17'b00000000000000000;
uRam[318] = 17'b00000000000000000;
uRam[319] = 17'b00000000000000000;
uRam[320] = 17'b00000000000000000;
uRam[321] = 17'b00000000000000000;
uRam[322] = 17'b00000000000000000;
uRam[323] = 17'b00000000000000000;
uRam[324] = 17'b00000000000000000;
uRam[325] = 17'b00000000000000000;
uRam[326] = 17'b00000000000000000;
uRam[327] = 17'b00000000000000000;
uRam[328] = 17'b00000000000000000;
uRam[329] = 17'b00000000000000000;
uRam[330] = 17'b00000000000000000;
uRam[331] = 17'b00000000000000000;
uRam[332] = 17'b00000000000000000;
uRam[333] = 17'b00000000000000000;
uRam[334] = 17'b00000000000000000;
uRam[335] = 17'b00000000000000000;
uRam[336] = 17'b10110000110100001;
uRam[337] = 17'b00011101000100000;
uRam[338] = 17'b00011101000100000;
uRam[339] = 17'b00010001000101110;
uRam[340] = 17'b01011010110000000;
uRam[341] = 17'b01011001010100000;
uRam[342] = 17'b10011101010100000;
uRam[343] = 17'b00000000000000100;
uRam[344] = 17'b10110000110100001;
uRam[345] = 17'b00110110000000000;
uRam[346] = 17'b10110000011100001;
uRam[347] = 17'b10110000011100001;
uRam[348] = 17'b10011101000000001;
uRam[349] = 17'b01110100111000000;
uRam[350] = 17'b00101101100100000;
uRam[351] = 17'b10011000100000000;
uRam[352] = 17'b00000000000000000;
uRam[353] = 17'b00000000000000000;
uRam[354] = 17'b00000000000000000;
uRam[355] = 17'b00000000000000000;
uRam[356] = 17'b00000000000000000;
uRam[357] = 17'b00000000000000000;
uRam[358] = 17'b00000000000000000;
uRam[359] = 17'b00000000000000000;
uRam[360] = 17'b00000000000000000;
uRam[361] = 17'b00000000000000000;
uRam[362] = 17'b00000000000000000;
uRam[363] = 17'b00000000000000000;
uRam[364] = 17'b00000000000000000;
uRam[365] = 17'b00000000000000000;
uRam[366] = 17'b00000000000000000;
uRam[367] = 17'b00000000000000000;
uRam[368] = 17'b10000000000000100;
uRam[369] = 17'b00000000000000100;
uRam[370] = 17'b00000100111000000;
uRam[371] = 17'b00000100111000000;
uRam[372] = 17'b00000100111000000;
uRam[373] = 17'b00001100010101010;
uRam[374] = 17'b00001000000010110;
uRam[375] = 17'b00101001010000000;
uRam[376] = 17'b10011000100000000;
uRam[377] = 17'b00011011100100000;
uRam[378] = 17'b01000100010000000;
uRam[379] = 17'b01000000000001100;
uRam[380] = 17'b10011000010000001;
uRam[381] = 17'b10011011110100000;
uRam[382] = 17'b10011111110100001;
uRam[383] = 17'b00011000010000000;
uRam[384] = 17'b00000000000000000;
uRam[385] = 17'b00000000000000000;
uRam[386] = 17'b00000000000000000;
uRam[387] = 17'b00000000000000000;
uRam[388] = 17'b00000000000000000;
uRam[389] = 17'b00000000000000000;
uRam[390] = 17'b00000000000000000;
uRam[391] = 17'b00000000000000000;
uRam[392] = 17'b00000000000000000;
uRam[393] = 17'b00000000000000000;
uRam[394] = 17'b00000000000000000;
uRam[395] = 17'b00000000000000000;
uRam[396] = 17'b00000000000000000;
uRam[397] = 17'b00000000000000000;
uRam[398] = 17'b00000000000000000;
uRam[399] = 17'b00000000000000000;
uRam[400] = 17'b00000000000000000;
uRam[401] = 17'b00000000000000000;
uRam[402] = 17'b00000000000000000;
uRam[403] = 17'b00000000000000000;
uRam[404] = 17'b00000000000000000;
uRam[405] = 17'b00000000000000000;
uRam[406] = 17'b00000000000000000;
uRam[407] = 17'b00000000000000000;
uRam[408] = 17'b00000000000000000;
uRam[409] = 17'b00000000000000000;
uRam[410] = 17'b00000000000000000;
uRam[411] = 17'b00000000000000000;
uRam[412] = 17'b00000000000000000;
uRam[413] = 17'b00000000000000000;
uRam[414] = 17'b00000000000000000;
uRam[415] = 17'b00000000000000000;
uRam[416] = 17'b00000000000000000;
uRam[417] = 17'b00000000000000000;
uRam[418] = 17'b00000000000000000;
uRam[419] = 17'b00000000000000000;
uRam[420] = 17'b00000000000000000;
uRam[421] = 17'b00000000000000000;
uRam[422] = 17'b00000000000000000;
uRam[423] = 17'b00000000000000000;
uRam[424] = 17'b00000000000000000;
uRam[425] = 17'b00000000000000000;
uRam[426] = 17'b00000000000000000;
uRam[427] = 17'b00000000000000000;
uRam[428] = 17'b00000000000000000;
uRam[429] = 17'b00000000000000000;
uRam[430] = 17'b00000000000000000;
uRam[431] = 17'b00000000000000000;
uRam[432] = 17'b00000000000000000;
uRam[433] = 17'b00000000000000000;
uRam[434] = 17'b00000000000000000;
uRam[435] = 17'b00000000000000000;
uRam[436] = 17'b00000000000000000;
uRam[437] = 17'b00000000000000000;
uRam[438] = 17'b00000000000000000;
uRam[439] = 17'b00000000000000000;
uRam[440] = 17'b00000000000000000;
uRam[441] = 17'b00000000000000000;
uRam[442] = 17'b00000000000000000;
uRam[443] = 17'b00000000000000000;
uRam[444] = 17'b00000000000000000;
uRam[445] = 17'b00000000000000000;
uRam[446] = 17'b00000000000000000;
uRam[447] = 17'b00000000000000000;
uRam[448] = 17'b00111110001000000;
uRam[449] = 17'b10101011100100001;
uRam[450] = 17'b10001010100000000;
uRam[451] = 17'b10101011100100001;
uRam[452] = 17'b00100011010000000;
uRam[453] = 17'b10110000001100001;
uRam[454] = 17'b10000000110000000;
uRam[455] = 17'b10110000101100001;
uRam[456] = 17'b00000000000000000;
uRam[457] = 17'b10110000101100001;
uRam[458] = 17'b10110110110100000;
uRam[459] = 17'b10100001110100001;
uRam[460] = 17'b00111100010000000;
uRam[461] = 17'b10011101100000001;
uRam[462] = 17'b10111110100100000;
uRam[463] = 17'b10010011010100001;
uRam[464] = 17'b00111100010100000;
uRam[465] = 17'b10101011100000001;
uRam[466] = 17'b10101001101000000;
uRam[467] = 17'b10101011100000001;
uRam[468] = 17'b00000000000000000;
uRam[469] = 17'b10011111000100001;
uRam[470] = 17'b10101001111000000;
uRam[471] = 17'b10011011000100001;
uRam[472] = 17'b00000000000000000;
uRam[473] = 17'b10010011010100001;
uRam[474] = 17'b00000000000000000;
uRam[475] = 17'b00000000000000000;
uRam[476] = 17'b00000000000000000;
uRam[477] = 17'b00000000000000000;
uRam[478] = 17'b00000000000000000;
uRam[479] = 17'b00000000000000000;
uRam[480] = 17'b00001010100000000;
uRam[481] = 17'b10111110000100000;
uRam[482] = 17'b10000100100000000;
uRam[483] = 17'b00111010001100000;
uRam[484] = 17'b00000000110000000;
uRam[485] = 17'b10011001000000000;
uRam[486] = 17'b10000100110000000;
uRam[487] = 17'b00111010011100000;
uRam[488] = 17'b00101101101100000;
uRam[489] = 17'b10001110111000000;
uRam[490] = 17'b10101111101000000;
uRam[491] = 17'b00010100100000000;
uRam[492] = 17'b00101011111000000;
uRam[493] = 17'b10110100001100000;
uRam[494] = 17'b10101111111000000;
uRam[495] = 17'b00010100010000000;
uRam[496] = 17'b00111000100000000;
uRam[497] = 17'b10110100101100000;
uRam[498] = 17'b10101001010100000;
uRam[499] = 17'b00101011001000000;
uRam[500] = 17'b00100001100000000;
uRam[501] = 17'b10001110010000000;
uRam[502] = 17'b10101111001000000;
uRam[503] = 17'b00101011011000000;
uRam[504] = 17'b00000110010111010;
uRam[505] = 17'b10111000110000000;
uRam[506] = 17'b10011101110100000;
uRam[507] = 17'b00111010101100000;
uRam[508] = 17'b00000000000000000;
uRam[509] = 17'b10101011011100000;
uRam[510] = 17'b01100011110100001;
uRam[511] = 17'b00111010111100000;
uRam[512] = 17'b00000000000000000;
uRam[513] = 17'b00000000000000000;
uRam[514] = 17'b00000000000000000;
uRam[515] = 17'b00000000000000000;
uRam[516] = 17'b00000000000000000;
uRam[517] = 17'b00000000000000000;
uRam[518] = 17'b00000000000000000;
uRam[519] = 17'b00000000000000000;
uRam[520] = 17'b00000000000000000;
uRam[521] = 17'b00000000000000000;
uRam[522] = 17'b00000000000000000;
uRam[523] = 17'b00000000000000000;
uRam[524] = 17'b00000000000000000;
uRam[525] = 17'b00000000000000000;
uRam[526] = 17'b00000000000000000;
uRam[527] = 17'b00000000000000000;
uRam[528] = 17'b00100101000000000;
uRam[529] = 17'b00000100000010110;
uRam[530] = 17'b00000000000000100;
uRam[531] = 17'b00001110000001110;
uRam[532] = 17'b00100001000000000;
uRam[533] = 17'b10110000110100001;
uRam[534] = 17'b00100101011001010;
uRam[535] = 17'b00111000001100000;
uRam[536] = 17'b00100101100000001;
uRam[537] = 17'b10011000010000000;
uRam[538] = 17'b01101101100000000;
uRam[539] = 17'b00000000000001100;
uRam[540] = 17'b01100101110000000;
uRam[541] = 17'b00000000000001100;
uRam[542] = 17'b00001100001111010;
uRam[543] = 17'b01001100001111010;
uRam[544] = 17'b00000000000000000;
uRam[545] = 17'b00000000000000000;
uRam[546] = 17'b00000000000000000;
uRam[547] = 17'b00000000000000000;
uRam[548] = 17'b00000000000000000;
uRam[549] = 17'b00000000000000000;
uRam[550] = 17'b00000000000000000;
uRam[551] = 17'b00000000000000000;
uRam[552] = 17'b00000000000000000;
uRam[553] = 17'b00000000000000000;
uRam[554] = 17'b00000000000000000;
uRam[555] = 17'b00000000000000000;
uRam[556] = 17'b00000000000000000;
uRam[557] = 17'b00000000000000000;
uRam[558] = 17'b00000000000000000;
uRam[559] = 17'b00000000000000000;
uRam[560] = 17'b10101111000000001;
uRam[561] = 17'b00000100111000000;
uRam[562] = 17'b10101111000000001;
uRam[563] = 17'b00000000000000100;
uRam[564] = 17'b00100111010000000;
uRam[565] = 17'b00001110101100000;
uRam[566] = 17'b11010001100000000;
uRam[567] = 17'b00110010100111010;
uRam[568] = 17'b00000000000000100;
uRam[569] = 17'b00000100111000000;
uRam[570] = 17'b00000000000000100;
uRam[571] = 17'b10110000110100001;
uRam[572] = 17'b01100111110000001;
uRam[573] = 17'b10000000000000100;
uRam[574] = 17'b01111100100100000;
uRam[575] = 17'b01100001100100001;
uRam[576] = 17'b00000000000000000;
uRam[577] = 17'b00000000000000000;
uRam[578] = 17'b00000000000000000;
uRam[579] = 17'b00000000000000000;
uRam[580] = 17'b00000000000000000;
uRam[581] = 17'b00000000000000000;
uRam[582] = 17'b00000000000000000;
uRam[583] = 17'b00000000000000000;
uRam[584] = 17'b00000000000000000;
uRam[585] = 17'b00000000000000000;
uRam[586] = 17'b00000000000000000;
uRam[587] = 17'b00000000000000000;
uRam[588] = 17'b00000000000000000;
uRam[589] = 17'b00000000000000000;
uRam[590] = 17'b00000000000000000;
uRam[591] = 17'b00000000000000000;
uRam[592] = 17'b00000000001100000;
uRam[593] = 17'b10001010010100001;
uRam[594] = 17'b00110110100000110;
uRam[595] = 17'b00000000000000100;
uRam[596] = 17'b00100001000000000;
uRam[597] = 17'b10111110000100000;
uRam[598] = 17'b10100111000100000;
uRam[599] = 17'b00111000010000000;
uRam[600] = 17'b10000000000000100;
uRam[601] = 17'b00101001100100000;
uRam[602] = 17'b00101101100100000;
uRam[603] = 17'b00000000000000100;
uRam[604] = 17'b00100101110100000;
uRam[605] = 17'b00000000000000100;
uRam[606] = 17'b00100101110100000;
uRam[607] = 17'b00100101110100000;
uRam[608] = 17'b00000000000000000;
uRam[609] = 17'b00000000000000000;
uRam[610] = 17'b00000000000000000;
uRam[611] = 17'b00000000000000000;
uRam[612] = 17'b00000000000000000;
uRam[613] = 17'b00000000000000000;
uRam[614] = 17'b00000000000000000;
uRam[615] = 17'b00000000000000000;
uRam[616] = 17'b00000000000000000;
uRam[617] = 17'b00000000000000000;
uRam[618] = 17'b00000000000000000;
uRam[619] = 17'b00000000000000000;
uRam[620] = 17'b00000000000000000;
uRam[621] = 17'b00000000000000000;
uRam[622] = 17'b00000000000000000;
uRam[623] = 17'b00000000000000000;
uRam[624] = 17'b10100111000100000;
uRam[625] = 17'b01101011000100000;
uRam[626] = 17'b01111110000100001;
uRam[627] = 17'b10100111000100000;
uRam[628] = 17'b10100111001000000;
uRam[629] = 17'b10111110000100000;
uRam[630] = 17'b00101111010000000;
uRam[631] = 17'b00110010100111010;
uRam[632] = 17'b00000000000000100;
uRam[633] = 17'b10100011100100001;
uRam[634] = 17'b00000000000000100;
uRam[635] = 17'b00000010011100001;
uRam[636] = 17'b10100111110100000;
uRam[637] = 17'b00000000000000100;
uRam[638] = 17'b00101111110100000;
uRam[639] = 17'b00101111101100000;
uRam[640] = 17'b00000000000000000;
uRam[641] = 17'b00000000000000000;
uRam[642] = 17'b00000000000000000;
uRam[643] = 17'b00000000000000000;
uRam[644] = 17'b00000000000000000;
uRam[645] = 17'b00000000000000000;
uRam[646] = 17'b00000000000000000;
uRam[647] = 17'b00000000000000000;
uRam[648] = 17'b00000000000000000;
uRam[649] = 17'b00000000000000000;
uRam[650] = 17'b00000000000000000;
uRam[651] = 17'b00000000000000000;
uRam[652] = 17'b00000000000000000;
uRam[653] = 17'b00000000000000000;
uRam[654] = 17'b00000000000000000;
uRam[655] = 17'b00000000000000000;
uRam[656] = 17'b00100101001000000;
uRam[657] = 17'b00101001000010110;
uRam[658] = 17'b00110010000100000;
uRam[659] = 17'b00100011000100000;
uRam[660] = 17'b00100101011000000;
uRam[661] = 17'b00101001011100000;
uRam[662] = 17'b00101011110110000;
uRam[663] = 17'b00101111001000000;
uRam[664] = 17'b00010100000000000;
uRam[665] = 17'b10110100111000001;
uRam[666] = 17'b01110010100100000;
uRam[667] = 17'b10110000110100001;
uRam[668] = 17'b00010100110000000;
uRam[669] = 17'b10110100110100001;
uRam[670] = 17'b01111000110100000;
uRam[671] = 17'b10111110110100001;
uRam[672] = 17'b00000000000000000;
uRam[673] = 17'b00000000000000000;
uRam[674] = 17'b00000000000000000;
uRam[675] = 17'b00000000000000000;
uRam[676] = 17'b00000000000000000;
uRam[677] = 17'b00000000000000000;
uRam[678] = 17'b00000000000000000;
uRam[679] = 17'b00000000000000000;
uRam[680] = 17'b00000000000000000;
uRam[681] = 17'b00000000000000000;
uRam[682] = 17'b00000000000000000;
uRam[683] = 17'b00000000000000000;
uRam[684] = 17'b00000000000000000;
uRam[685] = 17'b00000000000000000;
uRam[686] = 17'b00000000000000000;
uRam[687] = 17'b00000000000000000;
uRam[688] = 17'b00100011010100000;
uRam[689] = 17'b00100111000100000;
uRam[690] = 17'b00000110100000010;
uRam[691] = 17'b10111110000100000;
uRam[692] = 17'b00000100011100000;
uRam[693] = 17'b00110000110000000;
uRam[694] = 17'b00000110110000010;
uRam[695] = 17'b10010001110000000;
uRam[696] = 17'b10110100111000001;
uRam[697] = 17'b10000000000001000;
uRam[698] = 17'b01110000100100000;
uRam[699] = 17'b10110100101000000;
uRam[700] = 17'b10010101110100001;
uRam[701] = 17'b10111110000100000;
uRam[702] = 17'b01101101111100000;
uRam[703] = 17'b10101011101000000;
uRam[704] = 17'b00000000000000000;
uRam[705] = 17'b00000000000000000;
uRam[706] = 17'b00000000000000000;
uRam[707] = 17'b00000000000000000;
uRam[708] = 17'b00000000000000000;
uRam[709] = 17'b00000000000000000;
uRam[710] = 17'b00000000000000000;
uRam[711] = 17'b00000000000000000;
uRam[712] = 17'b00000000000000000;
uRam[713] = 17'b00000000000000000;
uRam[714] = 17'b00000000000000000;
uRam[715] = 17'b00000000000000000;
uRam[716] = 17'b00000000000000000;
uRam[717] = 17'b00000000000000000;
uRam[718] = 17'b00000000000000000;
uRam[719] = 17'b00000000000000000;
uRam[720] = 17'b00101001000010110;
uRam[721] = 17'b10001010011100001;
uRam[722] = 17'b00100001000000110;
uRam[723] = 17'b00101101000000110;
uRam[724] = 17'b00101001011100000;
uRam[725] = 17'b10001010011100001;
uRam[726] = 17'b00110110111000110;
uRam[727] = 17'b00101101010000110;
uRam[728] = 17'b10001100101000001;
uRam[729] = 17'b10110100101000000;
uRam[730] = 17'b10101101101100000;
uRam[731] = 17'b01111110000100001;
uRam[732] = 17'b10100101100100001;
uRam[733] = 17'b10101011101000000;
uRam[734] = 17'b10101011111000000;
uRam[735] = 17'b01100001100100001;
uRam[736] = 17'b00000000000000000;
uRam[737] = 17'b00000000000000000;
uRam[738] = 17'b00000000000000000;
uRam[739] = 17'b00000000000000000;
uRam[740] = 17'b00000000000000000;
uRam[741] = 17'b00000000000000000;
uRam[742] = 17'b00000000000000000;
uRam[743] = 17'b00000000000000000;
uRam[744] = 17'b00000000000000000;
uRam[745] = 17'b00000000000000000;
uRam[746] = 17'b00000000000000000;
uRam[747] = 17'b00000000000000000;
uRam[748] = 17'b00000000000000000;
uRam[749] = 17'b00000000000000000;
uRam[750] = 17'b00000000000000000;
uRam[751] = 17'b00000000000000000;
uRam[752] = 17'b00110010100111010;
uRam[753] = 17'b10001010010100001;
uRam[754] = 17'b10110100100000000;
uRam[755] = 17'b10110100111000001;
uRam[756] = 17'b01110010110111010;
uRam[757] = 17'b10001010010100001;
uRam[758] = 17'b10101011010100000;
uRam[759] = 17'b10110100110100001;
uRam[760] = 17'b10111100100100001;
uRam[761] = 17'b01101111110000000;
uRam[762] = 17'b01000110010000001;
uRam[763] = 17'b10101111111100000;
uRam[764] = 17'b10101011110000001;
uRam[765] = 17'b01100011110000000;
uRam[766] = 17'b01110100100100001;
uRam[767] = 17'b10110000000000000;
uRam[768] = 17'b10011001110000000;
uRam[769] = 17'b00110110000000000;
uRam[770] = 17'b00101111001000000;
uRam[771] = 17'b10111110000100000;
uRam[772] = 17'b00110100111000000;
uRam[773] = 17'b10001100100100000;
uRam[774] = 17'b00000000000000100;
uRam[775] = 17'b00110010000000000;
uRam[776] = 17'b00000100010100110;
uRam[777] = 17'b00111110000100000;
uRam[778] = 17'b00111110000100000;
uRam[779] = 17'b10100111011000000;
uRam[780] = 17'b01110100110000001;
uRam[781] = 17'b01110100100100000;
uRam[782] = 17'b10010101000000000;
uRam[783] = 17'b10110110100000000;
uRam[784] = 17'b00000000000000000;
uRam[785] = 17'b00000000000000000;
uRam[786] = 17'b00000000000000000;
uRam[787] = 17'b00000000000000000;
uRam[788] = 17'b00000000000000000;
uRam[789] = 17'b00000000000000000;
uRam[790] = 17'b00000000000000000;
uRam[791] = 17'b00000000000000000;
uRam[792] = 17'b00000000000000000;
uRam[793] = 17'b00000000000000000;
uRam[794] = 17'b00000000000000000;
uRam[795] = 17'b00000000000000000;
uRam[796] = 17'b00000000000000000;
uRam[797] = 17'b00000000000000000;
uRam[798] = 17'b00000000000000000;
uRam[799] = 17'b00000000000000000;
uRam[800] = 17'b00110110000000000;
uRam[801] = 17'b00010110001100000;
uRam[802] = 17'b00000110010111010;
uRam[803] = 17'b00000110010111010;
uRam[804] = 17'b00110100111000000;
uRam[805] = 17'b10111010010000000;
uRam[806] = 17'b00001110110000000;
uRam[807] = 17'b00000000000000100;
uRam[808] = 17'b10110000110100001;
uRam[809] = 17'b01111010100000000;
uRam[810] = 17'b01010110001100001;
uRam[811] = 17'b10111010110000000;
uRam[812] = 17'b10110000110100000;
uRam[813] = 17'b00100001010001010;
uRam[814] = 17'b01010110001100001;
uRam[815] = 17'b01110000100100000;
uRam[816] = 17'b00000000000000000;
uRam[817] = 17'b00000000000000000;
uRam[818] = 17'b00000000000000000;
uRam[819] = 17'b00000000000000000;
uRam[820] = 17'b00000000000000000;
uRam[821] = 17'b00000000000000000;
uRam[822] = 17'b00000000000000000;
uRam[823] = 17'b00000000000000000;
uRam[824] = 17'b00000000000000000;
uRam[825] = 17'b00000000000000000;
uRam[826] = 17'b00000000000000000;
uRam[827] = 17'b00000000000000000;
uRam[828] = 17'b00000000000000000;
uRam[829] = 17'b00000000000000000;
uRam[830] = 17'b00000000000000000;
uRam[831] = 17'b00000000000000000;
uRam[832] = 17'b00000100111000000;
uRam[833] = 17'b10111000000100001;
uRam[834] = 17'b00000000000000100;
uRam[835] = 17'b00110000010100000;
uRam[836] = 17'b01111110000100000;
uRam[837] = 17'b10111000010100001;
uRam[838] = 17'b00000000000000100;
uRam[839] = 17'b00111000001100000;
uRam[840] = 17'b01111110000100000;
uRam[841] = 17'b10000000000000100;
uRam[842] = 17'b01111100100100000;
uRam[843] = 17'b01000000000000100;
uRam[844] = 17'b00000000000000100;
uRam[845] = 17'b01110100111000000;
uRam[846] = 17'b01111100110100000;
uRam[847] = 17'b01110010100100000;
uRam[848] = 17'b00000000000000000;
uRam[849] = 17'b00000000000000000;
uRam[850] = 17'b00000000000000000;
uRam[851] = 17'b00000000000000000;
uRam[852] = 17'b00000000000000000;
uRam[853] = 17'b00000000000000000;
uRam[854] = 17'b00000000000000000;
uRam[855] = 17'b00000000000000000;
uRam[856] = 17'b00000000000000000;
uRam[857] = 17'b00000000000000000;
uRam[858] = 17'b00000000000000000;
uRam[859] = 17'b00000000000000000;
uRam[860] = 17'b00000000000000000;
uRam[861] = 17'b00000000000000000;
uRam[862] = 17'b00000000000000000;
uRam[863] = 17'b00000000000000000;
uRam[864] = 17'b01001110111100000;
uRam[865] = 17'b00000000000000100;
uRam[866] = 17'b00000000000000100;
uRam[867] = 17'b10110000110100001;
uRam[868] = 17'b00000000000000000;
uRam[869] = 17'b00000000000000000;
uRam[870] = 17'b00000000000000000;
uRam[871] = 17'b01011001100000000;
uRam[872] = 17'b01111010100100001;
uRam[873] = 17'b00000000001001010;
uRam[874] = 17'b10000000000000100;
uRam[875] = 17'b01110010110100000;
uRam[876] = 17'b01110110110100000;
uRam[877] = 17'b01111010110100001;
uRam[878] = 17'b01111110000100000;
uRam[879] = 17'b00000000000000100;
uRam[880] = 17'b00000000000000000;
uRam[881] = 17'b00000000000000000;
uRam[882] = 17'b00000000000000000;
uRam[883] = 17'b00000000000000000;
uRam[884] = 17'b00000000000000000;
uRam[885] = 17'b00000000000000000;
uRam[886] = 17'b00000000000000000;
uRam[887] = 17'b00000000000000000;
uRam[888] = 17'b00000000000000000;
uRam[889] = 17'b00000000000000000;
uRam[890] = 17'b00000000000000000;
uRam[891] = 17'b00000000000000000;
uRam[892] = 17'b00000000000000000;
uRam[893] = 17'b00000000000000000;
uRam[894] = 17'b00000000000000000;
uRam[895] = 17'b00000000000000000;
uRam[896] = 17'b10001100110100111;
uRam[897] = 17'b10111100001000001;
uRam[898] = 17'b10111100001000001;
uRam[899] = 17'b00101101000000110;
uRam[900] = 17'b10001100101100111;
uRam[901] = 17'b10111100011000001;
uRam[902] = 17'b10111100011000001;
uRam[903] = 17'b00101101010000110;
uRam[904] = 17'b10110100101000000;
uRam[905] = 17'b01111110000100000;
uRam[906] = 17'b10110100101000000;
uRam[907] = 17'b10111100100100001;
uRam[908] = 17'b10111110110000000;
uRam[909] = 17'b01000000000000100;
uRam[910] = 17'b10111110110000000;
uRam[911] = 17'b10111000100100001;
uRam[912] = 17'b00000000000000000;
uRam[913] = 17'b00000000000000000;
uRam[914] = 17'b00000000000000000;
uRam[915] = 17'b00000000000000000;
uRam[916] = 17'b00000000000000000;
uRam[917] = 17'b00000000000000000;
uRam[918] = 17'b00000000000000000;
uRam[919] = 17'b00000000000000000;
uRam[920] = 17'b00000000000000000;
uRam[921] = 17'b00000000000000000;
uRam[922] = 17'b00000000000000000;
uRam[923] = 17'b00000000000000000;
uRam[924] = 17'b00000000000000000;
uRam[925] = 17'b00000000000000000;
uRam[926] = 17'b00000000000000000;
uRam[927] = 17'b00000000000000000;
uRam[928] = 17'b10111110000000000;
uRam[929] = 17'b10110010010000001;
uRam[930] = 17'b00111110010000001;
uRam[931] = 17'b00111000001100000;
uRam[932] = 17'b10101001110000000;
uRam[933] = 17'b10110000000100001;
uRam[934] = 17'b00101111100100000;
uRam[935] = 17'b00111000101110000;
uRam[936] = 17'b00110010100111010;
uRam[937] = 17'b01111010101000000;
uRam[938] = 17'b01000110010000001;
uRam[939] = 17'b01000110010000000;
uRam[940] = 17'b01110010110111010;
uRam[941] = 17'b01111010111000000;
uRam[942] = 17'b01110100100100001;
uRam[943] = 17'b01110100100100001;
uRam[944] = 17'b00000000000000000;
uRam[945] = 17'b00000000000000000;
uRam[946] = 17'b00000000000000000;
uRam[947] = 17'b00000000000000000;
uRam[948] = 17'b00000000000000000;
uRam[949] = 17'b00000000000000000;
uRam[950] = 17'b00000000000000000;
uRam[951] = 17'b00000000000000000;
uRam[952] = 17'b00000000000000000;
uRam[953] = 17'b00000000000000000;
uRam[954] = 17'b00000000000000000;
uRam[955] = 17'b00000000000000000;
uRam[956] = 17'b00000000000000000;
uRam[957] = 17'b00000000000000000;
uRam[958] = 17'b00000000000000000;
uRam[959] = 17'b00000000000000000;
uRam[960] = 17'b00101001110100000;
uRam[961] = 17'b10001100100100000;
uRam[962] = 17'b01110010000100000;
uRam[963] = 17'b10110000110100001;
uRam[964] = 17'b00000010000011110;
uRam[965] = 17'b01111000000000000;
uRam[966] = 17'b01000000101000000;
uRam[967] = 17'b10110000010000001;
uRam[968] = 17'b00101101110100000;
uRam[969] = 17'b10111010000000000;
uRam[970] = 17'b01001010001000000;
uRam[971] = 17'b10110110000100001;
uRam[972] = 17'b00000000000000000;
uRam[973] = 17'b00000000000000000;
uRam[974] = 17'b00000000000000000;
uRam[975] = 17'b00000000000000000;
uRam[976] = 17'b00000000000000000;
uRam[977] = 17'b00000000000000000;
uRam[978] = 17'b00000000000000000;
uRam[979] = 17'b00000000000000000;
uRam[980] = 17'b00000000000000000;
uRam[981] = 17'b00000000000000000;
uRam[982] = 17'b00000000000000000;
uRam[983] = 17'b00000000000000000;
uRam[984] = 17'b00000000000000000;
uRam[985] = 17'b00000000000000000;
uRam[986] = 17'b00000000000000000;
uRam[987] = 17'b00000000000000000;
uRam[988] = 17'b00000000000000000;
uRam[989] = 17'b00000000000000000;
uRam[990] = 17'b00000000000000000;
uRam[991] = 17'b00000000000000000;
uRam[992] = 17'b10100111101000000;
uRam[993] = 17'b00000000000000000;
uRam[994] = 17'b10010010000000010;
uRam[995] = 17'b10100111000000001;
uRam[996] = 17'b10100111111000000;
uRam[997] = 17'b00000000000000000;
uRam[998] = 17'b10010010010000010;
uRam[999] = 17'b10001110011100001;
uRam[1000] = 17'b00100011001100000;
uRam[1001] = 17'b00100001001001010;
uRam[1002] = 17'b10010011000000010;
uRam[1003] = 17'b10001010110100001;
uRam[1004] = 17'b01100011011100000;
uRam[1005] = 17'b00100001011001010;
uRam[1006] = 17'b10010011010000010;
uRam[1007] = 17'b10001010100100001;
uRam[1008] = 17'b00000000000000000;
uRam[1009] = 17'b00000000000000000;
uRam[1010] = 17'b00000000000000000;
uRam[1011] = 17'b00000000000000000;
uRam[1012] = 17'b00000000000000000;
uRam[1013] = 17'b00000000000000000;
uRam[1014] = 17'b00000000000000000;
uRam[1015] = 17'b00000000000000000;
uRam[1016] = 17'b00000000000000000;
uRam[1017] = 17'b00000000000000000;
uRam[1018] = 17'b00000000000000000;
uRam[1019] = 17'b00000000000000000;
uRam[1020] = 17'b00000000000000000;
uRam[1021] = 17'b00000000000000000;
uRam[1022] = 17'b00000000000000000;
uRam[1023] = 17'b00000000000000000;
	end
	
	always_ff @( posedge clk) 
		microOutput <= uRam[ microAddr];
endmodule


module nanoRom( input clk, input [NADDR_WIDTH-1:0] nanoAddr, output logic [NANO_WIDTH-1:0] nanoOutput);
	reg [NANO_WIDTH-1:0] nRam[ NANO_DEPTH];		
	initial begin
		nRam[0] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[1] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[2] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[3] = 68'b00000000000000000000000000001000000110011100000000000000101001000001;
nRam[4] = 68'b00100001000000011000010001001000000110100000000001000000011001001001;
nRam[5] = 68'b00000001100000000010100000001000000110000000001001000000001001001001;
nRam[6] = 68'b00100000000000011000010001000000000101000000000010000000100001010000;
nRam[7] = 68'b11000001000000000000000000001000000100010000000001000000000001010001;
nRam[8] = 68'b00100001000000011000010000000000000000000000000101000000000000010000;
nRam[9] = 68'b01000001011000000000100000000110010001000000001100000000110100011000;
nRam[10] = 68'b01000001011000000000100000000110010001000000001100000001100100011000;
nRam[11] = 68'b00100001000000011000010000000000000100000000000001000000000001010000;
nRam[12] = 68'b10100100001000011000001000010000101001110000000001000100110010100001;
nRam[13] = 68'b01000000000000000000000010000000010100000000001000110001000000000000;
nRam[14] = 68'b00100001000000011000000000110010100100011111010001100000000001000000;
nRam[15] = 68'b00100010000000011000000000000000100010000100000000010100000100000011;
nRam[16] = 68'b00000001011000000000000001000110000000000000000010000000000100000000;
nRam[17] = 68'b00000000000000000000000000001000000100000000000001000000000001010001;
nRam[18] = 68'b00000001100000000010100000001000000110000000001001010000001001001001;
nRam[19] = 68'b00101000000000001000010000000000000000000000000010000000000000000000;
nRam[20] = 68'b01100010000000011000010010000000010100000000001000110001000000000000;
nRam[21] = 68'b00000000000000000000000010010010100000000000000100110010000000000000;
nRam[22] = 68'b00100000000000011000010001001000000110000000001001010000001001001001;
nRam[23] = 68'b00000000000000000000001000000000100100000000000000110010000001011000;
nRam[24] = 68'b00010010000000000100100000001000000100000000000010000000000001010001;
nRam[25] = 68'b00100010000000011100000000000000000001100000000010001000100000000000;
nRam[26] = 68'b00010010000000000100000000000000010001100000000010000000000000000000;
nRam[27] = 68'b00000000000000000000000000011001100110100000010001000000011011010001;
nRam[28] = 68'b10100010110000000000000000000000100000010000010010000100000100000000;
nRam[29] = 68'b10000000000000000000000000001000000100010000000001000000000001000001;
nRam[30] = 68'b00100000000000011001000000011010000110000000001001000000001001001001;
nRam[31] = 68'b00010011000000000000101000010000001001000000010101000000100000110000;
nRam[32] = 68'b00000001000000000001010000000000000000000000000101100000000000010000;
nRam[33] = 68'b00100010000000011000001000001000100110000000000001000000000001010001;
nRam[34] = 68'b00000001000000000010100001010000001001000000010110000000100000110000;
nRam[35] = 68'b01000001000000000000000000000000000001101010001100000000110000000000;
nRam[36] = 68'b00110100000000000100000100000000000000000000000010000000000000000000;
nRam[37] = 68'b00000000000100100000100000000000010000000000000000000001000000011000;
nRam[38] = 68'b01110101000000000100100000100010000001100000000000000000110100001010;
nRam[39] = 68'b00100010000000011010000100000000100010000100000000010100000100000011;
nRam[40] = 68'b11000001000000000000000000001000000100010000000001000000000001010001;
nRam[41] = 68'b01010011000000000100100000100010000001100000000000000000110100001010;
nRam[42] = 68'b11000001000000000000000000001001100110110000000001000000011011000001;
nRam[43] = 68'b01001001110000000000001000001000001000000000000101000000000000100001;
nRam[44] = 68'b00000000000000000000100000100010010000000000000000110001000100000010;
nRam[45] = 68'b00010000110000000001010000000000000000011100000010000000000000011000;
nRam[46] = 68'b01010001110000000001000000011010100100000000000001000000000001000001;
nRam[47] = 68'b00000000000000000000000001000000000100000000001100010000000001010000;
nRam[48] = 68'b00001000000000011001001000001000000110100000000001000100000011010001;
nRam[49] = 68'b01010001110000000001010000001000001000000000000101000000000000110001;
nRam[50] = 68'b10100010110100100100000001000000000001110000000010000000110000010000;
nRam[51] = 68'b00000000000100000000000000000010100001001010000101100000100000010000;
nRam[52] = 68'b00010000110000000001000000000000100000000000010010000100000100000000;
nRam[53] = 68'b10000000000000000000000000001000000100010000000001000000000001000001;
nRam[54] = 68'b00000001000000000000000001000000001001000000000101000000100000100000;
nRam[55] = 68'b00010010000000000000100000001010101000000000000101000000000000110001;
nRam[56] = 68'b10100000000100111000000000100001100010111010000101100000011010010010;
nRam[57] = 68'b00100000000000011000000000110010100110000000010000100000001101000010;
nRam[58] = 68'b00010010000000001100000000000000000000000000000010000000000000000000;
nRam[59] = 68'b11000001000000000000001000011101100100010000000001000000000001000001;
nRam[60] = 68'b00010100000000000100000100000000000000000000000010000000000000000000;
nRam[61] = 68'b10100010110000000100001000000000100000010000010010000100000010000000;
nRam[62] = 68'b00100000000100111000000000000000100000010010000101000100000100010010;
nRam[63] = 68'b00100010000000011000000000000000100010000100000000010100000100000011;
nRam[64] = 68'b00100010100000011001010000010000100100000000001110000100001000000000;
nRam[65] = 68'b00000000000100000000000000000010100000001010000101000000000000010000;
nRam[66] = 68'b00100010100000011001000000010010100100000000001110000100001000000000;
nRam[67] = 68'b00000001000000000000010000000000100000000000010101000100000010010000;
nRam[68] = 68'b00000000000100100000000000100010000000000100000000110001000100011010;
nRam[69] = 68'b00100000000000011000000000010000100110000000011000100000001001000000;
nRam[70] = 68'b00000000000100100000100000100010010000000000000000110001000100011010;
nRam[71] = 68'b00000000011000000000000000000110000000000000001110000000110100111000;
nRam[72] = 68'b00011000000000011001001000001000000100000000000001000000000001010001;
nRam[73] = 68'b00100010000000011100000000000000000001100000000010001000100000000000;
nRam[74] = 68'b00110000100000001000000100000000100000000000000010000100000100000000;
nRam[75] = 68'b00000000000100000000000000000010100001000000000101100000100000010000;
nRam[76] = 68'b10100010110000000100001000010001100000010000000010000000000000000000;
nRam[77] = 68'b01000001000000000000000000000000000000000000000101000000000000010000;
nRam[78] = 68'b10000000000000000000000000001000000100010000000001000000000001000001;
nRam[79] = 68'b00000000000000000000000000001000001000000000000101000000000000110001;
nRam[80] = 68'b00001000110000000000001000000000000000000000000010000000000000000000;
nRam[81] = 68'b00010010000000001100000000000000000000000000000010000000000000000000;
nRam[82] = 68'b00010000000000001010000100000000110001000000000010000100011000000000;
nRam[83] = 68'b01010001000000011000001000000000000001100000000000000000110000000000;
nRam[84] = 68'b00001100000000011000001000100001000010100000000101110000000000000011;
nRam[85] = 68'b01000000000000000000000010000000010100000000001000110000000001000000;
nRam[86] = 68'b11000001000000000000000000001000001000010000000101000000000000100001;
nRam[87] = 68'b00000000000000000000000000001000000100011100000001100000000001000001;
nRam[88] = 68'b00000000000000000000000000000000000000000000000101100000000000000000;
nRam[89] = 68'b00000000000100000000000000000000100000000000000101000100000100010000;
nRam[90] = 68'b11101011000000000000000000000000000000010000000010000000000000000000;
nRam[91] = 68'b01100001000000011001000000011010100100000000000001000000000001000001;
nRam[92] = 68'b01100010000000011000010010000000010100000000001000110000000001000000;
nRam[93] = 68'b00000000000000000000000010010010100000000000010100110000000100000000;
nRam[94] = 68'b01000001000000000000010000011001101000000000000101000100001000110001;
nRam[95] = 68'b00100000000100111100000000000000000010000010000100100010001000010000;
nRam[96] = 68'b00010010000000000000000000000010110100000000001110000000000000011000;
nRam[97] = 68'b00000000000000000000001000010000100100000000011100110010000001011000;
nRam[98] = 68'b00000000000100000000000000010000111000000000010101000100011000110000;
nRam[99] = 68'b00000000011000000010100000000110000100000000001101110000000101000000;
nRam[100] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[101] = 68'b00000001000000000000000000000000010101001010001101000000100001010000;
nRam[102] = 68'b00000001000000000000010000000000100000000000000101000100001000010000;
nRam[103] = 68'b01110101000000010000001000000000000001100000000000000000110000000000;
nRam[104] = 68'b01000001000000000000000010000000010100001010001000110001000000000000;
nRam[105] = 68'b00100010000000011000000000011010101010000000010101000000001100110001;
nRam[106] = 68'b00100001000000011000010001010000000100000000010000010000000001010000;
nRam[107] = 68'b01000001000000000000010000000000100000000110000101000000000000010000;
nRam[108] = 68'b01000001000000000000000010000000010100001010001000110001000000000000;
nRam[109] = 68'b00100000000000011000010001010001000000000000011010000000000010001000;
nRam[110] = 68'b00000001000000000000000001010000000100000000010001110000000001000000;
nRam[111] = 68'b00010010000000001000000000011010101000000000000101000000000000110001;
nRam[112] = 68'b00000000000000000000000000001000001000000000000101000000000000110001;
nRam[113] = 68'b00010010000000000001100000000010000000000000000101100000000000000000;
nRam[114] = 68'b00010010000000000001000000000010000100000000000101100000000000000000;
nRam[115] = 68'b00100010000000011100000000001000001000000000000101000000000000100001;
nRam[116] = 68'b00000001000000000001010000000000001010100000000110000000011000101000;
nRam[117] = 68'b00000001100000000000100000000000000000000000000101000000000000010000;
nRam[118] = 68'b00010010000000000000101000001001000100000000001001000000000011010001;
nRam[119] = 68'b11110101001000000100000000000000000000010000000010000000000000000000;
nRam[120] = 68'b00000000000000000000010000001001101000000000000101000010000010110001;
nRam[121] = 68'b00000000000000000000010000000000100000000110000101100000000000000000;
nRam[122] = 68'b00100010100000001001100000000010000010000100001000000000001000001000;
nRam[123] = 68'b00100010100000001001000000000010000110000100001000000000001000001000;
nRam[124] = 68'b00010010000000001000010000000000000000000000001110000000000000011000;
nRam[125] = 68'b00110100000100101100000000000000000001100000000001100000110000010000;
nRam[126] = 68'b01110101000000001000000100000000111000000000010010000100000100000000;
nRam[127] = 68'b01000000000000000000010000010000100110000000011100100000000001011000;
nRam[128] = 68'b11010011000000000000101000001001000100010000001001000000000011010001;
nRam[129] = 68'b11110101001000000000000000000000100000010000000010000100000100000000;
nRam[130] = 68'b01110101000000000100000000000000010000000000010010001000000001000000;
nRam[131] = 68'b01110101000000000000000000000000110000000000010010001100000101000000;
nRam[132] = 68'b01110101000000000000000000000000110000000000010010001100011001000000;
nRam[133] = 68'b01110000000000011100000000000000000001100000001101000000110000000000;
nRam[134] = 68'b00010000000000001000000000000010100000000000000010000000000000000000;
nRam[135] = 68'b00010010000000000100000100000000010001000000000010000000000000000000;
nRam[136] = 68'b01000000000000000000010000010000100110000000011100100010001001011000;
nRam[137] = 68'b00100000000000011000010000000000000100000000000000100000000001000000;
nRam[138] = 68'b00000001000000000000000000000000001000000000000101000000000000110000;
nRam[139] = 68'b00100001000000011100000001011001000110000000011000000000001011001001;
nRam[140] = 68'b01100001000000011000000000010010100110000000011100100000001101011000;
nRam[141] = 68'b01100001000000011000010000010010000010000000010101000000001100010000;
nRam[142] = 68'b00000000000000000000000100000000010010100000001100110001011000011000;
nRam[143] = 68'b01100001000000011000000000010000100110000000011000100000001001000000;
nRam[144] = 68'b00000000000000000000000000001000000100011100000001100000000001000001;
nRam[145] = 68'b00010010000000000000000000010010110110000000001110000010001000011000;
nRam[146] = 68'b01000001000000000000100000010010010000000000010000110001000100011000;
nRam[147] = 68'b00010010000000000000010000010000110110000000001110000010001000011000;
nRam[148] = 68'b01000001000000000000000010000000010100001010001000110000000001000000;
nRam[149] = 68'b01000001000000000000010000001000101000000110000101000000000000110001;
nRam[150] = 68'b00000001000000000000010000000000100000000000000101000100001000010000;
nRam[151] = 68'b00101000000000001000010000000000000000000000000010000000000000000000;
nRam[152] = 68'b00100010000000011000000000000000100000000000000010000100011000000000;
nRam[153] = 68'b00100010001000011010000000000000100000000000000010000100000100000000;
nRam[154] = 68'b11010011001000000100000000010000011000010000000010000000000000000000;
nRam[155] = 68'b00010010000000000100000000000000010000000000010010001000000001000000;
nRam[156] = 68'b00001000000000011000001000000000000000000000000101110000000000000011;
nRam[157] = 68'b00100010110000000000010000001000001000000000000101000000000000110001;
nRam[158] = 68'b00100010000000011000000000000000100010100000000010000000000000000000;
nRam[159] = 68'b00100000000000011000000000110001100100011111011001100000000011000010;
nRam[160] = 68'b00100000000000011000000000001000100110000000001001010000001001000001;
nRam[161] = 68'b01000001000000000000000000010000000100000000011100100000000001011000;
nRam[162] = 68'b00000000100000000010100000000000000001000000000101000000100000010000;
nRam[163] = 68'b00000001000000000000000000011001000100000000011001000000000011000001;
nRam[164] = 68'b00000000011000000010100001000110000101000000000000010000100101010000;
nRam[165] = 68'b00100001000000011100000001011001000100000000011001000000000011000001;
nRam[166] = 68'b01000000000000000000000000000000000101001010001101100000100001000000;
nRam[167] = 68'b00000000000100000000000000000000100001001010000101100100100100010000;
nRam[168] = 68'b00000000011000000000000000000010110110000000001100000000001101011000;
nRam[169] = 68'b01000001000000000000000000000001111001100000001010000000110010100000;
nRam[170] = 68'b00110010000000011000000000010010100010000000001110000010001000011000;
nRam[171] = 68'b11000001000000000000000000011001100110110000010001000000011011000001;
nRam[172] = 68'b00100000000000011010000000100001110000001100001010000000000010000010;
nRam[173] = 68'b00000000000000000000000000010000000100010101010001100000000001000000;
nRam[174] = 68'b01000000000000000000000000000000000010100000000010000000011000001000;
nRam[175] = 68'b00000001000000000000000000000000000001101010001101000000110000010000;
nRam[176] = 68'b10000000000000000000001000001101100100010000000001000000000001000001;
nRam[177] = 68'b01110101000000000000000000000000110000000000000010001100000101000000;
nRam[178] = 68'b11000001000000000000000000001000000100010000000001000000000001000001;
nRam[179] = 68'b00100010000000011000000000001001101000000010000101000010000010110001;
nRam[180] = 68'b00100010000100011000000000010010100000000000000101000000000000010000;
nRam[181] = 68'b11100101000000011100000000001001000100010000001001000000000011010001;
nRam[182] = 68'b00100100000100111000000000000000100000000000010101100100000100010000;
nRam[183] = 68'b00100010000100011000000000011010100100000000000000000000000001011001;
nRam[184] = 68'b00100000000000001000001000000000100000000000000010000100000010000000;
nRam[185] = 68'b00100010000000011100001000001000100100000000000001000100001001010001;
nRam[186] = 68'b00010010000000000100000100000000010001000000000010000000000000000000;
nRam[187] = 68'b10000000000000000000001000011101000100010000000001000000000001000001;
nRam[188] = 68'b00011000000000011000001000000000100010000000000010000000000000000000;
nRam[189] = 68'b01000000000000000000000000000000000100000000000001000000000001010000;
nRam[190] = 68'b01000000000000000000010000010000100110000000011100100000011001001000;
nRam[191] = 68'b00000000001000000010001000010001010000000000000010001000000000100000;
nRam[192] = 68'b11100101000000011100000000001000001000010000000101000000000000110001;
nRam[193] = 68'b01000001000000000000001000010001100000000000000010000000000000000000;
nRam[194] = 68'b00110100000000000000000000000000110000000000000010001100000101000000;
nRam[195] = 68'b10000000000000000000001000001000100100010000010001000100000011000001;
nRam[196] = 68'b01110101000000000100001000000001110000000000010010001000000001000000;
nRam[197] = 68'b10000000000000000000001000001000100100010000000001000100000011000001;
nRam[198] = 68'b00110100000000000000000000000000110000000000010010001100000101000000;
nRam[199] = 68'b00110100000000000000000000000000110000000000010010001100011001000000;
nRam[200] = 68'b01000000000000000000000000010000000110100000011100100000011001001000;
nRam[201] = 68'b00000000000100000000000000010000111000000000010101000100000100110010;
nRam[202] = 68'b00000000000100000000000000100010100001100000000001000000110000011000;
nRam[203] = 68'b01000000000000000000000000010010000110000000010000100000001101001000;
nRam[204] = 68'b00000000000000000000000000001000000110000000001001000000001001001001;
nRam[205] = 68'b01000000000000000000010000000001100000000000000101000010000010010000;
nRam[206] = 68'b01000000000000000000000000001000000110000000001001010000001001000001;
nRam[207] = 68'b00000001000000000000000000000000000001101010001101000000110000000000;
nRam[208] = 68'b11100101000000011000000000010000111001110000010010000100110100100000;
nRam[209] = 68'b00000000000000000000000000011010101010000000000101000010001000110001;
nRam[210] = 68'b11000001000000000000001000001101100100010000000001000000000001000001;
nRam[211] = 68'b00000000000000000000000100000000010000000000000001100001000000000000;
nRam[212] = 68'b00000000000000000000000000001001100100000000001001000000000011010001;
nRam[213] = 68'b11000001000000000000010000010001100000010000010010000000011010000000;
nRam[214] = 68'b00000000000000000000000000000000000000010110000010000000000000000000;
nRam[215] = 68'b00000000000000000000000000000000000000001100000000000001000000000000;
nRam[216] = 68'b00100010000000011000000000000000100010100000000010000000000000000000;
nRam[217] = 68'b00001000000000011000001000000000000000000000000101110000000000000011;
nRam[218] = 68'b10000000000000000000000000000000000000010000000010000000000000000000;
nRam[219] = 68'b00000000000000000000010000000000100010000000000010000010001000000000;
nRam[220] = 68'b00101000000000001000001000000000000000000000000010000000000000000000;
nRam[221] = 68'b01010011000000000000100000000010100001100000001100000000110000011000;
nRam[222] = 68'b00000001000010000000000001000000000000000000000101000000000000010000;
nRam[223] = 68'b00100010000000011000010000001101101000000000000101000000000000110001;
nRam[224] = 68'b00000000000000000000100000010010010000000000010000110001000100000000;
nRam[225] = 68'b01000000000000000000000000010000000100000000011100100000000001000000;
nRam[226] = 68'b00000000000000000000000100010010010000000000010000110001000100000000;
nRam[227] = 68'b01000000000000000000100000000000010000000000000001000000110000010000;
nRam[228] = 68'b01010011000000001000010000000000000001100000001100000000110000011000;
nRam[229] = 68'b01000001000000000000010000001001101000000000000101000000000000110001;
nRam[230] = 68'b00100100000100011001000000000000100000000000010101000100000100010000;
nRam[231] = 68'b01100010000000011000100000010010110010000000001100000000110000011000;
nRam[232] = 68'b00011000000000011000001000000000000000000000000101110000000000000011;
nRam[233] = 68'b00000000000000000000000000001000000100000000000001000000000001010001;
nRam[234] = 68'b00010010000000000100000100000000010001000000000010000000000000000000;
nRam[235] = 68'b00001010000000011000001000000000000000000000000101110000000000000011;
nRam[236] = 68'b00010010000000000000000000000001110100000010001110000010000010011000;
nRam[237] = 68'b01100010000000011000100000010010110010000000001100000001000000011000;
nRam[238] = 68'b01000000000000000000100000000010010000000000001100110001000100011000;
nRam[239] = 68'b00100010000100011000000001011010100100000000000001000000000001011001;
nRam[240] = 68'b00000001000000000000010000000001100001001010000101000000100000010000;
nRam[241] = 68'b00000000000000000000010000000000100101000110001110000000100001011000;
nRam[242] = 68'b00000000000000000000100000010010010000000000010000110001000100011000;
nRam[243] = 68'b01010011000000000000100000000001100001100010001100000010110010011000;
nRam[244] = 68'b01100011000000011000000000010010100100000000011101110000000001011000;
nRam[245] = 68'b00000000000100000001000000010000100100000000011101000100000101010000;
nRam[246] = 68'b00100010000100011000000001010010100100000000011100010000000001010000;
nRam[247] = 68'b00000001000000000000010000000000100000000001000101000100000010010000;
nRam[248] = 68'b00000001000000000000010000000001100000001111000101000000000000010000;
nRam[249] = 68'b00000000000000000000000000010010100000000110010101100000000100000000;
nRam[250] = 68'b00000111000000000000010000010000111000001000010110000100001000100000;
nRam[251] = 68'b01000000000000000000100000000001110000000000001001000000110010010000;
nRam[252] = 68'b01001011000000011000001000000000000001100000000000000000110000000000;
nRam[253] = 68'b00000000000000000000010000000000100010000000000101000000000000010000;
nRam[254] = 68'b10100100000000011100000000001000000100010000000001000000000001000001;
nRam[255] = 68'b00010000000000000000000000010000100100000010000010000000000000000000;
nRam[256] = 68'b00000000000000000000000000001000000100000010000000110010000001000001;
nRam[257] = 68'b01000000000000000000000000001001100100000000001001010000000011000001;
nRam[258] = 68'b00000000000000000000000000001001100100000000001001010000000011000001;
nRam[259] = 68'b00100000000000011000000000010010100010000000010101000000001100010000;
nRam[260] = 68'b00000000000100000000000000000000101000000000000101000100011000110000;
nRam[261] = 68'b00000000000100100000100000010010010000000000010000110001000100011000;
nRam[262] = 68'b01000000000000000000010000010001100000000000010101000010000010010000;
nRam[263] = 68'b00100001000000011100010100000000110010000000001110001000100000011000;
nRam[264] = 68'b00000000000000000000001000000000100000000110000101000000000000000000;
nRam[265] = 68'b00000110000000000000000000000000000000001000000010000000000000000000;
nRam[266] = 68'b01000000000000000000010000000000100100001010001100110010000001000000;
nRam[267] = 68'b01000000000000000000000000000000000100001010001100000000000001000000;
nRam[268] = 68'b01100001000000011000000000000000100001100010000000000000110000000000;
nRam[269] = 68'b01000001000000000000010000000000100000000110000101010000000000010000;
nRam[270] = 68'b00101000000000001000010000001000101010000000000101100000000000100001;
nRam[271] = 68'b10000110000000000000000000001000001000001000000101100000000000100001;
nRam[272] = 68'b00000000000000000000000000001000000100000000000001000000000001010001;
nRam[273] = 68'b00100010000100111000100000000000110010100000000001000000110000010000;
nRam[274] = 68'b00100100000100111100000000001000000100000000000001000000000001011001;
nRam[275] = 68'b00100011000000011000010100000000010000000000001110001000100000011000;
nRam[276] = 68'b00000000000000000000000000011001100110100000010001000000011011010001;
nRam[277] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[278] = 68'b00000000000100100000010001001000100100000000000001000000011001001001;
nRam[279] = 68'b00100100001000111100001000000000100010000000000101000000000000010000;
nRam[280] = 68'b01000001000000000000000000010001100000000010000010000000000000000000;
nRam[281] = 68'b00100010000000011010000000000000110100000000011110001100100100011000;
nRam[282] = 68'b11100101000000011100000100000000001000010000010101000000011010000000;
nRam[283] = 68'b00010000000000000000100000000000100001100010001100000000110000000000;
nRam[284] = 68'b00100010000100111000010001001000000100000000000000000000000001011001;
nRam[285] = 68'b00010000000000000010000000000000100100000010001110000000000000011000;
nRam[286] = 68'b11100011000000011100001000010101100000010000000101000000000000000000;
nRam[287] = 68'b00100000000000011000000000110010100100011111010001100000000001000000;
nRam[288] = 68'b10000000000100000000000000001000100110110000000001000000000001011001;
nRam[289] = 68'b11000001000000000000000000001001000100010000001001000000000011010001;
nRam[290] = 68'b00100100000100111100000000000000000000000000000101100000000000010000;
nRam[291] = 68'b10000000000100100000000001001001000100010000001001000000000011001001;
nRam[292] = 68'b11000001000000000000000000000000000000010000000010000000000000000000;
nRam[293] = 68'b00110100001100100000000000000000100000000000000101100100000100010000;
nRam[294] = 68'b00000001000001000000000001000000000000000000000101000000000000010000;
nRam[295] = 68'b00000001000010000000010001000000100000000000000101000100000010010000;
nRam[296] = 68'b00100000000100111000000000010000101000010111010101000100000100110010;
nRam[297] = 68'b11100101000000011100000000000000000000010000000010000000000000000000;
nRam[298] = 68'b11100101000000011000000000000000100000010000010010000100000100000000;
nRam[299] = 68'b00000000000000000000000000001000001000000000000101000000000000110001;
nRam[300] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[301] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[302] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[303] = 68'b00000001000000000000000000001000001001100000000001000000110000110001;
nRam[304] = 68'b00000001000001000000000001001000000100000000000001010000000001011001;
nRam[305] = 68'b00100000000000001000001000000000100000000000000010000100000010000000;
nRam[306] = 68'b11000001000000000000010000001001001000010000000101000000000000110001;
nRam[307] = 68'b00000000000110000000000001000000100000000000000101000100000100010000;
nRam[308] = 68'b00000000000101000000000001000000100000000000000101000100000100010000;
nRam[309] = 68'b00000000000010100000000001010000000100000000000101000000000000010000;
nRam[310] = 68'b00000000000101000000000001001010000100000000000001010000000001011001;
nRam[311] = 68'b11100101001000011100000000000000010000010000010010001000000000100000;
nRam[312] = 68'b00100000000000001000000000001000001000000000000110000000000000110001;
nRam[313] = 68'b00100000000000011000000000000000100000000100011100000101000100011000;
nRam[314] = 68'b00100000000000011000000000010000110100000000011100000101000100011000;
nRam[315] = 68'b01100011100000011000000100010010000000000000000101110000000000000011;
nRam[316] = 68'b01100010000000011000010100000000010000000000001100000001000000011000;
nRam[317] = 68'b10000000000100100000000001001000000100010000000001000000000001011001;
nRam[318] = 68'b01100010000000011000010100000010010000000000001100110001000100011000;
nRam[319] = 68'b01100011000000011000010000010000000100000000011101110000000001011000;
nRam[320] = 68'b00000000000000000000010000000000100000000110000101000000000000010000;
nRam[321] = 68'b00000000000000000000000000000000000000011100001110000000000000011000;
nRam[322] = 68'b10100000000000001000010000001000101000000110000101000000000000100001;
nRam[323] = 68'b00100000000000011000000000110001100100001111011001100000000011000010;
nRam[324] = 68'b00000001000000000000010000000001100001001010000101000010100010010000;
nRam[325] = 68'b00100010001000111000010000010000000100000000011101000000000001010000;
nRam[326] = 68'b00100100000100111100000000000000000000000000000101000000000000010000;
nRam[327] = 68'b00100010000100011000010001010000000100000000011100010000000001010000;
nRam[328] = 68'b01000001000000000000000100010000011000000000000010000000000000000000;
nRam[329] = 68'b00000000000000000000010000000000100010000000000101000010001000010000;
nRam[330] = 68'b00100000000100111000000000000000100000000010000100100000000000010000;
nRam[331] = 68'b00100010000000011000010000001000001000000000000101000000000000110001;
nRam[332] = 68'b00000001000000000000010000000000100000000000000101000100000010010000;
nRam[333] = 68'b00000000000000000000000000000000000000000000000010000000000000000000;
nRam[334] = 68'b00000000000000000000001000000000100100000000000000110010000001011000;
nRam[335] = 68'b00000000011000000000000000000010110110000000001100000000001101011000;
	end
	
	always_ff @( posedge clk) 
		nanoOutput <= nRam[ nanoAddr];
endmodule

// Translate uaddr to nanoaddr
module microToNanoAddr(
	input [UADDR_WIDTH-1:0] uAddr,
	output [NADDR_WIDTH-1:0] orgAddr);

	wire [UADDR_WIDTH-1:2] baseAddr = uAddr[UADDR_WIDTH-1:2];
	logic [NADDR_WIDTH-1:2] orgBase;
	assign orgAddr = { orgBase, uAddr[1:0]};

	always @( baseAddr)
	begin
		// nano ROM (136 addresses)
		case( baseAddr)

'h00: orgBase = 7'h0 ;
'h01: orgBase = 7'h1 ;
'h02: orgBase = 7'h2 ;
'h03: orgBase = 7'h2 ;
'h08: orgBase = 7'h3 ;
'h09: orgBase = 7'h4 ;
'h0A: orgBase = 7'h5 ;
'h0B: orgBase = 7'h5 ;
'h10: orgBase = 7'h6 ;
'h11: orgBase = 7'h7 ;
'h12: orgBase = 7'h8 ;
'h13: orgBase = 7'h8 ;
'h18: orgBase = 7'h9 ;
'h19: orgBase = 7'hA ;
'h1A: orgBase = 7'hB ;
'h1B: orgBase = 7'hB ;
'h20: orgBase = 7'hC ;
'h21: orgBase = 7'hD ;
'h22: orgBase = 7'hE ;
'h23: orgBase = 7'hD ;
'h28: orgBase = 7'hF ;
'h29: orgBase = 7'h10 ;
'h2A: orgBase = 7'h11 ;
'h2B: orgBase = 7'h10 ;
'h30: orgBase = 7'h12 ;
'h31: orgBase = 7'h13 ;
'h32: orgBase = 7'h14 ;
'h33: orgBase = 7'h14 ;
'h38: orgBase = 7'h15 ;
'h39: orgBase = 7'h16 ;
'h3A: orgBase = 7'h17 ;
'h3B: orgBase = 7'h17 ;
'h40: orgBase = 7'h18 ;
'h41: orgBase = 7'h18 ;
'h42: orgBase = 7'h18 ;
'h43: orgBase = 7'h18 ;
'h44: orgBase = 7'h19 ;
'h45: orgBase = 7'h19 ;
'h46: orgBase = 7'h19 ;
'h47: orgBase = 7'h19 ;
'h48: orgBase = 7'h1A ;
'h49: orgBase = 7'h1A ;
'h4A: orgBase = 7'h1A ;
'h4B: orgBase = 7'h1A ;
'h4C: orgBase = 7'h1B ;
'h4D: orgBase = 7'h1B ;
'h4E: orgBase = 7'h1B ;
'h4F: orgBase = 7'h1B ;
'h54: orgBase = 7'h1C ;
'h55: orgBase = 7'h1D ;
'h56: orgBase = 7'h1E ;
'h57: orgBase = 7'h1F ;
'h5C: orgBase = 7'h20 ;
'h5D: orgBase = 7'h21 ;
'h5E: orgBase = 7'h22 ;
'h5F: orgBase = 7'h23 ;
'h70: orgBase = 7'h24 ;
'h71: orgBase = 7'h24 ;
'h72: orgBase = 7'h24 ;
'h73: orgBase = 7'h24 ;
'h74: orgBase = 7'h24 ;
'h75: orgBase = 7'h24 ;
'h76: orgBase = 7'h24 ;
'h77: orgBase = 7'h24 ;
'h78: orgBase = 7'h25 ;
'h79: orgBase = 7'h25 ;
'h7A: orgBase = 7'h25 ;
'h7B: orgBase = 7'h25 ;
'h7C: orgBase = 7'h25 ;
'h7D: orgBase = 7'h25 ;
'h7E: orgBase = 7'h25 ;
'h7F: orgBase = 7'h25 ;
'h84: orgBase = 7'h26 ;
'h85: orgBase = 7'h27 ;
'h86: orgBase = 7'h28 ;
'h87: orgBase = 7'h29 ;
'h8C: orgBase = 7'h2A ;
'h8D: orgBase = 7'h2B ;
'h8E: orgBase = 7'h2C ;
'h8F: orgBase = 7'h2D ;
'h94: orgBase = 7'h2E ;
'h95: orgBase = 7'h2F ;
'h96: orgBase = 7'h30 ;
'h97: orgBase = 7'h31 ;
'h9C: orgBase = 7'h32 ;
'h9D: orgBase = 7'h33 ;
'h9E: orgBase = 7'h34 ;
'h9F: orgBase = 7'h35 ;
'hA4: orgBase = 7'h36 ;
'hA5: orgBase = 7'h36 ;
'hA6: orgBase = 7'h37 ;
'hA7: orgBase = 7'h37 ;
'hAC: orgBase = 7'h38 ;
'hAD: orgBase = 7'h38 ;
'hAE: orgBase = 7'h39 ;
'hAF: orgBase = 7'h39 ;
'hB4: orgBase = 7'h3A ;
'hB5: orgBase = 7'h3A ;
'hB6: orgBase = 7'h3B ;
'hB7: orgBase = 7'h3B ;
'hBC: orgBase = 7'h3C ;
'hBD: orgBase = 7'h3C ;
'hBE: orgBase = 7'h3D ;
'hBF: orgBase = 7'h3D ;
'hC0: orgBase = 7'h3E ;
'hC1: orgBase = 7'h3F ;
'hC2: orgBase = 7'h40 ;
'hC3: orgBase = 7'h41 ;
'hC8: orgBase = 7'h42 ;
'hC9: orgBase = 7'h43 ;
'hCA: orgBase = 7'h44 ;
'hCB: orgBase = 7'h45 ;
'hD0: orgBase = 7'h46 ;
'hD1: orgBase = 7'h47 ;
'hD2: orgBase = 7'h48 ;
'hD3: orgBase = 7'h49 ;
'hD8: orgBase = 7'h4A ;
'hD9: orgBase = 7'h4B ;
'hDA: orgBase = 7'h4C ;
'hDB: orgBase = 7'h4D ;
'hE0: orgBase = 7'h4E ;
'hE1: orgBase = 7'h4E ;
'hE2: orgBase = 7'h4F ;
'hE3: orgBase = 7'h4F ;
'hE8: orgBase = 7'h50 ;
'hE9: orgBase = 7'h50 ;
'hEA: orgBase = 7'h51 ;
'hEB: orgBase = 7'h51 ;
'hF0: orgBase = 7'h52 ;
'hF1: orgBase = 7'h52 ;
'hF2: orgBase = 7'h52 ;
'hF3: orgBase = 7'h52 ;
'hF8: orgBase = 7'h53 ;
'hF9: orgBase = 7'h53 ;
'hFA: orgBase = 7'h53 ;
'hFB: orgBase = 7'h53 ;

			default:
				orgBase = 'X;
		endcase
	end

endmodule

//
// For compilation test only
//


//
// FX 68K
//
// M68K cycle accurate, fully synchronous
// Copyright (c) 2018 by Jorge Cwik
//
// ALU
//

// altera message_off 10230
// altera message_off 10763
// altera message_off 10958

`timescale 1 ns / 1 ns

localparam MASK_NBITS = 5;

localparam
		OP_AND = 1,
		OP_SUB = 2, OP_SUBX = 3, OP_ADD = 4,
		OP_EXT = 5, OP_SBCD = 6, OP_SUB0 = 7,
		OP_OR = 8, OP_EOR = 9,
		OP_SUBC = 10, OP_ADDC = 11, OP_ADDX = 12,
		OP_ASL = 13,
		OP_ASR = 14,
		OP_LSL = 15,
		OP_LSR = 16,
		OP_ROL = 17,
		OP_ROR = 18,
		OP_ROXL = 19,
		OP_ROXR = 20,
		OP_SLAA = 21,
		OP_ABCD = 22;

module fx68kAlu ( input clk, pwrUp, enT1, enT3, enT4,
	input [15:0] ird,
	input [2:0] aluColumn,
	input [1:0] aluDataCtrl,
	input aluAddrCtrl, alueClkEn, ftu2Ccr, init, finish, aluIsByte,
	input [15:0] ftu,
	input [15:0] alub,
	input [15:0] iDataBus, input [15:0] iAddrBus,
	output ze,
	output reg [15:0] alue,
	output reg [7:0] ccr,
	output [15:0] aluOut);















	
	
	// Bit positions for flags in CCR
	localparam CF = 0, VF = 1, ZF = 2, NF = 3, XF = 4;

	reg [15:0] aluLatch;
	reg [4:0] pswCcr;
	reg [4:0] ccrCore;
	
	logic [15:0] result;
	logic [4:0] ccrTemp;
	reg coreH;		// half carry latch

	logic [15:0] subResult;
	logic subHcarry;
	logic subCout, subOv;

	assign aluOut = aluLatch;
	assign ze = ~ccrCore[ ZF];		// Check polarity !!!

	//
	// Control
	//	Signals derived from IRD *must* be registered on either T3 or T4
	//  Signals derived from nano rom can be registered on T4.

	reg [15:0] row;
	reg isArX;									// Don't set Z
	reg noCcrEn;
	reg isByte;
	
	reg [4:0] ccrMask;
	reg [4:0] oper;
	
	logic [15:0] aOperand, dOperand;
	wire isCorf = ( aluDataCtrl == 2'b10);

	wire [15:0] cRow;
	wire cIsArX;
	wire cNoCcrEn;
	rowDecoder rowDecoder( .ird( ird), .row( cRow), .noCcrEn( cNoCcrEn), .isArX( cIsArX));
	
	// Get Operation & CCR Mask from row/col
	// Registering them on T4 increase performance. But slowest part seems to be corf !
	wire [4:0] cMask;
	wire [4:0] aluOp;

	aluGetOp aluGetOp( .row, .col( aluColumn), .isCorf, .aluOp);	
	ccrTable ccrTable( .col( aluColumn), .row( row), .finish, .ccrMask( cMask));

	// Inefficient, uCode could help !
	wire shftIsMul = row[7];
	wire shftIsDiv = row[1];

	wire [31:0] shftResult;
	reg [7:0] bcdLatch;
	reg bcdCarry, bcdOverf;
		
	reg isLong;
	reg rIrd8;
	logic isShift;
	logic shftCin, shftRight, addCin;
	
	// Register some decoded signals	
	always_ff @( posedge clk) begin
		if( enT3) begin
			row <= cRow;
			isArX <= cIsArX;
			noCcrEn <= cNoCcrEn;
			rIrd8 <= ird[8];
			isByte <= aluIsByte;
		end
		
		if( enT4) begin
			// Decode if long shift
			// MUL and DIV are long (but special !)
			isLong <= (ird[7] & ~ird[6]) | shftIsMul | shftIsDiv;			
			
			ccrMask <= cMask;
			oper <= aluOp;
		end
	end
	
	
	always_comb begin
		// Dest (addr) operand source
		// If aluCsr (depends on column/row) addrbus is shifted !!
		aOperand = (aluAddrCtrl ? alub : iAddrBus);
		
		// Second (data,source) operand mux
		case( aluDataCtrl)
			2'b00:				dOperand = iDataBus;
			2'b01:				dOperand = 'h0000;
			2'b11:				dOperand = 'hffff;
			// 2'b10:				dOperand = bcdResult;
			2'b10:				dOperand = 'X;
		endcase
	end
	
	// Execution
	   
	// shift operand MSB. Input in ASR/ROL. Carry in right.
	// Can't be registered because uses bus operands that aren't available early !
	wire shftMsb = isLong ? alue[15] : (isByte ? aOperand[7] : aOperand[15]);
	   
	aluShifter shifter( .data( { alue, aOperand}),
		.swapWords( shftIsMul | shftIsDiv),
		.cin( shftCin), .dir( shftRight), .isByte( isByte), .isLong( isLong),
		.result( shftResult));
				
	wire [7:0] bcdResult;
	wire bcdC, bcdV;
	aluCorf aluCorf( .binResult( aluLatch[7:0]), .hCarry( coreH),
		.bAdd( (oper != OP_SBCD) ), .cin( pswCcr[ XF]),
		.bcdResult( bcdResult), .dC( bcdC), .ov( bcdV));

	// BCD adjust is among the slowest processing on ALU !
	// Precompute and register BCD result on T1
	// We don't need to wait for execution buses because corf is always added to ALU previous result
	always_ff @( posedge clk)
		if( enT1) begin
			bcdLatch <= bcdResult;
			bcdCarry <= bcdC;
			bcdOverf <= bcdV;
		end
		
	// Adder carry in selector
	always_comb
	begin
		case( oper)
			OP_ADD, OP_SUB:   addCin = 1'b0;
			OP_SUB0:          addCin = 1'b1;			// NOT = 0 - op - 1
			OP_ADDC,OP_SUBC:  addCin = ccrCore[ CF];
			OP_ADDX,OP_SUBX:  addCin = pswCcr[ XF];
			default: addCin = 1'bX;
		endcase
	end
   	
	// Shifter carry in and direction selector
	always_comb begin
		case( oper)
		OP_LSL, OP_ASL, OP_ROL, OP_ROXL, OP_SLAA:   shftRight = 1'b0;
		OP_LSR, OP_ASR, OP_ROR, OP_ROXR:            shftRight = 1'b1;
		default:									shftRight = 1'bX;
		endcase
		
		case( oper)
		OP_LSR,
		OP_ASL,
		OP_LSL:		shftCin = 1'b0;
		OP_ROL,
		OP_ASR:		shftCin = shftMsb;
		OP_ROR:		shftCin = aOperand[0];
		OP_ROXL,
		OP_ROXR:
			if( shftIsMul)
				shftCin = rIrd8 ? pswCcr[NF] ^ pswCcr[VF] : pswCcr[ CF];
			else
				shftCin = pswCcr[ XF];
				
		OP_SLAA:	shftCin = aluColumn[1];   // col4 -> 0, col 6-> 1
		default:	shftCin = 'X;
		endcase
	end
	
	// ALU operation selector
	always_comb begin	      

		// sub is DATA - ADDR	    
		mySubber( aOperand, dOperand, addCin,
			(oper == OP_ADD) | (oper == OP_ADDC) | (oper == OP_ADDX),
			isByte, subResult, subCout, subOv);
			
		isShift = 1'b0;
		case( oper)
		OP_AND: result = aOperand & dOperand;
		OP_OR:  result = aOperand | dOperand;
		OP_EOR: result = aOperand ^ dOperand;
		
		OP_EXT: result = { {8{aOperand[7]}}, aOperand[7:0]};
		
		OP_SLAA,
		OP_ASL, OP_ASR,
		OP_LSL, OP_LSR,
		OP_ROL, OP_ROR,
		OP_ROXL, OP_ROXR:
			begin
				result = shftResult[15:0];
				isShift = 1'b1;
			end
			
		OP_ADD,
		OP_ADDC,
		OP_ADDX,
		OP_SUB,
		OP_SUBC,
		OP_SUB0,
		OP_SUBX:	result = subResult;
		
		OP_ABCD,
		OP_SBCD:	result = { 8'hXX, bcdLatch};

		default:	result = 'X;
		endcase	   
	end
	
	task mySubber;
		input [15:0] inpa, inpb;
		input cin, bAdd, isByte;
		output reg [15:0] result;
		output cout, ov;

		// Not very efficient!
		logic [16:0] rtemp;
		logic rm,sm,dm,tsm;

		begin
			if( isByte)
			begin
				rtemp = bAdd ? { 1'b0, inpb[7:0]} + { 1'b0, inpa[7:0]} + cin:
								{ 1'b0, inpb[7:0] } - { 1'b0, inpa[7:0]} - cin;
				result = { {8{ rtemp[7]}}, rtemp[7:0]};
				cout = rtemp[8];
			end
			else begin
				rtemp = bAdd ? { 1'b0, inpb } + { 1'b0, inpa} + cin:
								{ 1'b0, inpb } - { 1'b0, inpa} - cin;
				result = rtemp[ 15:0];
				cout = rtemp[16];
			end
	        
			rm  = isByte ? rtemp[7] : rtemp[15];
			dm  = isByte ? inpb[ 7] : inpb[ 15];
			tsm = isByte ? inpa[ 7] : inpa[ 15];
			sm  = bAdd ? tsm : ~tsm;

			ov = (sm & dm & ~rm) | (~sm & ~dm & rm);
			
			// Store half carry for bcd correction
			subHcarry = inpa[4] ^ inpb[4] ^ rtemp[4];
		
		end
	endtask
	
	
	// CCR flags process
	always_comb begin
		
		ccrTemp[XF] = pswCcr[XF];     ccrTemp[CF] = 0;     ccrTemp[VF] = 0;	

		// Not on all operators
		ccrTemp[ ZF] = isByte ? ~(| result[7:0]) : ~(| result);
		ccrTemp[ NF] = isByte ? result[7] : result[15];

		unique case( oper)
		
		OP_EXT:
			// Division overflow.
			if( aluColumn == 5) begin
				ccrTemp[VF] = 1'b1;
				ccrTemp[NF] = 1'b1;				ccrTemp[ ZF] = 1'b0;
			end

		OP_SUB0,				// used by NOT
		OP_OR,
		OP_EOR:
			begin
				ccrTemp[CF] = 0;      ccrTemp[VF] = 0;
			end

		OP_AND:
			begin
				// ROXL/ROXR indeed copy X to C in column 1 (OP_AND), executed before entering the loop.
				// Needed when rotate count is zero, the ucode with the ROX operator never reached.
				// 	C must be set to the value of X, X remains unaffected.
				if( (aluColumn == 1) & (row[11] | row[8]))
					ccrTemp[CF] = pswCcr[XF];
				else
					ccrTemp[CF] = 0;
				ccrTemp[VF] = 0;
			end
			
		// Assumes col 3 of DIV use C and not X !
		// V will be set in other cols (2/3) of DIV
		OP_SLAA:   ccrTemp[ CF] = aOperand[15];
		
		OP_LSL,OP_ROXL:
			begin
				ccrTemp[ CF] = shftMsb;
				ccrTemp[ XF] = shftMsb;
				ccrTemp[ VF] = 1'b0;
			end
			
		OP_LSR,OP_ROXR:
			begin
				// 0 Needed for mul, or carry gets in high word
				ccrTemp[ CF] = shftIsMul ? 1'b0 : aOperand[0];
				ccrTemp[ XF] = aOperand[0];
				// Not relevant for MUL, we clear it at mulm6 (1f) anyway.
				// Not that MUL can never overlow!
				ccrTemp[ VF] = 0;
				// Z is checking here ALU (low result is actually in ALUE).
				// But it is correct, see comment above.
			end
			
		OP_ASL:
			begin
				ccrTemp[ XF] = shftMsb;			ccrTemp[ CF] = shftMsb;
				// V set if msb changed on any shift.
				// Otherwise clear previously on OP_AND (col 1i).
				ccrTemp[ VF] = pswCcr[VF] | (shftMsb ^
					(isLong ? alue[15-1] : (isByte ? aOperand[7-1] : aOperand[15-1])) );
			end
		OP_ASR:
			begin
				ccrTemp[ XF] = aOperand[0];		ccrTemp[ CF] = aOperand[0];
				ccrTemp[ VF] = 0;
			end
      
		// X not changed on ROL/ROR !
		OP_ROL:		ccrTemp[ CF] = shftMsb;
		OP_ROR:		ccrTemp[ CF] = aOperand[0];

		OP_ADD,
		OP_ADDC,
		OP_ADDX,
		OP_SUB,
		OP_SUBC,
		OP_SUBX:
			begin
				ccrTemp[ CF] = subCout;
				ccrTemp[ XF] = subCout;
				ccrTemp[ VF] = subOv;
			end

		OP_ABCD,
		OP_SBCD:
			begin
				ccrTemp[ XF] = bcdCarry;
				ccrTemp[ CF] = bcdCarry;
				ccrTemp[ VF] = bcdOverf;
			end
		
		endcase
				
	end
	
	// Core and psw latched at the same cycle
	
	// CCR filter
	// CCR out mux for Z & C flags
	// Z flag for 32-bit result
	// Not described, but should be used also for instructions
	//   that clear but not set Z (ADDX/SUBX/ABCD, etc)!
	logic [4:0] ccrMasked;
	always_comb begin
		ccrMasked = (ccrTemp & ccrMask) | (pswCcr & ~ccrMask);
		// if( finish | isCorf | isArX)		// No need to check specicially for isCorf as they always have the "finish" flag anyway
		if( finish | isArX)
			ccrMasked[ ZF] = ccrTemp[ ZF] & pswCcr[ ZF];
	end
		
	always_ff @( posedge clk) begin
		if( enT3) begin
			// Update latches from ALU operators
			if( (| aluColumn)) begin
				aluLatch <= result;
				
				coreH <= subHcarry;
			   
				// Update CCR core
				if( (| aluColumn))
					ccrCore <= ccrTemp;		// Most bits not really used
			end

			if( alueClkEn)
				alue <= iDataBus;
			else if( isShift & (| aluColumn))
				alue <= shftResult[31:16];
		end
				
		// CCR
		// Originally on T3-T4 edge pulse !!
		// Might be possible to update on T4 (but not after T0) from partial result registered on T3, it will increase performance!
		if( pwrUp)
			pswCcr <= '0;
		else if( enT3 & ftu2Ccr)
			pswCcr <= ftu[4:0];	
		else if( enT3 &	~noCcrEn & (finish | init))
			pswCcr <= ccrMasked;
	end
	assign ccr = { 3'b0, pswCcr};	

	      
endmodule

// add bcd correction factor
// It would be more efficient to merge add/sub with main ALU !!!
module aluCorf( input [7:0] binResult, input bAdd, input cin, input hCarry,
	output [7:0] bcdResult, output dC, output logic ov);

	reg [8:0] htemp;
	reg [4:0] hNib;
	
	wire lowC  = hCarry | (bAdd ? gt9( binResult[ 3:0]) : 1'b0);
	wire highC = cin	| (bAdd ? (gt9( htemp[7:4]) | htemp[8]) : 1'b0);
		
	always_comb begin
		if( bAdd) begin
			htemp = { 1'b0, binResult} + (lowC  ? 4'h6 : 4'h0);
			hNib  = htemp[8:4] + (highC ? 4'h6 : 4'h0);
			ov = hNib[3] & ~binResult[7];
		end
		else begin
			htemp = { 1'b0, binResult} - (lowC  ? 4'h6 : 4'h0);
			hNib  = htemp[8:4] - (highC ? 4'h6 : 4'h0);
			ov = ~hNib[3] & binResult[7];
		end
	end

	assign bcdResult = { hNib[ 3:0], htemp[3:0]};
	assign dC = hNib[4] | cin;

	// Nibble > 9
	function gt9 (input [3:0] nib);
	begin
		gt9 = nib[3] & (nib[2] | nib[1]);
	end
	endfunction

endmodule


module aluShifter( input [31:0] data,
	input isByte, input isLong, swapWords,
	input dir, input cin,
	output logic [31:0] result);
	// output reg cout

	logic [31:0] tdata;         

	// size mux, put cin in position if dir == right
	always_comb begin
		tdata = data;
		if( isByte & dir)
			tdata[8] = cin;
		else if( !isLong & dir)
			tdata[16] = cin;
	end
    
	always_comb begin
		// Reverse alu/alue position for MUL & DIV
		// Result reversed again
		if( swapWords & dir)
			result = { tdata[0], tdata[31:17], cin, tdata[15:1]};
		else if( swapWords)
			result = { tdata[30:16], cin, tdata[14:0], tdata[31]};
			
		else if( dir)
			result = { cin, tdata[31:1]};
		else
			result = { tdata[30:0], cin};
	end

endmodule


// Get current OP from row & col
module aluGetOp( input [15:0] row, input [2:0] col, input isCorf,
	output logic [4:0] aluOp);
	
	always_comb begin
		aluOp = 'X;
		unique case( col)  
		1:   aluOp = OP_AND;
		5:   aluOp = OP_EXT;

		default:
			unique case( 1'b1)
				row[1]:
					unique case( col)
					2: aluOp = OP_SUB;
					3: aluOp = OP_SUBC;
					4,6: aluOp = OP_SLAA;
					endcase
				
				row[2]:
					unique case( col)
					2: aluOp = OP_ADD;
					3: aluOp = OP_ADDC;
					4: aluOp = OP_ASR;
					endcase

				row[3]:
					unique case( col)
					2: aluOp = OP_ADDX;
					3: aluOp = isCorf ? OP_ABCD : OP_ADD;
					4: aluOp = OP_ASL;
					endcase
                  
				row[4]:
					aluOp = ( col == 4) ? OP_LSL : OP_AND;
				
				row[5],
				row[6]:
					unique case( col)
					2: aluOp = OP_SUB;
					3: aluOp = OP_SUBC;
					4: aluOp = OP_LSR;
					endcase
				
				row[7]:					// MUL
					unique case( col)
					2: aluOp = OP_SUB;
					3: aluOp = OP_ADD;
					4: aluOp = OP_ROXR;
					endcase
               
				row[8]:
					// OP_AND For EXT.L
					// But would be more efficient to change ucode and use column 1 instead of col3 at ublock extr1!				
					unique case( col)
					2: aluOp = OP_EXT;
					3: aluOp = OP_AND;
					4: aluOp = OP_ROXR;
					endcase
               
				row[9]:
					unique case( col)
					2: aluOp = OP_SUBX;
					3: aluOp = OP_SBCD;
					4: aluOp = OP_ROL;
					endcase

				row[10]:
					unique case( col)
					2: aluOp = OP_SUBX;
					3: aluOp = OP_SUBC;
					4: aluOp = OP_ROR;
					endcase
                
				row[11]:
					unique case( col)
					2: aluOp = OP_SUB0;
					3: aluOp = OP_SUB0;
					4: aluOp = OP_ROXL;
					endcase
                
				row[12]:	aluOp = OP_ADDX;               
				row[13]:	aluOp = OP_EOR;
				row[14]:	aluOp = (col == 4) ? OP_EOR : OP_OR;
				row[15]:	aluOp = (col == 3) ? OP_ADD : OP_OR;		// OP_ADD used by DBcc
				
			endcase         
		endcase
	end
endmodule

// Decodes IRD into ALU row (1-15)
// Slow, but no need to optimize for speed since IRD is latched at least two CPU cycles before it is used
// We also register the result after combining with column from nanocode
//
// Many opcodes are not decoded because they either don't do any ALU op,
// or use only columns 1 and 5 that are the same for all rows.

module rowDecoder( input [15:0] ird,
	output logic [15:0] row, output noCcrEn, output logic isArX);


	// Addr or data register direct
	wire eaRdir = (ird[ 5:4] == 2'b00);
	// Addr register direct
	wire eaAdir = (ird[ 5:3] == 3'b001);
	wire size11 = ird[7] & ird[6];
	
	always_comb begin
		case( ird[15:12])
		'h4,
		'h9,
		'hd:
			isArX = row[10] | row[12];
		default:
			isArX = 1'b0;
		endcase
	end

	always_comb begin
		unique case( ird[15:12])

		'h4:  begin
				if( ird[8])
					row = 16'h0040;			// chk (or lea)
				else case( ird[11:9])
					'b000: row = 16'h0400;	// negx
					'b001: row = 16'h0010;	// clr
					'b010: row = 16'h0020;	// neg
					'b011: row = 16'h0800;	// not
					'b100: row = (ird[7]) ? 16'h0100 : 16'h0200;	// nbcd/swap/ext(or pea)
					'b101: row = 16'h8000;	// tst & tas
					default: row = 0;
				endcase
			end

		'h0: begin
				if( ird[8])                       // dynamic bit
					row = ird[7] ? 16'h4000 : 16'h2000;
				else case( ird[ 11:9])
					'b000:   row = 16'h4000;	// ori
					'b001:   row = 16'h0010;	// andi
					'b010:   row = 16'h0020;	// subi
					'b011:   row = 16'h0004;	// addi
					'b100:   row = ird[7] ? 16'h4000 : 16'h2000;   // static bit
					'b101:   row = 16'h2000;	// eori
					'b110:   row = 16'h0040;	// cmpi
					default: row = 0;
					endcase
				end
				
		// MOVE
		// move.b originally also rows 5 & 15. Only because IRD bit 14 is not decoded.
		// It's the same for move the operations performed by MOVE.B

		'h1,'h2,'h3:   row = 16'h0004;
		
		'h5:
			if( size11)										
               row = 16'h8000;								// As originally and easier to decode
			else
				row = ird[8] ? 16'h0020 : 16'h0004;     // addq/subq
		'h6:	row = 0;						//bcc/bra/bsr
		'h7:	row = 16'h0004;				// moveq
		'h8:
			if( size11)						// div
				row = 16'h0002;
			else if( ird[8] & eaRdir)		// sbcd
				row = 16'h0200;
			else
				row = 16'h4000;			// or
		'h9:
			if( ird[8] & ~size11 & eaRdir)
				row = 16'h0400;			// subx
			else
				row = 16'h0020;			// sub/suba
		'hb:
			if( ird[8] & ~size11 & ~eaAdir)
				row = 16'h2000;			// eor
			else
				row = 16'h0040;			// cmp/cmpa/cmpm
		'hc:
			if( size11)
				row = 16'h0080;			// mul
			else if( ird[8] & eaRdir)		// abcd
				row = 16'h0008;
			else
				row = 16'h0010;			// and
		'hd:
			if( ird[8] & ~size11 & eaRdir)
				row = 16'h1000;			// addx
			else
				row = 16'h0004;			// add/adda
		'he:
			begin
				reg [1:0] stype;
				
				if( size11)					// memory shift/rotate
					stype = ird[ 10:9];
				else						// register shift/rotate
					stype = ird[ 4:3];

				case( {stype, ird[8]})
				0: row = 16'h0004;	// ASR
				1: row = 16'h0008;	// ASL
				2: row = 16'h0020;	// LSR
				3: row = 16'h0010;	// LSL
				4: row = 16'h0100;	// ROXR
				5: row = 16'h0800;	// ROXL
				6: row = 16'h0400;	// ROR
				7: row = 16'h0200;	// ROL
				endcase
			end
			
		default:	row = 0;
		endcase
	end
   
	// Decode opcodes that don't affect flags
	// ADDA/SUBA ADDQ/SUBQ MOVEA

	assign noCcrEn =
		// ADDA/SUBA
		( ird[15] & ~ird[13] & ird[12] & size11) |
		// ADDQ/SUBQ to An
		( (ird[15:12] == 4'h5) & eaAdir) |
		// MOVEA
		( (~ird[15] & ~ird[14] & ird[13]) & ird[8:6] == 3'b001);
        
endmodule

// Row/col CCR update table
module ccrTable( 
	input [2:0] col, input [15:0] row, input finish,
	output logic [MASK_NBITS-1:0] ccrMask);
    
	localparam
		KNZ00 = 5'b01111,   // ok coz operators clear them
		KKZKK = 5'b00100,
		KNZKK = 5'b01100,
		KNZ10 = 5'b01111,	// Used by OP_EXT on divison overflow
		KNZ0C = 5'b01111,	// Used by DIV. V should be 0, but it is ok:
							// DIVU: ends with quotient - 0, so V & C always clear.
							// DIVS: ends with 1i (AND), again, V & C always clear.

		KNZVC	= 5'b01111,
		XNKVC	= 5'b11011,	// Used by BCD instructions. Don't modify Z at all at the binary operation. Only at the BCD correction cycle
		
		CUPDALL = 5'b11111,
		CUNUSED = 5'bxxxxx;
    

	logic [MASK_NBITS-1:0] ccrMask1;

	always_comb begin
		unique case( col)
		1:			ccrMask = ccrMask1;
		
		2,3:
			unique case( 1'b1)
			row[1]:		ccrMask = KNZ0C;		// DIV, used as 3n in col3
			
			row[3],								// ABCD
			row[9]:								// SBCD/NBCD
						ccrMask = (col == 2) ? XNKVC : CUPDALL;
			
			row[2],
			row[5],
			row[10],							// SUBX/NEGX
			row[12]:	ccrMask = CUPDALL;		// ADDX

			row[6],								// CMP
			row[7],								// MUL		
			row[11]:	ccrMask = KNZVC;		// NOT
			row[4],
			row[8],								// Not used in col 3
			row[13],
			row[14]:	ccrMask = KNZ00;
			row[15]:	ccrMask = 5'b0;			// TAS/Scc, not used in col 3
			// default:	ccrMask = CUNUSED;
			endcase			
			
		4:
			unique case( row)
			// 1: DIV, only n (4n & 6n)
			// 14: BCLR 4n
			// 6,12,13,15	// not used
			16'h0004,
			16'h0008,							// ASL    (originally ANZVA)
			16'h0010,
			16'h0020:	ccrMask = CUPDALL;		// Shifts (originally ANZ0A)
			
			16'h0080:	ccrMask = KNZ00;		// MUL (originally KNZ0A)
			16'h0200,
			16'h0400:	ccrMask = KNZ00;		// RO[lr] (originally KNZ0A)
			16'h0100,							// ROXR (originally ANZ0A)
			16'h0800:	ccrMask = CUPDALL;		// ROXL (originally ANZ0A)
			default:	ccrMask = CUNUSED;
			endcase
		
		5:			ccrMask = row[1] ? KNZ10 : 5'b0;
		default:	ccrMask = CUNUSED;
		endcase
	end

	// Column 1 (AND)      
	always_comb begin
		if( finish)
			ccrMask1 = row[7] ? KNZ00 : KNZKK;
		else
			ccrMask1 = row[13] | row[14] ? KKZKK : KNZ00;
	end
    
endmodule

//
// FX68K
//
// Opcode to uaddr entry routines (A2-A2-A3) PLA
//

// altera message_off 10230


`timescale 1 ns / 1 ns































module pla_lined(
   input [3:0] movEa,
   input [3:0] col,

   input [15:0] opcode,
   input [15:0] lineBmap,
   
   output palIll,
   output logic [10-1:0] plaA1,
   output logic [10-1:0] plaA2,
   output logic [10-1:0] plaA3
   );

   wire [3:0] line = opcode[ 15:12];
   wire [2:0] row86 = opcode[8:6];
   
   logic [15:0] arIll;
   logic [10-1:0] arA1[ 15:0];
   logic [10-1:0] arA23[ 15:0];
   logic [10-1:0] scA3;

   logic illMisc;
   logic [10-1:0] a1Misc;
   
   /*
   reg [10-1:0] lineMask[ 15:0];  
   always_comb begin
       integer i;
       for( i = 0; i < 16; i = i + 1)
         lineMask[i] = { 16{lineBmap[ i]}};
   end
   */

   assign palIll = (| (arIll & lineBmap));
   
   // Only line 0 has 3 subs
   assign plaA1 = arA1[ line];
   assign plaA2 = arA23[ line];
   assign plaA3 = lineBmap[0] ? scA3 : arA23[ line];
   
   
   // Simple lines
   always_comb begin
      // Line 6: Branch
      arIll[ 'h6] = 1'b0;
      arA23[ 'h6] = 'X;
      if( opcode[ 11:8] == 4'h1)
         arA1[ 'h6] = (| opcode[7:0]) ? 'h089 : 'h0A9;
      else
         arA1[ 'h6] = (| opcode[7:0]) ? 'h308 : 'h068;
                         
      // Line 7: moveq
      arIll[ 'h7] = opcode[ 8];
      arA23[ 'h7] = 'X;
      arA1[ 'h7] = 'h23B;

      // Line A & F      
      arIll[ 'ha] = 1'b1;       arIll[ 'hf] = 1'b1;
      arA1[ 'ha]  = 'X;         arA1[ 'hf]  = 'X;
      arA23[ 'ha] = 'X;         arA23[ 'hf] = 'X;
      
   end   

   // Special lines

   // Line e: shifts
   always_comb begin
      if( ~opcode[11] & opcode[7] & opcode[6])
      begin
         arA23[ 'he] = 'h3C7;
         unique case( col)
            2: begin arIll[ 'he] = 1'b0; arA1[ 'he] = 'h006; end
            3: begin arIll[ 'he] = 1'b0; arA1[ 'he] = 'h21C; end
            4: begin arIll[ 'he] = 1'b0; arA1[ 'he] = 'h103; end
            5: begin arIll[ 'he] = 1'b0; arA1[ 'he] = 'h1C2; end
            6: begin arIll[ 'he] = 1'b0; arA1[ 'he] = 'h1E3; end
            7: begin arIll[ 'he] = 1'b0; arA1[ 'he] = 'h00A; end
            8: begin arIll[ 'he] = 1'b0; arA1[ 'he] = 'h1E2; end
            default: begin arIll[ 'he] = 1'b1; arA1[ 'he] = 'X; end
         endcase
      end
      else
      begin
         arA23[ 'he] = 'X;
         unique case( opcode[ 7:6])
         2'b00,
         2'b01: begin
                  arIll[ 'he] = 1'b0;
                  arA1[ 'he]  = opcode[ 5] ? 'h382 : 'h381;
               end
         2'b10: begin
                  arIll[ 'he] = 1'b0;
                  arA1[ 'he]  = opcode[ 5] ? 'h386 : 'h385;
              end
         2'b11: begin arIll[ 'he] = 1'b1; arA1[ 'he]  = 'X; end
         endcase
      end
   end

   // Misc. line 4 row
   always_comb begin
      illMisc = 1'b0;
      case( opcode[ 5:3])
      3'b000,
      3'b001:      a1Misc = 'h1D0;
      3'b010:      a1Misc = 'h30B;
      3'b011:      a1Misc = 'h119;
      3'b100:      a1Misc = 'h2F5;
      3'b101:      a1Misc = 'h230;
      
      3'b110:   
         case( opcode[ 2:0])
         3'b110:   a1Misc = 'h06D;
         3'b000:   a1Misc = 'h3A6;
         3'b001:   a1Misc = 'h363;
         3'b010:   a1Misc = 'h3A2;
         3'b011:   a1Misc = 'h12A;
         3'b111:   a1Misc = 'h12A;
         3'b101:   a1Misc = 'h126;
         default:  begin  illMisc = 1'b1; a1Misc = 'X; end
         endcase
         
      default:  begin  illMisc = 1'b1; a1Misc = 'X; end
      endcase
   end

//
// Past here
//


//
// Line: 0
//
always_comb begin

if( (opcode[11:6] & 'h1F) == 'h8) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h100; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h299; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h299; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h299; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h299; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h299; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h299; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h299; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1CC; scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h37) == 'h0) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h100; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h299; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h299; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h299; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h299; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h299; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h299; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h299; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1CC; scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h1F) == 'h9) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h100; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h299; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h299; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h299; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h299; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h299; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h299; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h299; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1CC; scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h37) == 'h1) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h100; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h299; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h299; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h299; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h299; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h299; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h299; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h299; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1CC; scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h1F) == 'hA) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h10C; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00B; scA3 = 'h29D; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00F; scA3 = 'h29D; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h179; scA3 = 'h29D; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1C6; scA3 = 'h29D; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1E7; scA3 = 'h29D; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00E; scA3 = 'h29D; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1E6; scA3 = 'h29D; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h37) == 'h2) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h10C; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00B; scA3 = 'h29D; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00F; scA3 = 'h29D; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h179; scA3 = 'h29D; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1C6; scA3 = 'h29D; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1E7; scA3 = 'h29D; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00E; scA3 = 'h29D; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1E6; scA3 = 'h29D; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h37) == 'h10) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h100; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h299; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h299; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h299; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h299; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h299; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h299; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h299; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h37) == 'h11) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h100; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h299; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h299; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h299; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h299; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h299; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h299; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h299; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h37) == 'h12) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h10C; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00B; scA3 = 'h29D; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00F; scA3 = 'h29D; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h179; scA3 = 'h29D; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1C6; scA3 = 'h29D; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1E7; scA3 = 'h29D; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00E; scA3 = 'h29D; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1E6; scA3 = 'h29D; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h7) == 'h4) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E7; arA23[ 'h0] = 'X;  scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1D2; arA23[ 'h0] = 'X;  scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h006; arA23[ 'h0] = 'X;  scA3 = 'h215; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h21C; arA23[ 'h0] = 'X;  scA3 = 'h215; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h103; arA23[ 'h0] = 'X;  scA3 = 'h215; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1C2; arA23[ 'h0] = 'X;  scA3 = 'h215; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E3; arA23[ 'h0] = 'X;  scA3 = 'h215; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h00A; arA23[ 'h0] = 'X;  scA3 = 'h215; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E2; arA23[ 'h0] = 'X;  scA3 = 'h215; end
     9: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1C2; arA23[ 'h0] = 'X;  scA3 = 'h215; end
    10: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E3; arA23[ 'h0] = 'X;  scA3 = 'h215; end
    11: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h0EA; arA23[ 'h0] = 'h0AB; scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h7) == 'h5) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3EF; arA23[ 'h0] = 'X;  scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1D6; arA23[ 'h0] = 'X;  scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h006; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h21C; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h103; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1C2; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E3; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h00A; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E2; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h7) == 'h7) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3EF; arA23[ 'h0] = 'X;  scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1CE; arA23[ 'h0] = 'X;  scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h006; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h21C; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h103; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1C2; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E3; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h00A; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E2; arA23[ 'h0] = 'X;  scA3 = 'h081; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h7) == 'h6) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3EB; arA23[ 'h0] = 'X;  scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1CA; arA23[ 'h0] = 'X;  scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h006; arA23[ 'h0] = 'X;  scA3 = 'h069; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h21C; arA23[ 'h0] = 'X;  scA3 = 'h069; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h103; arA23[ 'h0] = 'X;  scA3 = 'h069; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1C2; arA23[ 'h0] = 'X;  scA3 = 'h069; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E3; arA23[ 'h0] = 'X;  scA3 = 'h069; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h00A; arA23[ 'h0] = 'X;  scA3 = 'h069; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h1E2; arA23[ 'h0] = 'X;  scA3 = 'h069; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( opcode[11:6] == 'h20) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h3E7; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h215; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h215; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h215; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h215; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h215; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h215; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h215; end
     9: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h215; end
    10: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h215; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( opcode[11:6] == 'h21) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h3EF; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h081; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h081; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h081; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h081; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h081; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h081; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h081; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( opcode[11:6] == 'h23) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h3EF; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h081; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h081; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h081; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h081; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h081; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h081; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h081; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( opcode[11:6] == 'h22) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h3EB; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h069; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h069; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h069; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h069; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h069; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h069; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h069; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( opcode[11:6] == 'h30) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h108; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h087; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h087; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h087; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h087; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h087; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h087; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h087; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( opcode[11:6] == 'h31) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h108; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h006; scA3 = 'h087; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h21C; scA3 = 'h087; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h103; scA3 = 'h087; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1C2; scA3 = 'h087; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E3; scA3 = 'h087; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h00A; scA3 = 'h087; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h2B9; arA23[ 'h0] = 'h1E2; scA3 = 'h087; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else if( opcode[11:6] == 'h32) begin
    unique case ( col)
     0: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h104; scA3 = 'X; end
     1: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
     2: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00B; scA3 = 'h08F; end
     3: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00F; scA3 = 'h08F; end
     4: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h179; scA3 = 'h08F; end
     5: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1C6; scA3 = 'h08F; end
     6: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1E7; scA3 = 'h08F; end
     7: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h00E; scA3 = 'h08F; end
     8: begin arIll[ 'h0] = 1'b0; arA1[ 'h0] = 'h3E0; arA23[ 'h0] = 'h1E6; scA3 = 'h08F; end
     9: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    10: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    11: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    default: begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X;    scA3 = 'X; end
    endcase
end

else begin arIll[ 'h0] = 1'b1; arA1[ 'h0] = 'X   ; arA23[ 'h0] = 'X; scA3 = 'X; end

end


//
// Line: 4
//
always_comb begin

if( (opcode[11:6] & 'h27) == 'h0) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h133; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h2B8; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h2B8; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h2B8; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h2B8; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h2B8; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h2B8; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h2B8; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h27) == 'h1) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h133; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h2B8; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h2B8; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h2B8; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h2B8; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h2B8; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h2B8; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h2B8; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h27) == 'h2) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h137; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00B; arA23[ 'h4] = 'h2BC; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00F; arA23[ 'h4] = 'h2BC; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h179; arA23[ 'h4] = 'h2BC; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C6; arA23[ 'h4] = 'h2BC; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E7; arA23[ 'h4] = 'h2BC; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00E; arA23[ 'h4] = 'h2BC; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E6; arA23[ 'h4] = 'h2BC; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h3) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h3A5; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h3A1; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h3A1; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h3A1; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h3A1; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h3A1; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h3A1; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h3A1; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h13) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h301; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h159; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h159; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h159; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h159; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h159; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h159; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h159; end
     9: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h159; end
    10: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h159; end
    11: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h0EA; arA23[ 'h4] = 'h301; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h1B) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h301; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h159; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h159; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h159; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h159; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h159; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h159; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h159; end
     9: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h159; end
    10: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h159; end
    11: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h0EA; arA23[ 'h4] = 'h301; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h20) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h13B; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h15C; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h15C; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h15C; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h15C; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h15C; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h15C; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h15C; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h21) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h341; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h17C; arA23[ 'h4] = 'X; end
     3: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     4: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h17D; arA23[ 'h4] = 'X; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1FF; arA23[ 'h4] = 'X; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h178; arA23[ 'h4] = 'X; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1FA; arA23[ 'h4] = 'X; end
     9: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h17D; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1FF; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h22) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h133; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h3A0; arA23[ 'h4] = 'X; end
     3: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h3A4; arA23[ 'h4] = 'X; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F1; arA23[ 'h4] = 'X; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h325; arA23[ 'h4] = 'X; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1ED; arA23[ 'h4] = 'X; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E5; arA23[ 'h4] = 'X; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h23) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h232; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h3A0; arA23[ 'h4] = 'X; end
     3: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h3A4; arA23[ 'h4] = 'X; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F1; arA23[ 'h4] = 'X; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h325; arA23[ 'h4] = 'X; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1ED; arA23[ 'h4] = 'X; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E5; arA23[ 'h4] = 'X; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h28) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h12D; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h3C3; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h3C3; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h3C3; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h3C3; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h3C3; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h3C3; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h3C3; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h29) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h12D; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h3C3; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h3C3; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h3C3; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h3C3; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h3C3; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h3C3; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h3C3; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h2A) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h125; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00B; arA23[ 'h4] = 'h3CB; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00F; arA23[ 'h4] = 'h3CB; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h179; arA23[ 'h4] = 'h3CB; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C6; arA23[ 'h4] = 'h3CB; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E7; arA23[ 'h4] = 'h3CB; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00E; arA23[ 'h4] = 'h3CB; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E6; arA23[ 'h4] = 'h3CB; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h2B) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h345; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h343; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h343; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h343; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h343; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h343; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h343; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h343; end
     9: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h3E) == 'h32) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h127; arA23[ 'h4] = 'X; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h123; arA23[ 'h4] = 'X; end
     4: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1FD; arA23[ 'h4] = 'X; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F5; arA23[ 'h4] = 'X; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F9; arA23[ 'h4] = 'X; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E9; arA23[ 'h4] = 'X; end
     9: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1FD; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F5; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h7) == 'h6) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h152; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h006; arA23[ 'h4] = 'h151; end
     3: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h21C; arA23[ 'h4] = 'h151; end
     4: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h103; arA23[ 'h4] = 'h151; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h151; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h151; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h00A; arA23[ 'h4] = 'h151; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E2; arA23[ 'h4] = 'h151; end
     9: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1C2; arA23[ 'h4] = 'h151; end
    10: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1E3; arA23[ 'h4] = 'h151; end
    11: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h0EA; arA23[ 'h4] = 'h152; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( (opcode[11:6] & 'h7) == 'h7) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h2F1; arA23[ 'h4] = 'X; end
     3: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     4: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h2F2; arA23[ 'h4] = 'X; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1FB; arA23[ 'h4] = 'X; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h275; arA23[ 'h4] = 'X; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h3E4; arA23[ 'h4] = 'X; end
     9: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h2F2; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1FB; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h3A) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h273; arA23[ 'h4] = 'X; end
     3: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     4: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h2B0; arA23[ 'h4] = 'X; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F3; arA23[ 'h4] = 'X; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h293; arA23[ 'h4] = 'X; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F2; arA23[ 'h4] = 'X; end
     9: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h2B0; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F3; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h3B) begin
    unique case ( col)
     0: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     1: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     2: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h255; arA23[ 'h4] = 'X; end
     3: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     4: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
     5: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h2B4; arA23[ 'h4] = 'X; end
     6: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F7; arA23[ 'h4] = 'X; end
     7: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h297; arA23[ 'h4] = 'X; end
     8: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F6; arA23[ 'h4] = 'X; end
     9: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h2B4; arA23[ 'h4] = 'X; end
    10: begin arIll[ 'h4] = 1'b0; arA1[ 'h4] = 'h1F7; arA23[ 'h4] = 'X; end
    11: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    default: begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end
    endcase
end

else if( opcode[11:6] == 'h39) begin
     arIll[ 'h4] = illMisc; arA1[ 'h4] = a1Misc   ; arA23[ 'h4] = 'X;
end

else begin arIll[ 'h4] = 1'b1; arA1[ 'h4] = 'X   ; arA23[ 'h4] = 'X; end

end

always_comb begin

//
// Line: 1
//
unique case( movEa)

0: // Row: 0
    unique case ( col)
     0: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h121; arA23[ 'h1] = 'X; end
     1: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
     2: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h006; arA23[ 'h1] = 'h29B; end
     3: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h21C; arA23[ 'h1] = 'h29B; end
     4: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h103; arA23[ 'h1] = 'h29B; end
     5: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h29B; end
     6: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h29B; end
     7: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h00A; arA23[ 'h1] = 'h29B; end
     8: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E2; arA23[ 'h1] = 'h29B; end
     9: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h29B; end
    10: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h29B; end
    11: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h0EA; arA23[ 'h1] = 'h121; end
    default: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
    endcase

2: // Row: 2
    unique case ( col)
     0: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h2FA; arA23[ 'h1] = 'X; end
     1: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
     2: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h006; arA23[ 'h1] = 'h3AB; end
     3: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h21C; arA23[ 'h1] = 'h3AB; end
     4: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h103; arA23[ 'h1] = 'h3AB; end
     5: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h3AB; end
     6: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h3AB; end
     7: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h00A; arA23[ 'h1] = 'h3AB; end
     8: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E2; arA23[ 'h1] = 'h3AB; end
     9: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h3AB; end
    10: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h3AB; end
    11: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h0EA; arA23[ 'h1] = 'h2FA; end
    default: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
    endcase

3: // Row: 3
    unique case ( col)
     0: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h2FE; arA23[ 'h1] = 'X; end
     1: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
     2: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h006; arA23[ 'h1] = 'h3AF; end
     3: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h21C; arA23[ 'h1] = 'h3AF; end
     4: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h103; arA23[ 'h1] = 'h3AF; end
     5: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h3AF; end
     6: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h3AF; end
     7: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h00A; arA23[ 'h1] = 'h3AF; end
     8: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E2; arA23[ 'h1] = 'h3AF; end
     9: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h3AF; end
    10: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h3AF; end
    11: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h0EA; arA23[ 'h1] = 'h2FE; end
    default: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
    endcase

4: // Row: 4
    unique case ( col)
     0: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h2F8; arA23[ 'h1] = 'X; end
     1: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
     2: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h006; arA23[ 'h1] = 'h38B; end
     3: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h21C; arA23[ 'h1] = 'h38B; end
     4: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h103; arA23[ 'h1] = 'h38B; end
     5: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h38B; end
     6: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h38B; end
     7: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h00A; arA23[ 'h1] = 'h38B; end
     8: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E2; arA23[ 'h1] = 'h38B; end
     9: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h38B; end
    10: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h38B; end
    11: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h0EA; arA23[ 'h1] = 'h2F8; end
    default: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
    endcase

5: // Row: 5
    unique case ( col)
     0: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h2DA; arA23[ 'h1] = 'X; end
     1: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
     2: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h006; arA23[ 'h1] = 'h38A; end
     3: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h21C; arA23[ 'h1] = 'h38A; end
     4: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h103; arA23[ 'h1] = 'h38A; end
     5: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h38A; end
     6: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h38A; end
     7: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h00A; arA23[ 'h1] = 'h38A; end
     8: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E2; arA23[ 'h1] = 'h38A; end
     9: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h38A; end
    10: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h38A; end
    11: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h0EA; arA23[ 'h1] = 'h2DA; end
    default: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
    endcase

6: // Row: 6
    unique case ( col)
     0: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1EB; arA23[ 'h1] = 'X; end
     1: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
     2: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h006; arA23[ 'h1] = 'h298; end
     3: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h21C; arA23[ 'h1] = 'h298; end
     4: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h103; arA23[ 'h1] = 'h298; end
     5: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h298; end
     6: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h298; end
     7: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h00A; arA23[ 'h1] = 'h298; end
     8: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E2; arA23[ 'h1] = 'h298; end
     9: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h298; end
    10: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h298; end
    11: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h0EA; arA23[ 'h1] = 'h1EB; end
    default: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
    endcase

7: // Row: 7
    unique case ( col)
     0: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h2D9; arA23[ 'h1] = 'X; end
     1: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
     2: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h006; arA23[ 'h1] = 'h388; end
     3: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h21C; arA23[ 'h1] = 'h388; end
     4: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h103; arA23[ 'h1] = 'h388; end
     5: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h388; end
     6: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h388; end
     7: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h00A; arA23[ 'h1] = 'h388; end
     8: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E2; arA23[ 'h1] = 'h388; end
     9: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h388; end
    10: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h388; end
    11: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h0EA; arA23[ 'h1] = 'h2D9; end
    default: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
    endcase

8: // Row: 8
    unique case ( col)
     0: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1EA; arA23[ 'h1] = 'X; end
     1: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
     2: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h006; arA23[ 'h1] = 'h32B; end
     3: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h21C; arA23[ 'h1] = 'h32B; end
     4: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h103; arA23[ 'h1] = 'h32B; end
     5: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h32B; end
     6: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h32B; end
     7: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h00A; arA23[ 'h1] = 'h32B; end
     8: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E2; arA23[ 'h1] = 'h32B; end
     9: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1C2; arA23[ 'h1] = 'h32B; end
    10: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h1E3; arA23[ 'h1] = 'h32B; end
    11: begin arIll[ 'h1] = 1'b0; arA1[ 'h1] = 'h0EA; arA23[ 'h1] = 'h1EA; end
    default: begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
    endcase
default:  begin arIll[ 'h1] = 1'b1; arA1[ 'h1] = 'X   ; arA23[ 'h1] = 'X; end
endcase

//
// Line: 2
//
unique case( movEa)

0: // Row: 0
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h129; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h129; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h29F; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h29F; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h29F; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h29F; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h29F; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h29F; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h29F; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h29F; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h29F; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h129; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase

1: // Row: 1
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h129; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h129; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h29F; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h29F; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h29F; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h29F; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h29F; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h29F; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h29F; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h29F; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h29F; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h129; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase

2: // Row: 2
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2F9; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2F9; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h3A9; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h3A9; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h3A9; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h3A9; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h3A9; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h3A9; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h3A9; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h3A9; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h3A9; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h2F9; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase

3: // Row: 3
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2FD; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2FD; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h3AD; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h3AD; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h3AD; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h3AD; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h3AD; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h3AD; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h3AD; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h3AD; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h3AD; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h2FD; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase

4: // Row: 4
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2FC; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2FC; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h38F; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h38F; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h38F; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h38F; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h38F; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h38F; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h38F; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h38F; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h38F; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h2FC; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase

5: // Row: 5
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2DE; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2DE; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h38E; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h38E; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h38E; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h38E; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h38E; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h38E; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h38E; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h38E; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h38E; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h2DE; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase

6: // Row: 6
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1EF; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1EF; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h29C; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h29C; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h29C; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h29C; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h29C; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h29C; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h29C; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h29C; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h29C; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h1EF; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase

7: // Row: 7
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2DD; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h2DD; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h38C; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h38C; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h38C; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h38C; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h38C; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h38C; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h38C; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h38C; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h38C; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h2DD; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase

8: // Row: 8
    unique case ( col)
     0: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1EE; arA23[ 'h2] = 'X; end
     1: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1EE; arA23[ 'h2] = 'X; end
     2: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00B; arA23[ 'h2] = 'h30F; end
     3: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00F; arA23[ 'h2] = 'h30F; end
     4: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h179; arA23[ 'h2] = 'h30F; end
     5: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h30F; end
     6: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h30F; end
     7: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h00E; arA23[ 'h2] = 'h30F; end
     8: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E6; arA23[ 'h2] = 'h30F; end
     9: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1C6; arA23[ 'h2] = 'h30F; end
    10: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h1E7; arA23[ 'h2] = 'h30F; end
    11: begin arIll[ 'h2] = 1'b0; arA1[ 'h2] = 'h0A7; arA23[ 'h2] = 'h1EE; end
    default: begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
    endcase
default:  begin arIll[ 'h2] = 1'b1; arA1[ 'h2] = 'X   ; arA23[ 'h2] = 'X; end
endcase

//
// Line: 3
//
unique case( movEa)

0: // Row: 0
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h121; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h121; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h29B; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h29B; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h29B; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h29B; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h29B; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h29B; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h29B; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h29B; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h29B; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h121; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase

1: // Row: 1
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h279; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h279; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h158; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h158; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h158; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h158; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h158; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h158; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h158; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h158; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h158; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h279; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase

2: // Row: 2
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2FA; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2FA; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h3AB; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h3AB; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h3AB; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h3AB; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h3AB; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h3AB; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h3AB; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h3AB; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h3AB; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h2FA; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase

3: // Row: 3
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2FE; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2FE; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h3AF; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h3AF; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h3AF; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h3AF; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h3AF; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h3AF; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h3AF; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h3AF; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h3AF; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h2FE; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase

4: // Row: 4
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2F8; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2F8; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h38B; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h38B; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h38B; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h38B; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h38B; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h38B; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h38B; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h38B; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h38B; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h2F8; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase

5: // Row: 5
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2DA; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2DA; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h38A; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h38A; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h38A; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h38A; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h38A; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h38A; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h38A; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h38A; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h38A; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h2DA; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase

6: // Row: 6
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1EB; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1EB; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h298; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h298; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h298; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h298; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h298; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h298; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h298; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h298; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h298; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h1EB; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase

7: // Row: 7
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2D9; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h2D9; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h388; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h388; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h388; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h388; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h388; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h388; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h388; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h388; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h388; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h2D9; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase

8: // Row: 8
    unique case ( col)
     0: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1EA; arA23[ 'h3] = 'X; end
     1: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1EA; arA23[ 'h3] = 'X; end
     2: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h006; arA23[ 'h3] = 'h32B; end
     3: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h21C; arA23[ 'h3] = 'h32B; end
     4: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h103; arA23[ 'h3] = 'h32B; end
     5: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h32B; end
     6: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h32B; end
     7: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h00A; arA23[ 'h3] = 'h32B; end
     8: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E2; arA23[ 'h3] = 'h32B; end
     9: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1C2; arA23[ 'h3] = 'h32B; end
    10: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h1E3; arA23[ 'h3] = 'h32B; end
    11: begin arIll[ 'h3] = 1'b0; arA1[ 'h3] = 'h0EA; arA23[ 'h3] = 'h1EA; end
    default: begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
    endcase
default:  begin arIll[ 'h3] = 1'b1; arA1[ 'h3] = 'X   ; arA23[ 'h3] = 'X; end
endcase

//
// Line: 5
//
unique case( row86)

3'b000: // Row: 0
    unique case ( col)
     0: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2D8; arA23[ 'h5] = 'X; end
     1: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
     2: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h006; arA23[ 'h5] = 'h2F3; end
     3: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h21C; arA23[ 'h5] = 'h2F3; end
     4: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h103; arA23[ 'h5] = 'h2F3; end
     5: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1C2; arA23[ 'h5] = 'h2F3; end
     6: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E3; arA23[ 'h5] = 'h2F3; end
     7: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00A; arA23[ 'h5] = 'h2F3; end
     8: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E2; arA23[ 'h5] = 'h2F3; end
    default: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
    endcase

3'b001: // Row: 1
    unique case ( col)
     0: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2D8; arA23[ 'h5] = 'X; end
     1: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2DC; arA23[ 'h5] = 'X; end
     2: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h006; arA23[ 'h5] = 'h2F3; end
     3: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h21C; arA23[ 'h5] = 'h2F3; end
     4: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h103; arA23[ 'h5] = 'h2F3; end
     5: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1C2; arA23[ 'h5] = 'h2F3; end
     6: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E3; arA23[ 'h5] = 'h2F3; end
     7: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00A; arA23[ 'h5] = 'h2F3; end
     8: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E2; arA23[ 'h5] = 'h2F3; end
    default: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
    endcase

3'b010: // Row: 2
    unique case ( col)
     0: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2DC; arA23[ 'h5] = 'X; end
     1: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2DC; arA23[ 'h5] = 'X; end
     2: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00B; arA23[ 'h5] = 'h2F7; end
     3: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00F; arA23[ 'h5] = 'h2F7; end
     4: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h179; arA23[ 'h5] = 'h2F7; end
     5: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1C6; arA23[ 'h5] = 'h2F7; end
     6: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E7; arA23[ 'h5] = 'h2F7; end
     7: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00E; arA23[ 'h5] = 'h2F7; end
     8: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E6; arA23[ 'h5] = 'h2F7; end
    default: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
    endcase

3'b011: // Row: 3
    unique case ( col)
     0: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h384; arA23[ 'h5] = 'X; end
     1: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h06C; arA23[ 'h5] = 'X; end
     2: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h006; arA23[ 'h5] = 'h380; end
     3: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h21C; arA23[ 'h5] = 'h380; end
     4: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h103; arA23[ 'h5] = 'h380; end
     5: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1C2; arA23[ 'h5] = 'h380; end
     6: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E3; arA23[ 'h5] = 'h380; end
     7: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00A; arA23[ 'h5] = 'h380; end
     8: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E2; arA23[ 'h5] = 'h380; end
    default: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
    endcase

3'b100: // Row: 4
    unique case ( col)
     0: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2D8; arA23[ 'h5] = 'X; end
     1: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
     2: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h006; arA23[ 'h5] = 'h2F3; end
     3: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h21C; arA23[ 'h5] = 'h2F3; end
     4: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h103; arA23[ 'h5] = 'h2F3; end
     5: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1C2; arA23[ 'h5] = 'h2F3; end
     6: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E3; arA23[ 'h5] = 'h2F3; end
     7: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00A; arA23[ 'h5] = 'h2F3; end
     8: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E2; arA23[ 'h5] = 'h2F3; end
    default: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
    endcase

3'b101: // Row: 5
    unique case ( col)
     0: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2D8; arA23[ 'h5] = 'X; end
     1: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2DC; arA23[ 'h5] = 'X; end
     2: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h006; arA23[ 'h5] = 'h2F3; end
     3: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h21C; arA23[ 'h5] = 'h2F3; end
     4: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h103; arA23[ 'h5] = 'h2F3; end
     5: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1C2; arA23[ 'h5] = 'h2F3; end
     6: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E3; arA23[ 'h5] = 'h2F3; end
     7: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00A; arA23[ 'h5] = 'h2F3; end
     8: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E2; arA23[ 'h5] = 'h2F3; end
    default: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
    endcase

3'b110: // Row: 6
    unique case ( col)
     0: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2DC; arA23[ 'h5] = 'X; end
     1: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h2DC; arA23[ 'h5] = 'X; end
     2: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00B; arA23[ 'h5] = 'h2F7; end
     3: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00F; arA23[ 'h5] = 'h2F7; end
     4: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h179; arA23[ 'h5] = 'h2F7; end
     5: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1C6; arA23[ 'h5] = 'h2F7; end
     6: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E7; arA23[ 'h5] = 'h2F7; end
     7: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00E; arA23[ 'h5] = 'h2F7; end
     8: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E6; arA23[ 'h5] = 'h2F7; end
    default: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
    endcase

3'b111: // Row: 7
    unique case ( col)
     0: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h384; arA23[ 'h5] = 'X; end
     1: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h06C; arA23[ 'h5] = 'X; end
     2: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h006; arA23[ 'h5] = 'h380; end
     3: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h21C; arA23[ 'h5] = 'h380; end
     4: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h103; arA23[ 'h5] = 'h380; end
     5: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1C2; arA23[ 'h5] = 'h380; end
     6: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E3; arA23[ 'h5] = 'h380; end
     7: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h00A; arA23[ 'h5] = 'h380; end
     8: begin arIll[ 'h5] = 1'b0; arA1[ 'h5] = 'h1E2; arA23[ 'h5] = 'h380; end
    default: begin arIll[ 'h5] = 1'b1; arA1[ 'h5] = 'X   ; arA23[ 'h5] = 'X; end
    endcase
endcase

//
// Line: 8
//
unique case( row86)

3'b000: // Row: 0
    unique case ( col)
     0: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C1; arA23[ 'h8] = 'X; end
     1: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     2: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h006; arA23[ 'h8] = 'h1C3; end
     3: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h21C; arA23[ 'h8] = 'h1C3; end
     4: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h103; arA23[ 'h8] = 'h1C3; end
     5: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h1C3; end
     6: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h1C3; end
     7: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00A; arA23[ 'h8] = 'h1C3; end
     8: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E2; arA23[ 'h8] = 'h1C3; end
     9: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h1C3; end
    10: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h1C3; end
    11: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h0EA; arA23[ 'h8] = 'h1C1; end
    default: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    endcase

3'b001: // Row: 1
    unique case ( col)
     0: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C1; arA23[ 'h8] = 'X; end
     1: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     2: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h006; arA23[ 'h8] = 'h1C3; end
     3: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h21C; arA23[ 'h8] = 'h1C3; end
     4: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h103; arA23[ 'h8] = 'h1C3; end
     5: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h1C3; end
     6: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h1C3; end
     7: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00A; arA23[ 'h8] = 'h1C3; end
     8: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E2; arA23[ 'h8] = 'h1C3; end
     9: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h1C3; end
    10: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h1C3; end
    11: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h0EA; arA23[ 'h8] = 'h1C1; end
    default: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    endcase

3'b010: // Row: 2
    unique case ( col)
     0: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C5; arA23[ 'h8] = 'X; end
     1: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     2: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00B; arA23[ 'h8] = 'h1CB; end
     3: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00F; arA23[ 'h8] = 'h1CB; end
     4: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h179; arA23[ 'h8] = 'h1CB; end
     5: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C6; arA23[ 'h8] = 'h1CB; end
     6: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E7; arA23[ 'h8] = 'h1CB; end
     7: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00E; arA23[ 'h8] = 'h1CB; end
     8: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E6; arA23[ 'h8] = 'h1CB; end
     9: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C6; arA23[ 'h8] = 'h1CB; end
    10: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E7; arA23[ 'h8] = 'h1CB; end
    11: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h0A7; arA23[ 'h8] = 'h1C5; end
    default: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    endcase

3'b011: // Row: 3
    unique case ( col)
     0: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h0A6; arA23[ 'h8] = 'X; end
     1: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     2: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h006; arA23[ 'h8] = 'h0A4; end
     3: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h21C; arA23[ 'h8] = 'h0A4; end
     4: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h103; arA23[ 'h8] = 'h0A4; end
     5: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h0A4; end
     6: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h0A4; end
     7: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00A; arA23[ 'h8] = 'h0A4; end
     8: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E2; arA23[ 'h8] = 'h0A4; end
     9: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h0A4; end
    10: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h0A4; end
    11: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h0EA; arA23[ 'h8] = 'h0A6; end
    default: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    endcase

3'b100: // Row: 4
    unique case ( col)
     0: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1CD; arA23[ 'h8] = 'X; end
     1: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h107; arA23[ 'h8] = 'X; end
     2: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h006; arA23[ 'h8] = 'h299; end
     3: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h21C; arA23[ 'h8] = 'h299; end
     4: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h103; arA23[ 'h8] = 'h299; end
     5: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h299; end
     6: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h299; end
     7: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00A; arA23[ 'h8] = 'h299; end
     8: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E2; arA23[ 'h8] = 'h299; end
     9: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    10: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    11: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    default: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    endcase

3'b101: // Row: 5
    unique case ( col)
     0: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     1: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     2: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h006; arA23[ 'h8] = 'h299; end
     3: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h21C; arA23[ 'h8] = 'h299; end
     4: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h103; arA23[ 'h8] = 'h299; end
     5: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h299; end
     6: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h299; end
     7: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00A; arA23[ 'h8] = 'h299; end
     8: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E2; arA23[ 'h8] = 'h299; end
     9: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    10: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    11: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    default: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    endcase

3'b110: // Row: 6
    unique case ( col)
     0: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     1: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     2: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00B; arA23[ 'h8] = 'h29D; end
     3: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00F; arA23[ 'h8] = 'h29D; end
     4: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h179; arA23[ 'h8] = 'h29D; end
     5: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C6; arA23[ 'h8] = 'h29D; end
     6: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E7; arA23[ 'h8] = 'h29D; end
     7: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00E; arA23[ 'h8] = 'h29D; end
     8: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E6; arA23[ 'h8] = 'h29D; end
     9: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    10: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    11: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    default: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    endcase

3'b111: // Row: 7
    unique case ( col)
     0: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h0AE; arA23[ 'h8] = 'X; end
     1: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
     2: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h006; arA23[ 'h8] = 'h0AC; end
     3: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h21C; arA23[ 'h8] = 'h0AC; end
     4: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h103; arA23[ 'h8] = 'h0AC; end
     5: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h0AC; end
     6: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h0AC; end
     7: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h00A; arA23[ 'h8] = 'h0AC; end
     8: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E2; arA23[ 'h8] = 'h0AC; end
     9: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1C2; arA23[ 'h8] = 'h0AC; end
    10: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h1E3; arA23[ 'h8] = 'h0AC; end
    11: begin arIll[ 'h8] = 1'b0; arA1[ 'h8] = 'h0EA; arA23[ 'h8] = 'h0AE; end
    default: begin arIll[ 'h8] = 1'b1; arA1[ 'h8] = 'X   ; arA23[ 'h8] = 'X; end
    endcase
endcase

//
// Line: 9
//
unique case( row86)

3'b000: // Row: 0
    unique case ( col)
     0: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C1; arA23[ 'h9] = 'X; end
     1: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
     2: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h006; arA23[ 'h9] = 'h1C3; end
     3: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h21C; arA23[ 'h9] = 'h1C3; end
     4: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h103; arA23[ 'h9] = 'h1C3; end
     5: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C2; arA23[ 'h9] = 'h1C3; end
     6: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E3; arA23[ 'h9] = 'h1C3; end
     7: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00A; arA23[ 'h9] = 'h1C3; end
     8: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E2; arA23[ 'h9] = 'h1C3; end
     9: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C2; arA23[ 'h9] = 'h1C3; end
    10: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E3; arA23[ 'h9] = 'h1C3; end
    11: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h0EA; arA23[ 'h9] = 'h1C1; end
    default: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    endcase

3'b001: // Row: 1
    unique case ( col)
     0: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C1; arA23[ 'h9] = 'X; end
     1: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C1; arA23[ 'h9] = 'X; end
     2: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h006; arA23[ 'h9] = 'h1C3; end
     3: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h21C; arA23[ 'h9] = 'h1C3; end
     4: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h103; arA23[ 'h9] = 'h1C3; end
     5: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C2; arA23[ 'h9] = 'h1C3; end
     6: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E3; arA23[ 'h9] = 'h1C3; end
     7: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00A; arA23[ 'h9] = 'h1C3; end
     8: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E2; arA23[ 'h9] = 'h1C3; end
     9: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C2; arA23[ 'h9] = 'h1C3; end
    10: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E3; arA23[ 'h9] = 'h1C3; end
    11: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h0EA; arA23[ 'h9] = 'h1C1; end
    default: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    endcase

3'b010: // Row: 2
    unique case ( col)
     0: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C5; arA23[ 'h9] = 'X; end
     1: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C5; arA23[ 'h9] = 'X; end
     2: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00B; arA23[ 'h9] = 'h1CB; end
     3: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00F; arA23[ 'h9] = 'h1CB; end
     4: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h179; arA23[ 'h9] = 'h1CB; end
     5: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C6; arA23[ 'h9] = 'h1CB; end
     6: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E7; arA23[ 'h9] = 'h1CB; end
     7: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00E; arA23[ 'h9] = 'h1CB; end
     8: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E6; arA23[ 'h9] = 'h1CB; end
     9: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C6; arA23[ 'h9] = 'h1CB; end
    10: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E7; arA23[ 'h9] = 'h1CB; end
    11: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h0A7; arA23[ 'h9] = 'h1C5; end
    default: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    endcase

3'b011: // Row: 3
    unique case ( col)
     0: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C9; arA23[ 'h9] = 'X; end
     1: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C9; arA23[ 'h9] = 'X; end
     2: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h006; arA23[ 'h9] = 'h1C7; end
     3: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h21C; arA23[ 'h9] = 'h1C7; end
     4: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h103; arA23[ 'h9] = 'h1C7; end
     5: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C2; arA23[ 'h9] = 'h1C7; end
     6: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E3; arA23[ 'h9] = 'h1C7; end
     7: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00A; arA23[ 'h9] = 'h1C7; end
     8: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E2; arA23[ 'h9] = 'h1C7; end
     9: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C2; arA23[ 'h9] = 'h1C7; end
    10: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E3; arA23[ 'h9] = 'h1C7; end
    11: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h0EA; arA23[ 'h9] = 'h1C9; end
    default: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    endcase

3'b100: // Row: 4
    unique case ( col)
     0: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C1; arA23[ 'h9] = 'X; end
     1: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h10F; arA23[ 'h9] = 'X; end
     2: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h006; arA23[ 'h9] = 'h299; end
     3: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h21C; arA23[ 'h9] = 'h299; end
     4: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h103; arA23[ 'h9] = 'h299; end
     5: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C2; arA23[ 'h9] = 'h299; end
     6: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E3; arA23[ 'h9] = 'h299; end
     7: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00A; arA23[ 'h9] = 'h299; end
     8: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E2; arA23[ 'h9] = 'h299; end
     9: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    10: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    11: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    default: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    endcase

3'b101: // Row: 5
    unique case ( col)
     0: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C1; arA23[ 'h9] = 'X; end
     1: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h10F; arA23[ 'h9] = 'X; end
     2: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h006; arA23[ 'h9] = 'h299; end
     3: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h21C; arA23[ 'h9] = 'h299; end
     4: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h103; arA23[ 'h9] = 'h299; end
     5: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C2; arA23[ 'h9] = 'h299; end
     6: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E3; arA23[ 'h9] = 'h299; end
     7: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00A; arA23[ 'h9] = 'h299; end
     8: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E2; arA23[ 'h9] = 'h299; end
     9: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    10: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    11: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    default: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    endcase

3'b110: // Row: 6
    unique case ( col)
     0: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C5; arA23[ 'h9] = 'X; end
     1: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h10B; arA23[ 'h9] = 'X; end
     2: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00B; arA23[ 'h9] = 'h29D; end
     3: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00F; arA23[ 'h9] = 'h29D; end
     4: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h179; arA23[ 'h9] = 'h29D; end
     5: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C6; arA23[ 'h9] = 'h29D; end
     6: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E7; arA23[ 'h9] = 'h29D; end
     7: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00E; arA23[ 'h9] = 'h29D; end
     8: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E6; arA23[ 'h9] = 'h29D; end
     9: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    10: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    11: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    default: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    endcase

3'b111: // Row: 7
    unique case ( col)
     0: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C5; arA23[ 'h9] = 'X; end
     1: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C5; arA23[ 'h9] = 'X; end
     2: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00B; arA23[ 'h9] = 'h1CB; end
     3: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00F; arA23[ 'h9] = 'h1CB; end
     4: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h179; arA23[ 'h9] = 'h1CB; end
     5: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C6; arA23[ 'h9] = 'h1CB; end
     6: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E7; arA23[ 'h9] = 'h1CB; end
     7: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h00E; arA23[ 'h9] = 'h1CB; end
     8: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E6; arA23[ 'h9] = 'h1CB; end
     9: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1C6; arA23[ 'h9] = 'h1CB; end
    10: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h1E7; arA23[ 'h9] = 'h1CB; end
    11: begin arIll[ 'h9] = 1'b0; arA1[ 'h9] = 'h0A7; arA23[ 'h9] = 'h1C5; end
    default: begin arIll[ 'h9] = 1'b1; arA1[ 'h9] = 'X   ; arA23[ 'h9] = 'X; end
    endcase
endcase

//
// Line: B
//
unique case( row86)

3'b000: // Row: 0
    unique case ( col)
     0: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D1; arA23[ 'hb] = 'X; end
     1: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
     2: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h006; arA23[ 'hb] = 'h1D3; end
     3: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h21C; arA23[ 'hb] = 'h1D3; end
     4: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h103; arA23[ 'hb] = 'h1D3; end
     5: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C2; arA23[ 'hb] = 'h1D3; end
     6: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E3; arA23[ 'hb] = 'h1D3; end
     7: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00A; arA23[ 'hb] = 'h1D3; end
     8: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E2; arA23[ 'hb] = 'h1D3; end
     9: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C2; arA23[ 'hb] = 'h1D3; end
    10: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E3; arA23[ 'hb] = 'h1D3; end
    11: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h0EA; arA23[ 'hb] = 'h1D1; end
    default: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    endcase

3'b001: // Row: 1
    unique case ( col)
     0: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D1; arA23[ 'hb] = 'X; end
     1: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D1; arA23[ 'hb] = 'X; end
     2: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h006; arA23[ 'hb] = 'h1D3; end
     3: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h21C; arA23[ 'hb] = 'h1D3; end
     4: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h103; arA23[ 'hb] = 'h1D3; end
     5: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C2; arA23[ 'hb] = 'h1D3; end
     6: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E3; arA23[ 'hb] = 'h1D3; end
     7: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00A; arA23[ 'hb] = 'h1D3; end
     8: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E2; arA23[ 'hb] = 'h1D3; end
     9: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C2; arA23[ 'hb] = 'h1D3; end
    10: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E3; arA23[ 'hb] = 'h1D3; end
    11: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h0EA; arA23[ 'hb] = 'h1D1; end
    default: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    endcase

3'b010: // Row: 2
    unique case ( col)
     0: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D5; arA23[ 'hb] = 'X; end
     1: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D5; arA23[ 'hb] = 'X; end
     2: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00B; arA23[ 'hb] = 'h1D7; end
     3: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00F; arA23[ 'hb] = 'h1D7; end
     4: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h179; arA23[ 'hb] = 'h1D7; end
     5: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C6; arA23[ 'hb] = 'h1D7; end
     6: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E7; arA23[ 'hb] = 'h1D7; end
     7: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00E; arA23[ 'hb] = 'h1D7; end
     8: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E6; arA23[ 'hb] = 'h1D7; end
     9: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C6; arA23[ 'hb] = 'h1D7; end
    10: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E7; arA23[ 'hb] = 'h1D7; end
    11: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h0A7; arA23[ 'hb] = 'h1D5; end
    default: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    endcase

3'b011: // Row: 3
    unique case ( col)
     0: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D9; arA23[ 'hb] = 'X; end
     1: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D9; arA23[ 'hb] = 'X; end
     2: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h006; arA23[ 'hb] = 'h1CF; end
     3: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h21C; arA23[ 'hb] = 'h1CF; end
     4: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h103; arA23[ 'hb] = 'h1CF; end
     5: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C2; arA23[ 'hb] = 'h1CF; end
     6: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E3; arA23[ 'hb] = 'h1CF; end
     7: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00A; arA23[ 'hb] = 'h1CF; end
     8: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E2; arA23[ 'hb] = 'h1CF; end
     9: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C2; arA23[ 'hb] = 'h1CF; end
    10: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E3; arA23[ 'hb] = 'h1CF; end
    11: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h0EA; arA23[ 'hb] = 'h1D9; end
    default: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    endcase

3'b100: // Row: 4
    unique case ( col)
     0: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h100; arA23[ 'hb] = 'X; end
     1: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h06B; arA23[ 'hb] = 'X; end
     2: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h006; arA23[ 'hb] = 'h299; end
     3: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h21C; arA23[ 'hb] = 'h299; end
     4: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h103; arA23[ 'hb] = 'h299; end
     5: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C2; arA23[ 'hb] = 'h299; end
     6: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E3; arA23[ 'hb] = 'h299; end
     7: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00A; arA23[ 'hb] = 'h299; end
     8: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E2; arA23[ 'hb] = 'h299; end
     9: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    10: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    11: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    default: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    endcase

3'b101: // Row: 5
    unique case ( col)
     0: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h100; arA23[ 'hb] = 'X; end
     1: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h06B; arA23[ 'hb] = 'X; end
     2: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h006; arA23[ 'hb] = 'h299; end
     3: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h21C; arA23[ 'hb] = 'h299; end
     4: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h103; arA23[ 'hb] = 'h299; end
     5: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C2; arA23[ 'hb] = 'h299; end
     6: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E3; arA23[ 'hb] = 'h299; end
     7: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00A; arA23[ 'hb] = 'h299; end
     8: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E2; arA23[ 'hb] = 'h299; end
     9: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    10: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    11: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    default: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    endcase

3'b110: // Row: 6
    unique case ( col)
     0: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h10C; arA23[ 'hb] = 'X; end
     1: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h06F; arA23[ 'hb] = 'X; end
     2: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00B; arA23[ 'hb] = 'h29D; end
     3: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00F; arA23[ 'hb] = 'h29D; end
     4: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h179; arA23[ 'hb] = 'h29D; end
     5: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C6; arA23[ 'hb] = 'h29D; end
     6: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E7; arA23[ 'hb] = 'h29D; end
     7: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00E; arA23[ 'hb] = 'h29D; end
     8: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E6; arA23[ 'hb] = 'h29D; end
     9: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    10: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    11: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    default: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    endcase

3'b111: // Row: 7
    unique case ( col)
     0: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D5; arA23[ 'hb] = 'X; end
     1: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1D5; arA23[ 'hb] = 'X; end
     2: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00B; arA23[ 'hb] = 'h1D7; end
     3: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00F; arA23[ 'hb] = 'h1D7; end
     4: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h179; arA23[ 'hb] = 'h1D7; end
     5: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C6; arA23[ 'hb] = 'h1D7; end
     6: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E7; arA23[ 'hb] = 'h1D7; end
     7: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h00E; arA23[ 'hb] = 'h1D7; end
     8: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E6; arA23[ 'hb] = 'h1D7; end
     9: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1C6; arA23[ 'hb] = 'h1D7; end
    10: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h1E7; arA23[ 'hb] = 'h1D7; end
    11: begin arIll[ 'hb] = 1'b0; arA1[ 'hb] = 'h0A7; arA23[ 'hb] = 'h1D5; end
    default: begin arIll[ 'hb] = 1'b1; arA1[ 'hb] = 'X   ; arA23[ 'hb] = 'X; end
    endcase
endcase

//
// Line: C
//
unique case( row86)

3'b000: // Row: 0
    unique case ( col)
     0: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C1; arA23[ 'hc] = 'X; end
     1: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
     2: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h006; arA23[ 'hc] = 'h1C3; end
     3: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h21C; arA23[ 'hc] = 'h1C3; end
     4: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h103; arA23[ 'hc] = 'h1C3; end
     5: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h1C3; end
     6: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h1C3; end
     7: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00A; arA23[ 'hc] = 'h1C3; end
     8: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E2; arA23[ 'hc] = 'h1C3; end
     9: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h1C3; end
    10: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h1C3; end
    11: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h0EA; arA23[ 'hc] = 'h1C1; end
    default: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    endcase

3'b001: // Row: 1
    unique case ( col)
     0: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C1; arA23[ 'hc] = 'X; end
     1: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
     2: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h006; arA23[ 'hc] = 'h1C3; end
     3: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h21C; arA23[ 'hc] = 'h1C3; end
     4: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h103; arA23[ 'hc] = 'h1C3; end
     5: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h1C3; end
     6: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h1C3; end
     7: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00A; arA23[ 'hc] = 'h1C3; end
     8: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E2; arA23[ 'hc] = 'h1C3; end
     9: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h1C3; end
    10: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h1C3; end
    11: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h0EA; arA23[ 'hc] = 'h1C1; end
    default: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    endcase

3'b010: // Row: 2
    unique case ( col)
     0: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C5; arA23[ 'hc] = 'X; end
     1: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
     2: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00B; arA23[ 'hc] = 'h1CB; end
     3: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00F; arA23[ 'hc] = 'h1CB; end
     4: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h179; arA23[ 'hc] = 'h1CB; end
     5: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C6; arA23[ 'hc] = 'h1CB; end
     6: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E7; arA23[ 'hc] = 'h1CB; end
     7: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00E; arA23[ 'hc] = 'h1CB; end
     8: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E6; arA23[ 'hc] = 'h1CB; end
     9: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C6; arA23[ 'hc] = 'h1CB; end
    10: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E7; arA23[ 'hc] = 'h1CB; end
    11: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h0A7; arA23[ 'hc] = 'h1C5; end
    default: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    endcase

3'b011: // Row: 3
    unique case ( col)
     0: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h15B; arA23[ 'hc] = 'X; end
     1: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
     2: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h006; arA23[ 'hc] = 'h15A; end
     3: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h21C; arA23[ 'hc] = 'h15A; end
     4: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h103; arA23[ 'hc] = 'h15A; end
     5: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h15A; end
     6: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h15A; end
     7: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00A; arA23[ 'hc] = 'h15A; end
     8: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E2; arA23[ 'hc] = 'h15A; end
     9: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h15A; end
    10: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h15A; end
    11: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h0EA; arA23[ 'hc] = 'h15B; end
    default: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    endcase

3'b100: // Row: 4
    unique case ( col)
     0: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1CD; arA23[ 'hc] = 'X; end
     1: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h107; arA23[ 'hc] = 'X; end
     2: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h006; arA23[ 'hc] = 'h299; end
     3: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h21C; arA23[ 'hc] = 'h299; end
     4: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h103; arA23[ 'hc] = 'h299; end
     5: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h299; end
     6: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h299; end
     7: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00A; arA23[ 'hc] = 'h299; end
     8: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E2; arA23[ 'hc] = 'h299; end
     9: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    10: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    11: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    default: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    endcase

3'b101: // Row: 5
    unique case ( col)
     0: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h3E3; arA23[ 'hc] = 'X; end
     1: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h3E3; arA23[ 'hc] = 'X; end
     2: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h006; arA23[ 'hc] = 'h299; end
     3: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h21C; arA23[ 'hc] = 'h299; end
     4: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h103; arA23[ 'hc] = 'h299; end
     5: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h299; end
     6: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h299; end
     7: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00A; arA23[ 'hc] = 'h299; end
     8: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E2; arA23[ 'hc] = 'h299; end
     9: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    10: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    11: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    default: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    endcase

3'b110: // Row: 6
    unique case ( col)
     0: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
     1: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h3E3; arA23[ 'hc] = 'X; end
     2: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00B; arA23[ 'hc] = 'h29D; end
     3: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00F; arA23[ 'hc] = 'h29D; end
     4: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h179; arA23[ 'hc] = 'h29D; end
     5: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C6; arA23[ 'hc] = 'h29D; end
     6: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E7; arA23[ 'hc] = 'h29D; end
     7: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00E; arA23[ 'hc] = 'h29D; end
     8: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E6; arA23[ 'hc] = 'h29D; end
     9: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    10: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    11: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    default: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    endcase

3'b111: // Row: 7
    unique case ( col)
     0: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h15B; arA23[ 'hc] = 'X; end
     1: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
     2: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h006; arA23[ 'hc] = 'h15A; end
     3: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h21C; arA23[ 'hc] = 'h15A; end
     4: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h103; arA23[ 'hc] = 'h15A; end
     5: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h15A; end
     6: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h15A; end
     7: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h00A; arA23[ 'hc] = 'h15A; end
     8: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E2; arA23[ 'hc] = 'h15A; end
     9: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1C2; arA23[ 'hc] = 'h15A; end
    10: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h1E3; arA23[ 'hc] = 'h15A; end
    11: begin arIll[ 'hc] = 1'b0; arA1[ 'hc] = 'h0EA; arA23[ 'hc] = 'h15B; end
    default: begin arIll[ 'hc] = 1'b1; arA1[ 'hc] = 'X   ; arA23[ 'hc] = 'X; end
    endcase
endcase

//
// Line: D
//
unique case( row86)

3'b000: // Row: 0
    unique case ( col)
     0: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C1; arA23[ 'hd] = 'X; end
     1: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
     2: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h006; arA23[ 'hd] = 'h1C3; end
     3: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h21C; arA23[ 'hd] = 'h1C3; end
     4: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h103; arA23[ 'hd] = 'h1C3; end
     5: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C2; arA23[ 'hd] = 'h1C3; end
     6: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E3; arA23[ 'hd] = 'h1C3; end
     7: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00A; arA23[ 'hd] = 'h1C3; end
     8: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E2; arA23[ 'hd] = 'h1C3; end
     9: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C2; arA23[ 'hd] = 'h1C3; end
    10: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E3; arA23[ 'hd] = 'h1C3; end
    11: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h0EA; arA23[ 'hd] = 'h1C1; end
    default: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    endcase

3'b001: // Row: 1
    unique case ( col)
     0: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C1; arA23[ 'hd] = 'X; end
     1: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C1; arA23[ 'hd] = 'X; end
     2: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h006; arA23[ 'hd] = 'h1C3; end
     3: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h21C; arA23[ 'hd] = 'h1C3; end
     4: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h103; arA23[ 'hd] = 'h1C3; end
     5: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C2; arA23[ 'hd] = 'h1C3; end
     6: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E3; arA23[ 'hd] = 'h1C3; end
     7: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00A; arA23[ 'hd] = 'h1C3; end
     8: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E2; arA23[ 'hd] = 'h1C3; end
     9: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C2; arA23[ 'hd] = 'h1C3; end
    10: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E3; arA23[ 'hd] = 'h1C3; end
    11: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h0EA; arA23[ 'hd] = 'h1C1; end
    default: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    endcase

3'b010: // Row: 2
    unique case ( col)
     0: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C5; arA23[ 'hd] = 'X; end
     1: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C5; arA23[ 'hd] = 'X; end
     2: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00B; arA23[ 'hd] = 'h1CB; end
     3: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00F; arA23[ 'hd] = 'h1CB; end
     4: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h179; arA23[ 'hd] = 'h1CB; end
     5: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C6; arA23[ 'hd] = 'h1CB; end
     6: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E7; arA23[ 'hd] = 'h1CB; end
     7: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00E; arA23[ 'hd] = 'h1CB; end
     8: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E6; arA23[ 'hd] = 'h1CB; end
     9: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C6; arA23[ 'hd] = 'h1CB; end
    10: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E7; arA23[ 'hd] = 'h1CB; end
    11: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h0A7; arA23[ 'hd] = 'h1C5; end
    default: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    endcase

3'b011: // Row: 3
    unique case ( col)
     0: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C9; arA23[ 'hd] = 'X; end
     1: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C9; arA23[ 'hd] = 'X; end
     2: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h006; arA23[ 'hd] = 'h1C7; end
     3: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h21C; arA23[ 'hd] = 'h1C7; end
     4: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h103; arA23[ 'hd] = 'h1C7; end
     5: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C2; arA23[ 'hd] = 'h1C7; end
     6: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E3; arA23[ 'hd] = 'h1C7; end
     7: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00A; arA23[ 'hd] = 'h1C7; end
     8: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E2; arA23[ 'hd] = 'h1C7; end
     9: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C2; arA23[ 'hd] = 'h1C7; end
    10: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E3; arA23[ 'hd] = 'h1C7; end
    11: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h0EA; arA23[ 'hd] = 'h1C9; end
    default: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    endcase

3'b100: // Row: 4
    unique case ( col)
     0: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C1; arA23[ 'hd] = 'X; end
     1: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h10F; arA23[ 'hd] = 'X; end
     2: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h006; arA23[ 'hd] = 'h299; end
     3: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h21C; arA23[ 'hd] = 'h299; end
     4: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h103; arA23[ 'hd] = 'h299; end
     5: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C2; arA23[ 'hd] = 'h299; end
     6: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E3; arA23[ 'hd] = 'h299; end
     7: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00A; arA23[ 'hd] = 'h299; end
     8: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E2; arA23[ 'hd] = 'h299; end
     9: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    10: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    11: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    default: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    endcase

3'b101: // Row: 5
    unique case ( col)
     0: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C1; arA23[ 'hd] = 'X; end
     1: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h10F; arA23[ 'hd] = 'X; end
     2: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h006; arA23[ 'hd] = 'h299; end
     3: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h21C; arA23[ 'hd] = 'h299; end
     4: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h103; arA23[ 'hd] = 'h299; end
     5: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C2; arA23[ 'hd] = 'h299; end
     6: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E3; arA23[ 'hd] = 'h299; end
     7: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00A; arA23[ 'hd] = 'h299; end
     8: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E2; arA23[ 'hd] = 'h299; end
     9: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    10: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    11: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    default: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    endcase

3'b110: // Row: 6
    unique case ( col)
     0: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C5; arA23[ 'hd] = 'X; end
     1: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h10B; arA23[ 'hd] = 'X; end
     2: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00B; arA23[ 'hd] = 'h29D; end
     3: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00F; arA23[ 'hd] = 'h29D; end
     4: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h179; arA23[ 'hd] = 'h29D; end
     5: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C6; arA23[ 'hd] = 'h29D; end
     6: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E7; arA23[ 'hd] = 'h29D; end
     7: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00E; arA23[ 'hd] = 'h29D; end
     8: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E6; arA23[ 'hd] = 'h29D; end
     9: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    10: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    11: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    default: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    endcase

3'b111: // Row: 7
    unique case ( col)
     0: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C5; arA23[ 'hd] = 'X; end
     1: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C5; arA23[ 'hd] = 'X; end
     2: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00B; arA23[ 'hd] = 'h1CB; end
     3: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00F; arA23[ 'hd] = 'h1CB; end
     4: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h179; arA23[ 'hd] = 'h1CB; end
     5: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C6; arA23[ 'hd] = 'h1CB; end
     6: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E7; arA23[ 'hd] = 'h1CB; end
     7: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h00E; arA23[ 'hd] = 'h1CB; end
     8: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E6; arA23[ 'hd] = 'h1CB; end
     9: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1C6; arA23[ 'hd] = 'h1CB; end
    10: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h1E7; arA23[ 'hd] = 'h1CB; end
    11: begin arIll[ 'hd] = 1'b0; arA1[ 'hd] = 'h0A7; arA23[ 'hd] = 'h1C5; end
    default: begin arIll[ 'hd] = 1'b1; arA1[ 'hd] = 'X   ; arA23[ 'hd] = 'X; end
    endcase
endcase
end


endmodule
