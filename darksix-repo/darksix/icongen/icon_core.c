// DarkSix icon recoloring core: plain C, works on RGBA bytes (alpha ignored, icons are opaque).
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

// the near-black the new background is made of (slightly lighter at the top, like the stock gloss base)
static void ds_black(int y, int h, float *o) {
    float t = (float)y / (float)(h > 1 ? h - 1 : 1);
    float v = 0.075f * (1.0f - t) + 0.012f * t;
    o[0] = v; o[1] = v; o[2] = v * 1.05f;
}

// per-row average colour of the pixels where weight (1 - w) is high; rows without any are filled from neighbours; smoothed
static void ds_row_color(const float *rgb, const float *w, int width, int h, float *row, float wmax) {
    float *sum = (float *)calloc((size_t)h * 3, sizeof(float));
    int *cnt = (int *)calloc((size_t)h, sizeof(int));
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < width; x++) {
            int i = y * width + x;
            if (w[i] <= wmax) {
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
    // fill gaps from the nearest valid row above/below
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
    // vertical smoothing
    float *tmp = (float *)malloc((size_t)h * 3 * sizeof(float));
    int r = h / 40 > 2 ? h / 40 : 2;
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

static void ds_lum_sat(const float *c, float *L, float *S) {
    float mx = c[0] > c[1] ? (c[0] > c[2] ? c[0] : c[2]) : (c[1] > c[2] ? c[1] : c[2]);
    float mn = c[0] < c[1] ? (c[0] < c[2] ? c[0] : c[2]) : (c[1] < c[2] ? c[1] : c[2]);
    *L = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2];
    *S = (mx - mn) / (mx + 1e-4f);
}

// mode 1: white shape on a colour  -> colour shape on black   (Messages, Phone, Mail ...)
// mode 2: dark shape on a colour   -> colour shape on black   (Music)
static void ds_swap(float *rgb, int w, int h, int mode) {
    int n = w * h;
    float *m = (float *)malloc((size_t)n * sizeof(float));
    float *Ls = (float *)malloc((size_t)n * sizeof(float));
    for (int i = 0; i < n; i++) {
        float L, S;
        ds_lum_sat(&rgb[i * 3], &L, &S);
        Ls[i] = L;
        if (mode == 1) {
            m[i] = sstep(0.58f, 0.88f, L) * (1.0f - sstep(0.12f, 0.34f, S));
        } else {
            m[i] = 1.0f - sstep(0.20f, 0.32f, L);
        }
    }
    float *row = (float *)malloc((size_t)h * 3 * sizeof(float));
    ds_row_color(rgb, m, w, h, row, 0.04f);
    float *out = (float *)malloc((size_t)n * 3 * sizeof(float));
    for (int y = 0; y < h; y++) {
        float k[3];
        ds_black(y, h, k);
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            float shade;
            if (mode == 1) {
                shade = 0.60f + 0.60f * clampf((Ls[i] - 0.60f) / 0.40f, 0, 1);
            } else {
                shade = 0.72f + 0.55f * sstep(0.08f, 0.32f, Ls[i]);
            }
            for (int c = 0; c < 3; c++) {
                float g = clampf(row[y * 3 + c] * shade, 0, 1);
                out[i * 3 + c] = m[i] * g + (1.0f - m[i]) * k[c];
            }
        }
    }
    memcpy(rgb, out, (size_t)n * 3 * sizeof(float));
    free(m); free(Ls); free(row); free(out);
}

