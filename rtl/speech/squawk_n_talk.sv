//============================================================================
//  Bally "Squawk & Talk" sound/speech board
//
//  Used by Discs of Tron (Environmental) -- MAME set `dotrone`. NOT present on
//  the upright `dotron`/`dotrona` PCBs, which have no speech hardware at all.
//
//  Board contents (MAME `bally_squawk_n_talk_device`, src/mame/shared/
//  ballysound.cpp). Discs of Tron uses the BASE variant: no AY-3-8910 (the
//  AY pair in dotrone's device list belongs to the SSIO board, not to this one):
//
//      MC6802   @ 3.579545 MHz  -> E clock /4 ~= 894.9 kHz
//      2x PIA 6821
//      TMS5200  @ 640 kHz       -> ROMCLK 160 kHz
//      AD558 8-bit DAC
//
//  Host interface: the SSIO's OP4 output latch (mcr.cpp `dotron_op4_w`)
//      bits 3:0 = MD3-0 sound select, read back on PIA2 port A as ~sel & 0x1F
//      bit  4   = interrupt, INVERTED into PIA2 CB1
//      bits 7,6 = flasher/backlight, bits 5:0 = lamp sequencer (cosmetic, and
//                 not modelled here)
//
//  Memory map (`squawk_n_talk_map`), as seen by the 6802:
//      0000-007F  internal 128 B RAM (inside the 6802, not in the map)
//      0080-0083  PIA2                mirror 0x4F6C
//      0090-0093  PIA1                mirror 0x4F6C
//      1000       AD558 DAC           mirror 0x40FF
//      8000-BFFF  ROM (U2..U5)        mirror 0x4000
//
//  The 0x4000 ROM mirror is load-bearing, and more so than it first looks.
//  The 6802 fetches its vectors from FFF8-FFFF, which the mirror serves out of
//  BFF8-BFFF in `pre.u5`. Reading those bytes out of the actual ROM:
//
//      IRQ   $FFF8 = $FA45      NMI   $FFFC = $F974
//      SWI   $FFFA = $F983      RESET $FFFE = $F983
//
//  Every one of them points into the $C000-$FFFF MIRROR, not into the
//  $8000-$BFFF base window ($F983 - $4000 = $B983, inside pre.u5). So the
//  board does not merely take its reset vector through the mirror -- it
//  EXECUTES there. Decoding only $8000-$BFFF gives a 6802 that resets to an
//  unmapped address and a board that is silent with no other symptom.
//
//  Hence: chip select on cpu_addr[15] alone, ignoring cpu_addr[14], with
//  rom_addr = cpu_addr[13:0]. That covers base and mirror in one decode.
//
//  STATUS: STEP 4. Everything is real -- 6802, both PIAs, the AD558 DAC and
//  the TMS5200 speech synthesiser. No stubs remain.
//
//  jt680x is (c) Jose Tejada / JTCORES, GPL-3.0, vendored from
//  MiSTer-devel/Arcade-Qix_MiSTer where it is likewise used as an MC6802.
//  pia6821.vhd is the MiSTer Arcade-MCR3Scroll copy, byte-identical to the one
//  the Tang parent project already vendors -- deliberately, so the port is a
//  move rather than a rewrite.
//============================================================================

module squawk_n_talk
(
	input             clk,        // 40 MHz system clock
	input             reset,

	// ---- host side: SSIO OP4 latch -------------------------------------
	input       [3:0] sound_select,  // OP4[3:0], MD3-0
	input             sound_int,     // OP4[4]
	// Debug taps so the JTAG probe can answer "is the game even in
	// Environmental mode?" -- IP2 bit 7 is the cabinet strap, active low,
	// so 0 = Environmental. Environmental ROMs strapped as upright would
	// play perfectly and simply never ask for speech.
	input       [7:0] dbg_in2,
	input       [7:0] dbg_op4,

	// ---- board ROM: 16 KB window at 6802 $8000-$BFFF (+ mirror) --------
	output     [13:0] rom_addr,
	input       [7:0] rom_do,

	// ---- audio ---------------------------------------------------------
	output signed [15:0] audio_out,

	// ---- observability -------------------------------------------------
	// `active` is a stretched flag: the host has written a NEW non-zero
	// sound command. It answers the one question step 3 exists to answer --
	// is the game actually talking to this board? -- without needing
	// SignalTap. The rest are raw taps for a SignalTap instance later.
	output            active,
	// `seen` is the STICKY form of `active`: set on the first non-zero sound
	// command and held until reset, so a single screenshot can answer the
	// question rather than needing to catch a flash.
	output            seen,
	// Two more sticky facts about the BOARD side, so one screenshot can
	// distinguish "the game never asked" from "the board never answered":
	//   cpu_run    - the 6802's address bus has changed 255 times, i.e. it is
	//                fetching, not parked on a bad vector
	//   dac_written- the 6802 has written the AD558 at least once, i.e. it is
	//                executing real board code rather than just spinning
	// RED is now a 3-bit code too, aimed at the "is the ROM even there?"
	// question that green=0 raised:
	//   bit0  cpu_run       - address bus is moving
	//   bit1  ram_seen      - the 6802 has touched its internal RAM, which any
	//                         real program does almost immediately
	//   bit2  rom_nonzero   - the ROM has returned a byte that is not 0x00
	// A blank snt_rom makes the 6802 fetch 0x00 forever and march the PC up
	// through memory: bus moving, nothing ever accessed. That is
	// indistinguishable from "running" on a single bit, which is why the
	// first version of this probe was misleading.
	output      [2:0] cpu_run,
	// 3-bit PROGRESS CODE, not a flag. Rendered as green intensity so one
	// screenshot says how far down the chain the board actually got:
	//   bit0  the 6802 has READ pia2  - it is polling/servicing the host port
	//   bit1  cpu_irq has asserted    - the PIA actually interrupted it
	//   bit2  /WS has toggled twice   - it is pushing bytes at the TMS5200
	// Using the three bits of one colour channel buys three more facts per
	// build cycle without spending another channel.
	output      [2:0] progress,
	// LOOSE PIA decode: 0080-009F with the mirror mask ignored entirely.
	// Compared against the strict decode, this says whether the mirror mask
	// is wrong or whether the CPU simply never goes near the PIAs.
	// Repurposed now that the strict-vs-loose decode question is settled:
	//   pia_loose -> tms_streaming : /WS has pulsed >=16 times (real LPC data,
	//                                not just the single init write)
	output            pia_loose,
	// Does the speech chip actually PRODUCE anything? Splits 'chip never fed'
	// from 'chip speaks but the mix swallows it' -- the only two possibilities
	// left once every digital link reads good.
	output            tms_audio_nz,
	output            dac_written,
	output      [7:0] dbg_dac,
	output     [15:0] dbg_cpu_addr,
	output            dbg_tms_wsn,
	output            dbg_tms_rsn
);

