// Strata Duo: one DeepSeek V4.1 model over two hosts, split by layers at a cut K.
//
// The prefix host (the worker) holds layers [0, K) and the Engram rows; the suffix host (the coordinator) holds
// layers [K, nl), the head and the sampler, and is the one a server talks to.  Both processes are this same engine
// with the same pack: the coordinator repeats every call that changes the conversation's state (a window's tokens,
// reset, checkpoint, mark, pin, restore) to the worker, which runs it on its own layers, and a window's hand-off
// (h | pre | topk | cand, what a device change moves in forward_serial) comes back over the link.
//
// A long prompt goes through the chunked path on both hosts (kChunks: the run's tokens, its layout - the rows a chunk,
// the long prompt's skip - and the restore points it keeps on the way): the worker runs its layers over each chunk
// and sends that chunk's hand-off rows (kHand, b the chunk's index; 92 KB a row, so a chunk is one stream of up to
// hundreds of MB - no message bound), the coordinator runs its layers and the head on them; both keep the run's
// restore points from their own layers' states, so restore() after it is what it is after windows.  A run of chunks
// across the hosts ignores a yield and reads on through a Stop (the request ends after the run).
//
// The link is one TCP stream between two addresses of a private point-to-point network (the worker binds one address
// and admits one peer address), and over it, in a build with -DSTRATA_DUO_TLS=ON, TLS 1.3 with mutual authentication
// (--duo-certs DIR):
//   - DIR holds ca.crt and this host's role certificate and key: strata-stage-worker.crt/.key on the worker,
//     strata-stage-coordinator.crt/.key on the coordinator (the names duo/gen_certs.sh writes;
//     worker.crt/.key and coordinator.crt/.key are read when those are absent)
//   - each side verifies the other's certificate against ca.crt and checks its ROLE, which is the certificate's DNS
//     subjectAltName (the CN when there is none): a worker admits "strata-stage-coordinator" only, a coordinator
//     "strata-stage-worker" only
//   - TLS 1.3 or nothing, ALPN "strata-duo-1", no session tickets, no compression
//   - the worker's source-address check (--duo-allow) stays, before any TLS byte
//   - after its checks the worker sends an 8-byte tag inside the channel and the coordinator waits for it, so a
//     refusal (in TLS 1.3 the client's handshake ends before the server has judged its certificate) is reported by
//     connect_to and not by the first call after it
// Without --duo-certs the link refuses to open, unless --duo-insecure asks for the plain stream of the bench: token
// ids and activations unencrypted, the peer known by its source address only.
// One thread uses a Link at a time (a call and its answer); TLS adds no thread of its own.
#pragma once

#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#if defined(STRATA_DUO_TLS)
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#endif

