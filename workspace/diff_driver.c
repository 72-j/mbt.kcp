// diff_driver.c — K5 差分驱动(C 参照侧;与 diff_driver/main.mbt 逐行同构)
//
// 场景机:双实例 conv=0x12345678,nodelay(1,10,2,1),mtu=300;
// 四相收发(A 环前 50/300/550/1000,B@120 拍 120/260/40,A@150 拍 276/277/800,
// B@180 拍 1000/55);400 拍快钟,每拍序:update A → update B → 转录 → 带损交叉投递。
// 带损 = LCG 确定性丢失(x = x*1664525u+1013904223u;(x & 0x7FFFFFFF) % 5 == 0
// 则弃,~20% 丢率,种子 12345)——与 MoonBit 侧同式同种,重传动力学全上桌。
// 探窗帧(cmd 83/84)屏蔽字节 8..15(ts+sn)。尾行 done <side> <累计收字节数>。
//
// 编译(仓根):gcc -O2 -I moonkcp/bak/kcp moonkcp/bak/kcp/ikcp.c \
//   moonkcp/workspace/diff_driver.c -o /tmp/kcp_cdriver (单行,尾反斜杠勿用)

#include <stdio.h>
#include <string.h>
#include "ikcp.h"

#define MAX_FRAMES 256
#define MAX_FRAME 2048

static ikcpcb *g_a;
static ikcpcb *g_b;

static char frame_store[2][MAX_FRAMES][MAX_FRAME];
static int frame_lens[2][MAX_FRAMES];
static int frame_count[2];

static unsigned int g_lcg;

static unsigned int lcg_draw(void) {
    g_lcg = g_lcg * 1664525u + 1013904223u;
    return g_lcg & 0x7FFFFFFFu;
}

static int loss_drop(void) {
    return (int)(lcg_draw() % 5u) == 0;
}

static int batch_reversed(void) {
    return (int)(lcg_draw() % 2u) == 0;
}

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

static void print_frames(int round, int slot) {
    int i;
    for (i = 0; i < frame_count[slot]; i++) {
        int len = frame_lens[slot][i];
        int j;
        printf("%d %c ", round, slot == 0 ? 'a' : 'b');
        for (j = 0; j < len; j++) {
            printf("%02x", (unsigned char)frame_store[slot][i][j]);
        }
        printf("\n");
    }
}

static void make_payload(unsigned char *buf, int tag, int length) {
    int j;
    for (j = 0; j < length; j++) {
        buf[j] = (unsigned char)((tag * 37 + j) & 0x7F);
    }
}

static int total_received(ikcpcb *kcp) {
    static char rcvbuf[8192];
    int total = 0;
    int len;
    while ((len = ikcp_recv(kcp, rcvbuf, sizeof(rcvbuf))) >= 0) {
        total += len;
    }
    return total;
}

int main(void) {
    static unsigned char payload[4096];
    long long drained_b = 0;
    int r;
    int i;

    g_a = ikcp_create(0x12345678, NULL);
    g_b = ikcp_create(0x12345678, NULL);
    ikcp_setoutput(g_a, collect_output);
    ikcp_setoutput(g_b, collect_output);
    ikcp_nodelay(g_a, 1, 10, 2, 1);
    ikcp_nodelay(g_b, 1, 10, 2, 1);
    ikcp_setmtu(g_a, 300);
    ikcp_setmtu(g_b, 300);

    make_payload(payload, 1, 50);
    ikcp_send(g_a, (const char *)payload, 50);
    make_payload(payload, 2, 300);
    ikcp_send(g_a, (const char *)payload, 300);
    make_payload(payload, 3, 550);
    ikcp_send(g_a, (const char *)payload, 550);
    make_payload(payload, 4, 1000);
    ikcp_send(g_a, (const char *)payload, 1000);

    g_lcg = 12345u;

    for (r = 0; r < 2000; r++) {
        IUINT32 t = (IUINT32)(r * 10);
        if (r == 120) {
            make_payload(payload, 5, 120);
            ikcp_send(g_b, (const char *)payload, 120);
            make_payload(payload, 6, 260);
            ikcp_send(g_b, (const char *)payload, 260);
            make_payload(payload, 7, 40);
            ikcp_send(g_b, (const char *)payload, 40);
        }
        if (r == 150) {
            make_payload(payload, 8, 276);
            ikcp_send(g_a, (const char *)payload, 276);
            make_payload(payload, 9, 277);
            ikcp_send(g_a, (const char *)payload, 277);
            make_payload(payload, 10, 800);
            ikcp_send(g_a, (const char *)payload, 800);
        }
        if (r == 180) {
            make_payload(payload, 11, 1000);
            ikcp_send(g_b, (const char *)payload, 1000);
            make_payload(payload, 12, 55);
            ikcp_send(g_b, (const char *)payload, 55);
        }
        if (r == 60) {
            for (i = 13; i <= 212; i++) {
                make_payload(payload, i, 20);
                ikcp_send(g_a, (const char *)payload, 20);
            }
        }
        if (r == 600) {
            static char drainbuf[4096];
            int dlen;
            while ((dlen = ikcp_recv(g_b, drainbuf, sizeof(drainbuf))) >= 0) {
                drained_b += dlen;
            }
        }
        frame_count[0] = 0;
        frame_count[1] = 0;
        ikcp_update(g_a, t);
        ikcp_update(g_b, t);
        print_frames(r, 0);
        print_frames(r, 1);
        {
            int rev_a = batch_reversed();
            int rev_b = batch_reversed();
            for (i = 0; i < frame_count[0]; i++) {
                int idx = rev_a ? (frame_count[0] - 1 - i) : i;
                if (!loss_drop()) {
                    ikcp_input(g_b, frame_store[0][idx], frame_lens[0][idx]);
                }
            }
            for (i = 0; i < frame_count[1]; i++) {
                int idx = rev_b ? (frame_count[1] - 1 - i) : i;
                if (!loss_drop()) {
                    ikcp_input(g_a, frame_store[1][idx], frame_lens[1][idx]);
                }
            }
        }
    }

    printf("done b %d\n", (int)(drained_b + total_received(g_b)));
    printf("done a %d\n", total_received(g_a));

    ikcp_release(g_a);
    ikcp_release(g_b);
    return 0;
}
