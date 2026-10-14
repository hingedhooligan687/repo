// DarkSix icon recoloring core: plain C on RGBA bytes.
// Input/output: premultiplied RGBA exactly as a CGBitmapContext hands it out. Alpha is kept.
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "icon_core.h"

static float sstep(float a, float b, float x) {
    if (b == a) return x >= a ? 1.0f : 0.0f;
    float t = (x - a) / (b - a);
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return t * t * (3.0f - 2.0f * t);
}
static float clampf(float x, float a, float b) { return x < a ? a : (x > b ? b : x); }

// the near-black the new background is made of (a touch lighter at the top, like the stock gloss base)
static void ds_black(int y, int h, float *o) {
    float t = (float)y / (float)(h > 1 ? h - 1 : 1);
    float v = 0.075f * (1.0f - t) + 0.012f * t;
    o[0] = v; o[1] = v; o[2] = v * 1.05f;
}

static void ds_lum_sat(const float *c, float *L, float *S) {
    float mx = c[0] > c[1] ? (c[0] > c[2] ? c[0] : c[2]) : (c[1] > c[2] ? c[1] : c[2]);
    float mn = c[0] < c[1] ? (c[0] < c[2] ? c[0] : c[2]) : (c[1] < c[2] ? c[1] : c[2]);
    *L = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2];
    *S = (mx - mn) / (mx + 1e-4f);
}

// per-row average colour of the pixels that are background (weight w small) and opaque; gaps filled from neighbours; smoothed
static void ds_row_color(const float *rgb, const float *w, const unsigned char *skip, int width, int h, float *row, float wmax, int smooth) {
    float *sum = (float *)calloc((size_t)h * 3, sizeof(float));
    int *cnt = (int *)calloc((size_t)h, sizeof(int));
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < width; x++) {
            int i = y * width + x;
            if (w[i] <= wmax && !skip[i]) {
                sum[y * 3] += rgb[i * 3]; sum[y * 3 + 1] += rgb[i * 3 + 1]; sum[y * 3 + 2] += rgb[i * 3 + 2];
                cnt[y]++;
            }
        }
    }
    int minCnt = width / 12 > 3 ? width / 12 : 3;
    for (int y = 0; y < h; y++) {
        if (cnt[y] >= minCnt) {
            row[y * 3] = sum[y * 3] / cnt[y]; row[y * 3 + 1] = sum[y * 3 + 1] / cnt[y]; row[y * 3 + 2] = sum[y * 3 + 2] / cnt[y];
        } else {
            row[y * 3] = -1;
        }
    }
    for (int y = 0; y < h; y++) {
        if (row[y * 3] >= 0) continue;
        int a = y - 1, b = y + 1;
        while (a >= 0 && row[a * 3] < 0) a--;
        while (b < h && row[b * 3] < 0) b++;
        int src = (a >= 0 && (b >= h || y - a <= b - y)) ? a : b;
        if (src >= 0 && src < h && row[src * 3] >= 0) {
            row[y * 3] = row[src * 3]; row[y * 3 + 1] = row[src * 3 + 1]; row[y * 3 + 2] = row[src * 3 + 2];
        } else {
            row[y * 3] = 0.4f; row[y * 3 + 1] = 0.4f; row[y * 3 + 2] = 0.4f;
        }
    }
    float *tmp = (float *)malloc((size_t)h * 3 * sizeof(float));
    int r = smooth ? (h / 40 > 2 ? h / 40 : 2) : 0;
    for (int y = 0; y < h; y++) {
        float s[3] = {0, 0, 0}; int n = 0;
        for (int k = -r; k <= r; k++) {
            int yy = y + k;
            if (yy < 0 || yy >= h) continue;
            s[0] += row[yy * 3]; s[1] += row[yy * 3 + 1]; s[2] += row[yy * 3 + 2]; n++;
        }
        tmp[y * 3] = s[0] / n; tmp[y * 3 + 1] = s[1] / n; tmp[y * 3 + 2] = s[2] / n;
    }
    memcpy(row, tmp, (size_t)h * 3 * sizeof(float));
    free(tmp); free(sum); free(cnt);
}