namespace strata::ds4::duo {

enum Op : uint32_t { kHello = 1, kOk = 2, kErr = 3, kForward = 4, kHand = 5, kReset = 6, kCheckpoint = 7, kMark = 8, kPin = 9,
                     kRestore = 10, kBye = 11, kChunks = 12 };

// kChunks' payload (a = the run's first position, b = its tokens): this, then n_inner pairs of int64 (a restore
// point's position, 1 the end of a shared start), then the b tokens (int32)
struct ChunksPlan {
    int32_t per = 0;         // rows a chunk (the last one: the rest)
    int32_t yoco = -1;       // the long prompt's skip: its layer (-1 none) and the rows skipped past it
    int32_t skip = 0;
    int32_t snap_slot = -1;  // feed_mark's checkpoint before the run's last row (-1: none)
    int32_t after = 0;
    int32_t n_inner = 0;
};

struct Head {
    uint32_t magic = 0x4f554444u;   // "DDUO"
    uint32_t op = 0;
    int64_t a = 0, b = 0;
    uint64_t bytes = 0;             // of the payload after this head
};

inline bool split_addr(const std::string& s, std::string& ip, int& port) {
    const size_t c = s.rfind(':');
    if (c == std::string::npos) return false;
    ip = s.substr(0, c);
    port = std::atoi(s.c_str() + c + 1);
    return !ip.empty() && port > 0 && port < 65536;
}

// a role's name: its certificate's identity and its files' stem (role: 1 the worker, 2 the coordinator)
inline const char* role_name(int role) { return role == 1 ? "strata-stage-worker" : "strata-stage-coordinator"; }
inline const char* kAlpn = "strata-duo-1";
inline const char kTag[8] = {'D', 'U', 'O', 'T', 'L', 'S', '1', '\n'};
inline const int kHandshakeSeconds = 10;

// What the options ask of the link, before anything is opened: false with the reason when Duo may not start.
inline bool link_policy(const std::string& certs, bool insecure, std::string& err) {
    if (certs.empty() && !insecure)
        err = "duo: the link needs --duo-certs DIR (TLS 1.3 with mutual authentication), or --duo-insecure for the plain "
              "unauthenticated stream (bench use only)";
    else if (!certs.empty() && insecure) err = "duo: --duo-certs and --duo-insecure are both given: choose one";
#if !defined(STRATA_DUO_TLS)
    else if (!certs.empty())
        err = "duo: --duo-certs needs an engine built with TLS (cmake -DSTRATA_DUO_TLS=ON -DSTRATA_DUO_OPENSSL_ROOT=...); "
              "this build has the plain link only (--duo-insecure)";
#endif
    else return true;
    return false;
}

#if defined(STRATA_DUO_TLS)
// the OpenSSL error queue (and the certificate verdict, when there is one) as one line
inline std::string tls_error(SSL* ssl = nullptr) {
    const int en = errno;
    std::string s;
    for (unsigned long e; (e = ERR_get_error()) != 0;) {
        const char* r = ERR_SYSTEM_ERROR(e) ? std::strerror((int) ERR_GET_REASON(e)) : ERR_reason_error_string(e);
        if (!s.empty()) s += "; ";
        s += r ? std::string(r) : "error " + std::to_string(e);
    }
    const long v = ssl ? SSL_get_verify_result(ssl) : X509_V_OK;
    if (v != X509_V_OK) s += std::string(s.empty() ? "" : " ") + "(certificate: " + X509_verify_cert_error_string(v) + ")";
    if (s.empty()) s = en == EAGAIN || en == EWOULDBLOCK ? "timed out" : "the peer closed the connection";
    return s;
}
inline std::string role_file(const std::string& dir, int role, const char* ext) {
    const std::string full = dir + "/" + role_name(role) + ext;
    if (::access(full.c_str(), R_OK) == 0) return full;
    const std::string brief = dir + "/" + (role == 1 ? "worker" : "coordinator") + ext;
    return ::access(brief.c_str(), R_OK) == 0 ? brief : full;   // (neither: the full name is the one reported)
}
inline int alpn_select(SSL*, const unsigned char** out, unsigned char* outlen, const unsigned char* in, unsigned int len, void*) {
    const size_t want = std::strlen(kAlpn);
    for (unsigned i = 0; i < len;) {
        const unsigned n = in[i++];
        if (i + n > len) break;
        if (n == want && std::memcmp(in + i, kAlpn, n) == 0) {
            *out = in + i, *outlen = (unsigned char) n;
            return SSL_TLSEXT_ERR_OK;
        }
        i += n;
    }
    return SSL_TLSEXT_ERR_ALERT_FATAL;
}
// this role's context: the CA, the role certificate and its key, TLS 1.3 at least, the peer's certificate required
inline SSL_CTX* tls_context(int role, const std::string& dir, std::string& err) {
    const std::string ca = dir + "/ca.crt", crt = role_file(dir, role, ".crt"), key = role_file(dir, role, ".key");
    SSL_CTX* c = SSL_CTX_new(role == 1 ? TLS_server_method() : TLS_client_method());
    const char* what = "a TLS context";
    bool ok = c != nullptr;
    if (ok) ERR_clear_error();
    if (ok && SSL_CTX_set_min_proto_version(c, TLS1_3_VERSION) != 1) ok = false, what = "TLS 1.3";
    if (ok && SSL_CTX_load_verify_locations(c, ca.c_str(), nullptr) != 1) ok = false, what = ca.c_str();
    if (ok && SSL_CTX_use_certificate_chain_file(c, crt.c_str()) != 1) ok = false, what = crt.c_str();
    if (ok && SSL_CTX_use_PrivateKey_file(c, key.c_str(), SSL_FILETYPE_PEM) != 1) ok = false, what = key.c_str();
    if (ok && SSL_CTX_check_private_key(c) != 1) ok = false, what = "the key does not belong to the certificate";
    if (ok) {   // (this host's own certificate must carry its own role: a swapped pair fails here, on the host that swapped it)
        X509* mine = SSL_CTX_get0_certificate(c);
        const char* name = role_name(role);
        if (!mine || X509_check_host(mine, name, std::strlen(name), X509_CHECK_FLAG_NO_WILDCARDS, nullptr) != 1) {
            err = "duo: --duo-certs: " + crt + " is not a " + name + " certificate";
            SSL_CTX_free(c);
            return nullptr;
        }
    }
    if (!ok) {
        err = std::string("duo: --duo-certs: ") + what + ": " + tls_error();
        if (c) SSL_CTX_free(c);
        return nullptr;
    }
    SSL_CTX_set_verify(c, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nullptr);
    SSL_CTX_set_options(c, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_session_cache_mode(c, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_num_tickets(c, 0);
    if (role == 1) SSL_CTX_set_alpn_select_cb(c, alpn_select, nullptr);
    return c;
}
#endif

// The checks a host can make before the model's load (the options, and with TLS this host's files), and the one line
// that says which link this is.
inline bool link_preflight(int role, const std::string& certs, bool insecure, std::string& err) {
    if (!link_policy(certs, insecure, err)) return false;
#if defined(STRATA_DUO_TLS)
    if (!certs.empty()) {
        SSL_CTX* c = tls_context(role, certs, err);
        if (!c) return false;
        SSL_CTX_free(c);
        std::fprintf(stderr, "ds4 duo: link mode TLS 1.3, mutual authentication: this host is %s, the peer must present a %s "
                             "certificate of %s/ca.crt\n", role_name(role), role_name(3 - role), certs.c_str());
        return true;
    }
#endif
    std::fprintf(stderr, "ds4 duo: link mode INSECURE (--duo-insecure): plain TCP, token ids and activations unencrypted, the "
                         "peer known by its source address only\n");
    return true;
}

class Link {
public:
    ~Link() { close(); }
    bool open() const { return fd_ >= 0; }
    bool encrypted() const {
#if defined(STRATA_DUO_TLS)
        return ssl_ != nullptr;
#else
        return false;
#endif
    }
    void close() {
        drop();
#if defined(STRATA_DUO_TLS)
        if (ctx_) SSL_CTX_free(ctx_);
        ctx_ = nullptr;
#endif
    }
    // the worker: bind `addr` (ip:port), take one connection, from `allow` only (an ip; empty: any); with `certs` the
    // connection is the first one that also passes the TLS checks (a refused one is reported and the wait goes on)
    bool accept_one(const std::string& addr, const std::string& allow, const std::string& certs, bool insecure, std::string& err) {
        std::string ip;
        int port = 0;
        if (!link_policy(certs, insecure, err)) return false;
        if (!split_addr(addr, ip, port)) return fail(err, "--duo-listen wants ip:port");
#if defined(STRATA_DUO_TLS)
        if (!certs.empty() && !(ctx_ = tls_context(1, certs, err))) return false;
#endif
        const int ls = ::socket(AF_INET, SOCK_STREAM, 0);
        if (ls < 0) return fail(err, "socket");
        int one = 1;
        ::setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        sockaddr_in sa{};
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t) port);
        if (::inet_pton(AF_INET, ip.c_str(), &sa.sin_addr) != 1) {
            ::close(ls);
            return fail(err, "--duo-listen: not an IPv4 address");
        }
        if (::bind(ls, (sockaddr*) &sa, sizeof sa) != 0 || ::listen(ls, 1) != 0) {
            const std::string e = std::strerror(errno);
            ::close(ls);
            return fail(err, "bind " + addr + ": " + e);
        }
        for (;;) {
            sockaddr_in pa{};
            socklen_t n = sizeof pa;
            const int fd = ::accept(ls, (sockaddr*) &pa, &n);
            if (fd < 0) {
                if (errno == EINTR) continue;
                ::close(ls);
                return fail(err, "accept");
            }
            char pip[64] = {};
            ::inet_ntop(AF_INET, &pa.sin_addr, pip, sizeof pip);
            if (!allow.empty() && allow != pip) {   // (not the coordinator: refused, the wait goes on)
                std::fprintf(stderr, "ds4 duo: refused a connection from %s: not the --duo-allow address\n", pip);
                ::close(fd);
                continue;
            }
            fd_ = fd;
            tune();
#if defined(STRATA_DUO_TLS)
            std::string why;
            if (ctx_ && !handshake(true, why)) {   // (not a coordinator of this CA: refused, the wait goes on)
                std::fprintf(stderr, "ds4 duo: refused a connection from %s: %s\n", pip, why.c_str());
                continue;
            }
#endif
            break;
        }
        ::close(ls);
        return true;
    }
    bool connect_to(const std::string& addr, const std::string& certs, bool insecure, std::string& err) {
        std::string ip;
        int port = 0;
        if (!link_policy(certs, insecure, err)) return false;
        if (!split_addr(addr, ip, port)) return fail(err, "--duo-connect wants ip:port");
#if defined(STRATA_DUO_TLS)
        if (!certs.empty() && !(ctx_ = tls_context(2, certs, err))) return false;
#endif
        fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd_ < 0) return fail(err, "socket");
        sockaddr_in sa{};
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t) port);
        if (::inet_pton(AF_INET, ip.c_str(), &sa.sin_addr) != 1) return fail(err, "--duo-connect: not an IPv4 address");
        if (::connect(fd_, (sockaddr*) &sa, sizeof sa) != 0) return fail(err, "connect " + addr + ": " + std::strerror(errno));
        tune();
