/* Freestanding multi-process atomic workload: fork + MAP_SHARED, no libc.
 *
 * Strong memory emulation (BOX64_DYNAREC_STRONGMEM) is exactly the cost paid for
 * LOCK-prefixed atomics and the barriers box64 inserts around them, so this is
 * the shape of load that decides whether .NET's GC threads crawl or fly.
 * Processes share one page, so the atomics really contend. */
typedef unsigned long u64;
typedef long i64;

static inline i64 sys6(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
    register i64 r0 __asm__("rax") = n;
    register i64 r1 __asm__("rdi") = a;
    register i64 r2 __asm__("rsi") = b;
    register i64 r3 __asm__("rdx") = c;
    register i64 r10 __asm__("r10") = d;
    register i64 r8 __asm__("r8") = e;
    register i64 r9 __asm__("r9") = f;
    __asm__ volatile("syscall"
                     : "+r"(r0)
                     : "r"(r1), "r"(r2), "r"(r3), "r"(r10), "r"(r8), "r"(r9)
                     : "rcx", "r11", "memory");
    return r0;
}

#define SYS_WRITE 1
#define SYS_MMAP 9
#define SYS_FORK 57
#define SYS_WAIT4 61
#define SYS_EXIT 60

static void print_u64(u64 v) {
    char buf[24];
    int i = 24;
    buf[--i] = '\n';
    if (!v) {
        buf[--i] = '0';
    }
    while (v) {
        buf[--i] = (char)('0' + (v % 10));
        v /= 10;
    }
    sys6(SYS_WRITE, 1, (i64)(buf + i), 24 - i, 0, 0, 0);
}

static volatile u64 *shared;
static u64 per_child = 3000000;

static void child_work(void) {
    u64 local = 0;
    u64 i;
    for (i = 0; i < per_child; i++) {
        __atomic_add_fetch((u64 *)&shared[0], i & 7, __ATOMIC_SEQ_CST);
        local += __atomic_load_n((u64 *)&shared[0], __ATOMIC_SEQ_CST);
        shared[1] = i; /* plain store into the same page: cache-line contention */
    }
    shared[2] += local;
}

void _start(void) {
    i64 page;
    int n = 4;
    int i;

    /* PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS */
    page = sys6(SYS_MMAP, 0, 8192, 3, 0x21, -1, 0);
    if (page < 0) {
        print_u64(0xdead);
        sys6(SYS_EXIT, 1, 0, 0, 0, 0, 0);
    }
    shared = (volatile u64 *)page;

    for (i = 0; i < n; i++) {
        if (sys6(SYS_FORK, 0, 0, 0, 0, 0, 0) == 0) {
            child_work();
            sys6(SYS_EXIT, 0, 0, 0, 0, 0, 0);
            __builtin_unreachable();
        }
    }
    for (i = 0; i < n; i++) {
        sys6(SYS_WAIT4, -1, 0, 0, 0, 0, 0);
    }
    print_u64(shared[0] ^ shared[2]);
    sys6(SYS_EXIT, 0, 0, 0, 0, 0, 0);
    __builtin_unreachable();
}