# Build the iova_stress kernel module.
#
# Usage:
#   make                  # build against the running kernel's headers
#   make KDIR=/lib/modules/<version>/build
#   make clean
#
# The module is intentionally NOT auto-loaded by anything here.
# See the README for the safety warnings before insmod.

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

obj-m += iova_stress.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
