/* crt0.S - C 程序的启动入口（RV32I 裸机）
 *
 * 为什么需要它：
 *   内核的寄存器堆在复位时**不做初始化**（见 RISC_V/Core/CoreReg.sv：
 *   `if (!rst && ... && wen && waddr != 0)` 只门控写使能），
 *   所以复位后 sp(x2) 是未定义值。
 *
 *   纯汇编程序如果只有一层 jal/ret、不碰栈，可以不设 sp（blink.S 就是）；
 *   但只要有函数调用嵌套、或者用 C 编译，就必须先设好 sp，否则压栈压到
 *   随机地址，程序立刻跑飞。
 *
 * 编译（配合 link.ld，.text.start 必须排在最前）：
 *   riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -O2 \
 *       -nostdlib -nostartfiles -ffreestanding \
 *       -T link.ld -o app.elf crt0.S app.c -lgcc
 *
 * 注意：这里**不清 .bss**。当前 link.ld 没有定义 __bss_start/_end 符号，
 *       所以 C 里的未初始化全局变量不保证是 0，需要初值就显式赋值。
 */

    .section .text.start
    .globl _start

_start:
    /* 栈顶 = RAM 末尾。RAM 是 0x0000~0x1FFF（2048 字 = 8KB），
     * 栈从 0x2000 往下长，最高用到 0x1FFC。 */
    li    sp, 0x2000

    /* 全局指针 gp：RV32I 的 gp 相对寻址用得到，指到 .data 附近。
     * 这里放在 0x1800（RAM 中段），避开栈和代码。 */
    li    gp, 0x1800

    call  main

    /* main 返回就停在这里，不返回给不存在的 C 运行时 */
1:  j     1b
