#define REG32(addr)   (*(volatile unsigned int  *)(addr))
#define REG8(addr)    (*(volatile unsigned char *)(addr))

/* ---- 自举控制 0x2000 ---- */
#define BOOT_CTRL       REG32(0x2000)   /* 读 bit0=K1按下; 写 0x00=RAM模式复位, 0x55=ROM模式复位 */

/* ---- 外部中断 0x2020 ---- */
#define EINT_ENABLE     REG32(0x2020)   /* 中断使能，每位对应 irq_source[i] */
#define EINT_PENDING    REG32(0x2024)   /* 待处理中断（只读） */

/* ---- 系统计时器 0x2040 ---- */
#define MTIME_LO        REG32(0x2040)
#define MTIME_HI        REG32(0x2044)
#define MTIMECMP_LO     REG32(0x2048)   /* 写入自动清中断 */
#define MTIMECMP_HI     REG32(0x204C)

/* ---- UART 0x2060 ---- */
#define UART_DATA       REG32(0x2060)   /* 写=发送, 读=接收(自动清中断) */
#define UART_STAT       REG32(0x2064)
#define UART_TX_READY   (1u << 0)       /* 发送缓冲未满 */
#define UART_RX_READY   (1u << 1)       /* 有数据可读 */
#define UART_TX_EMPTY   (1u << 2)       /* 发送缓冲空 */
#define UART_RX_FULL    (1u << 3)       /* 接收缓冲满 */

/* ---- 软件中断 0x2080 ---- */
#define MSIP            REG32(0x2080)   /* 写 1 触发，写 0 清除 */

/* ---- GPIO 0x20A0 ---- */
#define GPIO_DIR        REG32(0x20A0)   /* 1=输出, 0=输入 */
#define GPIO_DATA       REG32(0x20A4)   /* 写=输出, 读=输入 */
#define GPIO_AF_EN      REG32(0x20A8)
#define GPIO_AFL        REG32(0x20AC)
#define GPIO_AFH        REG32(0x20B0)

/* ---- 低速外设 0x4000 ---- */
#define KEY_REG         REG32(0x4000)   /* bit0 = K1 按下 */
#define SWITCH_REG      REG8 (0x4001)
#define LED             REG32(0x4080)   /* 低 8 位, top 只引出 led[1:0] */
#define LEDSD_DATA      REG32(0x40C0)
#define LEDSD_CTRL      REG32(0x40C4)



#define LOOP_COUNT_500MS  2000000UL 
#define LOOP_COUNT_1000MS 4000000UL

// 使用 volatile 防止编译器将空循环优化掉
void delay_loops(volatile int count) {
    for (volatile int i = 0; i < count; i++) {
        // 空循环，仅用于消耗时间
        __asm__ volatile ("nop"); // 插入一个空操作指令，确保循环不被优化，并增加可预测的延时
    }
}
int main(){
    while (1)
    {
        delay_loops(LOOP_COUNT_1000MS);
        LED=0b01;
        delay_loops(LOOP_COUNT_1000MS);
        LED=0b10;
        delay_loops(LOOP_COUNT_1000MS);
    }
    
   
}