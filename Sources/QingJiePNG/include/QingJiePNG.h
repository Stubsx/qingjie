#include <stdint.h>
#include <stddef.h>

typedef struct QJPNG QJPNG;
QJPNG *qj_png_open(const char *path, uint32_t width, uint32_t height);
// Input is top-to-bottom, premultiplied RGBA. Memory usage is bounded by one row.
int qj_png_rows(QJPNG *png, const uint8_t *pixels, size_t stride, uint32_t count);
int qj_png_finish(QJPNG *png);
void qj_png_destroy(QJPNG *png);
