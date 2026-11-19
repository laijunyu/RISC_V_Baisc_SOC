// Xilinx 7 系列替代 Lattice EHXPLLL (SystemPLL)
//
// 原 Lattice 配置 (IPs/riscv_pll/SystemPLL.lpc):
//   CLKI = 12MHz, VCO = 516MHz, CLKOP_DIV = 43  -> CLKOP  = 12MHz
//   CLKOS  = CLKOP / 12 = 1MHz
//   CLKOS2 = CLKOP / 78 = 153.846kHz
//   CLKOS3 = CLKOS / 10 = 100kHz
//
// 本实现: MMCM 出 12MHz -> 计数器分频出另外三路
//         分频系数与原设计完全一致: 12 / 78 / 120(=12*10)
//
// 原 100MHz 配置（Vivado PS IP 声明值），注释保留：
//   CLKIN_PERIOD = 10.000 / MULT_F = 9.000  / CLKOUT0_DIV = 75.000
//   MMCM: CLKFBOUT_MULT_F(9.000), CLKIN1_PERIOD(10.000) -> VCO = 900MHz
//
// ⚠️ 板上实测 (cat /sys/kernel/debug/clk/clk_summary): fclk0 = 50MHz
//    FSBL/BOOT.bin 覆盖了 Vivado PS IP 的配置，实际不是 100MHz。
//    若仍用 MULT_F=9，VCO = 50*9 = 450MHz < MMCM 下限 600MHz，LOCKED 永远为 0，
//    12MHz 主时钟无输出，整个 SoC 不跑。故改用 50MHz 参数：
//      50MHz x 18 = 900MHz VCO, / 75 = 12MHz   (与原设计输出完全一致)
//    其余三路仍由 12MHz 计数器分频，频率不变：
//      1MHz / 153.846kHz / 100kHz，UART 19200 波特不受影响
//
// 若换板子导致 FCLK0 变频率，改下面三个参数即可（保持 VCO=900MHz）：
//   100MHz -> CLKIN_PERIOD=10.000, MULT_F=9.0,  CLKOUT0_DIV=75.0
//   60MHz  -> CLKIN_PERIOD=16.667, MULT_F=15.0, CLKOUT0_DIV=75.0
//   50MHz  -> CLKIN_PERIOD=20.000, MULT_F=18.0, CLKOUT0_DIV=75.0  <- 当前
//   24MHz  -> CLKIN_PERIOD=41.667, MULT_F=37.5, CLKOUT0_DIV=75.0
module SystemPLL #(
    parameter real CLKIN_PERIOD = 20.000,  // 输入 50MHz = 20ns
    parameter real MULT_F       = 18.000,  // VCO = 50 * 18 = 900MHz
    parameter real CLKOUT0_DIV  = 75.000   // 900 / 75 = 12MHz
) (
    input  logic CLKI,    // 50MHz from PS FCLK_CLK0 (板上实测)
    output logic CLKOP,   // 12MHz   核心/高速总线/WISHBONE
    output logic CLKOS,   // 1MHz    机器定时器
    output logic CLKOS2,  // 153.8kHz UART 过采样
    output logic CLKOS3,  // 100kHz  低速总线
    input  logic RST,     // 高有效复位
    output logic LOCK
);

  //----------MMCM: 50MHz -> 12MHz (VCO 900MHz)----------//
  logic clk_12m_raw, clkfb_raw, clkfb, clk_12m;
  logic locked;

  MMCME2_ADV #(
      .BANDWIDTH         ("OPTIMIZED"),
      .CLKOUT4_CASCADE   ("FALSE"),
      .COMPENSATION      ("ZHOLD"),
      .STARTUP_WAIT      ("FALSE"),
      .DIVCLK_DIVIDE     (1),
      .CLKFBOUT_MULT_F   (MULT_F),        // 原 9.000 (100MHz 输入)
      .CLKFBOUT_PHASE    (0.000),
      .CLKOUT0_DIVIDE_F  (CLKOUT0_DIV),
      .CLKOUT0_DUTY_CYCLE(0.500),
      .CLKOUT0_PHASE     (0.000),
      .CLKIN1_PERIOD     (CLKIN_PERIOD),  // 原 10.000 (100MHz 输入)
      .REF_JITTER1       (0.010)
  ) u_MMCM (
      .CLKOUT0  (clk_12m_raw),
      .CLKFBOUT (clkfb_raw),
      .CLKFBIN  (clkfb),
      .CLKIN1   (CLKI),
      .CLKIN2   (1'b0),
      .CLKINSEL (1'b1),
      .DADDR    (7'd0),
      .DCLK     (1'b0),
      .DEN      (1'b0),
      .DI       (16'd0),
      .DWE      (1'b0),
      .PSCLK    (1'b0),
      .PSEN     (1'b0),
      .PSINCDEC (1'b0),
      .PWRDWN   (1'b0),
      .RST      (RST),
      .LOCKED   (locked)
  );

  BUFG u_bufg_fb (.I(clkfb_raw), .O(clkfb));
  BUFG u_bufg_op (.I(clk_12m_raw), .O(clk_12m));

  assign CLKOP = clk_12m;
  assign LOCK  = locked;

  //----------12MHz / 12 = 1MHz----------//
  // 6 个周期翻转一次 -> 周期 12 拍
  logic [2:0] cnt_1m;
  logic       clk_1m_r;
  always_ff @(posedge clk_12m or posedge RST) begin
    if (RST) begin
      cnt_1m   <= '0;
      clk_1m_r <= 1'b0;
    end else if (cnt_1m == 3'd5) begin
      cnt_1m   <= '0;
      clk_1m_r <= ~clk_1m_r;
    end else begin
      cnt_1m <= cnt_1m + 1'b1;
    end
  end
  BUFG u_bufg_os (.I(clk_1m_r), .O(CLKOS));

  //----------12MHz / 78 = 153.846kHz----------//
  // 39 个周期翻转一次
  logic [5:0] cnt_153k;
  logic       clk_153k_r;
  always_ff @(posedge clk_12m or posedge RST) begin
    if (RST) begin
      cnt_153k   <= '0;
      clk_153k_r <= 1'b0;
    end else if (cnt_153k == 6'd38) begin
      cnt_153k   <= '0;
      clk_153k_r <= ~clk_153k_r;
    end else begin
      cnt_153k <= cnt_153k + 1'b1;
    end
  end
  BUFG u_bufg_os2 (.I(clk_153k_r), .O(CLKOS2));

  //----------12MHz / 120 = 100kHz----------//
  // 60 个周期翻转一次（等价于 1MHz / 10，与原设计 CLKOS3 = CLKOS/10 一致）
  logic [5:0] cnt_100k;
  logic       clk_100k_r;
  always_ff @(posedge clk_12m or posedge RST) begin
    if (RST) begin
      cnt_100k   <= '0;
      clk_100k_r <= 1'b0;
    end else if (cnt_100k == 6'd59) begin
      cnt_100k   <= '0;
      clk_100k_r <= ~clk_100k_r;
    end else begin
      cnt_100k <= cnt_100k + 1'b1;
    end
  end
  BUFG u_bufg_os3 (.I(clk_100k_r), .O(CLKOS3));

endmodule
