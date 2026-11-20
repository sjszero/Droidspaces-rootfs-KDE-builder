/* Freestanding x86-64 microbenchmark: no libc, no startup files, raw syscalls.
 * Everything that runs is box64-emulated code, so the timing reflects the
 * dynarec output and nothing else. Built with -ffreestanding -nostdlib -static.
 *
 * Loads: ALU dependency chains, array traffic, SSE double math, and a
 * call/return heavy mix (what BOX64_DYNAREC_CALLRET/SEP act on). */
typedef unsigned long u64;
typedef unsigned int u32;
typedef long i64;

static inline i64 sys3(i64 n, i64 a, i64 b, i64 c) {
    register i64 r0 __asm__("rax") = n;
    register i64 r1 __asm__("rdi") = a;
    register i64 r2 __asm__("rsi") = b;
    register i64 r3 __asm__("rdx") = c;
    __asm__ volatile("syscall" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3) : "rcx", "r11", "memory");
    return r0;
}

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
    sys3(1, 1, (i64)(buf + i), 24 - i);
}

static u32 mem[1u << 18];

__attribute__((noinline)) static u64 mix1(u64 x) {
    return (x ^ (x >> 7)) * 0x100000001b3ULL;
}
__attribute__((noinline)) static u64 mix2(u64 x) {
    return mix1(x + 0x9e3779b97f4a7c15ULL) ^ mix1(x >> 11);
}
__attribute__((noinline)) static u64 mix3(u64 x) {
    return mix2(x) + mix1(x << 3);
}

static u64 alu_work(u64 n) {
    u64 a = 0x9e3779b97f4a7c15ULL, b = 0xbf58476d1ce4e5b9ULL, c = 0x94d049bb133111ebULL;
    u64 i;
    for (i = 0; i < n; i++) {
        a ^= a << 13;
        a ^= a >> 7;
        a ^= a << 17;
        b += a ^ (i * 0x2545f4914f6cdd1dULL);
        c ^= b + (a >> 3) + (c << 5);
    }
    return a ^ b ^ c;
}

static u64 mem_work(u64 rounds) {
    u64 sum = 0;
    u32 i;
    u64 r;
    for (i = 0; i < (1u << 18); i++) {
        mem[i] = i * 2654435761u;
    }
    for (r = 0; r < rounds; r++) {
        for (i = 0; i < (1u << 18); i++) {
            sum += mem[i] ^ (u32)r;
        }
    }
    return sum;
}

static i64 fp_work(u64 n) {
    double x = 1.000001, y = 2.718281828;
    u64 i;
    for (i = 0; i < n; i++) {
        x = x * 1.0000003 + y * 0.9999997;
        y = y / 1.0000001 + x * 0.5;
    }
    return (i64)(x + y);
}

static u64 call_work(u64 n) {
    u64 r = 0;
    u64 i;
    for (i = 0; i < n; i++) {
        r += mix3(i);
    }
    return r;
}

void _start(void) {
    u64 r = alu_work(40000000);
    r ^= mem_work(40);
    r ^= call_work(10000000);
    r += (u64)fp_work(20000000);
    print_u64(r);
    sys3(60, 0, 0, 0);
    __builtin_unreachable();
}