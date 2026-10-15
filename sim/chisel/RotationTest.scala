import chisel3._
import _root_.circt.stage.ChiselStage
import lib.video.{FramebufferTransform, FrameRotationLatch}

class RotationTestTop extends Module {
  val io = IO(new Bundle {
    val x = Input(UInt(12.W))
    val y = Input(UInt(12.W))
    val requested = Input(UInt(2.W))
    val boundary = Input(Bool())
    val rotation = Output(UInt(2.W))
    val lcdAddress = Output(UInt(17.W))
    val lcdInBounds = Output(Bool())
    val hdmiAddress = Output(UInt(17.W))
    val hdmiInBounds = Output(Bool())
  })
  val latch = Module(new FrameRotationLatch)
  latch.io.requested := io.requested
  latch.io.boundary := io.boundary
  io.rotation := latch.io.active
  val lcd = Module(new FramebufferTransform(320, 240, 800, 480, offsetX = -28, delayY = 3, xBits = 10, yBits = 9))
  val hdmi = Module(new FramebufferTransform(320, 240, 720, 480, delayX = 3, xBits = 10, yBits = 10))
  for (mapper <- Seq(lcd, hdmi)) {
    mapper.io.x := io.x
    mapper.io.y := io.y
    mapper.io.rotation := latch.io.active
  }
  io.lcdAddress := lcd.io.address
  io.lcdInBounds := lcd.io.inBounds
  io.hdmiAddress := hdmi.io.address
  io.hdmiInBounds := hdmi.io.inBounds
}

object GenerateRotationTest extends App {
  ChiselStage.emitSystemVerilogFile(new RotationTestTop, args)
}
