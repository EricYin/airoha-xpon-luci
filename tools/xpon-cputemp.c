/*
 * xpon-cputemp.c — EN7581 CPU 温度读取（XG2010G / ECONET EN7581）
 *
 * 静态、无 libc、裸 syscall；通过 mmap /dev/mem 访问 SCU/PTP 寄存器，
 * 不依赖 busybox devmem/od applet（XG2010G 固件 busybox 无 devmem）。
 *
 * 编译：aarch64-linux-gnu-gcc -Os -static -nostdlib -ffreestanding -fno-builtin \
 *       -fno-stack-protector -fno-unwind-tables -o xpon-cputemp xpon-cputemp.c
 *
 * 用法：
 *   xpon-cputemp            → temp=44.3   或 temp=NA（读取失败）
 *   xpon-cputemp reg <addr> → 0xXXXXXXXX（只读诊断，无副作用）
 */

typedef unsigned long ulong;
typedef unsigned int  u32;
typedef long s32;

#define AT_FDCWD   (-100)
#define O_RDWR     2
#define PROT_READ  1
#define PROT_WRITE 2
#define MAP_SHARED 1

#define SYS_openat    56
#define SYS_close     57
#define SYS_write     64
#define SYS_nanosleep 101
#define SYS_munmap    215
#define SYS_mmap      222
#define SYS_exit      93

/* SCU（0x1fa20000）/ PTP（0x1efbd000）寄存器偏移 */
#define PLLRG_PROTECT  0x268
#define MUX_TADC       0x2ec
#define DOUT_TADC      0x2f8
#define MUX_TADC_CPU   0x2fc
#define DOUT_TADC_CPU  0x308
#define PTPSPARE0      0xf20   /* efuse code30 高 16 位 */
#define PTPSPARE2      0xf28   /* 0 = CPK/AVS */
#define PROTECT_KEY    0x12

static long sc(long n, long a, long b, long c, long d, long e, long f)
{
	register long x0 asm("x0") = a;
	register long x1 asm("x1") = b;
	register long x2 asm("x2") = c;
	register long x3 asm("x3") = d;
	register long x4 asm("x4") = e;
	register long x5 asm("x5") = f;
	register long x8 asm("x8") = n;
	asm volatile("svc #0" : "+r"(x0)
	             : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8)
	             : "memory");
	return x0;
}

static void wraw(int fd, const char *s, long n)
{
	while (n > 0) {
		long r = sc(SYS_write, fd, (long)s, n, 0, 0, 0);
		if (r <= 0) break;
		s += r; n -= r;
	}
}

static void wstr(const char *s)
{
	long n = 0;
	while (s[n]) n++;
	wraw(1, s, n);
}

static void wnum(long v)
{
	char b[24];
	long i = 23;
	b[i--] = 0;
	if (v == 0) { b[i--] = '0'; }
	else {
		int neg = 0;
		if (v < 0) { neg = 1; v = -v; }
		while (v > 0) { b[i--] = (char)('0' + v % 10); v /= 10; }
		if (neg) b[i--] = '-';
	}
	wstr(&b[i + 1]);
}

/* mmap 一页（4KB）物理地址，返回页对齐基址；失败返回 0 */
static volatile u32 *map_page(ulong addr)
{
	int fd = (int)sc(SYS_openat, AT_FDCWD, (long)"/dev/mem", O_RDWR, 0, 0, 0);
	void *p;
	if (fd < 0) return 0;
	p = (void *)sc(SYS_mmap, 0, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, addr);
	sc(SYS_close, fd, 0, 0, 0, 0, 0);
	if ((ulong)p >= 0xfffffffffffff000UL) return 0;
	return (volatile u32 *)p;
}

static u32 rd(volatile u32 *b, u32 off)
{
	__sync_synchronize();
	return *(volatile u32 *)((char *)b + off);
}

static void wr(volatile u32 *b, u32 off, u32 v)
{
	__sync_synchronize();
	*(volatile u32 *)((char *)b + off) = v;
	__sync_synchronize();
}

static void nsleep(ulong ns)
{
	struct { long tv_sec; long tv_nsec; } t = { 0, (long)ns };
	sc(SYS_nanosleep, (long)&t, 0, 0, 0, 0, 0);
}

