/*
 * ulite_dump.c - 一次性读 AXI UART Lite 的 STAT + RX FIFO
 *
 * 替代连续执行 devmem：只 mmap 一次，循环读，避免反复 open/mmap/munmap
 * 造成的 AXI 事务竞态（表现为 "external abort on non-linefetch"）。
 *
 * 编译：
 *   arm-linux-gnueabihf-gcc -O2 -static -o ulite_dump ulite_dump.c
 *
 * 用法（板子上，root）：
 *   ./ulite_dump        读 16 字节
 *   ./ulite_dump 32     读 32 字节
 *   ./ulite_dump -s     只读 STAT
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>

#define ULITE_BASE  0x40600000UL
#define ULITE_SIZE  0x1000UL

int main(int argc, char **argv)
{
    int n = 16;
    int stat_only = 0;
    int fd, i;
    void *map;
    volatile uint32_t *r;

    if (argc > 1) {
        if (strcmp(argv[1], "-s") == 0)
            stat_only = 1;
        else
            n = atoi(argv[1]);
    }
    if (n <= 0 || n > 4096)
        n = 16;

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
        return 1;
    }

    map = mmap(NULL, ULITE_SIZE, PROT_READ | PROT_WRITE,
               MAP_SHARED, fd, (off_t)ULITE_BASE);
    if (map == MAP_FAILED) {
        fprintf(stderr, "mmap: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    r = (volatile uint32_t *)map;

    uint32_t stat = r[0x08 / 4];
    printf("STAT=0x%08X  rx_valid=%d rx_full=%d tx_empty=%d tx_full=%d ovr=%d\n",
           stat,
           !!(stat & 1), !!(stat & 2), !!(stat & 4), !!(stat & 8), !!(stat & 0x20));

    if (!stat_only) {
        printf("RX(%d): ", n);
        for (i = 0; i < n; i++) {
            uint32_t v = r[0x00 / 4];
            printf("%02X ", v & 0xFF);
            if ((i & 15) == 15 && i != n - 1)
                printf("\n       ");
        }
        printf("\n");
    }

    munmap(map, ULITE_SIZE);
    close(fd);
    return 0;
}
