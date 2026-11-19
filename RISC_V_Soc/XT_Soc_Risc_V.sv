// 新增GPIO复用功能后，rgb移入GPIO
//
// Xilinx Zynq-7000 移植版 (原设计为 Lattice MachXO2-4000HC)
// 与原版的差异:
//   1. OSCH 内部振荡器删除, 复位控制器的独立时钟改由 PS 提供 (clk_aux)
//   2. SystemPLL 换成 FPGA_Xilinx/SystemPLL.sv (MMCM + 计数器分频)
//   3. SystemRAM 换成 FPGA_Xilinx/SystemRAM.sv (行为级推断 BRAM)
//   4. efb 硬核删除, WISHBONE 段改用 Null_Device 占位, 地址映射保持不变
//   5. ResetController 去掉 MXO2 专有的 GSR/Flash 命令阶段
//
// 原 Lattice 版的代码以 /* */ 注释保留在原位置, 方便对照与回滚。
module XT_Soc_Risc_V
  import SocConfig::*;
  import Rom_Pkg::*;
(
    input                         clk_ps,   // 100MHz, 来自 PS FCLK_CLK0
    input                         clk_aux,  // 50MHz,  来自 PS FCLK_CLK1 (复位控制器独立时钟)
    input                         rst_sw,
    inout        [GPIO_COUNT-1:0] gpio,
    input        [           3:0] key_raw,
    input        [           2:0] sw_raw,
    output logic [           7:0] led,
    output logic [           8:0] ledsd  [2],

    input        uart_rx,
    output logic uart_tx,

    // 原 Lattice 版: I2C/SPI 引脚由 EFB 硬核驱动, Xilinx 无 EFB, 暂时注释
    /*
    inout i2c1_scl,
    inout i2c1_sda,
    inout i2c2_scl,
    inout i2c2_sda,

    output spi_csn,
    inout  spi_clk,
    inout  spi_miso,
    inout  spi_mosi,
    */

    input tck,
    input tms,
    input tdi,
    output logic tdo
);
  // 原 Lattice 版: WISHBONE 端口宽度 (EFB 用), Xilinx 版不需要
  // localparam int WB_PORT_SIZE = 8;


  //----------时钟树与复位----------//
  // 原 Lattice 版: 内部 2.15MHz 振荡器, 给复位控制器做独立时钟源。
  // Xilinx 7 系列没有等效原语, 改由顶层端口 clk_aux 输入。
  /*
  wire clk_inner_osc;
  OSCH #("2.15") osc_int (  //2.15MHz for XO2
      .STDBY(1'b0),
      .OSC(clk_inner_osc),
      .SEDSTDBY()
  );
  */

  wire clk;              // 12MHz   核心/高速总线
  wire systemtimer_clk;  // 1MHz    机器定时器
  wire sampling_clk;     // 153.8kHz UART 过采样
  wire lb_clk;           // 100kHz  低速总线
  wire pll_lock, pll_rst;

  SystemPLL u_SystemPLL (
      .CLKI  (clk_ps),   // 原版: .CLKI(clk_osc)
      .CLKOP (clk),
      .CLKOS (systemtimer_clk),
      .CLKOS2(sampling_clk),
      .CLKOS3(lb_clk),
      .RST   (pll_rst),
      .LOCK  (pll_lock)
  );


  // 原 Lattice 版: WISHBONE 系统控制接口, 只提供 clk/rst 给 ResetController 和 WISHBONE_Adapter。
  // Xilinx 版 ResetController 不再需要 WISHBONE, 整个 syscon 一并注释。
  /*
  wishbone_syscon_if wb_sys ();
  WISHBONE_SYSCON u_WISHBONE_SYSCON (.*);
  */

  wire ndmreset;       // JTAG调试器复位
  wire bootstrapreset; // 自举控制器复位
  wire rst;

  // 原 Lattice 版: ResetController 的 WISHBONE 相关信号 (用于发 GSR/Flash 命令)
  // wire wb_idle, wb_override;
  // wishbone_if #(.PORT_SIZE(WB_PORT_SIZE)) reset_wb ();

  logic rst_sw_sync;  // 复位按钮
  always_ff @(posedge clk) rst_sw_sync <= rst_sw;

  ResetController #(
      .MAX_LOCK_PERIOD((50_000_000 / 1_000) * 15)  // 50MHz 下约 15ms; 原版: (2_150_000/1_000)*15
  ) u_ResetController (
      .independent_clk(clk_aux),   // 原版: clk_inner_osc
      .pll_lock       (pll_lock),
      .pll_rst        (pll_rst),
      // 原版还有四个 WISHBONE 端口, 新版已删除:
      // .syscon         (wb_sys),
      // .wb             (reset_wb),
      // .wb_idle        (wb_idle),
      // .wb_override    (wb_override),
      .reset_req      (ndmreset | rst_sw_sync | bootstrapreset),
      .reset          (rst)
  );


  //----------XT_HB高速总线互联定义----------//
  // 在SocConfig中配置

  // 高速总线 主设备接口
  memory_direct_if hb_master[HB_MASTER_COUNT] ();
  // 高速总线 IO设备接口
  xt_hbus_if #(.ADDR_WIDTH(HB_ADDR_WIDTH)) hb_if[HB_DEVICE_COUNT] ();
  // 高速总线 主设备反馈接口
  xt_hbus_rsp_if hb_rsp_master[HB_MASTER_COUNT] ();
  // 高速总线
  XT_HB #(
      .ADDR_WIDTH    (HB_ADDR_WIDTH),    // 总线地址总位宽
      .ID_WIDTH      (HB_ID_WIDTH),      // 总线识别符位宽
      .MASTER_COUNT  (HB_MASTER_COUNT),  // 总线上主设备的数量
      .DEVICE_COUNT  (HB_DEVICE_COUNT),  // 总线上IO设备的数量
      .DEVICE_BASE_ID(DEVICE_BASE_ID)
  ) u_XT_HB (
      .*,
      .clk(clk),
      .rst(rst),
      .master(hb_master),
      .rsp_master(hb_rsp_master),
      .devices(hb_if)
  );


  // 调试器
  dmi_if #(.ABITS(7)) dmi ();
  wire dm_rst;
  JtagDTM #(
      .ABITS       (7),
      .IDCODE_VALUE(32'h0000_00E1)
  ) u_JtagDTM (
      .*,
      .dm_clk(clk)
  );

  dm_hart_minimal_if dm_hart ();
  dm_register_if access_register ();
  DM #(
      .DATACOUNT(4'd2)
  ) u_DM (
      .*,
      .dm_clk(clk),
      .dm_rst_n(pll_lock),
      .memory(hb_master[M_IDX_DM]),
      .memory_rsp(hb_rsp_master[M_IDX_DM])
  );


  // 直连RAM/ROM(指令读取)
  instruction_if core_inst_if ();
  wire core_stall_n;

  // 中断相关
  wire mextern_int;
  wire msoftware_int;
  wire mtimer_int;
  wire [30:0] custom_int_code;
  int_source_if mint (.*);
  // 外部中断 (原版 13 路, 其中 [12:8] 来自 EFB 硬核)
  localparam int EXTERNAL_INT_COUNT = 13;
  wire [EXTERNAL_INT_COUNT-1:0] irq_source;
  // 原版: assign irq_source[7:1] = 7'b0;   ([12:8] 由 EFB 的 I2C/SPI/Timer/UFM 驱动)
  assign irq_source[EXTERNAL_INT_COUNT-1:1] = '0;

  RISC_V_Core #(
      .CFG(CORE_CFG),
      .INST_FETCH_REG(1)
  ) u_RISC_V_Core (
      .*,
      .memory   (hb_master[M_IDX_CORE]),
      .stall_req(hb_rsp_master[M_IDX_CORE].stall_req),
      .command0 (access_register)
  );

  // 提前声明，指令选择
  wire [31:0] boot_instruction;
  wire [31:0] user_instruction;


  // Bootstrap固化程序
  localparam int BOOT_ROM_ADDR_WIDTH = $clog2(BOOT_DEPTH * 4);
  ROM_Reg #(
      .DEPTH(BOOT_DEPTH),
      .WIDTH(BOOT_WIDTH),
      .DATA (BOOT)
  ) u_ROM_Reg (
      .clk    (clk),
      .clk_en (core_inst_if.enable),
      .rst    (1'b0),
      .address(core_inst_if.addr[BOOT_ROM_ADDR_WIDTH-1:2]),
      .q      (boot_instruction)
  );


  // 系统主存
  HarvardSystemRAM_BUS #(
      // 字深度(最大为2^30对应4GB字节)
      .RAM_DEPTH(RAM_DEPTH)
  ) u_HarvardSystemRAM (
      // 总线接口
      .hb               (hb_if[IDX_RAM]),
      // 指令接口
      .inst_fetch_clk_en(core_inst_if.enable),
      .inst_fetch_addr  (core_inst_if.addr),
      .inst_fetch       (user_instruction)
  );


  //----------高速总线32位对齐外设----------//
  xt_hbus32_if #(.OFFSET_WIDTH(HB32_OFFSET_WIDTH)) hb32_if[HB32_DEVICE_COUNT] ();
  XT_HB32_Adapter #(
      .ADDR_WIDTH(HB32_ADDR_WIDTH),
      .ID_WIDTH(HB32_ID_WIDTH),
      .DEVICE_COUNT(HB32_DEVICE_COUNT)
  ) u_XT_HB32_Adapter (
      .*,
      .hb     (hb_if[IDX_HB32]),
      .devices(hb32_if)
  );

  // 自举控制器
  HarvardBootstrap u_HarvardBootstrap (
      .*,
      .download_key     (~key_raw[0]),
      .ram_mode_stop_key(~key_raw[1]),
      .reset_req        (bootstrapreset),
      .hb               (hb32_if[IDX_BOOT_CTRL])
  );

  // 外部中断控制器
  External_INT_Ctrl #(
      .INT_COUNT(EXTERNAL_INT_COUNT)
  ) u_External_INT_Ctrl (
      .*,
      .hb(hb32_if[IDX_EINT_CTRL])
  );

  // mtime和mtimecmp
  SystemTimer u_SystemTimer (
      .*,
      .hb(hb32_if[IDX_SYSTEM_TIMER])
  );

  UART_BUS #(
      // 超采样比率(波特率=SAMPLING_CLK/OVER_SAMPLING)
      // 必须为偶数，最小为8
      .OVER_SAMPLING(8)
  ) u_UART (
      .*,
      .hb    (hb32_if[IDX_UART]),
      .rx_irq(irq_source[0])
  );

  SoftwareINT u_SoftwareINT (
      .*,
      .hb(hb32_if[IDX_SOFTWARE_INT])
  );

  wire funct_in [ AF_FUNCT_IN_COUNT];
  wire funct_out[AF_FUNCT_OUT_COUNT];
  AF_GPIO_BUS #(
      // 数量不能超过32个
      .COUNT          (GPIO_COUNT),
      .FUNCT_IN_COUNT (AF_FUNCT_IN_COUNT),
      .FUNCT_OUT_COUNT(AF_FUNCT_OUT_COUNT),
      .AF_CFGS        (AF_CFGS)
  ) u_AF_GPIO_BUS (
      .hb       (hb32_if[IDX_GPIO]),
      .funct_in (funct_in),
      .funct_out(funct_out),
      .gpio     (gpio)
  );


  //----------WISHBONE总线段----------//
  // 原版此处挂 Lattice EFB 硬核(I2C x2 / SPI / Timer / UFM)。
  // Xilinx 无等效物, 用空设备占住 IDX_WISHBONE 槽位, 保证 XT_LB 的地址 0x4000 不变。
  // 以后要接 PS 的 I2C/SPI, 把 Null_Device 换成真正的桥即可。
  //
  // 以下为原 Lattice 版代码, 保留作参考:
  /*
  //----------WISHBONE总线外设----------//
  wishbone_if #(.PORT_SIZE(WB_PORT_SIZE)) efb_wb ();
  WISHBONE_Adapter #(
      .PORT_SIZE(WB_PORT_SIZE)
  ) u_WISHBONE_Adapter (
      .syscon(wb_sys),
      .wb    (efb_wb),
      .hb    (hb_if[IDX_WISHBONE])
  );

  wishbone_if #(.PORT_SIZE(WB_PORT_SIZE)) wb ();
  ResetWishboneOverride u_ResetWishboneOverride (
      .override(wb_override),
      .idle    (wb_idle),
      .syscon  (wb_sys),
      .efb_wb  (efb_wb),
      .reset_wb(reset_wb),
      .wb      (wb)
  );

  // 原版: GPIO 复用输出接 EFB 的 SPI 片选
  localparam int CSN_COUNT = 8;
  wire [CSN_COUNT-1:0] all_spi_csn;
  assign spi_csn = all_spi_csn[0];
  generate
    for (genvar i = 0; i < CSN_COUNT - 1; ++i) begin : gen_af_spi_csn
      assign funct_out[i+SPI_CSN1] = all_spi_csn[i+1];
    end
  endgenerate

  // 原版: Lattice EFB 硬核 (I2C x2 / SPI / Timer / UFM)
  efb u_efb (
      .*,
      .wb_clk_i(wb_sys.clk),
      .wb_rst_i(wb_sys.rst),
      .wb_cyc_i(wb.cyc),
      .wb_stb_i(wb.stb),
      .wb_we_i (wb.we),
      .wb_adr_i(wb.adr),
      .wb_dat_i(wb.dat_master),
      .wb_dat_o(wb.dat_slave),
      .wb_ack_o(wb.ack),

      .ufm_sn (1'b1),
      .tc_clki(clk_osc),

      .i2c1_irqo(irq_source[8]),
      .i2c2_irqo(irq_source[9]),
      .spi_irq(irq_source[10]),
      .tc_int(irq_source[11]),
      .wbc_ufm_irq(irq_source[12]),

      .spi_csn(all_spi_csn),
      .spi_scsn(funct_in[SPI_SCSN]),
      .tc_ic(funct_in[TIMER_INPUT]),
      .tc_rstn(!funct_in[TIMER_RST]),
      .tc_oc(funct_out[TIMER_OUTPUT])
  );
  */

  // 原版 funct_out 由 EFB 驱动(SPI片选/定时器输出), 现在没有接收方, 统一接地
  generate
    for (genvar i = 0; i < AF_FUNCT_OUT_COUNT; ++i) begin : gen_funct_out_tie
      assign funct_out[i] = 1'b0;
    end
  endgenerate

  Null_Device u_Null_WB (
      .hb(hb_if[IDX_WISHBONE])
  );


  //----------低速总线及其外设----------//
  localparam int LB_ADDR_WIDTH = 8, LB_ID_WIDTH = 2, LB_DEVICE_COUNT = 4;
  localparam int LB_OFFSET_WIDTH = LB_ADDR_WIDTH - LB_ID_WIDTH;
  xt_lbus_if #(.OFFSET_WIDTH(LB_OFFSET_WIDTH)) lb_if[LB_DEVICE_COUNT] ();
  XT_LB #(
      .ADDR_WIDTH(LB_ADDR_WIDTH),
      .ID_WIDTH(LB_ID_WIDTH),
      .DEVICE_COUNT(LB_DEVICE_COUNT)
  ) u_XT_LB (
      .*,
      .hb     (hb_if[IDX_XT_LB]),
      .devices(lb_if)
  );

  SW_KEY_LBUS u_SW_KEY_LBUS (
      .*,
      .lb(lb_if[0])
  );

  LED_LBUS #(
      .LED_COUNT(8)
  ) u_LED_LBUS (
      .lb (lb_if[2]),
      .led(led)
  );

  LEDSD_Direct_LBUS u_LEDSD_Direct_BUS (
      .lb(lb_if[3]),
      .ledsd(ledsd)
  );


endmodule