#if defined(STRATA_DUO_TLS)
        std::string why;
        if (ctx_ && !handshake(false, why)) return fail(err, addr + ": " + why);
#endif
        return true;
    }
    bool put(const void* p, size_t n) {
        const char* q = (const char*) p;
#if defined(STRATA_DUO_TLS)
        if (ssl_) {
            while (n > 0) {
                size_t k = 0;
                const int r = SSL_write_ex(ssl_, q, n, &k);
                if (r != 1) {
                    const int why = SSL_get_error(ssl_, r);
                    if (why == SSL_ERROR_WANT_READ || why == SSL_ERROR_WANT_WRITE) continue;   // (a signal: the same call again)
                    return false;
                }
                q += k;
                n -= k;
            }
            return true;
        }
#endif
        while (n > 0) {
            const ssize_t k = ::send(fd_, q, n, 0);
            if (k < 0 && errno == EINTR) continue;
            if (k <= 0) return false;
            q += k;
            n -= (size_t) k;
        }
        return true;
    }
    bool get(void* p, size_t n) {
        char* q = (char*) p;
#if defined(STRATA_DUO_TLS)
        if (ssl_) {
            while (n > 0) {
                size_t k = 0;
                const int r = SSL_read_ex(ssl_, q, n, &k);
                if (r != 1) {
                    const int why = SSL_get_error(ssl_, r);
                    if (why == SSL_ERROR_WANT_READ || why == SSL_ERROR_WANT_WRITE) continue;
                    return false;
                }
                q += k;
                n -= k;
            }
            return true;
        }
#endif
        while (n > 0) {
            const ssize_t k = ::recv(fd_, q, n, 0);
            if (k < 0 && errno == EINTR) continue;
            if (k <= 0) return false;
            q += k;
            n -= (size_t) k;
        }
        return true;
    }
    bool send(uint32_t op, int64_t a = 0, int64_t b = 0, const void* body = nullptr, size_t bytes = 0) {
        Head h;
        h.op = op, h.a = a, h.b = b, h.bytes = bytes;
#if defined(STRATA_DUO_TLS)
        if (ssl_ && bytes > 0 && bytes <= 4096) {   // (a small call: one TLS record, one segment, not two)
            char one[sizeof h + 4096];
            std::memcpy(one, &h, sizeof h);
            std::memcpy(one + sizeof h, body, bytes);
            return put(one, sizeof h + bytes);
        }
#endif
        return put(&h, sizeof h) && (bytes == 0 || put(body, bytes));
    }
    bool recv_head(Head& h) { return get(&h, sizeof h) && h.magic == 0x4f554444u; }