// distance (in pixels, capped) from each pixel to the nearest transparent / non-opaque pixel
static void ds_edge_dist(const unsigned char *inv, int w, int h, unsigned char *dist) {
    int n = w * h;
    int *q = (int *)malloc((size_t)n * sizeof(int));
    int head = 0, tail = 0;
    for (int i = 0; i < n; i++) {
        if (inv[i]) { dist[i] = 0; q[tail++] = i; }
        else dist[i] = 255;
    }
    // pixels on the picture border count as edge too
    for (int x = 0; x < w; x++) {
        int a = x, b = (h - 1) * w + x;
        if (dist[a] != 0) { dist[a] = 0; q[tail++] = a; }
        if (dist[b] != 0) { dist[b] = 0; q[tail++] = b; }
    }
    for (int y = 0; y < h; y++) {
        int a = y * w, b = y * w + w - 1;
        if (dist[a] != 0) { dist[a] = 0; q[tail++] = a; }
        if (dist[b] != 0) { dist[b] = 0; q[tail++] = b; }
    }
    while (head < tail) {
        int cur = q[head++];
        int cx = cur % w, cy = cur / w;
        int d = dist[cur];
        if (d >= 40) continue;
        int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
        for (int k = 0; k < 4; k++) {
            int j = nb[k];
            if (j < 0 || dist[j] <= d + 1) continue;
            dist[j] = (unsigned char)(d + 1);
            q[tail++] = j;
        }
    }
    free(q);
}

// hue in degrees 0..360 (0 for greys)
static float ds_hue(const float *c) {
    float mx = c[0] > c[1] ? (c[0] > c[2] ? c[0] : c[2]) : (c[1] > c[2] ? c[1] : c[2]);
    float mn = c[0] < c[1] ? (c[0] < c[2] ? c[0] : c[2]) : (c[1] < c[2] ? c[1] : c[2]);
    float d = mx - mn;
    if (d < 1e-4f) return 0.0f;
    float hh;
    if (mx == c[0]) hh = fmodf((c[1] - c[2]) / d, 6.0f);
    else if (mx == c[1]) hh = (c[2] - c[0]) / d + 2.0f;
    else hh = (c[0] - c[1]) / d + 4.0f;
    hh *= 60.0f;
    if (hh < 0) hh += 360.0f;
    return hh;
}

