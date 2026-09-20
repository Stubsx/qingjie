#include "QingJiePNG.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

struct QJPNG {
    FILE *file;
    z_stream stream;
    uint32_t width, height, rows;
    uint8_t *row, *previous, *filtered;
    int initialized, failed;
};

static void be32(uint8_t *p, uint32_t n) {
    p[0] = n >> 24; p[1] = n >> 16; p[2] = n >> 8; p[3] = n;
}
static int chunk(QJPNG *p, const char *type, const uint8_t *data, uint32_t size) {
    uint8_t header[8], checksum[4];
    be32(header, size); memcpy(header + 4, type, 4);
    uLong crc = crc32(0, (const Bytef *)type, 4);
    if (size) crc = crc32(crc, data, size);
    be32(checksum, (uint32_t)crc);
    if (fwrite(header, 1, 8, p->file) != 8 ||
        (size && fwrite(data, 1, size, p->file) != size) ||
        fwrite(checksum, 1, 4, p->file) != 4) { p->failed = 1; return 0; }
    return 1;
}
static int compress_bytes(QJPNG *p, const uint8_t *data, uInt size, int flush) {
    uint8_t output[65536];
    p->stream.next_in = (Bytef *)data; p->stream.avail_in = size;
    int result;
    do {
        p->stream.next_out = output; p->stream.avail_out = sizeof(output);
        result = deflate(&p->stream, flush);
        if (result != Z_OK && result != Z_STREAM_END) { p->failed = 1; return 0; }
        uint32_t count = sizeof(output) - p->stream.avail_out;
        if (count && !chunk(p, "IDAT", output, count)) return 0;
    } while (p->stream.avail_in || !p->stream.avail_out || (flush == Z_FINISH && result != Z_STREAM_END));
    return 1;
}
QJPNG *qj_png_open(const char *path, uint32_t width, uint32_t height) {
    if (!width || !height || width > 0x1fffffff || height > 0x7fffffff) return NULL;
    QJPNG *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->width = width; p->height = height;
    size_t bytes = (size_t)width * 4;
    p->row = malloc(bytes); p->previous = calloc(1, bytes); p->filtered = malloc(bytes + 1);
    p->file = fopen(path, "wb");
    if (!p->row || !p->previous || !p->filtered || !p->file) goto fail;
    if (deflateInit(&p->stream, Z_DEFAULT_COMPRESSION) != Z_OK) goto fail;
    p->initialized = 1;
    const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (fwrite(signature, 1, 8, p->file) != 8) goto fail;
    uint8_t header[13] = {0};
    be32(header, width); be32(header + 4, height); header[8] = 8; header[9] = 6;
    const uint8_t intent = 0;
    if (!chunk(p, "IHDR", header, 13) || !chunk(p, "sRGB", &intent, 1)) goto fail;
    return p;
fail:
    qj_png_destroy(p); return NULL;
}
int qj_png_rows(QJPNG *p, const uint8_t *pixels, size_t stride, uint32_t count) {
    if (!p || p->failed || !pixels || count > p->height - p->rows || stride < (size_t)p->width * 4) return 0;
    size_t bytes = (size_t)p->width * 4;
    for (uint32_t y = 0; y < count; y++) {
        const uint8_t *source = pixels + y * stride;
        for (size_t i = 0; i < bytes; i += 4) {
            unsigned alpha = source[i + 3];
            for (int c = 0; c < 3; c++) {
                unsigned value = alpha ? (source[i + c] * 255u + alpha / 2) / alpha : 0;
                p->row[i + c] = value > 255 ? 255 : value;
            }
            p->row[i + 3] = alpha;
        }
        // Choose Sub or Up per row; text and flat backgrounds compress well with either.
        uint64_t sub = 0, up = 0;
        for (size_t i = 0; i < bytes; i++) {
            sub += abs((int)(int8_t)(p->row[i] - (i >= 4 ? p->row[i - 4] : 0)));
            up += abs((int)(int8_t)(p->row[i] - p->previous[i]));
        }
        int useUp = up < sub; p->filtered[0] = useUp ? 2 : 1;
        for (size_t i = 0; i < bytes; i++)
            p->filtered[i + 1] = p->row[i] - (useUp ? p->previous[i] : (i >= 4 ? p->row[i - 4] : 0));
        if (!compress_bytes(p, p->filtered, (uInt)(bytes + 1), Z_NO_FLUSH)) return 0;
        memcpy(p->previous, p->row, bytes); p->rows++;
    }
    return 1;
}
int qj_png_finish(QJPNG *p) {
    if (!p || p->failed || p->rows != p->height) return 0;
    if (!compress_bytes(p, NULL, 0, Z_FINISH) || !chunk(p, "IEND", NULL, 0)) return 0;
    if (fflush(p->file) != 0) { p->failed = 1; return 0; }
    return 1;
}
void qj_png_destroy(QJPNG *p) {
    if (!p) return;
    if (p->initialized) deflateEnd(&p->stream);
    if (p->file) fclose(p->file);
    free(p->row); free(p->previous); free(p->filtered); free(p);
}
