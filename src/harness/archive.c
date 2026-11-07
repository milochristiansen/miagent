/* zlib gzip compression for session archives. Decompression is handled by
 * Odin's core:compress/gzip; only compression needs the C library. */
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define MI_GZIP_MAX_OUTPUT (256ull << 20)

int mi_gzip_compress(const void *data, size_t len, unsigned char **out, size_t *outlen) {
    if (out == NULL || outlen == NULL) return -1;
    *out = NULL;
    *outlen = 0;

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        return -1;
    }

    uLong bound = deflateBound(&strm, (uLong)len);
    if (bound == 0) bound = 64;
    unsigned char *buf = (unsigned char *)malloc(bound);
    if (buf == NULL) {
        deflateEnd(&strm);
        return -1;
    }

    strm.next_in = (Bytef *)data;
    strm.avail_in = (uInt)len;
    strm.next_out = buf;
    strm.avail_out = (uInt)bound;

    int rc = deflate(&strm, Z_FINISH);
    if (rc != Z_STREAM_END) {
        free(buf);
        deflateEnd(&strm);
        return -1;
    }
    *outlen = (size_t)strm.total_out;
    *out = buf;
    deflateEnd(&strm);
    return 0;
}

void mi_free(void *p) {
    free(p);
}

int mi_gzip_decompress(const void *data, size_t len, unsigned char **out, size_t *outlen) {
    if (out == NULL || outlen == NULL) return -1;
    *out = NULL;
    *outlen = 0;

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, 15 + 16) != Z_OK) return -1;

    size_t cap = len * 4 + 1024;
    if (cap > MI_GZIP_MAX_OUTPUT) {
        inflateEnd(&strm);
        return -1;
    }
    unsigned char *buf = (unsigned char *)malloc(cap);
    if (buf == NULL) {
        inflateEnd(&strm);
        return -1;
    }

    strm.next_in = (Bytef *)data;
    strm.avail_in = (uInt)len;
    strm.next_out = buf;
    strm.avail_out = (uInt)cap;

    int rc;
    for (;;) {
        rc = inflate(&strm, Z_NO_FLUSH);
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK) {
            free(buf);
            inflateEnd(&strm);
            return -1;
        }
        if (strm.avail_out == 0) {
            size_t used = cap;
            if (cap >= MI_GZIP_MAX_OUTPUT) {
                free(buf);
                inflateEnd(&strm);
                return -1;
            }
            cap *= 2;
            if (cap > MI_GZIP_MAX_OUTPUT) cap = MI_GZIP_MAX_OUTPUT;
            unsigned char *grown = (unsigned char *)realloc(buf, cap);
            if (grown == NULL) {
                free(buf);
                inflateEnd(&strm);
                return -1;
            }
            buf = grown;
            strm.next_out = buf + used;
            strm.avail_out = (uInt)(cap - used);
        } else if (strm.avail_in == 0) {
            /* Truncated stream. */
            free(buf);
            inflateEnd(&strm);
            return -1;
        }
    }

    *outlen = (size_t)strm.total_out;
    *out = buf;
    inflateEnd(&strm);
    return 0;
}