static int cmp_float(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

// mode 1: white shape on a colour -> colour shape on black   (Messages, Phone, Mail ...)
// mode 2: dark shape on a colour  -> colour shape on black   (Music)
static void ds_swap(float *rgb, const unsigned char *inv, int w, int h, int mode, int badge) {
    int n = w * h;
    float *m = (float *)malloc((size_t)n * sizeof(float));
    float *Ls = (float *)malloc((size_t)n * sizeof(float));
    for (int i = 0; i < n; i++) {
        float L, S;
        ds_lum_sat(&rgb[i * 3], &L, &S);
        Ls[i] = L;
    }
    if (mode == 1) {
        for (int i = 0; i < n; i++) {
            float L, S;
            ds_lum_sat(&rgb[i * 3], &L, &S);
            m[i] = sstep(0.62f, 0.88f, L) * (1.0f - sstep(0.10f, 0.28f, S));
        }
    } else {
        // dark shape: judged against how bright the background is on that row (gloss makes it vary)
        float *tmp = (float *)malloc((size_t)w * sizeof(float));
        for (int y = 0; y < h; y++) {
            int c = 0;
            for (int x = 0; x < w; x++) if (!inv[y * w + x]) tmp[c++] = Ls[y * w + x];
            float p = 0.6f;
            if (c > 8) {
                qsort(tmp, (size_t)c, sizeof(float), cmp_float);
                p = tmp[(int)(c * 0.8f)];
            }
            for (int x = 0; x < w; x++) m[y * w + x] = 1.0f - sstep(0.42f * p, 0.62f * p, Ls[y * w + x]);
        }
        free(tmp);
    }

    // glyph cleanup: shapes that reach the icon's edge are gloss lines, glows or clouds, not the symbol -> they go black.
    // Badge icons (iTunes Store, App Store) also lose everything outside the central circle.
    {
        unsigned char *dist = (unsigned char *)malloc((size_t)n);
        unsigned char *lbl = (unsigned char *)calloc((size_t)n, 1);
        int *stk = (int *)malloc((size_t)n * sizeof(int));
        unsigned char *rem = (unsigned char *)calloc((size_t)n, 1);
        if (dist != NULL && lbl != NULL && stk != NULL && rem != NULL) {
            ds_edge_dist(inv, w, h, dist);
            int rim = (int)(w * 0.075f);
            if (rim < 5) rim = 5;
            for (int start = 0; start < n; start++) {
                if (lbl[start] || m[start] <= 0.5f || inv[start]) continue;
                int top = 0, head = 0, minD = 255;
                stk[top++] = start;
                lbl[start] = 1;
                while (head < top) {
                    int cur = stk[head++];
                    if (dist[cur] < minD) minD = dist[cur];
                    int cx = cur % w, cy = cur / w;
                    int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
                    for (int k = 0; k < 4; k++) {
                        int j = nb[k];
                        if (j < 0 || lbl[j] || m[j] <= 0.5f || inv[j]) continue;
                        lbl[j] = 1;
                        stk[top++] = j;
                    }
                }
                if (minD <= rim) {
                    for (int q = 0; q < top; q++) rem[stk[q]] = 1;
                }
            }
            // spread the removal two pixels so the soft fringe of a removed shape goes too
            for (int pass = 0; pass < 2; pass++) {
                unsigned char *nx = (unsigned char *)malloc((size_t)n);
                if (nx == NULL) break;
                memcpy(nx, rem, (size_t)n);
                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        int i = y * w + x;
                        if (rem[i]) continue;
                        if ((x > 0 && rem[i - 1]) || (x < w - 1 && rem[i + 1]) || (y > 0 && rem[i - w]) || (y < h - 1 && rem[i + w])) nx[i] = 1;
                    }
                }
                free(rem);
                rem = nx;
            }
            for (int i = 0; i < n; i++) {
                if (rem[i]) m[i] = 0.0f;
                if (dist[i] <= 2) m[i] = 0.0f;
            }
            if (mode == 2) {
                memset(lbl, 0, (size_t)n);
                int bestStart = -1, bestSize = 0;
                for (int start = 0; start < n; start++) {
                    if (lbl[start] || m[start] <= 0.5f || inv[start]) continue;
                    int top = 0, head = 0;
                    stk[top++] = start; lbl[start] = 1;
                    while (head < top) {
                        int cur = stk[head++];
                        int cx = cur % w, cy = cur / w;
                        int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
                        for (int k = 0; k < 4; k++) {
                            int j = nb[k];
                            if (j < 0 || lbl[j] || m[j] <= 0.5f || inv[j]) continue;
                            lbl[j] = 1; stk[top++] = j;
                        }
                    }
                    if (top > bestSize) { bestSize = top; bestStart = start; }
                }
                if (bestStart >= 0) {
                    // mark the biggest piece (the note) with 2, then drop everything else
                    int top = 0, head = 0;
                    stk[top++] = bestStart; lbl[bestStart] = 2;
                    while (head < top) {
                        int cur = stk[head++];
                        int cx = cur % w, cy = cur / w;
                        int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
                        for (int k = 0; k < 4; k++) {
                            int j = nb[k];
                            if (j < 0 || lbl[j] != 1) continue;
                            lbl[j] = 2; stk[top++] = j;
                        }
                    }
                    // grow the note by 3 px so its soft edge survives, everything farther from it goes
                    for (int y = 0; y < h; y++) {
                        for (int x = 0; x < w; x++) {
                            int i = y * w + x;
                            if (lbl[i] == 2) continue;
                            int near = 0;
                            for (int oy = -3; oy <= 3 && !near; oy++) {
                                int yy = y + oy; if (yy < 0 || yy >= h) continue;
                                for (int ox = -3; ox <= 3; ox++) {
                                    int xx = x + ox; if (xx < 0 || xx >= w) continue;
                                    if (lbl[yy * w + xx] == 2) { near = 1; break; }
                                }
                            }
                            if (!near) m[i] = 0.0f;
                        }
                    }
                }
            }
            if (badge) {
                float cx0 = (w - 1) * 0.5f, cy0 = (h - 1) * 0.5f, R = 0.345f * w;
                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        float dx = x - cx0, dy = y - cy0;
                        float r = sqrtf(dx * dx + dy * dy);
                        m[y * w + x] *= 1.0f - sstep(R - 1.5f, R + 1.0f, r);
                    }
                }
            }
        }
        free(dist); free(lbl); free(stk); free(rem);
    }
    float *row = (float *)malloc((size_t)h * 3 * sizeof(float));
    ds_row_color(rgb, m, inv, w, h, row, 0.04f, (mode == 1 && !badge) ? 0 : 1);
    float *out = (float *)malloc((size_t)n * 3 * sizeof(float));
    for (int y = 0; y < h; y++) {
        float k[3];
        ds_black(y, h, k);
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            float shade;
            if (mode == 1) shade = 0.60f + 0.60f * clampf((Ls[i] - 0.60f) / 0.40f, 0, 1);
            else shade = 0.72f + 0.55f * sstep(0.08f, 0.32f, Ls[i]);
            float mm = inv[i] ? 0.0f : m[i];
            for (int c = 0; c < 3; c++) {
                float g = clampf(row[y * 3 + c] * shade, 0, 1);
                out[i * 3 + c] = mm * g + (1.0f - mm) * k[c];
            }
        }
    }
    memcpy(rgb, out, (size_t)n * 3 * sizeof(float));
    free(m); free(Ls); free(row); free(out);
}

