// Image decoding and HTTP fetching for Markdown images. stb_image is vendored
// beside this file (public domain) so the desktop app does not gain a runtime
// dependency on libpng/libjpeg. Decoding is serialized because stb_image keeps
// a small amount of global failure state.
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define STBI_MAX_DIMENSIONS 8192
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

static pthread_mutex_t mi_image_decode_mu = PTHREAD_MUTEX_INITIALIZER;

// Decode any supported image into tightly packed RGBA. The caller frees the
// returned buffer with mi_image_free.
void *mi_image_decode(const void *data, int len, int *w, int *h) {
    if (data == NULL || len <= 0 || w == NULL || h == NULL) return NULL;
    pthread_mutex_lock(&mi_image_decode_mu);
    int channels = 0;
    unsigned char *pixels = stbi_load_from_memory(
        (const stbi_uc *)data, len, w, h, &channels, 4);
    pthread_mutex_unlock(&mi_image_decode_mu);
    return pixels;
}

void mi_image_free(void *pixels) {
    if (pixels != NULL) stbi_image_free(pixels);
}

// --- remote images ---------------------------------------------------------

typedef struct {
    unsigned char *data;
    size_t len;
    size_t cap;
    size_t max;
    int failed;
} mi_image_buffer;

static size_t mi_image_write_cb(char *ptr, size_t size, size_t nmemb, void *ud) {
    mi_image_buffer *buf = (mi_image_buffer *)ud;
    size_t n = size * nmemb;
    if (buf->failed) return 0;
    if (n > buf->max - buf->len) {
        buf->failed = 1;
        return 0;
    }
    if (buf->len + n > buf->cap) {
        size_t cap = buf->cap > 0 ? buf->cap : 65536;
        while (cap < buf->len + n) cap *= 2;
        if (cap > buf->max) cap = buf->max;
        unsigned char *next = (unsigned char *)realloc(buf->data, cap);
        if (next == NULL) {
            buf->failed = 1;
            return 0;
        }
        buf->data = next;
        buf->cap = cap;
    }
    memcpy(buf->data + buf->len, ptr, n);
    buf->len += n;
    return n;
}

static pthread_once_t mi_image_curl_once = PTHREAD_ONCE_INIT;
static void mi_image_curl_init(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

// Download a URL into a malloc'd buffer. Returns NULL on failure; the caller
// frees successful buffers with mi_image_buf_free.
unsigned char *mi_image_http_get(const char *url, size_t max, size_t *out_len) {
    if (url == NULL || url[0] == 0 || max == 0 || out_len == NULL) return NULL;
    *out_len = 0;
    pthread_once(&mi_image_curl_once, mi_image_curl_init);

    CURL *curl = curl_easy_init();
    if (curl == NULL) return NULL;

    mi_image_buffer buf;
    memset(&buf, 0, sizeof(buf));
    buf.max = max;

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 6L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 20L);
    curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)max);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "MiAgent/1.0");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, mi_image_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);

    CURLcode res = curl_easy_perform(curl);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK || buf.failed || buf.len == 0) {
        free(buf.data);
        return NULL;
    }
    *out_len = buf.len;
    return buf.data;
}

void mi_image_buf_free(void *p) { free(p); }
