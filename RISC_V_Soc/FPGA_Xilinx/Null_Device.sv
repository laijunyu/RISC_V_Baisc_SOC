// 空设备占位
//
// 原设计的 WISHBONE 段 (IDX_WISHBONE, 0x3000-0x3FFF) 挂的是 Lattice EFB 硬核。
// Xilinx 无 EFB 等效物，这里用空设备占住该槽位：
//   - 地址映射保持不变（XT_LB 仍在 0x4000）
//   - 任何读写都在一个周期内完成，读返回 0
//   - 以后要接 PS 的 I2C/SPI，把本模块换成真正的桥即可
module Null_Device (
    xt_hbus_if.port hb
);

  assign hb.read_finish  = hb.ren;
  assign hb.write_finish = hb.wen;

  always_ff @(posedge hb.clk) begin
    if (hb.ren) hb.rdata <= 32'h0000_0000;
  end

endmodule
