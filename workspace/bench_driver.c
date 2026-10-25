// bench_driver.c — 吞吐模式(C 参照侧;与 bench_driver/main.mbt 逐项同构)
//
// 场景:纯核零传输,双实例无损交叉投递——sender 每拍顶满发送窗(512 段),
// update + 投递 + drain,跑满 64MB 载荷。读数 = 墙钟 pps / MBps。
//
// 编译(仓根):gcc -O2 -I moonkcp/bak/kcp moonkcp/bak/kcp/ikcp.c \
//   moonkcp/workspace/bench_driver.c -o /tmp/kcp_cbench

#include <stdio.h>
#include <string.h>
#include <time.h>
#include "ikcp.h"

#define CHUNK_LEN 1376
#define WINDOW_SEGS 512
#define TARGET_BYTES (64LL * 1024LL * 1024LL)
#define MAX_ROUNDS 100000
#define MAX_FRAMES 4096
#define MAX_FRAME 2048

static ikcpcb *g_a;
static ikcpcb *g_b;

static char frame_store[2][MAX_FRAMES][MAX_FRAME];
static int frame_lens[2][MAX_FRAMES];
static int frame_count[2];

static int collect_output(const char *buf, int len, ikcpcb *kcp, void *user) {
    (void)user;
    int slot = (kcp == g_a) ? 0 : 1;
    if (frame_count[slot] < MAX_FRAMES && len <= MAX_FRAME) {
        memcpy(frame_store[slot][frame_count[slot]], buf, len);
        frame_lens[slot][frame_count[slot]] = len;
        frame_count[slot]++;
    }
    return 0;
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

int main(void) {
    static unsigned char chunk[CHUNK_LEN];
    static char rcvbuf[4096];
    long long sent_bytes = 0, segments = 0, received = 0;
    int round = 0;
    int i;

    memset(chunk, 65, sizeof(chunk));

    g_a = ikcp_create(1, NULL);
    g_b = ikcp_create(1, NULL);
    ikcp_setoutput(g_a, collect_output);
    ikcp_setoutput(g_b, collect_output);
    ikcp_nodelay(g_a, 1, 10, 2, 1);
    ikcp_nodelay(g_b, 1, 10, 2, 1);
    ikcp_wndsize(g_a, WINDOW_SEGS, WINDOW_SEGS);
    ikcp_wndsize(g_b, WINDOW_SEGS, WINDOW_SEGS);

    long long start = now_ms();
    while (received < TARGET_BYTES && round < MAX_ROUNDS) {
        while (ikcp_waitsnd(g_a) < WINDOW_SEGS && sent_bytes < TARGET_BYTES) {
            ikcp_send(g_a, (const char *)chunk, CHUNK_LEN);
            sent_bytes += CHUNK_LEN;
            segments++;
        }
        frame_count[0] = 0;
        frame_count[1] = 0;
        ikcp_update(g_a, (IUINT32)(round * 10));
        ikcp_update(g_b, (IUINT32)(round * 10));
        for (i = 0; i < frame_count[0]; i++) {
            ikcp_input(g_b, frame_store[0][i], frame_lens[0][i]);
        }
        for (i = 0; i < frame_count[1]; i++) {
            ikcp_input(g_a, frame_store[1][i], frame_lens[1][i]);
        }
        {
            int len;
            while ((len = ikcp_recv(g_b, rcvbuf, sizeof(rcvbuf))) >= 0) {
                received += len;
            }
        }
        round++;
    }
    long long elapsed_ms = now_ms() - start;

    if (elapsed_ms <= 0) {
        printf("KCPBENCH:C pps=? mbps=? (elapsed too small)\n");
        return 0;
    }
    long long pps = segments * 1000LL / elapsed_ms;
    long long mbps = received * 1000LL / elapsed_ms / (1024LL * 1024LL);
    printf("KCPBENCH:C pps=%lld mbps=%lld bytes=%lld segs=%lld ms=%lld\n",
           pps, mbps, received, segments, elapsed_ms);

    ikcp_release(g_a);
    ikcp_release(g_b);
    return 0;
}
