// Native shims for the MCP bridge/host: detached process spawning, secure
// tokens, and a small blocking HTTP request helper built on libcurl.
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <curl/curl.h>

// --- signal-driven shutdown -------------------------------------------------

static volatile sig_atomic_t mi_shutdown_requested_flag = 0;
static int mi_watched_listen_fd = -1;

static void mi_shutdown_signal(int sig) {
    (void)sig;
    mi_shutdown_requested_flag = 1;
    if (mi_watched_listen_fd >= 0) {
        /* Wake a blocking accept() so the Odin loop can clean up sessions. */
        shutdown(mi_watched_listen_fd, SHUT_RDWR);
    }
}

void mi_mcp_watch_signals(int fd) {
    mi_watched_listen_fd = fd;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = mi_shutdown_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
}

int mi_mcp_shutdown_requested(void) { return (int)mi_shutdown_requested_flag; }

// --- detached process spawning ---------------------------------------------

int mi_mcp_spawn_detached(char **argv, const char *log_path) {
    if (!argv || !argv[0]) return -1;

    pid_t first = fork();
    if (first < 0) return -1;
    if (first == 0) {
        setsid();
        pid_t second = fork();
        if (second < 0) _exit(127);
        if (second > 0) _exit(0);

        int logfd = -1;
        if (log_path && *log_path) {
            logfd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
        }
        if (logfd >= 0) {
            dup2(logfd, STDOUT_FILENO);
            dup2(logfd, STDERR_FILENO);
            if (logfd > STDERR_FILENO) close(logfd);
        }
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            if (devnull > STDERR_FILENO) close(devnull);
        }
        for (int fd = 3; fd < 1024; fd++) close(fd);
        if (chdir("/") != 0) { /* best effort */ }
        execvp(argv[0], argv);
        _exit(127);
    }

    int status = 0;
    while (waitpid(first, &status, 0) < 0 && errno == EINTR) {}
    return 0;
}

// --- random tokens ----------------------------------------------------------

int mi_mcp_random_hex(char *out, int bytes) {
    if (!out || bytes <= 0) return -1;
    unsigned char buf[64];
    if (bytes > (int)sizeof(buf)) bytes = (int)sizeof(buf);
    int got = 0;
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        while (got < bytes) {
            ssize_t n = read(fd, buf + got, (size_t)(bytes - got));
            if (n <= 0) break;
            got += (int)n;
        }
        close(fd);
    }
    if (got < bytes) {
        uint64_t seed = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32) ^ (uintptr_t)out;
        for (int i = got; i < bytes; i++) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
            buf[i] = (unsigned char)seed;
        }
    }
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < bytes; i++) {
        out[i * 2] = hex[buf[i] >> 4];
        out[i * 2 + 1] = hex[buf[i] & 15];
    }
    out[bytes * 2] = 0;
    return 0;
}

// --- HTTP -------------------------------------------------------------------

typedef struct {
    char *body;
    size_t len;
    size_t cap;
    char content_type[256];
    char session_id[512];
    long status;
    long curl_code;
    char error[512];
} mi_mcp_http_result;

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static void curl_init_once(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

static int body_grow(mi_mcp_http_result *out, size_t need) {
    if (out->len + need + 1 <= out->cap) return 0;
    size_t cap = out->cap ? out->cap : 4096;
    while (cap < out->len + need + 1) cap *= 2;
    char *p = (char *)realloc(out->body, cap);
    if (!p) return -1;
    out->body = p;
    out->cap = cap;
    return 0;
}

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    mi_mcp_http_result *out = (mi_mcp_http_result *)userdata;
    size_t n = size * nmemb;
    if (body_grow(out, n) != 0) return 0;
    memcpy(out->body + out->len, ptr, n);
    out->len += n;
    out->body[out->len] = 0;
    return n;
}

static void copy_header_value(char *dst, size_t cap, const char *value, size_t len) {
    while (len > 0 && (*value == ' ' || *value == '\t')) { value++; len--; }
    while (len > 0 && (value[len - 1] == '\r' || value[len - 1] == '\n' ||
                       value[len - 1] == ' ' || value[len - 1] == '\t')) len--;
    if (len >= cap) len = cap - 1;
    memcpy(dst, value, len);
    dst[len] = 0;
}

static size_t header_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    mi_mcp_http_result *out = (mi_mcp_http_result *)userdata;
    size_t n = size * nmemb;
    char *colon = memchr(ptr, ':', n);
    if (!colon) return n;
    size_t name_len = (size_t)(colon - ptr);
    if (name_len == 12 && strncasecmp(ptr, "content-type", 12) == 0) {
        copy_header_value(out->content_type, sizeof(out->content_type), colon + 1, n - name_len - 1);
    } else if (name_len == 14 && strncasecmp(ptr, "mcp-session-id", 14) == 0) {
        copy_header_value(out->session_id, sizeof(out->session_id), colon + 1, n - name_len - 1);
    }
    return n;
}

int mi_mcp_http_request(const char *method, const char *url,
                        const char *headers_nl, const char *body, size_t body_len,
                        long timeout_ms, mi_mcp_http_result *out) {
    if (!method || !url || !out) return -1;
    pthread_once(&curl_once, curl_init_once);
    memset(out, 0, sizeof(*out));

    CURL *curl = curl_easy_init();
    if (!curl) {
        snprintf(out->error, sizeof(out->error), "could not initialize libcurl");
        return -1;
    }
    struct curl_slist *headers = NULL;
    if (headers_nl && *headers_nl) {
        char *copy = strdup(headers_nl);
        if (copy) {
            char *line = copy;
            while (line && *line) {
                char *nl = strchr(line, '\n');
                if (nl) *nl = 0;
                if (*line) headers = curl_slist_append(headers, line);
                line = nl ? nl + 1 : NULL;
            }
            free(copy);
        }
    }
    headers = curl_slist_append(headers, "Accept: application/json, text/event-stream");
    headers = curl_slist_append(headers, "User-Agent: miagent-mcp/1.0");
    if (body && body_len > 0) headers = curl_slist_append(headers, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, out);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, header_cb);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, out);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 3L);
    if (timeout_ms > 0) curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, timeout_ms);

    if (strcmp(method, "POST") == 0) {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body ? body : "");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)(body ? body_len : 0));
    } else if (strcmp(method, "GET") == 0) {
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    } else if (strcmp(method, "DELETE") == 0) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");
    } else {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
        if (body) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_len);
        }
    }

    CURLcode rc = curl_easy_perform(curl);
    out->curl_code = (long)rc;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &out->status);
    if (rc != CURLE_OK) {
        snprintf(out->error, sizeof(out->error), "%s", curl_easy_strerror(rc));
    } else if (!out->body) {
        out->body = (char *)calloc(1, 1);
        out->cap = 1;
    }
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return rc == CURLE_OK ? 0 : -1;
}

void mi_mcp_http_free(mi_mcp_http_result *out) {
    if (!out) return;
    free(out->body);
    memset(out, 0, sizeof(*out));
}
