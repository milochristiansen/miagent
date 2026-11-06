#include <stdlib.h>
/* Small libcurl shim for streaming Server-Sent Events. The Odin harness wants
 * the HTTP body delivered chunk by chunk as it arrives; binding libcurl's
 * variadic setopt from Odin is unnecessarily fragile, so this one function
 * does it in C. */
#include <curl/curl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef size_t (*mi_http_write_fn)(void *userdata, const char *data, size_t len);

typedef struct {
    mi_http_write_fn fn;
    void *userdata;
    long status;
    char *errbuf;
    size_t errcap;
    size_t errlen;
    int aborted;
    volatile int *cancel;
} mi_http_ctx;

static int mi_http_progress_cb(void *ud, curl_off_t dltotal, curl_off_t dlnow,
                               curl_off_t ultotal, curl_off_t ulnow) {
    (void)dltotal; (void)dlnow; (void)ultotal; (void)ulnow;
    mi_http_ctx *ctx = (mi_http_ctx *)ud;
    return (ctx->cancel != NULL && *ctx->cancel) ? 1 : 0;
}

static size_t mi_http_header_cb(char *buf, size_t size, size_t nmemb, void *ud) {
    mi_http_ctx *ctx = (mi_http_ctx *)ud;
    size_t len = size * nmemb;
    /* A status line looks like "HTTP/1.1 200 OK". Interim 1xx responses are
     * followed by another status line; the last one wins. */
    if (len >= 5 && strncmp(buf, "HTTP/", 5) == 0) {
        const char *p = buf;
        while (p < buf + len && *p != ' ') p++;
        if (p < buf + len) {
            ctx->status = strtol(p + 1, NULL, 10);
        }
    }
    return len;
}

static int mi_http_append_err(mi_http_ctx *ctx, const char *data, size_t len) {
    if (ctx->errcap == 0 || ctx->errlen + 1 >= ctx->errcap) return 0;
    size_t room = ctx->errcap - ctx->errlen - 1;
    if (len > room) len = room;
    memcpy(ctx->errbuf + ctx->errlen, data, len);
    ctx->errlen += len;
    ctx->errbuf[ctx->errlen] = 0;
    return 1;
}

static size_t mi_http_write_cb(char *buf, size_t size, size_t nmemb, void *ud) {
    mi_http_ctx *ctx = (mi_http_ctx *)ud;
    size_t len = size * nmemb;
    if (ctx->status >= 400 || ctx->status == 0) {
        mi_http_append_err(ctx, buf, len);
        return len;
    }
    size_t n = ctx->fn ? ctx->fn(ctx->userdata, buf, len) : len;
    if (n != len) {
        ctx->aborted = 1;
        return 0;
    }
    return len;
}

static pthread_once_t mi_curl_once = PTHREAD_ONCE_INIT;

