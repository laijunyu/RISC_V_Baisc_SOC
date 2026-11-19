// Xilinx 7 系列版复位控制器
//
// 原版 (Lattice MachXO2) 做两件事:
//   1. 监控 PLL 脱锁, 脱锁则复位 PLL 并触发系统复位
//   2. 通过 WISHBONE 发 9 字节命令关闭 Flash 接口, 以恢复被禁用的全局复位(GSR)
//
// Xilinx 没有 GSR 被 Flash 接口禁用的毛病, 所以第 2 项整体删除,
// 只保留 PLL 脱锁检测与复位脉冲生成。
// 复位脉冲固定保持 RESET_HOLD 个 independent_clk 周期, 保证所有逻辑都能被清干净。
//
// 原 Lattice 版的代码以 /* */ 注释保留在原位置, 方便对照与回滚。
module ResetController #(
    parameter int MAX_LOCK_PERIOD = 750_000,  // 50MHz 下约 15ms; 原版默认 360_000
    parameter int RESET_HOLD      = 256       // 复位保持周期数 (原版靠 9 个 WB 事务天然延迟)
) (
    input  logic independent_clk,  // 独立时钟(不经过被监控的 PLL)
    input  logic pll_lock,
    output logic pll_rst,

    // 原 Lattice 版: WISHBONE 端口, 用于发送 GSR/Flash 命令。
    // Xilinx 版不再需要, 注释保留:
    /*
    wishbone_syscon_if.port syscon,
    wishbone_if.master wb,
    input wb_idle,
    output logic wb_override,
    */

    input  logic reset_req,
    output logic reset
);
  localparam int WIDTH      = $clog2(MAX_LOCK_PERIOD);
  localparam int CNT        = MAX_LOCK_PERIOD - 1;
  localparam int HOLD_WIDTH = (RESET_HOLD <= 2) ? 1 : $clog2(RESET_HOLD);

  //----------PLL 脱锁检测----------//
  logic [1:0] pll_lock_sync;
  logic       pll_reseting = 0;
  logic [WIDTH-1:0] lock_counter;

  assign pll_rst = !pll_lock && !pll_reseting;

  always_ff @(posedge independent_clk) begin
    pll_lock_sync <= {pll_lock_sync[0], pll_lock};

    if (pll_reseting) begin
      if (lock_counter == CNT[WIDTH-1:0]) pll_reseting <= 0;
      else lock_counter <= lock_counter + 'd1;
    end else if (!pll_lock_sync[1]) begin
      lock_counter <= 0;
      pll_reseting <= 1;
    end
  end


  //----------原 Lattice 版: 关闭 Flash 接口以恢复 GSR----------//
  // Xilinx 无此问题, 整段注释保留作参考:
  /*
  // 最高位为1表示写入0x71, 否则写入0x70
  localparam bit [8:0] COMMAND_STRING[9] = '{
      {1'b0, 8'h40},  // 复位
      {1'b0, 8'h80},  // 开始命令
      {1'b1, 8'h26},
      {1'b1, 8'h00},
      {1'b1, 8'h00},  // Disable
      {1'b0, 8'h00},  // 结束命令
      {1'b0, 8'h80},  // 开始命令
      {1'b1, 8'hFF},  // Bypass
      {1'b0, 8'h00}   // 结束命令
  };
  logic [3:0] ptr;

  logic perform;
  wire ack;
  wire [wb.PORT_SIZE-1:0] wdata = COMMAND_STRING[ptr][7:0];
  wire [wb.PORT_SIZE-1:0] addr = {4'h7, 3'b0, COMMAND_STRING[ptr][8]};
  WISHBONE_MASTER #(
      .PORT_SIZE(wb.PORT_SIZE)
  ) u_WISHBONE_MASTER (
      .*,
      .perform(perform),
      .write(1'b1),
      .rdata(),
      .write_mode()
  );

  typedef enum bit [1:0] {
    PENDING      = 2'd0,
    COMMAND      = 2'd1,
    ASSERT_RESET = 2'd2,
    RELEASE      = 2'd3
  } reset_state_e;

  assign perform = reset_state == COMMAND;
  */


  //----------复位状态机 (Xilinx 版: 三态, 去掉 COMMAND 阶段)----------//
  typedef enum bit [1:0] {
    PENDING      = 2'd0,
    ASSERT_RESET = 2'd1,
    RELEASE      = 2'd2
  } reset_state_e;

  reset_state_e reset_state;
  logic         reset_pending;
  logic [HOLD_WIDTH-1:0] hold_cnt;

  always_ff @(posedge independent_clk, negedge pll_lock) begin
    if (!pll_lock) begin
      reset_state   <= PENDING;
      reset_pending <= 1;
      reset         <= 1;   // 原版未初始化, 上电时 reset 会是 X
      hold_cnt      <= '0;
    end else begin
      unique case (reset_state)
        PENDING: begin
          if (reset_req) reset_pending <= 1;
          if (reset_pending) begin
            reset_state <= ASSERT_RESET;
            reset       <= 1;
            hold_cnt    <= '0;
          end
        end
        ASSERT_RESET: begin
          if (hold_cnt == HOLD_WIDTH'(RESET_HOLD - 1)) reset_state <= RELEASE;
          else hold_cnt <= hold_cnt + 1'b1;
        end
        RELEASE: begin
          if (!reset_req) begin
            reset         <= 0;
            reset_pending <= 0;
            reset_state   <= PENDING;
          end
        end
      endcase
    end
  end

endmodule