static int hexval(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

/* 初始化 TADC 并读取校准后的温度。 */
static int run_temp(void)
{
	volatile u32 *scu = map_page(0x1fa20000UL);
	volatile u32 *ptp = map_page(0x1efbd000UL);
	u32 k, E, F, v, mn, mx, avg;
	int code30, slope, init, i, t10;

	if (!scu || !ptp) {
		if (scu) sc(SYS_munmap, (long)scu, 0x1000, 0, 0, 0, 0);
		if (ptp) sc(SYS_munmap, (long)ptp, 0x1000, 0, 0, 0, 0);
		return -1;
	}

	k = rd(scu, PLLRG_PROTECT);
	wr(scu, PLLRG_PROTECT, PROTECT_KEY);
	/* TADC 复位脉冲 [4]: 0 -> 1 */
	wr(scu, MUX_TADC, rd(scu, MUX_TADC) & ~0x10u);
	wr(scu, MUX_TADC, (rd(scu, MUX_TADC) & ~0x10u) | 0x10u);
	/* 模式：rw(0x0390, 0xf3ff, 0) → (cur & ~0xf3ff) | 0x290 */
	wr(scu, MUX_TADC, (rd(scu, MUX_TADC) & ~0xf3ffu) | 0x290u);
	/* TADC_CPU 同流程 */
	wr(scu, MUX_TADC_CPU, rd(scu, MUX_TADC_CPU) & ~0x10u);
	wr(scu, MUX_TADC_CPU, (rd(scu, MUX_TADC_CPU) & ~0x10u) | 0x10u);
	wr(scu, MUX_TADC_CPU, (rd(scu, MUX_TADC_CPU) & ~0xf3ffu) | 0x290u);
	/* 选温度/二极管通道：MUX bits[3:1] = 0x7（thermal_TADC_mode(0,1,10)） */
	wr(scu, MUX_TADC, (rd(scu, MUX_TADC) & ~0xeu) | 0xeu);
	wr(scu, PLLRG_PROTECT, k);
	nsleep(10000000UL);   /* mdelay(10) */

	E = rd(ptp, PTPSPARE0);
	F = rd(ptp, PTPSPARE2);
	if (E) {
		code30 = (int)((E >> 16) & 0xffffu);
		slope  = (F == 0) ? 5645 : 5710;
		init   = (F == 0) ? 300  : 620;
	} else {
		/* efuse 无效 → NONK 路径：首次 ADC 作 code30（不缓存，进程内一次） */
		code30 = (int)rd(scu, DOUT_TADC);
		slope  = 5710;
		init   = 550;
	}

	v = rd(scu, DOUT_TADC);
	mn = mx = avg = v;
	for (i = 1; i < 6; i++) {
		v = rd(scu, DOUT_TADC);
		avg += v;
		if (v > mx) mx = v;
		else if (v < mn) mn = v;
	}
	avg = (avg - mx - mn) >> 2;

	/* temp_x10 = 1000*(avg-code30)/slope + init（C 语义：先乘后整除） */
	t10 = 1000 * ((int)avg - code30) / slope + init;

	sc(SYS_munmap, (long)scu, 0x1000, 0, 0, 0, 0);
	sc(SYS_munmap, (long)ptp, 0x1000, 0, 0, 0, 0);

	wstr("temp=");
	if (t10 < 0) { wstr("-"); t10 = -t10; }
	wnum(t10 / 10);
	wstr(".");
	wnum(t10 % 10);
	wstr("\n");
	return 0;
}

static int run_reg(const char *arg)
{
	ulong addr = 0;
	const char *p = arg;
	while (*p) {
		int h = hexval(*p);
		if (h < 0) return -1;
		addr = (addr << 4) | (ulong)h;
		p++;
	}
	{
		volatile u32 *b = map_page(addr & ~0xfffUL);
		if (!b) return -1;
		wstr("0x");
		/* 16 位 hex 输出 */
		{
			u32 v = rd(b, (u32)(addr & 0xfffUL));
			char o[9];
			int i;
			for (i = 7; i >= 0; i--) {
				int d = (int)((v >> (i * 4)) & 0xf);
				o[7 - i] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
			}
			o[8] = 0;
			wstr(o);
		}
		wstr("\n");
		sc(SYS_munmap, (long)b, 0x1000, 0, 0, 0, 0);
	}
	return 0;
}

/* 由 entry.S 的 _start 以 sp 为参调用；返回退出码 */
long xpon_main(ulong *sp)
{
	long argc = (long)sp[0];
	char **argv = (char **)(sp + 1);
	long rc = 0;

	if (argc >= 3 && argv[1][0] == 'r' && argv[1][1] == 'e' && argv[1][2] == 'g' && argv[1][3] == 0) {
		rc = (run_reg(argv[2]) == 0) ? 0 : 1;
	} else if (argc == 1 || (argc == 2 && argv[1][0] == 't' && argv[1][1] == 'e' && argv[1][2] == 'm' && argv[1][3] == 'p' && argv[1][4] == 0)) {
		rc = (run_temp() == 0) ? 0 : 1;
	} else {
		wstr("usage: xpon-cputemp [reg <hexaddr>]\n");
		rc = 2;
	}
	if (rc != 0)
		wstr("temp=NA\n");
	return rc;
}
