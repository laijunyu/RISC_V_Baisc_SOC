/* 链接脚本: 程序从 RAM 0x0 开始, 供 BOOT 自举下载使用 */
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;

  .text : {
    *(.text.start)
    *(.text*)
  }

  .rodata : { *(.rodata*) }
  .data   : { *(.data*) }
  .bss    : { *(.bss*) *(COMMON) }

  /DISCARD/ : { *(.comment) *(.note*) }
}