static float cdist(const float *a, const float *b) {
    float d = 0;
    for (int c = 0; c < 3; c++) {
        float dd = fabsf(a[c] - b[c]);
        if (dd > d) d = dd;
    }
    return d;
}

// mode 3: the background that touches the edge goes black, whatever sits on top stays.
// The background is found by growing a region in from the edge across pixels that change smoothly,
// so gradients and the soft gloss highlight do not stop it, but the sharp edge of a shape does.
static void ds_darken_bg(float *rgb, const unsigned char *inv, int w, int h) {
    int n = w * h;
    unsigned char *reached = (unsigned char *)calloc((size_t)n, 1);
    int *stack = (int *)malloc((size_t)n * sizeof(int));
    int top = 0;
    for (int i = 0; i < n; i++) {
        if (inv[i]) { reached[i] = 1; stack[top++] = i; }       // transparent corners count as background
    }
    for (int x = 0; x < w; x++) {
        int a = x, b = (h - 1) * w + x;
        if (!reached[a]) { reached[a] = 1; stack[top++] = a; }
        if (!reached[b]) { reached[b] = 1; stack[top++] = b; }
    }
    for (int y = 0; y < h; y++) {
        int a = y * w, b = y * w + w - 1;
        if (!reached[a]) { reached[a] = 1; stack[top++] = a; }
        if (!reached[b]) { reached[b] = 1; stack[top++] = b; }
    }
    // The border ring itself might hold a rim line; only seed pixels count, spread uses smoothness.
    const float STEP = 0.045f;
    while (top > 0) {
        int cur = stack[--top];
        int cx = cur % w, cy = cur / w;
        int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
        for (int k = 0; k < 4; k++) {
            int j = nb[k];
            if (j < 0 || reached[j]) continue;
            if (!inv[j] && !inv[cur] && cdist(&rgb[cur * 3], &rgb[j * 3]) > STEP) continue;
            if (!inv[j] && inv[cur]) {
                // coming in from a transparent corner: accept the first opaque pixel only if it is not wildly bright/dark
                // (it is the icon's own edge)
            }
            reached[j] = 1;
            stack[top++] = j;
        }
    }
    // soft edge: pixels next to the region that look like a blend of background and shape get partly darkened
    float *al = (float *)malloc((size_t)n * sizeof(float));
    for (int i = 0; i < n; i++) al[i] = reached[i] ? 1.0f : 0.0f;
    for (int pass = 0; pass < 2; pass++) {
        float *next = (float *)malloc((size_t)n * sizeof(float));
        memcpy(next, al, (size_t)n * sizeof(float));
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int i = y * w + x;
                if (al[i] > 0.0f) continue;
                int best = -1;
                if (x > 0 && al[i - 1] > 0.5f) best = i - 1;
                else if (x < w - 1 && al[i + 1] > 0.5f) best = i + 1;
                else if (y > 0 && al[i - w] > 0.5f) best = i - w;
                else if (y < h - 1 && al[i + w] > 0.5f) best = i + w;
                if (best >= 0) {
                    float d = cdist(&rgb[i * 3], &rgb[best * 3]);
                    next[i] = (1.0f - sstep(0.04f, 0.30f, d)) * 0.9f;
                }
            }
        }
        free(al);
        al = next;
    }
    // The pixels right at the edge of a shape are a blend of the old background and the shape. Work out how much of
    // each is in there and rebuild them as shape + black, so no light halo is left around the shape.
    {
        unsigned char *dd = (unsigned char *)malloc((size_t)n);
        int *q = (int *)malloc((size_t)n * sizeof(int));
        float *fix = (float *)malloc((size_t)n * 3 * sizeof(float));
        unsigned char *done = (unsigned char *)calloc((size_t)n, 1);
        if (dd != NULL && q != NULL && fix != NULL && done != NULL) {
            int head = 0, tail = 0;
            for (int i = 0; i < n; i++) {
                if (reached[i] || al[i] > 0.5f) { dd[i] = 0; q[tail++] = i; }
                else dd[i] = 255;
            }
            while (head < tail) {
                int cur = q[head++];
                int d = dd[cur];
                if (d >= 4) continue;
                int cx = cur % w, cy = cur / w;
                int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
                for (int k = 0; k < 4; k++) {
                    int j = nb[k];
                    if (j < 0 || dd[j] <= d + 1) continue;
                    dd[j] = (unsigned char)(d + 1);
                    q[tail++] = j;
                }
            }
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int i = y * w + x;
                    if (dd[i] < 1 || dd[i] > 3 || inv[i]) continue;
                    float B[3] = {0, 0, 0}, S[3] = {0, 0, 0};
                    int nbk = 0, nsk = 0;
                    for (int oy = -4; oy <= 4; oy++) {
                        int yy = y + oy;
                        if (yy < 0 || yy >= h) continue;
                        for (int ox = -4; ox <= 4; ox++) {
                            int xx = x + ox;
                            if (xx < 0 || xx >= w) continue;
                            int j = yy * w + xx;
                            if (inv[j]) continue;
                            if (dd[j] == 0) {
                                for (int c = 0; c < 3; c++) B[c] += rgb[j * 3 + c];
                                nbk++;
                            } else if (dd[j] >= 4) {
                                for (int c = 0; c < 3; c++) S[c] += rgb[j * 3 + c];
                                nsk++;
                            }
                        }
                    }
                    if (nbk < 3 || nsk < 3) continue;
                    float dv[3], pv[3], dot = 0, dn = 0;
                    for (int c = 0; c < 3; c++) {
                        B[c] /= nbk; S[c] /= nsk;
                        dv[c] = S[c] - B[c];
                        pv[c] = rgb[i * 3 + c] - B[c];
                        dot += pv[c] * dv[c];
                        dn += dv[c] * dv[c];
                    }
                    if (dn < 0.012f) continue;
                    float a = clampf(dot / dn, 0.0f, 1.0f);
                    a = a * a * (3.0f - 2.0f * a);                  // slightly crisper edge
                    float k[3];
                    ds_black(y, h, k);
                    for (int c = 0; c < 3; c++) fix[i * 3 + c] = a * S[c] + (1.0f - a) * k[c];
                    done[i] = 1;
                }
            }
        }
        for (int y = 0; y < h; y++) {
            float k[3];
            ds_black(y, h, k);
            for (int x = 0; x < w; x++) {
                int i = y * w + x;
                if (done != NULL && done[i]) {
                    for (int c = 0; c < 3; c++) rgb[i * 3 + c] = fix[i * 3 + c];
                    continue;
                }
                for (int c = 0; c < 3; c++) rgb[i * 3 + c] = rgb[i * 3 + c] * (1.0f - al[i]) + k[c] * al[i];
            }
        }
        if (dd != NULL) free(dd);
        if (q != NULL) free(q);
        if (fix != NULL) free(fix);
        if (done != NULL) free(done);
    }
    free(reached); free(stack); free(al);
}

