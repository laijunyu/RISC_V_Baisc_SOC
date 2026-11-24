# RISC_V_Baisc_SOC
 一个fork至别人的RISC_V_SOC的基础soc，仅作个人学习用途
# 如何开始
创建xpc项目（我是用赛灵思的zynq7z010），项目中有运用xilinx ip的部分（uart通过axi连接了ps等），可酌情替换，导入进项目即可运行。
# TODO
- [√] 实现RISCV M指令。
- [ ] 实现RISCV F，D指令。
- [ ] 实现 A指令。
- [ ] 。。。
# 致谢（引用）
[XT_RISC_V_Soc](https://github.com/XuanTongYao/XT_RISC-V_Soc),复用了RV32i的流水线代码
[ACT4](https://github.com/riscv/riscv-arch-test/) RISC_V 官方指令测试框架