// --------------------------------------------------------------------------
// Clock enable. jt680x wants `cen` at the CRYSTAL rate, which its header
// documents as 4x the E-pin frequency -- so 3.579545 MHz here, giving
// E = 894.886 kHz, matching MAME's DERIVED_CLOCK(1,1) on a 3'579'545 device.
//
// 40e6 / 3.579545e6 is not an integer (11.1745), so this must be a FRACTIONAL
// enable, not a counter compare. Same phase-accumulator shape Arcade-Qix uses.
// --------------------------------------------------------------------------
localparam int SYS_HZ = 40_000_000;

// --------------------------------------------------------------------------
// THE CPU RATE IS DELIBERATELY *NOT* THE CRYSTAL RATE. Read this before
// "fixing" it back to 3_579_545.
//
// jt680x is a 6801/6803 core; this board has an MC6802, which is a 6800 part.
// They differ in BRANCH timing: 6801 branches take 3 cycles, 6800/6802 take 4.
// Measured (sim/tb_speed.v): jt680x runs `DECB / BNE` in 5 cycles per
// iteration where a 6802 takes 6.
//
// That matters here because the command-assembly handler is built ON a delay
// loop. $FA57 in pre.u5 is `LDAB #$C1 / DECB / BNE *-1` -- 193 iterations --
// sitting between the two reads of PIA2 port A that make up one 8-bit sound
// command:
//     real 6802 : 193 * 6 = 1158 cy @ 894.886 kHz = 1.294 ms
//     jt680x    : 193 * 5 =  965 cy @ 894.886 kHz = 1.078 ms
//
// The game presents the two nibbles 1.255 ms apart (MEASURED in MAME: low
// nibble + strobe at t+0, high nibble at t+1255 us). The board must read once
// BEFORE that second write and once AFTER it. A real 6802's second read lands
// ~155 us after it; ours landed ~60 us BEFORE it, so both reads returned the
// LOW nibble and the handler assembled a doubled byte -- $22 for command $32 --
// which the dispatcher at $F180 routes away from the speech table. The board
// then correctly said nothing. Confirmed on hardware: last_cmd=02, high nibble
// 3 on the OP4 trace, but cmd_at_read=1D (= ~2, the low nibble again).
//
// So scale the clock enable by 5/6, which makes branch-based delay loops --
// the only timing this ROM actually depends on -- match the real part. Every
// other instruction then runs 17% slow, which is harmless: nothing else on
// this board is timing-critical (the TMS5200 runs off its own 160 kHz enable,
// and the LPC feed only has to outrun an 8 kHz frame rate).
//
// The proper fix is 6800 branch timing in the CPU core. Until jt680x grows
// that, this is the one-constant equivalent.
// --------------------------------------------------------------------------
localparam int CPU_XTAL_HZ = 3_579_545;                    // the real crystal
localparam int CPU_HZ      = (CPU_XTAL_HZ * 5) / 6;        // = 2_982_954

reg [25:0] cen_acc = 0;
wire       cen = (cen_acc >= SYS_HZ[25:0]);

always @(posedge clk) begin
	if (cen) cen_acc <= cen_acc - SYS_HZ[25:0] + CPU_HZ[25:0];
	else     cen_acc <= cen_acc + CPU_HZ[25:0];
end

reg cen_d;
always @(posedge clk) cen_d <= cen;

// --------------------------------------------------------------------------
// Power-on reset. The board's 6802 free-runs from power-up; this just
// guarantees a clean vector fetch after configuration.
// --------------------------------------------------------------------------
reg [1:0] por = 2'b11;
always @(posedge clk) begin
	if (reset)          por <= 2'b11;
	else if (|por && cen) por <= por - 2'd1;
end
wire cpu_rst = reset | (|por);

// --------------------------------------------------------------------------
// Host-side latches.
//
// MAME synchronises both of these into the sound board's domain before they
// are visible (sound_select_sync / sound_int_sync). Registering them here does
// the same job and keeps the OP4 -> board path off the critical path.
//
// PIA2 port A reads `~sound_select & 0x1F` -- five lines through inverters, so
// store it already inverted, the way the PIA will read it. PIA2 CB1 takes
// `!sound_int`, likewise inverted ("the line runs through an inverter").
// --------------------------------------------------------------------------
reg [4:0] pia2_porta;
reg       pia2_cb1;