// mode 6: wooden background -> black (Compass). Wood = brown/tan pixels connected to the icon's edge.
static int ds_is_wood(const float *c) {
    float L, S;
    ds_lum_sat(c, &L, &S);
    float hh = ds_hue(c);
    return (S > 0.16f && hh >= 8.0f && hh <= 58.0f && L > 0.08f && L < 0.92f);
}

static void ds_wood(float *rgb, const unsigned char *inv, int w, int h) {
    int n = w * h;
    unsigned char *reached = (unsigned char *)calloc((size_t)n, 1);
    int *stack = (int *)malloc((size_t)n * sizeof(int));
    int top = 0;
    for (int i = 0; i < n; i++) {
        int x = i % w, y = i / w;
        int edge = (x < 3 || y < 3 || x >= w - 3 || y >= h - 3);
        if (!inv[i] && edge && ds_is_wood(&rgb[i * 3])) { reached[i] = 1; stack[top++] = i; }
    }
    while (top > 0) {
        int cur = stack[--top];
        int cx = cur % w, cy = cur / w;
        int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
        for (int k = 0; k < 4; k++) {
            int j = nb[k];
            if (j < 0 || reached[j] || inv[j]) continue;
            if (!ds_is_wood(&rgb[j * 3])) continue;
            reached[j] = 1;
            stack[top++] = j;
        }
    }
    float *al = (float *)malloc((size_t)n * sizeof(float));
    for (int i = 0; i < n; i++) al[i] = reached[i] ? 1.0f : 0.0f;
    // soften by two pixels so no brown fringe stays
    for (int pass = 0; pass < 2; pass++) {
        float *nx = (float *)malloc((size_t)n * sizeof(float));
        memcpy(nx, al, (size_t)n * sizeof(float));
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int i = y * w + x;
                if (al[i] > 0.0f || inv[i]) continue;
                int nbr = (x > 0 && al[i - 1] > 0.5f) || (x < w - 1 && al[i + 1] > 0.5f) || (y > 0 && al[i - w] > 0.5f) || (y < h - 1 && al[i + w] > 0.5f);
                if (!nbr) continue;
                float L, S;
                ds_lum_sat(&rgb[i * 3], &L, &S);
                float hh = ds_hue(&rgb[i * 3]);
                float woodish = (hh >= 5.0f && hh <= 65.0f) ? sstep(0.08f, 0.30f, S) : 0.0f;
                nx[i] = woodish * 0.95f;
            }
        }
        free(al);
        al = nx;
    }
    for (int y = 0; y < h; y++) {
        float k[3];
        ds_black(y, h, k);
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            for (int c = 0; c < 3; c++) rgb[i * 3 + c] = rgb[i * 3 + c] * (1.0f - al[i]) + k[c] * al[i];
        }
    }
    free(reached); free(stack); free(al);
}

