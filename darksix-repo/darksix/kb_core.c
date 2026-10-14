// DarkSix keyboard picture recolor (the full 640x432 keyboard sheet): black background, gray keys, white legends.
// Pure C so it can be tested on a computer. Pixels are premultiplied RGBA, 4 bytes each.
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "kb_core.h"

static float kb_clamp(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

// zeros that cannot be reached from the picture's border become ones (the legend holes inside a key)
static void kb_fill_holes(unsigned char *m, int w, int h, int *stk)
{
    int n = w * h, i, top = 0, head = 0, x, y;
    unsigned char *seen = (unsigned char *)calloc(n, 1);
    if (!seen) return;
    for (x = 0; x < w; x++) {
        if (!m[x] && !seen[x]) { seen[x] = 1; stk[top++] = x; }
        i = (h - 1) * w + x;
        if (!m[i] && !seen[i]) { seen[i] = 1; stk[top++] = i; }
    }
    for (y = 0; y < h; y++) {
        i = y * w;
        if (!m[i] && !seen[i]) { seen[i] = 1; stk[top++] = i; }
        i = y * w + w - 1;
        if (!m[i] && !seen[i]) { seen[i] = 1; stk[top++] = i; }
    }
    while (head < top) {
        int cur = stk[head++], cx = cur % w, cy = cur / w, dir;
        for (dir = 0; dir < 4; dir++) {
            int nx = cx + (dir == 0 ? -1 : (dir == 1 ? 1 : 0));
            int ny = cy + (dir == 2 ? -1 : (dir == 3 ? 1 : 0));
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            int ni = ny * w + nx;
            if (m[ni] || seen[ni]) continue;
            seen[ni] = 1;
            stk[top++] = ni;
        }
    }
    for (i = 0; i < n; i++) if (!m[i] && !seen[i]) m[i] = 1;
    free(seen);
}

// square erosion of a 0/1 picture by radius r
static void kb_erode(const unsigned char *src, unsigned char *dst, unsigned char *tmp, int w, int h, int r)
{
    int x, y, k;
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++) {
            int ok = 1;
            for (k = -r; k <= r && ok; k++) {
                int xx = x + k;
                if (xx < 0 || xx >= w || !src[y * w + xx]) ok = 0;
            }
            tmp[y * w + x] = (unsigned char)ok;
        }
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++) {
            int ok = 1;
            for (k = -r; k <= r && ok; k++) {
                int yy = y + k;
                if (yy < 0 || yy >= h || !tmp[yy * w + x]) ok = 0;
            }
            dst[y * w + x] = (unsigned char)ok;
        }
}

enum { KB_MAXC = 400 };

typedef struct {
    int n;
    int miny[KB_MAXC + 1], maxy[KB_MAXC + 1];
    float base[KB_MAXC + 1];
} KbComps;

// label the connected pieces of a core picture into id (starting at first id), return count
static int kb_label(const unsigned char *core, const unsigned char *lb, int *id, int *stk, int w, int h, int first, KbComps *cc)
{
    int n = w * h, i, made = 0;
    for (i = 0; i < n; i++) {
        if (!core[i] || id[i]) continue;
        if (first + made > KB_MAXC) break;
        int top = 0, head = 0, hist[256], miny = h, maxy = -1;
        memset(hist, 0, sizeof(hist));
        stk[top++] = i;
        id[i] = -1;
        while (head < top) {
            int cur = stk[head++], cx = cur % w, cy = cur / w, dir;
            hist[lb[cur]]++;
            if (cy < miny) miny = cy;
            if (cy > maxy) maxy = cy;
            for (dir = 0; dir < 4; dir++) {
                int nx = cx + (dir == 0 ? -1 : (dir == 1 ? 1 : 0));
                int ny = cy + (dir == 2 ? -1 : (dir == 3 ? 1 : 0));
                if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                int ni = ny * w + nx;
                if (!core[ni] || id[ni]) continue;
                id[ni] = -1;
                stk[top++] = ni;
            }
        }
        if (top < 600) {                      // too small to be a key
            int m;
            for (m = 0; m < top; m++) id[stk[m]] = -2;
            continue;
        }
        // the key's own level is the most common brightness (the face is far bigger than its legend)
        int b, best = 0, bestv = -1;
        for (b = 2; b < 254; b++) {
            int s = hist[b - 2] + hist[b - 1] + hist[b] + hist[b + 1] + hist[b + 2];
            if (s > bestv) { bestv = s; best = b; }
        }
        made++;
        int cid = first + made - 1;
        int m;
        for (m = 0; m < top; m++) id[stk[m]] = cid;
        cc->base[cid] = (float)best;
        cc->miny[cid] = miny;
        cc->maxy[cid] = maxy;
    }
    for (i = 0; i < n; i++) if (id[i] < 0) id[i] = 0;
    return made;
}