always @(posedge clk) begin
	if (reset) begin
		pia2_porta <= 5'h1f;
		pia2_cb1   <= 1'b1;
	end
	else begin
		pia2_porta <= ~{1'b0, sound_select};
		pia2_cb1   <= ~sound_int;
	end
end

// --------------------------------------------------------------------------
// 6802
// --------------------------------------------------------------------------
wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;
wire        cpu_wr;
wire        cpu_irq;

jt680x u_cpu
(
	.rst      (cpu_rst),
	.clk      (clk),
	.cen      (cen),
	.wr       (cpu_wr),
	.addr     (cpu_addr),
	.din      (cpu_din),
	.dout     (cpu_dout),
	.ext_halt (1'b0),
	.ba       (),
	.irq      (cpu_irq),
	.nmi      (1'b0),
	// 6801/6301-only interrupt sources - tied off for a 6802
	.irq_icf  (1'b0),
	.irq_ocf  (1'b0),
	.irq_tof  (1'b0),
	.irq_sci  (1'b0),
	.irq_cmf  (1'b0),
	.irq2     (1'b0)
);

// --------------------------------------------------------------------------
// Address decode.
//
// The mirrors in the MAME map are stated as don't-care MASKS, so decode by
// masking the don't-care bits out rather than by range compare:
//
//   PIA2  0080-0083 mirror 4F6C -> (addr & ~4F6C & ~0003) == 0080  -> &B090
//   PIA1  0090-0093 mirror 4F6C -> likewise                        == 0090
//   DAC   1000      mirror 40FF -> (addr & ~40FF)         == 1000  -> &BF00
//   ROM   8000-BFFF mirror 4000 -> addr[15], ignoring addr[14]
//
// A range compare would miss the aliases the board's code actually uses --
// and the vector table above proves it does use them.
// --------------------------------------------------------------------------
wire ram_cs  = (cpu_addr[15:7] == 9'd0);              // 0000-007F, internal RAM
wire pia2_cs = ((cpu_addr & 16'hB090) == 16'h0080);
wire pia1_cs = ((cpu_addr & 16'hB090) == 16'h0090);
wire dac_cs  = ((cpu_addr & 16'hBF00) == 16'h1000);
wire rom_cs  = cpu_addr[15];

assign rom_addr = cpu_addr[13:0];

// --------------------------------------------------------------------------
// 6802 internal 128-byte RAM. jt680x is a bare CPU core, so this lives here.
// --------------------------------------------------------------------------
reg [7:0] iram [0:127];
reg [7:0] iram_do;

always @(posedge clk) begin
	if (cen && cpu_wr && ram_cs) iram[cpu_addr[6:0]] <= cpu_dout;
	if (cen_d && ram_cs)         iram_do <= iram[cpu_addr[6:0]];
end

// DO NOT re-register `rom_do`. `dpram` already registers its own output, so
// latching it a second time at cen_d hands the CPU the PREVIOUS byte:
//
//   edge N   (cen)   jt680x drives the new address; dpram samples the OLD one
//                    (its value before the edge) -> q_b = ram[A_old]
//   edge N+1 (cen_d) a second latch would capture ram[A_old]. Stale by one.
//
// Symptom on hardware: the 6802 fetches garbage, crashes, re-reads the reset
// vector, and loops -- so it looks perfectly "alive" (address bus moving, RAM
// touched, ROM returning non-zero) while never reaching a single PIA. Cost a
// long detour; caught by simulating this exact pipeline in sim/tb_hw.v, where
// pia_touched=0, versus tb_fix.v where the PIA init appears at bus cycle 19.
//
// Arcade-Qix does not hit this because it reads an inferred array directly at
// cen_d (one register total). Using dpram adds a stage; the address is stable
// for ~45 clocks per bus cycle, so its registered output is simply used as-is.
wire [7:0] rom_do_r = rom_do;

// --------------------------------------------------------------------------
// PIAs. `cs` must be a ONE-CYCLE pulse per bus cycle: pia6821.vhd commits a
// write on any rising clk with cs=1 and rw=0, so a level-held cs would write
// repeatedly for the whole CPU cycle. Gating with `cen` gives exactly one.
// rw is 6800 polarity: 1 = read, 0 = write.
// --------------------------------------------------------------------------
wire pia1_en = cen & pia1_cs;
wire pia2_en = cen & pia2_cs;
wire cpu_rw  = ~cpu_wr;

wire [7:0] pia1_dout, pia2_dout;
wire [7:0] pia1_pa_o, pia1_pa_oe, pia1_pb_o, pia1_pb_oe;
wire [7:0] pia2_pa_o, pia2_pa_oe, pia2_pb_o, pia2_pb_oe;
wire       pia1_irqa, pia1_irqb, pia2_irqa, pia2_irqb;
wire       pia1_ca2_o, pia1_ca2_oe, pia1_cb2_o, pia1_cb2_oe;
wire       pia2_ca2_o, pia2_ca2_oe, pia2_cb2_o, pia2_cb2_oe;

// PORT B PULL-UPS -- do not drive the TMS from pia1_pb_o directly.
//
// A 6821 comes out of reset with DDRB = 0, i.e. port B pins are INPUTS
// (high impedance). On the real board, pull-ups hold /RS and /WS HIGH
// (inactive) during that window; the ROM does not set DDRB until $FA12.
// Taking the raw output register instead presents /RS = /WS = 0 -- BOTH
// STROBES ASSERTED -- from power-on. That is a reset condition on a 5220-class
// part, and in this model it leaves `ldce_gate` set, which blocks every
// subsequent command load: the board writes its first byte, waits for a
// /READY transition on CA2, and hangs there forever.
//
// Symptom that led here: 6802 healthy, PIAs configured, IRQ working, exactly
// ONE /WS edge, no audio. Found by tracing the board ROM in simulation to
// $F2BF (LDAA $91 / ASLA / BPL) -- a poll of PIA1 CRA waiting on the CA2 flag.
//
// Model an undriven bit as high, which is what a pull-up does:
wire [7:0] pia1_pb = pia1_pb_o | ~pia1_pb_oe;

// TMS5200 handshake lines (stubbed below)
wire tms_ready, tms_int_n;
wire [7:0] tms_status;

// PIA1: port A is the TMS5200 data bus (write = data_w, read = status_r),
// port B bit0 = /RS, bit1 = /WS. CA2 in = READY, CB1 in = /INT.
pia6821 u_pia1
(
	.clk(clk), .rst(reset),
	.cs(pia1_en), .rw(cpu_rw), .addr(cpu_addr[1:0]),
	.data_in(cpu_dout), .data_out(pia1_dout),
	.irqa(pia1_irqa), .irqb(pia1_irqb),
	.pa_i(tms_status), .pa_o(pia1_pa_o), .pa_oe(pia1_pa_oe),
	.ca1(1'b1),
	.ca2_i(tms_ready), .ca2_o(pia1_ca2_o), .ca2_oe(pia1_ca2_oe),
	.pb_i(8'hff), .pb_o(pia1_pb_o), .pb_oe(pia1_pb_oe),
	.cb1(tms_int_n),
	.cb2_i(1'b1), .cb2_o(pia1_cb2_o), .cb2_oe(pia1_cb2_oe)
);

// PIA2: port A reads the host's inverted sound-select nibble; CB1 is the
// host interrupt. CA2 drives a panel LED on the real board (ignored).
pia6821 u_pia2
(
	.clk(clk), .rst(reset),
	.cs(pia2_en), .rw(cpu_rw), .addr(cpu_addr[1:0]),
	.data_in(cpu_dout), .data_out(pia2_dout),
	.irqa(pia2_irqa), .irqb(pia2_irqb),
	// Upper three bits read as ZERO, not one. MAME is explicit about this:
	// `return ~m_sound_select & 0x1f` masks bits 7:5 off, so the board sees
	// 0x15 for command 0x0A, not 0xF5. Tying them high instead was a guess,
	// and if the ROM compares the whole byte against a command table it would
	// never match -- which looks exactly like "6802 takes the interrupt, pokes
	// the chip, then gives up".
	.pa_i({3'b000, pia2_porta[4:0]}), .pa_o(pia2_pa_o), .pa_oe(pia2_pa_oe),
	.ca1(1'b1),
	.ca2_i(1'b1), .ca2_o(pia2_ca2_o), .ca2_oe(pia2_ca2_oe),
	.pb_i(8'hff), .pb_o(pia2_pb_o), .pb_oe(pia2_pb_oe),
	.cb1(pia2_cb1),
	.cb2_i(1'b1), .cb2_o(pia2_cb2_o), .cb2_oe(pia2_cb2_oe)
);

// All four PIA interrupt outputs are wire-ORed onto the 6802's IRQ.
assign cpu_irq = pia1_irqa | pia1_irqb | pia2_irqa | pia2_irqb;

// --------------------------------------------------------------------------
// AD558 8-bit DAC at $1000. Unsigned on the real part; centred here so it
// sums cleanly with signed speech in step 5.
// --------------------------------------------------------------------------
reg [7:0] dac_val = 8'h80;
always @(posedge clk) begin
	if (reset)                      dac_val <= 8'h80;
	else if (cen && cpu_wr && dac_cs) dac_val <= cpu_dout;
end

wire signed [8:0] dac_centered = $signed({1'b0, dac_val}) - 9'sh80;

// --------------------------------------------------------------------------
// TMS5200 STUB -- step 4 replaces this whole block.
//
// The stub deliberately keeps the board's speech loop MOVING rather than
// letting it wedge, so that step 3 exercises the 6802, the PIAs and the DAC:
//   status = BL|BE set, TS clear  -> "not talking, buffer empty, send more"
//   READY  asserted, /INT idle
// Both handshake polarities here are ASSUMPTIONS and must be re-derived from
// the datasheet against the real core in step 4; they are the likeliest place
// for step 4 to go wrong quietly.
// --------------------------------------------------------------------------
// REAL TMS5200 (zeldin/Mega99 `tms5200_vsp`, LGPL-3.0, patent-schematic
// accurate). Its `tms5200_parameter_rom.hex` carries the genuine TMS5200
// coefficient set -- pitch table verified against MAME's TI_2501E_PITCH -- so
// it does NOT need the 5220-vs-5200 table swap the Qix core would.
//
// The TMS6100 VSM (phrase ROM) is deliberately NOT instantiated: Squawk & Talk
// has no phrase ROM, the 6802 streams LPC data itself, so the chip only ever
// runs in Speak External mode and the VSM pins tie off.
//
// POLARITIES -- every one of these is INVERTED relative to the chip pins, and
// all were confirmed by measurement, not read off a datasheet:
//   * Mega99 drives rs/ws ACTIVE HIGH (`.rs(enable_vsp && sbe && !a[5])`),
//     whereas the real pins are /RS and /WS. PIA1 PB[0]/PB[1] carry the
//     active-low pins, so both are inverted going in.
//   * `rdy` is ACTIVE HIGH ready -- Mega99 ANDs it into `sysrdy`, and a
//     standalone sim shows rdy=1 after reset. PIA1 CA2 sees the /READY pin.
//   * `int` is ACTIVE HIGH -- the same sim shows int=1 (buffer low) after 64
//     bytes are streamed. PIA1 CB1 sees the /INT pin.
//
// Verilog-2001 ONLY: the module has a port literally named `int`, which is a
// SystemVerilog keyword. It must be listed as VERILOG_FILE in files.qip, and
// iverilog needs -g2001. Compiling it as SystemVerilog fails at the port list.
//
// clk_en is the ROMCLK rate, 160 kHz (Mega99's clkgen.v labels it exactly
// that), which is 640 kHz / 4. 40 MHz / 160 kHz = 250 exactly, so unlike the
// 6802's enable this one is a plain integer divider.
reg [7:0] tms_div = 0;
reg       tms_cen = 0;
always @(posedge clk) begin
	tms_div <= (tms_div == 8'd249) ? 8'd0 : tms_div + 8'd1;
	tms_cen <= (tms_div == 8'd0);
end

wire       tms_rdy, tms_irq, tms_dq_valid;
wire [7:0] tms_dq;

// HOLD the chip's data bus. `dq` is valid only during the core's internal
// c1/c2 read pulse; a real TMS5220 holds it for the whole /RS assertion. The
// 6802 waits for /READY before reading, so without this latch it always
// samples 0x00 -- status TS=BL=BE=0, i.e. "buffer full, do not send" -- and
// silently declines to stream any speech data.
reg [7:0] tms_dq_hold = 8'h00;
wire       tms_t11, tms_io;

tms5200_vsp u_tms
(
	.reset   (reset),
	.clk     (clk),
	.clk_en  (tms_cen),
	.t11     (tms_t11),
	.io      (tms_io),
	.dd      (pia1_pa_o),          // 6802 -> TMS  (PIA1 port A)
	.dq      (tms_dq),             // TMS  -> 6802 (status / read data)
	.rs      (~pia1_pb[0]),        // PB0 is /RS, model wants active high
	.ws      (~pia1_pb[1]),        // PB1 is /WS, likewise
	.rdy     (tms_rdy),
	.int_o   (tms_irq),   // renamed upstream port; see tms5200_vsp.v header
	// No VSM on this board - tie the phrase-ROM interface off
	.add_out (),
	.add8_in (1'b0),
	.m0      (),
	.m1      (),
	.promout (),
	.dq_valid(tms_dq_valid)
);

wire signed [15:0] tms_audio;
tms5200_dac #(.audio_bits(16)) u_tms_dac
(
	.clk(clk), .clk_en(tms_cen),
	.t11(tms_t11), .io(tms_io),
	.audioout(tms_audio)
);

always @(posedge clk) if (tms_dq_valid) tms_dq_hold <= tms_dq;
assign tms_status = tms_dq_hold;

// --------------------------------------------------------------------------
// RECONSTRUCTION LOWPASS on the speech output.
//
// tms5200_dac emits a STAIRCASE: the underlying speech sample rate is 8 kHz,
// held across 20 of the 160 kHz clk_en ticks. Feeding that straight into the
// mix leaves the 8/16/24 kHz images in the audio. Measured against a real
// cabinet recording, ours carried 22-29% of its energy above 4 kHz where the
// arcade has 3-6%, and brick-wall filtering our capture at 4 kHz moved its
// rolloff from 8728 Hz onto the arcade's 3424-3638 Hz.
//
// A real TMS5220 cannot produce content above ~4 kHz at all; the board filters
// it in analog (MAME models a filter on the speech output too).
//
// FIRST ATTEMPT was two cascaded one-pole IIRs (shift 3, ~3.2 kHz, -12 dB/oct).
// That helped -- 22-29% down to 9.0% -- but the real cabinet measures 3.8% on a
// same-phrase GREETINGS recording, so it was too gentle.
// --------------------------------------------------------------------------
// REVERTED to two cascaded one-pole IIRs (shift 3, ~3.2 kHz, -12 dB/oct).
//
// A 20-tap boxcar was tried, to put nulls exactly on the 8/16/24 kHz image
// frequencies. It sounded MUCH worse - every phrase heavily garbled - because
// of a Verilog width bug, not because the idea is wrong:
//
//     tms_box <= (tms_sum * 21'sd13) >>> 8;   // WRONG
//
// The product width in Verilog is max(operand widths). Both operands are
// 21 bits, so the result truncates to 21 bits, but tms_sum reaches +/-655360
// and x13 needs 24 - every loud sample wrapped. If the boxcar is retried, do
// the multiply in an explicitly widened signed intermediate:
//
//     wire signed [31:0] scaled = $signed({{11{tms_sum[20]}}, tms_sum}) * 32'sd13;
//
// SHIFT 3 WAS TOO AGGRESSIVE, and the reasoning above that set it is unsound.
// It rested on a YouTube cabinet recording with game audio mixed in, compared
// against a phrase that was never matched. Redone analytically (2026-08-01),
// composite response INCLUDING the 8 kHz staircase, normalised at 100 Hz:
//
//   design            1k     2k     3k     4k    12k(image)
//   shift 3 x2      -0.9   -3.5   -7.1  -11.4   -35.9      <- was here
//   shift 2 x2      -0.4   -1.5   -3.4   -6.2   -24.6      <- now here
//   shift 1 x2      -0.2   -1.0   -2.3   -4.3   -16.6
//   boxcar 20       -0.4   -1.8   -4.2   -7.8   -26.8
//
// Shift 3 threw away 11.4 dB at 4 kHz and 7 dB at 3 kHz -- the top third of the
// speech band, right where the consonants are. That is why it sounded muffled.
// Shift 2 recovers 5.2 dB at 4 kHz and still rejects the images by 24.6 dB.
//
// Two things to know before touching this again:
//   - the 8 kHz staircase alone costs 3.9 dB at 4 kHz, so -4.3 dB (shift 1 x2)
//     is about the best achievable without ZOH compensation;
//   - MAME is NOT a model for this filter. It puts only a 15.9 Hz DC blocker
//     on the speech path (`FILTER_RC ... set_ac()` = 10k/1uF) because its
//     8 kHz -> 48 kHz resampler band-limits for free. We emit a real 160 kHz
//     staircase and genuinely need a reconstruction filter it does not.
// Evaluate any change with the response table above, not by ear alone.
reg signed [15:0] tms_lp1 = 0, tms_lp2 = 0;
always @(posedge clk) begin
	if (reset) begin
		tms_lp1 <= 0;
		tms_lp2 <= 0;
	end
	else if (tms_cen) begin
		tms_lp1 <= tms_lp1 + ((tms_audio - tms_lp1) >>> 2);
		tms_lp2 <= tms_lp2 + ((tms_lp1   - tms_lp2) >>> 2);
	end
end

assign tms_ready  = ~tms_rdy;   // PIA1 CA2 sees the active-low /READY pin
assign tms_int_n  = ~tms_irq;   // PIA1 CB1 sees the active-low /INT pin

assign dbg_tms_rsn = pia1_pb[0];
assign dbg_tms_wsn = pia1_pb[1];

// --------------------------------------------------------------------------
// CPU read mux
// --------------------------------------------------------------------------
always @(*) begin
	if      (ram_cs)  cpu_din = iram_do;
	else if (pia2_cs) cpu_din = pia2_dout;
	else if (pia1_cs) cpu_din = pia1_dout;
	else if (rom_cs)  cpu_din = rom_do_r;
	else              cpu_din = 8'hff;
end

// --------------------------------------------------------------------------
// Audio out. DAC only until step 4; scaled up from 8 bits.
// --------------------------------------------------------------------------
// AD558 DAC plus TMS5200 speech, both signed about zero.
//
// Concatenation in Verilog is UNSIGNED, so `{dac_centered, 6'b0}` would throw
// the sign away and turn every negative DAC sample into a large positive one.
// Sign-extend first, then shift.
//
// dac_centered is 9-bit signed (-256..255); <<6 puts it at -16384..16320.
// The speech core's output is halved so a loud DAC effect and a loud phrase
// cannot together clip the sum. Saturate rather than wrap - a wrapped mix is
// the kind of fault that sounds like a broken speech core.
wire signed [15:0] dac_scaled = $signed({{7{dac_centered[8]}}, dac_centered}) <<< 6;
wire signed [16:0] snd_mix    = dac_scaled + (tms_lp2 >>> 1);

assign audio_out = (snd_mix >  17'sd32767) ?  16'sh7FFF :
                   (snd_mix < -17'sd32768) ?  16'sh8000 : snd_mix[15:0];

// --------------------------------------------------------------------------
// Activity flag: stretch any change to a non-zero sound command so it is
// visible on an LED. ~7 M clocks at 40 MHz is about 0.17 s.
// --------------------------------------------------------------------------
// WATCH BIT 4 (sound_int), NOT bits 3:0.
//
// The first cut of this probe triggered on any change of `sound_select`, and a
// strap=Upright control run lit it just as brightly as Environmental did --
// which is what exposed the mistake. OP4[3:0] is DUAL-PURPOSE in
// `dotron_op4_w`: the same four bits feed this board's MD3-0 *and* the lamp
// sequencer (J1-4 enable, J1-5 sequence, J1-6 speed, latched on bit 5's rising
// edge). The game drives that nibble for lamps on any cabinet, so a change
// there says nothing about speech.
//
// OP4 bit 4 is the actual strobe: MAME routes it to PIA2 CB1 (inverted), and
// that is what interrupts the 6802 to come and collect a command. Rising edges
// of it are the real "the game is commanding the speech board" event.
//
// Requiring TWO edges before latching `seen` guards against a single
// power-on/reset glitch being mistaken for traffic.
reg [22:0] act_cnt = 0;
reg  [1:0] int_edges = 0;
reg        si_d = 0;

always @(posedge clk) begin
	si_d <= sound_int;
	if (reset) begin
		act_cnt   <= 0;
		int_edges <= 0;
	end
	// Count EITHER edge, not just rising. MAME inverts this line into CB1
	// (`cb1_w(!param)`), so whether a command shows up as a 0->1 or a 1->0 on
	// OP4[4] depends on the board's idle level, which is not documented
	// anywhere I can check. Counting both, and requiring two, covers a pulse
	// of either polarity while still rejecting a single reset glitch.
	else if (sound_int ^ si_d) begin
		act_cnt <= '1;
		if (~&int_edges) int_edges <= int_edges + 1'd1;
	end
	else if (|act_cnt) act_cnt <= act_cnt - 1'd1;
end

assign active       = |act_cnt;
assign seen         = &int_edges;

// Board-side liveness. These are the answer to "is the 6802 wedged?", which
// the host-side probe above cannot see either way.
// GREEN now reports "the 6802 is trying to SPEAK", not "wrote the DAC".
//
// Measured 2026-07-30: with a game running, the host strobe (BLUE) lights but
// dac_written never did. That is probably correct rather than broken -- Discs
// of Tron's Squawk & Talk is a speech board, and its AD558 may simply never be
// used for these sounds. So a dark DAC bit tells us nothing either way, which
// makes it the wrong thing to spend a channel on.
//
// The informative signal is /WS (PIA1 port B bit 1): the 6802 pulses it to
// push each LPC byte into the TMS5200's FIFO. If that toggles, the 6802 took
// the interrupt, read the command, and is driving the speech chip -- which is
// the LAST link before the real TMS5200 goes in. Two edges required, same
// glitch rejection as the host strobe.
reg  [7:0] run_cnt = 0;
reg [15:0] addr_d  = 0;
reg  [1:0] ws_edges = 0;
reg        ws_d = 1'b1;
reg        dac_written_r = 0;

always @(posedge clk) begin
	if (cen) addr_d <= cpu_addr;
	ws_d <= pia1_pb[1];
	if (reset) begin
		run_cnt       <= 0;
		ws_edges      <= 0;
		dac_written_r <= 0;
	end
	else begin
		if (cen && cpu_addr != addr_d && ~&run_cnt) run_cnt <= run_cnt + 1'd1;
		if (cen && cpu_wr && dac_cs)                dac_written_r <= 1'b1;
		if ((pia1_pb[1] ^ ws_d) && ~&ws_edges)    ws_edges <= ws_edges + 1'd1;
	end
end

// Where does the chain actually stop? Latch each stage independently.
reg pia2_read_seen = 0;
reg irq_seen       = 0;

always @(posedge clk) begin
	if (reset) begin
		pia2_read_seen <= 0;
		irq_seen       <= 0;
	end
	else begin
		// ANY PIA access, either chip, read or write. Reads alone under-report:
		// at init the board only WRITES the DDR/control registers, and it does
		// not read port A until a command interrupt actually arrives -- so a
		// read-only probe reads 0 even when init is working perfectly.
		if (cen && (pia1_cs | pia2_cs)) pia2_read_seen <= 1'b1;
		if (cpu_irq)                  irq_seen       <= 1'b1;
	end
end

reg ram_seen     = 0;
reg rom_nonzero  = 0;
always @(posedge clk) begin
	if (reset) begin
		ram_seen    <= 0;
		rom_nonzero <= 0;
	end
	else begin
		if (cen && ram_cs)              ram_seen    <= 1'b1;
		if (cen_d && rom_cs && |rom_do) rom_nonzero <= 1'b1;
	end
end

reg pia_loose_r = 0;
always @(posedge clk) begin
	if (reset) pia_loose_r <= 0;
	else if (cen && cpu_addr[15:8] == 8'h00 && cpu_addr[7:5] == 3'b100) pia_loose_r <= 1'b1;
end
// /WS pulse count: 16+ means the 6802 is streaming LPC bytes, not just
// poking the chip once during init.
reg [4:0] ws_pulses = 0;
always @(posedge clk) begin
	if (reset) ws_pulses <= 0;
	else if ((pia1_pb[1] ^ ws_d) && ~&ws_pulses) ws_pulses <= ws_pulses + 1'd1;
end
assign pia_loose = &ws_pulses;

// Has the speech DAC ever produced a non-zero sample?
reg tms_nz = 0;
always @(posedge clk) begin
	if (reset) tms_nz <= 0;
	else if (|tms_audio) tms_nz <= 1'b1;
end
assign tms_audio_nz = tms_nz;

// ===========================================================================
// JTAG live probes (In-System Sources and Probes).
//
// Read headlessly with: quartus_stp -t tools/snt_probe.tcl
//
// This exists because SIMULATION SPEAKS AND HARDWARE DOES NOT. The screen
// probe only carries sticky booleans; these carry counts and latched VALUES,
// which is what is needed to tell "wrong command number" from "chip refuses".
//
// The critical one is `last_cmd`: the command nibble latched at the instant
// the host strobe arrives. The testbench always sent 3. On hardware OP4[3:0]
// is SHARED WITH THE LAMP SEQUENCER, so the board may be latching something
// that is not a speech cue at all.
// ===========================================================================
reg [7:0] ws_count8 = 0, rs_count8 = 0;
reg [3:0] last_cmd  = 0;
reg [7:0] cmd_count = 0;
reg       rs_d = 1'b1;

always @(posedge clk) begin
	rs_d <= pia1_pb[0];
	if (reset) begin
		ws_count8 <= 0; rs_count8 <= 0; last_cmd <= 0; cmd_count <= 0;
	end
	else begin
		if ((pia1_pb[1] ^ ws_d) && ~&ws_count8) ws_count8 <= ws_count8 + 1'd1;
		if ((pia1_pb[0] ^ rs_d) && ~&rs_count8) rs_count8 <= rs_count8 + 1'd1;
		// latch the command the board will actually see, on the strobe edge
		if (sound_int & ~si_d) begin
			last_cmd  <= sound_select;
			if (~&cmd_count) cmd_count <= cmd_count + 1'd1;
		end
	end
end

// Hardware says: valid command (0B) arrives, chip ready (status 60), and the
// 6802 never leaves its idle loop. So the question is whether the interrupt
// reaches the CPU at all. Count the IRQ line and the ISR entry separately:
//   irq_edges > 0, isr_hits == 0  -> IRQ asserts but the CPU ignores it
//                                    (I-flag still set, or PIA IRQ masked)
//   irq_edges == 0               -> the PIA never raises it: CB1 config
//   isr_hits > 0                 -> ISR runs and declines - different problem
reg [7:0] irq_edges = 0, isr_hits = 0, pia2_rd = 0;
reg [4:0] cmd_at_read = 5'h1F;
reg       irq_d = 0;
always @(posedge clk) begin
	irq_d <= cpu_irq;
	if (reset) begin
		irq_edges <= 0; isr_hits <= 0; pia2_rd <= 0;
	end
	else begin
		if (cpu_irq & ~irq_d      && ~&irq_edges) irq_edges <= irq_edges + 1'd1;
		// $FA45 is the IRQ vector target read out of pre.u5
		if (cen && cpu_addr == 16'hFA45 && ~&isr_hits) isr_hits <= isr_hits + 1'd1;
		if (cen && pia2_cs && cpu_rw  && ~&pia2_rd)    pia2_rd  <= pia2_rd  + 1'd1;
		// THE value the handler actually sees, captured at the instant it
		// reads PIA2 port A. `last_cmd` is the nibble at the STROBE; this is
		// the nibble at the READ. If they differ, the game has rewritten OP4
		// (lamp data shares those bits) in between, and the board is being
		// handed a different command than the one that interrupted it.
		if (cen && pia2_cs && cpu_rw && cpu_addr[1:0] == 2'b00)
			cmd_at_read <= pia2_porta[4:0];
	end
end

// ===========================================================================
// OP4 TRACE BUFFER -- the decisive test for in-game speech.
//
// The handler assembles a command from TWO reads of PIA2 port A, ~650 us
// apart, so the game must present two DIFFERENT nibbles. Both hardware
// captures so far showed the SAME nibble at both reads, which would make every
// in-game command collapse to a doubled byte and land in the ignored range.
//
// Either the game writes OP4 twice and our SSIO drops the second write (a real
// bug -- in-game speech could never work), or it writes once and those events
// simply were not speech cues. A snapshot cannot tell these apart; a
// time-series can.
//
// 16 entries, captured on every CHANGE of OP4, each with a 16-bit timestamp in
// units of ~1.6 us (clk/64) so the ~650 us handler window is resolvable.
// Read over JTAG: drive the index on the source, read the entry on the probe.
// ===========================================================================
// Rolling window of the LAST FOUR OP4 writes, each with a ~1.6 us timestamp.
// Exposed directly in the probe word -- no JTAG source needed, because
// write_source_data never actually moved the index select.
//
// This answers the shippability question: the handler needs TWO writes ~650 us
// apart carrying DIFFERENT nibbles. If the game only ever writes once per
// command, in-game speech can never work with the current OP4 path.
reg  [7:0] trc_v0 = 0, trc_v1 = 0, trc_v2 = 0, trc_v3 = 0;
reg [15:0] trc_t0 = 0, trc_t1 = 0, trc_t2 = 0, trc_t3 = 0;
reg  [7:0] trc_cnt = 0;
reg [15:0] trc_now = 0;
reg  [5:0] trc_pre = 0;
reg  [7:0] op4_d   = 0;

always @(posedge clk) begin
	trc_pre <= trc_pre + 1'd1;
	if (&trc_pre) trc_now <= trc_now + 1'd1;
	op4_d <= dbg_op4;
	if (reset) begin
		trc_cnt <= 0; trc_now <= 0;
		trc_v0 <= 0; trc_v1 <= 0; trc_v2 <= 0; trc_v3 <= 0;
		trc_t0 <= 0; trc_t1 <= 0; trc_t2 <= 0; trc_t3 <= 0;
	end
	else if (dbg_op4 != op4_d) begin
		trc_v3 <= trc_v2; trc_t3 <= trc_t2;
		trc_v2 <= trc_v1; trc_t2 <= trc_t1;
		trc_v1 <= trc_v0; trc_t1 <= trc_t0;
		trc_v0 <= dbg_op4; trc_t0 <= trc_now;
		if (~&trc_cnt) trc_cnt <= trc_cnt + 1'd1;
	end
end

// The JTAG probes are ALTERA-ONLY (In-System Sources and Probes). Guarded so
// the same file compiles on Gowin for the Tang port, where `altsource_probe`
// does not exist. Defined by SNT_JTAG_PROBE in Arcade-MCR3.qsf; leaving it
// undefined simply omits the probes and changes no behaviour.


wire [95:0] snt_probe_word = {
	8'h5A,              // [95:88] signature, confirms the probe is live
	cmd_count,          // [87:80] how many host commands arrived
	{4'h0, last_cmd},   // [79:72] the command nibble actually latched
	tms_dq_hold,        // [71:64] last status byte read from the TMS
	cpu_addr,           // [63:48] where the 6802 is right now
	ws_count8,          // [47:40] /WS transitions
	rs_count8,          // [39:32] /RS transitions
	dbg_in2,            // [31:24] IP2 as presented to the SSIO; bit7 = cabinet
	dbg_op4,            // [23:16] raw OP4 latch (lamp bits + cmd + strobe)
	irq_edges,          // [15:8]  cpu_irq rising edges
	{3'h0, cmd_at_read} // [7:0]   command as seen AT THE READ
};



assign cpu_run     = { rom_nonzero, ram_seen, &run_cnt };
assign progress    = { &ws_edges, irq_seen, pia2_read_seen };
// Either the board wrote the DAC, or it is pushing bytes at the TMS5200.
// Both mean "the 6802 acted on a command"; DAC alone would under-report.
assign dac_written = dac_written_r | (&ws_edges);
assign dbg_dac      = dac_val;
assign dbg_cpu_addr = cpu_addr;

endmodule