// mode 7: Weather. Background and edges black; only the sun (warm colours) and the temperature (white) stay.
static void ds_weather(float *rgb, const unsigned char *inv, int w, int h) {
    int n = w * h;
    float *orig = (float *)malloc((size_t)n * 3 * sizeof(float));
    unsigned char *warm = (unsigned char *)calloc((size_t)n, 1);
    unsigned char *tmp = (unsigned char *)calloc((size_t)n, 1);
    unsigned char *outside = (unsigned char *)calloc((size_t)n, 1);
    int *stk = (int *)malloc((size_t)n * sizeof(int));
    float *keepA = (float *)calloc((size_t)n, sizeof(float));
    if (!orig || !warm || !tmp || !outside || !stk || !keepA) { free(orig); free(warm); free(tmp); free(outside); free(stk); free(keepA); return; }
    memcpy(orig, rgb, (size_t)n * 3 * sizeof(float));
    ds_darken_bg(rgb, inv, w, h);
    int top0 = (int)(0.02f * h), bot0 = (int)(0.68f * h);
    for (int i = 0; i < n; i++) {
        int y = i / w;
        float L, S;
        ds_lum_sat(&orig[i * 3], &L, &S);
        float hh = ds_hue(&orig[i * 3]);
        if (!inv[i] && y >= top0 && y <= bot0 && S > 0.20f && hh >= 6.0f && hh <= 72.0f && L > 0.20f) warm[i] = 1;
    }
    // close small gaps (3 px) so the sun's dark crescent counts as part of the sun
    int R = 3;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int hit = 0;
        for (int oy = -R; oy <= R && !hit; oy++) { int yy = y + oy; if (yy < 0 || yy >= h) continue;
            for (int ox = -R; ox <= R; ox++) { int xx = x + ox; if (xx < 0 || xx >= w) continue; if (warm[yy * w + xx]) { hit = 1; break; } } }
        tmp[y * w + x] = (unsigned char)hit;
    }
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int all = 1;
        for (int oy = -R; oy <= R && all; oy++) { int yy = y + oy; if (yy < 0 || yy >= h) { continue; }
            for (int ox = -R; ox <= R; ox++) { int xx = x + ox; if (xx < 0 || xx >= w) continue; if (!tmp[yy * w + xx]) { all = 0; break; } } }
        warm[y * w + x] = (unsigned char)(all || warm[y * w + x]);
    }
    // fill holes: whatever the outside cannot reach is inside the sun
    int top = 0;
    for (int i = 0; i < n; i++) {
        int x = i % w, y = i / w;
        if ((x == 0 || y == 0 || x == w - 1 || y == h - 1) && !warm[i]) { outside[i] = 1; stk[top++] = i; }
    }
    while (top > 0) {
        int cur = stk[--top];
        int cx = cur % w, cy = cur / w;
        int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
        for (int k = 0; k < 4; k++) { int j = nb[k]; if (j < 0 || outside[j] || warm[j]) continue; outside[j] = 1; stk[top++] = j; }
    }
    for (int i = 0; i < n; i++) keepA[i] = (!outside[i] && (warm[i] || 1)) ? 1.0f : 0.0f;
    // only the part of the filled area that lies in the sun's zone
    for (int i = 0; i < n; i++) { int y = i / w; if (y < top0 || y > bot0) keepA[i] = 0.0f; }
    // soften the edge by a 3x3 average
    float *sm = (float *)malloc((size_t)n * sizeof(float));
    if (sm) {
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            float sacc = 0; int c = 0;
            for (int oy = -1; oy <= 1; oy++) { int yy = y + oy; if (yy < 0 || yy >= h) continue;
                for (int ox = -1; ox <= 1; ox++) { int xx = x + ox; if (xx < 0 || xx >= w) continue; sacc += keepA[yy * w + xx]; c++; } }
            sm[y * w + x] = sacc / c;
        }
        memcpy(keepA, sm, (size_t)n * sizeof(float)); free(sm);
    }
    for (int y = 0; y < h; y++) {
        float k[3];
        ds_black(y, h, k);
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            const float *o = &orig[i * 3];
            float col[3] = { o[0], o[1], o[2] };
            float sunA = keepA[i];
            if (sunA > 0.0f && !warm[i]) {
                // a hole inside the sun: take the colour from the nearest sun pixel below (or above) it
                int found = 0;
                for (int d = 1; d < 30 && !found; d++) {
                    if (y + d < h && warm[(y + d) * w + x]) { for (int c = 0; c < 3; c++) col[c] = orig[((y + d) * w + x) * 3 + c]; found = 1; }
                    else if (y - d >= 0 && warm[(y - d) * w + x]) { for (int c = 0; c < 3; c++) col[c] = orig[((y - d) * w + x) * 3 + c]; found = 1; }
                }
            }
            float L, S;
            ds_lum_sat(o, &L, &S);
            float bluish = clampf((o[2] - o[0]) / 0.10f, 0.0f, 1.0f);
            float white = sstep(0.70f, 0.92f, L) * (1.0f - sstep(0.10f, 0.26f, S)) * (1.0f - 0.5f * bluish);
            float lowZone = sstep(0.70f * h, 0.74f * h, (float)y) * (1.0f - sstep(0.88f * h, 0.95f * h, (float)y));
            white *= lowZone;
            for (int c = 0; c < 3; c++) {
                float v;
                if (sunA >= white) v = col[c] * sunA + k[c] * (1.0f - sunA);
                else v = L * white + k[c] * (1.0f - white);
                rgb[i * 3 + c] = v;
            }
        }
    }
    free(orig); free(warm); free(tmp); free(outside); free(stk); free(keepA);
}

