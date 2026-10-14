#ifndef DS_KB_CORE_H
#define DS_KB_CORE_H
#ifdef __cplusplus
extern "C" {
#endif
// Recolors a full keyboard picture in place (premultiplied RGBA). Returns 1 on success.
int ds_kb_sheet(unsigned char *px, int w, int h, int rb);
#ifdef __cplusplus
}
#endif
#endif
