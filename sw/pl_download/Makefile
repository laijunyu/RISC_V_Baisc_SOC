# pl_download.ko 编译 Makefile
#
# 板子内核版本：6.18.39（ARM 32 位）
# 需要该版本的**内核源码树**（含 .config 和 Module.symvers），不是只有 Image。
#
# 用法：
#   make KDIR=~/linux-6.18.39
#   make KDIR=~/linux-6.18.39 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
#
# 产物：pl_download.ko

obj-m := pl_download.o

KDIR   ?= /lib/modules/$(shell uname -r)/build
ARCH   ?= arm
CROSS  ?= arm-linux-gnueabihf-

PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) clean

.PHONY: all clean