// mode 8: Settings. Keep the silver frame and the gears; the dotted metal behind them goes much darker.
static void ds_settings(float *rgb, const unsigned char *inv, int w, int h) {
    int n = w * h;
    unsigned char *dist = (unsigned char *)malloc((size_t)n);
    float *Ls = (float *)malloc((size_t)n * sizeof(float));
    float *wt = (float *)malloc((size_t)n * sizeof(float));
    float *wt2 = (float *)malloc((size_t)n * sizeof(float));
    if (dist == NULL || Ls == NULL || wt == NULL || wt2 == NULL) { free(dist); free(Ls); free(wt); free(wt2); return; }
    ds_edge_dist(inv, w, h, dist);
    for (int i = 0; i < n; i++) {
        float L, S;
        ds_lum_sat(&rgb[i * 3], &L, &S);
        Ls[i] = L;
    }
    int frame = (int)(w * 0.085f);
    if (frame < 4) frame = 4;
    // texture strength: the dots make the brightness jump around over a few pixels, the gears are smooth
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            float sum = 0, sum2 = 0; int cnt = 0;
            for (int oy = -2; oy <= 2; oy++) {
                int yy = y + oy;
                if (yy < 0 || yy >= h) continue;
                for (int ox = -2; ox <= 2; ox++) {
                    int xx = x + ox;
                    if (xx < 0 || xx >= w) continue;
                    float v = Ls[yy * w + xx];
                    sum += v; sum2 += v * v; cnt++;
                }
            }
            float mean = sum / cnt;
            float var = sum2 / cnt - mean * mean;
            if (var < 0) var = 0;
            float sd = sqrtf(var);
            float t = sstep(0.045f, 0.095f, sd);
            // dark bits count even when flat
            float dk = 1.0f - sstep(0.30f, 0.42f, mean);
            wt[i] = t > dk ? t : dk;
        }
    }
    // smooth the pattern weight so the result is an even dark panel, not blotches
    for (int pass = 0; pass < 2; pass++) {
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            float sacc = 0; int c = 0;
            for (int oy = -1; oy <= 1; oy++) { int yy = y + oy; if (yy < 0 || yy >= h) continue;
                for (int ox = -1; ox <= 1; ox++) { int xx = x + ox; if (xx < 0 || xx >= w) continue; sacc += wt[yy * w + xx]; c++; } }
            wt2[y * w + x] = sacc / c;
        }
        memcpy(wt, wt2, (size_t)n * sizeof(float));
    }
    // spread the pattern area by one pixel so the rims of the dots go dark too
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            float m = wt[i];
            if (x > 0 && wt[i - 1] > m) m = wt[i - 1];
            if (x < w - 1 && wt[i + 1] > m) m = wt[i + 1];
            if (y > 0 && wt[i - w] > m) m = wt[i - w];
            if (y < h - 1 && wt[i + w] > m) m = wt[i + w];
            wt2[i] = m;
        }
    }
    for (int i = 0; i < n; i++) {
        if (inv[i] || dist[i] <= frame) continue;                        // the silver frame stays as it is
        float edgeFade = sstep((float)frame, (float)frame + 3.0f, (float)dist[i]);
        float f = 1.0f - 0.86f * wt2[i] * edgeFade;
        // bright gear surfaces are protected
        float prot = sstep(0.60f, 0.78f, Ls[i]);
        f = f * (1.0f - prot) + 1.0f * prot;
        for (int c = 0; c < 3; c++) rgb[i * 3 + c] *= f;
    }
    free(dist); free(Ls); free(wt); free(wt2);
}

