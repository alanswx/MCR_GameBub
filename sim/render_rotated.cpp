// Render a captured native framebuffer through the production address mapper.
#include "VRotationTestTop.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  try {
    if (argc != 5) throw std::runtime_error("input.ppm output.ppm rotation hdmi");
    std::ifstream input(argv[1], std::ios::binary);
    std::string magic; int width, height, maximum;
    input >> magic >> width >> height >> maximum; input.get();
    if (magic != "P6" || width != 320 || height != 240 || maximum != 255)
      throw std::runtime_error("Expected a 320x240 RGB888 PPM capture");
    std::vector<unsigned char> source(width*height*3);
    input.read(reinterpret_cast<char*>(source.data()), source.size());
    if (!input) throw std::runtime_error("Incomplete capture");
    int turn = std::stoi(argv[3]); bool hdmi = std::stoi(argv[4]);
    if (turn < 0 || turn > 3) throw std::runtime_error("Invalid rotation");
    VRotationTestTop dut;
    auto tick = [&] { dut.clock=0; dut.eval(); dut.clock=1; dut.eval(); dut.clock=0; dut.eval(); };
    dut.reset=1; tick(); dut.reset=0; dut.io_requested=turn; dut.io_boundary=1; tick(); dut.io_boundary=0;
    int output_width=hdmi ? 720 : 800;
    std::vector<unsigned char> pixels(output_width*480*3, 0);
    int outer=hdmi ? 480 : output_width, inner=hdmi ? output_width : 480;
    for (int line=0; line<outer; line++) {
      unsigned pipeline[3]={0,0,0};
      for (int position=-8; position<inner; position++) {
        int x=hdmi ? position : line, y=hdmi ? line : position;
        dut.io_x=x & 4095; dut.io_y=y & 4095; dut.eval();
        unsigned address=pipeline[0]; pipeline[0]=pipeline[1]; pipeline[1]=pipeline[2];
        pipeline[2]=hdmi ? dut.io_hdmiAddress : dut.io_lcdAddress;
        bool visible=hdmi ? dut.io_hdmiInBounds : dut.io_lcdInBounds;
        if (position>=0 && visible) {
          if (address >= 320*240) throw std::runtime_error("Visible read outside framebuffer");
          for (int c=0; c<3; c++) pixels[(y*output_width+x)*3+c]=source[address*3+c];
        }
      }
    }
    std::ofstream output(argv[2],std::ios::binary);
    output << "P6\n" << output_width << " 480\n255\n";
    output.write(reinterpret_cast<char*>(pixels.data()),pixels.size());
    if (!output) throw std::runtime_error("Cannot write output");
    std::cout << "Rendered " << output_width << "x480 through production mapper\n";
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