private:
    int fd_ = -1;
    bool fail(std::string& err, const std::string& what) {
        err = "duo: " + what;
        close();
        return false;
    }
    // the connection (the context stays: the worker's next one uses it)
    void drop() {
#if defined(STRATA_DUO_TLS)
        if (ssl_) {
            if (up_) SSL_shutdown(ssl_);   // (close_notify, not waited for)
            SSL_free(ssl_);
        }
        ssl_ = nullptr, up_ = false;
#endif
        if (fd_ >= 0) ::close(fd_);
        fd_ = -1;
    }
#if defined(STRATA_DUO_TLS)
    SSL_CTX* ctx_ = nullptr;
    SSL* ssl_ = nullptr;
    bool up_ = false;
    void patience(int seconds) {   // (0: none - the worker waits between a person's turns for as long as it takes)
        timeval tv{seconds, 0};
        ::setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        ::setsockopt(fd_, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    }
    // TLS on the connected fd_, as the worker (server) or the coordinator; on a failure the connection is dropped
    bool handshake(bool server, std::string& why) {
        const char* peer = role_name(server ? 2 : 1);
        const auto no = [&](const std::string& w) {
            why = w;
            drop();
            return false;
        };
        patience(kHandshakeSeconds);   // (a peer that connects and says nothing does not hold the worker)
        ERR_clear_error();
        ssl_ = SSL_new(ctx_);
        if (!ssl_ || SSL_set_fd(ssl_, fd_) != 1) return no("TLS setup: " + tls_error());
        SSL_set_hostflags(ssl_, X509_CHECK_FLAG_NO_WILDCARDS);
        if (SSL_set1_host(ssl_, peer) != 1) return no("TLS setup: " + tls_error());   // (the role, checked in the handshake)
        if (!server) {
            unsigned char protos[64];
            const size_t n = std::strlen(kAlpn);
            protos[0] = (unsigned char) n;
            std::memcpy(protos + 1, kAlpn, n);
            if (SSL_set_tlsext_host_name(ssl_, peer) != 1 || SSL_set_alpn_protos(ssl_, protos, (unsigned) n + 1) != 0)
                return no("TLS setup: " + tls_error());
        }
        errno = 0;
        if ((server ? SSL_accept(ssl_) : SSL_connect(ssl_)) != 1) return no("TLS handshake: " + tls_error(ssl_));
        up_ = true;
        // (again, after the handshake and by hand: nothing below rests on one library call's defaults)
        if (SSL_version(ssl_) != TLS1_3_VERSION) return no(std::string("TLS handshake: ") + SSL_get_version(ssl_) + ", not TLS 1.3");
        if (SSL_get_verify_result(ssl_) != X509_V_OK) return no("TLS handshake: " + tls_error(ssl_));
        X509* cert = SSL_get1_peer_certificate(ssl_);
        const bool role = cert && X509_check_host(cert, peer, std::strlen(peer), X509_CHECK_FLAG_NO_WILDCARDS, nullptr) == 1;
        if (cert) X509_free(cert);
        if (!role) return no(std::string("the peer's certificate is not a ") + peer + " certificate");
        const unsigned char* sel = nullptr;
        unsigned nsel = 0;
        SSL_get0_alpn_selected(ssl_, &sel, &nsel);
        if (nsel != std::strlen(kAlpn) || std::memcmp(sel, kAlpn, nsel) != 0) return no(std::string("the peer does not speak ") + kAlpn);
        size_t k = 0;
        char tag[sizeof kTag] = {};
        errno = 0;
        if (server) {
            if (SSL_write_ex(ssl_, kTag, sizeof kTag, &k) != 1) return no("TLS: " + tls_error(ssl_));
        } else {
            for (size_t got = 0; got < sizeof tag; got += k)
                if (SSL_read_ex(ssl_, tag + got, sizeof tag - got, &k) != 1)
                    return no("the worker refused this host after the TLS handshake: " + tls_error(ssl_));
            if (std::memcmp(tag, kTag, sizeof tag) != 0) return no("the peer is not a Strata Duo worker");
        }
        patience(0);
        std::fprintf(stderr, "ds4 duo: link up, %s %s, peer %s verified\n", SSL_get_version(ssl_), SSL_get_cipher_name(ssl_), peer);
        return true;
    }
#endif
    void tune() {
        int one = 1;
        ::setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#if defined(SO_NOSIGPIPE)
        ::setsockopt(fd_, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        int buf = 4 << 20;
        ::setsockopt(fd_, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);
        ::setsockopt(fd_, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
    }
};

}   // namespace strata::ds4::duo