// mode 4: paper-like icons: light neutral areas go dark and dark ink goes light, colours stay
static void ds_invert_neutral(float *rgb, int w, int h) {
    for (int i = 0; i < w * h; i++) {
        float L, S;
        ds_lum_sat(&rgb[i * 3], &L, &S);
        float n = 1.0f - sstep(0.30f, 0.50f, S);
        float want = (1.0f - L) * 0.80f + 0.05f;
        float f = want / (L > 0.06f ? L : 0.06f);
        for (int c = 0; c < 3; c++) {
            float v = clampf(rgb[i * 3 + c] * f, 0, 1);
            rgb[i * 3 + c] = rgb[i * 3 + c] * (1.0f - n) + v * n;
        }
    }
}

// mode 5: just darker
static void ds_dim(float *rgb, int w, int h) {
    for (int i = 0; i < w * h; i++) {
        for (int c = 0; c < 3; c++) rgb[i * 3 + c] *= 0.52f;
    }
}

void ds_process(unsigned char *rgba, int w, int h, int mode) {
    if (rgba == NULL || w < 8 || h < 8 || w > 1024 || h > 1024) return;
    int n = w * h;
    float *rgb = (float *)malloc((size_t)n * 3 * sizeof(float));
    unsigned char *inv = (unsigned char *)calloc((size_t)n, 1);
    unsigned char *alpha = (unsigned char *)malloc((size_t)n);
    if (rgb == NULL || inv == NULL || alpha == NULL) { free(rgb); free(inv); free(alpha); return; }
    for (int i = 0; i < n; i++) {
        float a = rgba[i * 4 + 3] / 255.0f;
        alpha[i] = rgba[i * 4 + 3];
        if (a < 0.96f) inv[i] = 1;
        for (int c = 0; c < 3; c++) {
            float v = rgba[i * 4 + c] / 255.0f;
            rgb[i * 3 + c] = (a > 0.01f) ? clampf(v / a, 0, 1) : 0.0f;
        }
    }
    switch (mode) {
        case 1: case 2: ds_swap(rgb, inv, w, h, mode, 0); break;
        case 11: ds_swap(rgb, inv, w, h, 1, 1); break;
        case 3: ds_darken_bg(rgb, inv, w, h); break;
        case 6: ds_wood(rgb, inv, w, h); break;
        case 7: ds_weather(rgb, inv, w, h); break;
        case 8: ds_settings(rgb, inv, w, h); break;
        case 4: ds_invert_neutral(rgb, w, h); break;
        case 5: ds_dim(rgb, w, h); break;
        default: break;
    }
    for (int i = 0; i < n; i++) {
        float a = alpha[i] / 255.0f;
        for (int c = 0; c < 3; c++) {
            float v = clampf(rgb[i * 3 + c], 0, 1) * a;
            rgba[i * 4 + c] = (unsigned char)(v * 255.0f + 0.5f);
        }
        rgba[i * 4 + 3] = alpha[i];
    }
    free(rgb); free(inv); free(alpha);
}