static void mi_curl_global_init(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

int mi_http_post_stream(const char *url, const char *api_key, const char *body,
                        size_t body_len, const char *accept,
                        mi_http_write_fn fn, void *userdata,
                        char *errbuf, size_t errcap, volatile int *cancel) {
    pthread_once(&mi_curl_once, mi_curl_global_init);

    mi_http_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.fn = fn;
    ctx.userdata = userdata;
    ctx.errbuf = errbuf;
    ctx.errcap = errcap;
    ctx.cancel = cancel;
    if (errcap > 0) errbuf[0] = 0;

    CURL *curl = curl_easy_init();
    if (!curl) {
        snprintf(errbuf, errcap, "could not initialize libcurl");
        return -1;
    }

    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    char accept_header[256];
    snprintf(accept_header, sizeof(accept_header), "Accept: %s",
             (accept != NULL && accept[0] != 0) ? accept : "application/json");
    headers = curl_slist_append(headers, accept_header);
    if (api_key != NULL && api_key[0] != 0) {
        char auth[4096];
        snprintf(auth, sizeof(auth), "Authorization: Bearer %s", api_key);
        headers = curl_slist_append(headers, auth);
    }

    char curl_error[CURL_ERROR_SIZE];
    curl_error[0] = 0;

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_len);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, mi_http_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, mi_http_header_cb);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &ctx);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 30L);
    /* The CLI abandons a model call that produces no output for two minutes.
     * Low-speed detection is the closest libcurl equivalent for a streaming
     * response; lifecycle bytes that keep the socket warm do not count much
     * toward the one-byte-per-second floor. */
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 120L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "MiAgentDesktop/0.1");
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, curl_error);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, mi_http_progress_cb);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &ctx);

    CURLcode rc = curl_easy_perform(curl);

    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (ctx.aborted || (cancel != NULL && *cancel)) {
        snprintf(errbuf, errcap, "request cancelled");
        return -2;
    }
    if (rc != CURLE_OK) {
        if (ctx.errlen > 0) {
            /* Keep the server's body if we got one; append curl's reason. */
            size_t used = strlen(errbuf);
            snprintf(errbuf + used, errcap - used, " (%s)", curl_error[0] ? curl_error : curl_easy_strerror(rc));
        } else {
            snprintf(errbuf, errcap, "%s", curl_error[0] ? curl_error : curl_easy_strerror(rc));
        }
        return -1;
    }
    if (status >= 400) {
        if (ctx.errlen == 0) snprintf(errbuf, errcap, "HTTP %ld", status);
        return 1;
    }
    return 0;
}

/* Buffered GET for small JSON documents such as the endpoint's /models list.
 * The caller provides the output buffer; the response is NUL-terminated. */
typedef struct {
    char *out;
    size_t cap;
    size_t len;
} mi_http_buf;

static size_t mi_http_buf_write(char *buf, size_t size, size_t nmemb, void *ud) {
    mi_http_buf *ctx = (mi_http_buf *)ud;
    size_t len = size * nmemb;
    if (ctx->cap == 0 || ctx->len + 1 >= ctx->cap) return len; /* truncate */
    size_t room = ctx->cap - ctx->len - 1;
    if (len > room) len = room;
    memcpy(ctx->out + ctx->len, buf, len);
    ctx->len += len;
    ctx->out[ctx->len] = 0;
    return size * nmemb;
}

int mi_http_get_buffered(const char *url, const char *api_key,
                         char *out, size_t outcap, size_t *outlen,
                         char *errbuf, size_t errcap) {
    pthread_once(&mi_curl_once, mi_curl_global_init);
    if (outcap > 0) out[0] = 0;
    if (errcap > 0) errbuf[0] = 0;
    if (outlen != NULL) *outlen = 0;

    CURL *curl = curl_easy_init();
    if (!curl) {
        snprintf(errbuf, errcap, "could not initialize libcurl");
        return -1;
    }

    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Accept: application/json");
    if (api_key != NULL && api_key[0] != 0) {
        char auth[4096];
        snprintf(auth, sizeof(auth), "Authorization: Bearer %s", api_key);
        headers = curl_slist_append(headers, auth);
    }

    char curl_error[CURL_ERROR_SIZE];
    curl_error[0] = 0;
    mi_http_buf ctx = { out, outcap, 0 };

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, mi_http_buf_write);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 60L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "MiAgentDesktop/0.1");
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, curl_error);

    CURLcode rc = curl_easy_perform(curl);
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (outlen != NULL) *outlen = ctx.len;
    if (rc != CURLE_OK) {
        snprintf(errbuf, errcap, "%s", curl_error[0] ? curl_error : curl_easy_strerror(rc));
        return -1;
    }
    if (status >= 400) {
        size_t used = 0;
        if (errcap > 0) {
            used = snprintf(errbuf, errcap, "HTTP %ld", status);
            if (used < errcap - 1 && ctx.len > 0) {
                snprintf(errbuf + used, errcap - used, ": %s", out);
            }
        }
        return 1;
    }
    return 0;
}