// mode 3: the plain background that touches the edge goes black, whatever sits on top stays as it is
static void ds_darken_bg(float *rgb, int w, int h) {
    int n = w * h;
    float *row = (float *)malloc((size_t)h * 3 * sizeof(float));
    int e = w / 16 > 3 ? w / 16 : 3;
    for (int y = 0; y < h; y++) {
        float s[3] = {0, 0, 0};
        for (int k = 0; k < e; k++) {
            for (int c = 0; c < 3; c++) {
                s[c] += rgb[(y * w + k) * 3 + c] + rgb[(y * w + (w - 1 - k)) * 3 + c];
            }
        }
        for (int c = 0; c < 3; c++) row[y * 3 + c] = s[c] / (2.0f * e);
    }
    float *bgn = (float *)malloc((size_t)n * sizeof(float));
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            float d = 0;
            for (int c = 0; c < 3; c++) {
                float dd = fabsf(rgb[i * 3 + c] - row[y * 3 + c]);
                if (dd > d) d = dd;
            }
            bgn[i] = 1.0f - sstep(0.07f, 0.17f, d);
        }
    }
    // flood fill from the border through plain-background pixels
    unsigned char *reached = (unsigned char *)calloc((size_t)n, 1);
    int *stack = (int *)malloc((size_t)n * sizeof(int));
    int top = 0;
    for (int x = 0; x < w; x++) {
        int a = x, b = (h - 1) * w + x;
        if (bgn[a] > 0.5f && !reached[a]) { reached[a] = 1; stack[top++] = a; }
        if (bgn[b] > 0.5f && !reached[b]) { reached[b] = 1; stack[top++] = b; }
    }
    for (int y = 0; y < h; y++) {
        int a = y * w, b = y * w + w - 1;
        if (bgn[a] > 0.5f && !reached[a]) { reached[a] = 1; stack[top++] = a; }
        if (bgn[b] > 0.5f && !reached[b]) { reached[b] = 1; stack[top++] = b; }
    }
    while (top > 0) {
        int cur = stack[--top];
        int cx = cur % w, cy = cur / w;
        int nb[4] = { cx > 0 ? cur - 1 : -1, cx < w - 1 ? cur + 1 : -1, cy > 0 ? cur - w : -1, cy < h - 1 ? cur + w : -1 };
        for (int k = 0; k < 4; k++) {
            int j = nb[k];
            if (j < 0 || reached[j] || bgn[j] <= 0.5f) continue;
            reached[j] = 1;
            stack[top++] = j;
        }
    }
    // soft mask: reached pixels, plus a one pixel feather into neighbours
    float *a = (float *)calloc((size_t)n, sizeof(float));
    for (int i = 0; i < n; i++) if (reached[i]) a[i] = bgn[i];
    for (int y = 0; y < h; y++) {
        float k[3];
        ds_black(y, h, k);
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            float al = a[i];
            if (al < 0.999f) {
                float best = al;
                if (x > 0 && reached[i - 1]) best = fmaxf(best, 0.35f * bgn[i]);
                if (x < w - 1 && reached[i + 1]) best = fmaxf(best, 0.35f * bgn[i]);
                if (y > 0 && reached[i - w]) best = fmaxf(best, 0.35f * bgn[i]);
                if (y < h - 1 && reached[i + w]) best = fmaxf(best, 0.35f * bgn[i]);
                al = best;
            }
            for (int c = 0; c < 3; c++) rgb[i * 3 + c] = rgb[i * 3 + c] * (1.0f - al) + k[c] * al;
        }
    }
    free(row); free(bgn); free(reached); free(stack); free(a);
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
    if (rgb == NULL) return;
    for (int i = 0; i < n; i++) {
        rgb[i * 3] = rgba[i * 4] / 255.0f; rgb[i * 3 + 1] = rgba[i * 4 + 1] / 255.0f; rgb[i * 3 + 2] = rgba[i * 4 + 2] / 255.0f;
    }
    switch (mode) {
        case 1: case 2: ds_swap(rgb, w, h, mode); break;
        case 3: ds_darken_bg(rgb, w, h); break;
        case 4: ds_invert_neutral(rgb, w, h); break;
        case 5: ds_dim(rgb, w, h); break;
        default: break;
    }
    for (int i = 0; i < n; i++) {
        for (int c = 0; c < 3; c++) {
            float v = clampf(rgb[i * 3 + c], 0, 1);
            rgba[i * 4 + c] = (unsigned char)(v * 255.0f + 0.5f);
        }
        rgba[i * 4 + 3] = 255;
    }
    free(rgb);
}