int ds_kb_sheet(unsigned char *px, int w, int h, int rb)
{
    int n = w * h, i, x, y;
    if (w < 64 || h < 64 || w > 2048 || h > 2048) return 0;
    unsigned char *lb = (unsigned char *)malloc(n);
    unsigned char *wm = (unsigned char *)calloc(n, 1);      // light keys (with their legends)
    unsigned char *dm = (unsigned char *)calloc(n, 1);      // dark keys (with their legends)
    unsigned char *tmp = (unsigned char *)malloc(n);
    unsigned char *cw = (unsigned char *)malloc(n);
    unsigned char *cd = (unsigned char *)malloc(n);
    unsigned char *dw = (unsigned char *)malloc(n);         // deep inside a light key (legend area)
    unsigned char *dd = (unsigned char *)malloc(n);         // deep inside a dark key
    int *id = (int *)calloc(n, sizeof(int));
    int *id2 = (int *)calloc(n, sizeof(int));
    int *stk = (int *)malloc(sizeof(int) * n);
    float *bg = (float *)malloc(sizeof(float) * h);
    KbComps *cc = (KbComps *)calloc(1, sizeof(KbComps));
    unsigned char *isWhite = (unsigned char *)calloc(KB_MAXC + 1, 1);
    if (!lb || !wm || !dm || !tmp || !cw || !cd || !dw || !dd || !id || !id2 || !stk || !bg || !cc || !isWhite) {
        free(lb); free(wm); free(dm); free(tmp); free(cw); free(cd); free(dw); free(dd);
        free(id); free(id2); free(stk); free(bg); free(cc); free(isWhite);
        return 0;
    }
    for (y = 0; y < h; y++) {
        for (x = 0; x < w; x++) {
            unsigned char *q = px + (size_t)y * rb + x * 4;
            float a = q[3] / 255.0f;
            float l = (a > 0.01f) ? (0.299f * q[0] + 0.587f * q[1] + 0.114f * q[2]) / a : 0.0f;
            lb[y * w + x] = (unsigned char)kb_clamp(l + 0.5f, 0, 255);
        }
    }
    for (y = 0; y < h; y++) {                  // background level per row: the edge columns (no keys reach them)
        float s = 0;
        for (x = 0; x < 2; x++) s += lb[y * w + x] + lb[y * w + w - 1 - x];
        bg[y] = s / 4.0f;
    }
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++) {
            float d = (float)lb[y * w + x] - bg[y];
            if (d > 30.0f) wm[y * w + x] = 1;
            else if (d < -30.0f) dm[y * w + x] = 1;
        }
    kb_fill_holes(wm, w, h, stk);
    kb_fill_holes(dm, w, h, stk);
    kb_erode(wm, cw, tmp, w, h, 2);
    kb_erode(dm, cd, tmp, w, h, 2);
    kb_erode(wm, dw, tmp, w, h, 7);
    kb_erode(dm, dd, tmp, w, h, 7);
    int nw = kb_label(cw, lb, id, stk, w, h, 1, cc);
    for (i = 1; i <= nw; i++) isWhite[i] = 1;
    // dark keys: label into a second id picture so the two sets never merge
    {
        int *idd = id2;
        memset(idd, 0, sizeof(int) * n);
        int nd = kb_label(cd, lb, idd, stk, w, h, nw + 1, cc);
        for (i = 0; i < n; i++) if (idd[i] > 0 && !id[i]) id[i] = idd[i];
        cc->n = nw + nd;
    }
    // grow each key a few pixels to take in its antialiased rim (never into the dark shadow of a light key)
    {
        int pass;
        for (pass = 0; pass < 4; pass++) {
            memcpy(id2, id, sizeof(int) * n);
            for (y = 0; y < h; y++) {
                for (x = 0; x < w; x++) {
                    int p = y * w + x;
                    if (id[p]) continue;
                    int c = 0, dir;
                    for (dir = 0; dir < 4 && !c; dir++) {
                        int nx = x + (dir == 0 ? -1 : (dir == 1 ? 1 : 0));
                        int ny = y + (dir == 2 ? -1 : (dir == 3 ? 1 : 0));
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        c = id[ny * w + nx];
                    }
                    if (!c) continue;
                    float l = (float)lb[p];
                    if (isWhite[c]) {
                        if (l > bg[y] + 6.0f) id2[p] = c;
                    } else {
                        if (l < bg[y] - 6.0f && l > 6.0f) id2[p] = c;
                    }
                }
            }
            memcpy(id, id2, sizeof(int) * n);
        }
    }
    const float bgOut = 0.0f;
    for (y = 0; y < h; y++) {
        for (x = 0; x < w; x++) {
            int p = y * w + x;
            unsigned char *q = px + (size_t)y * rb + x * 4;
            float a = q[3] / 255.0f;
            float v = bgOut;
            int c = id[p];
            if (c) {
                float l = (float)lb[p];
                float base = cc->base[c];
                float span = (float)(cc->maxy[c] - cc->miny[c] + 1);
                float vf = 0.27f - 0.08f * kb_clamp((y - cc->miny[c]) / span, 0, 1);      // gray key, a little lighter at the top
                float cov = 1.0f, t = 0.0f;
                int deep = isWhite[c] ? dw[p] : dd[p];
                if (deep) {
                    float gl = isWhite[c] ? 8.0f : 4.0f;
                    t = (base - l) / (base - gl);                                           // how much of this pixel is the dark legend
                    t = kb_clamp((t - 0.12f) / 0.6f, 0, 1);
                    t = t * t * (3.0f - 2.0f * t);
                } else if (!(isWhite[c] ? cw[p] : cd[p])) {
                    float den = isWhite[c] ? (base - bg[y]) : (bg[y] - base);
                    float num = isWhite[c] ? (l - bg[y]) : (bg[y] - l);
                    cov = (den > 8.0f) ? kb_clamp(num / den, 0, 1) : 1.0f;
                }
                v = bgOut + (vf - bgOut) * cov;
                v = v + (1.0f - v) * t;
            }
            unsigned char g = (unsigned char)(v * a * 255.0f + 0.5f);
            q[0] = g; q[1] = g; q[2] = g;
        }
    }
    free(lb); free(wm); free(dm); free(tmp); free(cw); free(cd); free(dw); free(dd);
    free(id); free(id2); free(stk); free(bg); free(cc); free(isWhite);
    return 1;
}
