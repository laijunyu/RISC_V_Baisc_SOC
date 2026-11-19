module ID_EX
  import Exception_Pkg::*;
  import RV32I_Inst_Pkg::*;
(
    input clk,
    input rst,
    input flush,
    input stall_n,

    instruction_if.from_prev if_id_inst,
    instruction_if.to_next   id_ex_inst,

    exception_if.observer id_exception,

    // 来自ID
    id_to_ex_if.from_prev id_out,
    // 传递给EX
    id_to_ex_if.to_next   id_ex_out
);

  // 都是NOP指令了，指令地址 不需要清零，对处理异常也有好处(中断处理)
  always_ff @(posedge clk) begin
    if (stall_n) begin
      id_ex_inst.addr <= if_id_inst.addr;
      id_ex_out.load_addr <= id_out.load_addr;
      id_ex_out.store_addr <= id_out.store_addr;
      id_ex_out.store_data <= id_out.store_data;
      id_ex_out.operand1 <= id_out.operand1;
      id_ex_out.operand2 <= id_out.operand2;
    end
  end

  // 原写法（综合报 6 条 "Mix of synchronous and asynchronous control"）：
  //   always_ff @(posedge clk, posedge rst) begin
  //     if (rst || flush || (id_exception.raise && stall_n)) begin
  //       ... 清零 ...
  //     end else if (stall_n) begin
  //       ... 加载 ...
  //     end
  //   end
  // 异步 rst 和同步 flush/stall_n 混在同一个 if 里，综合器必须二选一，
  // 是「仿真对、上板错」的典型来源。下面把 rst 拆成独立的异步复位分支，
  // 语义完全等价，但综合不再有歧义。
  wire clear_ex = flush || (id_exception.raise && stall_n);

  always_ff @(posedge clk, posedge rst) begin
    if (rst) begin
      id_ex_out.load <= 0;
      id_ex_out.store <= 0;
      id_ex_inst.inst <= INST_NOP;
      id_ex_out.reg_wen <= 0;
      id_ex_out.csr_ren <= 0;
      id_ex_out.csr_wen <= 0;
    end else if (clear_ex) begin
      id_ex_out.load <= 0;
      id_ex_out.store <= 0;
      id_ex_inst.inst <= INST_NOP;
      id_ex_out.reg_wen <= 0;
      id_ex_out.csr_ren <= 0;
      id_ex_out.csr_wen <= 0;
    end else if (stall_n) begin
      id_ex_out.load <= id_out.load;
      id_ex_out.store <= id_out.store;
      id_ex_inst.inst <= if_id_inst.inst;
      id_ex_out.reg_wen <= id_out.reg_wen;
      id_ex_out.csr_ren <= id_out.csr_ren;
      id_ex_out.csr_wen <= id_out.csr_wen;
    end
  end


endmodule
