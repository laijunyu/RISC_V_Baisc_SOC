// Xilinx 7 系列替代 Lattice ramdp (SystemRAM)
//
// 原 Lattice 配置 (IPs/system_ram/SystemRAM.lpc):
//   RAddress=2048, RData=32, WAddress=2048, WData=32
//   enByte=1, ByteSize=8, 真双端口(ramdp), writemodeA/B = NORMAL (读优先)
//
// 本实现用行为级描述让 Vivado 自动推断成 RAMB36E1:
//   2048 x 32 = 64Kb -> 2 个 RAMB36E1 (72Kb, 利用率 89%)
//   A 口: 只读 (WrA 恒 0), 用于取指
//   B 口: 读写, 用于总线数据访问
//
// 推断要点:
//   1. 读必须同步 (always_ff + 非阻塞赋值)
//   2. 写放读之后 -> read-first, 与原 Lattice NORMAL 模式一致
//   3. 按字节拆分写 -> 推断出 byte-write enable
//
// ResetA/ResetB 原设计恒接 0; 7 系列 BRAM 输出寄存器复位会额外消耗 LUT,
// 故此处不使用, 保持纯 BRAM 推断。
module SystemRAM #(
    parameter int DEPTH = 2048,
    parameter int WIDTH = 32,
    localparam int AW   = $clog2(DEPTH)
) (
    // A 口 (指令取指, 只读)
    input  logic [AW-1:0]    AddressA,
    input  logic             ClockA,
    input  logic             ClockEnA,
    input  logic             ResetA,
    input  logic             WrA,
    input  logic [WIDTH-1:0] DataInA,
    input  logic [WIDTH/8-1:0] ByteEnA,
    output logic [WIDTH-1:0] QA,

    // B 口 (数据访问, 读写)
    input  logic [AW-1:0]    AddressB,
    input  logic             ClockB,
    input  logic             ClockEnB,
    input  logic             ResetB,
    input  logic             WrB,
    input  logic [WIDTH-1:0] DataInB,
    input  logic [WIDTH/8-1:0] ByteEnB,
    output logic [WIDTH-1:0] QB
);

  logic [WIDTH-1:0] mem[DEPTH];

  //----------A 口----------//
  always_ff @(posedge ClockA) begin
    if (ClockEnA) begin
      QA <= mem[AddressA];
      if (WrA) begin
        for (int i = 0; i < WIDTH / 8; ++i) begin
          if (ByteEnA[i]) mem[AddressA][i*8+:8] <= DataInA[i*8+:8];
        end
      end
    end
  end

  //----------B 口----------//
  always_ff @(posedge ClockB) begin
    if (ClockEnB) begin
      QB <= mem[AddressB];
      if (WrB) begin
        for (int i = 0; i < WIDTH / 8; ++i) begin
          if (ByteEnB[i]) mem[AddressB][i*8+:8] <= DataInB[i*8+:8];
        end
      end
    end
  end

endmodule
