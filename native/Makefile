# native/ — the merged CMP 50HX userland binary (multi-call; see main.c).
#
# The kernel-patch build path keeps compiling verify's probe standalone
# (build.sh: cc -DCMP50HX_VERIFY_STANDALONE native/verify.c), so one source
# serves both the artifact and the dispatcher.

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11
LDLIBS := -ldl

SRCS := main.c governor.c gen2.c osunlock.c tune.c verify.c explain.c nvml.c
HDRS := nvml.h ../common/cmp50hx_regs.h

cmp50hx: $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) $(SRCS) -I. -I../common $(LDLIBS) -o $@

clean:
	rm -f cmp50hx *.o

.PHONY: clean
