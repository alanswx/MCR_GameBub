import chisel3._
import net.gamebub.framework.Core
import net.gamebub.framework.interface._

/** MCR3 platform declarations; implementation in rtl/gamebub/. */
class MCR3 extends Module with Core {
  val io = IO(new Bundle {
    // 50 MHz * 24 = 1200 MHz; /30 system, /42 LCD, /6 SPI.
    val clocks = new ClocksV0(
      clockSystemHz = 40_000_000,
      clockDisplayHz = (1_200_000_000.0 / 42).toInt,
      clockSpiHz = 200_000_000,
    )
    val video = new VideoV0(
      videoWidth = 320, videoHeight = 240,
      colorDepthR = 3, colorDepthG = 3, colorDepthB = 3,
      framePeriod = 634.0 * 525 / 20_000_000,
    )
    val audio = new AudioV0()
    val host = new HostV0()
    val input = new InputV0()
    val sram = new SramV0()
  })
  bindExtModule("mcr3_gamebub", io, Map())
}
