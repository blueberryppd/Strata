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
// and, with --duo-allow IP, admits that one peer address: optional over TLS, required with --duo-insecure), and over
// it, in a build with -DSTRATA_DUO_TLS=ON, TLS 1.3 with mutual authentication (--duo-certs DIR):
//   - DIR holds ca.crt and this host's role certificate and key: strata-stage-worker.crt/.key on the worker,
//     strata-stage-coordinator.crt/.key on the coordinator (the names duo/gen_certs.sh writes;
//     worker.crt/.key and coordinator.crt/.key are read when those are absent); a key file that its group or other
//     users can read is refused (chmod 600)
//   - each side verifies the other's certificate against ca.crt and checks its ROLE, which is the certificate's DNS
//     subjectAltName (the CN when there is none): a worker admits "strata-stage-coordinator" only, a coordinator
//     "strata-stage-worker" only
//   - trust is "a certificate of this CA that carries the role's name": there is no revocation list - to shut a host
//     out, make a new CA and new certificates for both hosts
//   - TLS 1.3 or nothing, ALPN "strata-duo-1", no session tickets, no compression
//   - the worker's source-address check (--duo-allow) stays, before any TLS byte
//   - after its checks the worker sends an 8-byte tag inside the channel and the coordinator waits for it, so a
//     refusal (in TLS 1.3 the client's handshake ends before the server has judged its certificate) is reported by
//     connect_to and not by the first call after it
// Without --duo-certs the link refuses to open, unless --duo-insecure asks for the plain stream of the bench: token
// ids and activations unencrypted, the peer known by its source address only.
//
// Time limits.  Opening the link has deadlines of kHandshakeSeconds each: the connect, the TLS handshake as a whole
// (not a limit a read: a peer that sends a byte now and then does not hold the worker), and the greeting (kHello and
// its answer, Link::deadline).  The established link has none: the coordinator waits for as long as the worker's
// layers take, the worker for as long as a person thinks.  A peer HOST that vanishes (power, sleep, the cable) is
// found by TCP keepalive on both ends (tune(): kKeepIdle s of silence, then kKeepCnt probes kKeepIntvl s apart -
// kDeadSeconds in all) and, for data already sent, by the retransmission limit: the blocked send or recv then fails
// and Link::why() says so.  A peer PROCESS that ends closes the stream, which both ends see at once.  (A process that
// is stopped but whose host answers - SIGSTOP - is not a dead peer to TCP: nothing here notices it.)
// One thread uses a Link at a time (a call and its answer); TLS adds no thread of its own.
#pragma once

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <vector>
#if defined(STRATA_DUO_TLS)
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#endif

namespace strata::ds4::duo {

enum Op : uint32_t { kHello = 1, kOk = 2, kErr = 3, kForward = 4, kHand = 5, kReset = 6, kCheckpoint = 7, kMark = 8, kPin = 9,
                     kRestore = 10, kBye = 11, kChunks = 12, kSlotSave = 13, kSlot = 14, kSlotLoad = 15 };
// kBye: the coordinator's last call when it ends in order; a link that closes without it is reported by the worker as
// a failure.  kReset, kCheckpoint, kMark, kPin, kRestore, kSlotSave and kBye carry no payload (bytes must be 0).
// A conversation set aside (slot_save / slot_load on the coordinator) is both hosts' halves:
//   kSlotSave (a = the restore point to save at, -1 the state as it is; b = the position that is: the worker refuses
//     when its own differs) -> kSlot (a the same, the payload the worker's half: its own layers' state) or kErr (why
//     not; the worker's layers are as they were)
//   kSlotLoad (a = the conversation's position, the payload a worker's half) -> kOk, or kErr (a = 1: the worker wrote
//     some of it and has reset itself; 0: its state is as it was)
// Unlike the other state calls these two are answered: the coordinator returns only when both hosts agree.

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

inline const uint32_t kMagic = 0x4f554444u;   // "DDUO"
struct Head {
    uint32_t magic = kMagic;
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
inline const int kHandshakeSeconds = 10;   // the connect, the TLS handshake, the greeting: a deadline each
// a peer host that is gone: kKeepIdle s without a segment, then kKeepCnt unanswered probes kKeepIntvl s apart
inline const int kKeepIdle = 10, kKeepIntvl = 5, kKeepCnt = 4;
inline const int kDeadSeconds = kKeepIdle + kKeepIntvl * kKeepCnt;
#if defined(MSG_NOSIGNAL)   // (Linux: a write to a closed link is an error, not a SIGPIPE; macOS: SO_NOSIGPIPE, tune())
inline const int kSendFlags = MSG_NOSIGNAL;
#else
inline const int kSendFlags = 0;
#endif
inline int64_t tick_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// A peer's text on its way into a log or an error message: printable ASCII only, at most `most` bytes.
inline std::string printable(const std::string& s, size_t most = 2048) {
    std::string out = s.substr(0, most);
    for (char& c : out)
        if ((unsigned char) c < 0x20 || (unsigned char) c > 0x7e) c = '?';
    if (s.size() > most) out += "...";
    return out;
}

// A model file's content fingerprint for the greeting: 64-bit FNV-1a over the file's size and kPrintBlocks blocks of
// kPrintBlock bytes at fixed places - the first (the header), the last (the tail) and the ones evenly between, each
// start rounded down to 4 KiB; a file of at most kPrintBlocks blocks is read whole.  1 MiB a file whatever its size,
// the same number on both hosts for the same file.  It tells two different files of one name and size apart (a
// re-quantised or fine-tuned model differs everywhere); it is no proof that two files are equal byte for byte, and no
// defence against a file made to collide.  false: the file cannot be read.
inline const uint64_t kPrintBlock = 64 * 1024;
inline const int kPrintBlocks = 16;
inline bool file_print(int fd, uint64_t size, uint64_t& print) {
    uint64_t h = 0xcbf29ce484222325ull;
    const auto mix = [&h](const uint8_t* p, size_t n) {
        for (size_t i = 0; i < n; ++i) h = (h ^ p[i]) * 0x100000001b3ull;
    };
    uint8_t sz[8];
    for (int i = 0; i < 8; ++i) sz[i] = (uint8_t) (size >> (8 * i));
    mix(sz, 8);
    std::vector<uint8_t> buf((size_t) kPrintBlock);
    const auto block = [&](uint64_t off, uint64_t n) {
        for (uint64_t got = 0; got < n;) {
            const ssize_t r = ::pread(fd, buf.data() + got, (size_t) (n - got), (off_t) (off + got));
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) return false;
            got += (uint64_t) r;
        }
        mix(buf.data(), (size_t) n);
        return true;
    };
    if (size <= kPrintBlock * kPrintBlocks) {
        for (uint64_t off = 0; off < size; off += kPrintBlock)
            if (!block(off, std::min<uint64_t>(kPrintBlock, size - off))) return false;
    } else {
        const uint64_t last = size - kPrintBlock;
        for (int i = 0; i < kPrintBlocks; ++i) {
            const uint64_t off = i == kPrintBlocks - 1 ? last : (last / (kPrintBlocks - 1) * (uint64_t) i) & ~4095ull;
            if (!block(off, kPrintBlock)) return false;
        }
    }
    print = h;
    return true;
}

// What the options ask of the link, before anything is opened: false with the reason when Duo may not start.
// (role 1, the worker: `allow` is its --duo-allow)
inline bool link_policy(const std::string& certs, bool insecure, std::string& err, int role = 0, const std::string& allow = "") {
    in_addr a4{};
    if (certs.empty() && !insecure)
        err = "duo: the link needs --duo-certs DIR (TLS 1.3 with mutual authentication), or --duo-insecure for the plain "
              "unauthenticated stream (bench use only)";
    else if (!certs.empty() && insecure) err = "duo: --duo-certs and --duo-insecure are both given: choose one";
    else if (role == 1 && insecure && allow.empty())
        err = "duo: --duo-insecure on the prefix host needs --duo-allow IP: the plain link knows its peer by that address only";
    else if (role == 1 && !allow.empty() && ::inet_pton(AF_INET, allow.c_str(), &a4) != 1)
        err = "duo: --duo-allow wants an IPv4 address";
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
    struct stat ks;   // (a private key others can read is no secret: refused before anything is loaded)
    if (::stat(key.c_str(), &ks) == 0 && (ks.st_mode & 077) != 0) {
        char mode[8];
        std::snprintf(mode, sizeof mode, "%03o", (unsigned) (ks.st_mode & 0777));
        err = "duo: --duo-certs: the private key " + key + " can be read by its group or other users (mode " + mode +
              "); run: chmod 600 '" + key + "'";
        return nullptr;
    }
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
inline bool link_preflight(int role, const std::string& certs, bool insecure, const std::string& allow, std::string& err) {
    if (!link_policy(certs, insecure, err, role, allow)) return false;
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
        stop_listening();
#if defined(STRATA_DUO_TLS)
        if (ctx_) SSL_CTX_free(ctx_);
        ctx_ = nullptr;
#endif
    }
    // the worker: bind `addr` (ip:port), take one connection, from `allow` only (an ip; empty: any); with `certs` the
    // connection is the first one that also passes the TLS checks (a refused one is reported and the wait goes on).
    // keep_listening: the address stays bound after it - a caller that then refuses the peer's greeting calls refuse()
    // and accept_one again, and stop_listening() once it has its peer
    bool accept_one(const std::string& addr, const std::string& allow, const std::string& certs, bool insecure, std::string& err,
                    bool keep_listening = false) {
        std::string ip;
        int port = 0;
        if (!link_policy(certs, insecure, err, 1, allow)) return false;
        if (!split_addr(addr, ip, port)) return fail(err, "--duo-listen wants ip:port");
        drop();
        if (ls_ < 0) {
#if defined(STRATA_DUO_TLS)
            if (!certs.empty() && !ctx_ && !(ctx_ = tls_context(1, certs, err))) return false;
#endif
            ls_ = ::socket(AF_INET, SOCK_STREAM, 0);
            if (ls_ < 0) return fail(err, "socket");
            int one = 1;
            ::setsockopt(ls_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
            sockaddr_in sa{};
            sa.sin_family = AF_INET;
            sa.sin_port = htons((uint16_t) port);
            if (::inet_pton(AF_INET, ip.c_str(), &sa.sin_addr) != 1) return fail(err, "--duo-listen: not an IPv4 address");
            if (::bind(ls_, (sockaddr*) &sa, sizeof sa) != 0 || ::listen(ls_, 1) != 0) {
                const std::string e = std::strerror(errno);
                return fail(err, "bind " + addr + ": " + e);
            }
        }
        for (;;) {
            sockaddr_in pa{};
            socklen_t n = sizeof pa;
            const int fd = ::accept(ls_, (sockaddr*) &pa, &n);
            if (fd < 0) {
                if (errno == EINTR || errno == ECONNABORTED) continue;
                return fail(err, std::string("accept: ") + std::strerror(errno));
            }
            char pip[64] = {};
            ::inet_ntop(AF_INET, &pa.sin_addr, pip, sizeof pip);
            if (!allow.empty() && allow != pip) {   // (not the coordinator: refused, the wait goes on)
                std::fprintf(stderr, "ds4 duo: refused a connection from %s: not the --duo-allow address\n", pip);
                ::close(fd);
                continue;
            }
            fd_ = fd;
            fault_ = kNone;
            peer_ = pip;
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
        if (!keep_listening) stop_listening();
        return true;
    }
    // the worker: this peer is not the one (its greeting was refused) - the connection ends, the address stays bound
    void refuse() { drop(); }
    void stop_listening() {
        if (ls_ >= 0) ::close(ls_);
        ls_ = -1;
    }
    const std::string& peer() const { return peer_; }
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
        fault_ = kNone;
        peer_ = ip;
        sockaddr_in sa{};
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t) port);
        if (::inet_pton(AF_INET, ip.c_str(), &sa.sin_addr) != 1) return fail(err, "--duo-connect: not an IPv4 address");
        deadline(kHandshakeSeconds);   // (an address nothing answers on: not the system's 75 s)
        if (::connect(fd_, (sockaddr*) &sa, sizeof sa) != 0) {
            if (errno != EINPROGRESS && errno != EINTR) return fail(err, "connect " + addr + ": " + std::strerror(errno));
            if (!wait(false)) return fail(err, "connect " + addr + ": no answer in " + std::to_string(kHandshakeSeconds) + " s");
            int so = 0;
            socklen_t sl = sizeof so;
            if (::getsockopt(fd_, SOL_SOCKET, SO_ERROR, &so, &sl) != 0) so = errno;
            if (so != 0) return fail(err, "connect " + addr + ": " + std::strerror(so));
        }
        tune();
#if defined(STRATA_DUO_TLS)
        std::string why;
        if (ctx_ && !handshake(false, why)) return fail(err, addr + ": " + why);
#endif
        deadline(0);
        return true;
    }
    // A deadline for the calls that follow, `seconds` from now (the greeting); 0: none - the established link, where
    // put and get block for as long as the peer takes and only a closed or dead link ends them.
    void deadline(int seconds) {
        until_ = seconds > 0 ? tick_ms() + (int64_t) seconds * 1000 : 0;
        const int fl = fd_ >= 0 ? ::fcntl(fd_, F_GETFL, 0) : -1;
        if (fl >= 0) ::fcntl(fd_, F_SETFL, seconds > 0 ? fl | O_NONBLOCK : fl & ~O_NONBLOCK);
    }
    // why the last put, get or recv_head failed, for the error's text
    std::string why() const {
        switch (fault_) {
        case kShut: return "the link is closed";
        case kLeft: return "the peer closed the link";
        case kSilent:
            return "the peer's host stopped answering (TCP keepalive, " + std::to_string(kDeadSeconds) + " s): it is off, asleep or unreachable";
        case kLate: return "no answer in time";
        case kBadHead: return "a call that is not Strata Duo's (a bad header)";
        case kErrno: return std::strerror(errno_);
        default: return fd_ < 0 ? "the link is closed" : "no failure";
        }
    }
    bool peer_left() const { return fault_ == kLeft; }     // the stream ended: the peer closed it, or its process ended
    bool bad_head() const { return fault_ == kBadHead; }
    bool put(const void* p, size_t n) {
        const char* q = (const char*) p;
        if (fd_ < 0) return lost(kShut);
#if defined(STRATA_DUO_TLS)
        if (ssl_) {
            while (n > 0) {
                size_t k = 0;
                errno = 0;
                const int r = SSL_write_ex(ssl_, q, n, &k);
                if (r != 1) {
                    const int why = SSL_get_error(ssl_, r), en = errno;
                    if (why == SSL_ERROR_WANT_READ || why == SSL_ERROR_WANT_WRITE) {   // (a signal: the same call again)
                        if (until_ != 0 && !wait(why == SSL_ERROR_WANT_READ)) return false;
                        continue;
                    }
                    return lost_tls(why, en);
                }
                q += k;
                n -= k;
            }
            return true;
        }
#endif
        while (n > 0) {
            const ssize_t k = ::send(fd_, q, n, kSendFlags);
            if (k < 0 && errno == EINTR) continue;
            if (k < 0 && until_ != 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (!wait(false)) return false;
                continue;
            }
            if (k <= 0) return lost_errno(k == 0 ? EPIPE : errno);
            q += k;
            n -= (size_t) k;
        }
        return true;
    }
    bool get(void* p, size_t n) {
        char* q = (char*) p;
        if (fd_ < 0) return lost(kShut);
#if defined(STRATA_DUO_TLS)
        if (ssl_) {
            while (n > 0) {
                size_t k = 0;
                errno = 0;
                const int r = SSL_read_ex(ssl_, q, n, &k);
                if (r != 1) {
                    const int why = SSL_get_error(ssl_, r), en = errno;
                    if (why == SSL_ERROR_WANT_READ || why == SSL_ERROR_WANT_WRITE) {
                        if (until_ != 0 && !wait(why == SSL_ERROR_WANT_READ)) return false;
                        continue;
                    }
                    return lost_tls(why, en);
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
            if (k < 0 && until_ != 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (!wait(true)) return false;
                continue;
            }
            if (k == 0) return lost(kLeft);
            if (k < 0) return lost_errno(errno);
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
    // false: the link failed (why()), or what came is not a call's head (bad_head(): the stream is out of step)
    bool recv_head(Head& h) {
        if (!get(&h, sizeof h)) return false;
        if (h.magic != kMagic) return lost(kBadHead);
        // These calls never carry a body, on either role. Refuse before any caller can leave unexpected bytes
        // in the stream and mistake them for the next head.
        switch (h.op) {
        case kOk: case kReset: case kCheckpoint: case kMark: case kPin: case kRestore: case kSlotSave: case kBye:
            if (h.bytes != 0) return lost(kBadHead);
            break;
        default: break;
        }
        return true;
    }

private:
    enum Fault { kNone, kShut, kLeft, kSilent, kLate, kBadHead, kErrno };
    int fd_ = -1, ls_ = -1;
    int64_t until_ = 0;   // deadline(): tick_ms() at which the calls give up (the socket is non-blocking until then)
    Fault fault_ = kNone;
    int errno_ = 0;
    std::string peer_;
    bool fail(std::string& err, const std::string& what) {
        err = "duo: " + what;
        close();
        return false;
    }
    bool lost(Fault f) {
        fault_ = f;
        return false;
    }
    bool lost_errno(int en) {
        errno_ = en;
        // (ETIMEDOUT: the keepalive's probes, or sent data, went unanswered - the peer's host is gone)
        return lost(en == ETIMEDOUT ? kSilent : en == EPIPE || en == ECONNRESET ? kLeft : kErrno);
    }
    // until the deadline: the socket readable (rd) or writable; false - the deadline passed
    bool wait(bool rd) {
        for (;;) {
            const int64_t left = until_ - tick_ms();
            if (left <= 0) return lost(kLate);
            pollfd p{fd_, (short) (rd ? POLLIN : POLLOUT), 0};
            const int r = ::poll(&p, 1, (int) left);
            if (r > 0) return true;
            if (r < 0 && errno != EINTR) return lost_errno(errno);
        }
    }
    // the connection (the context and the bound address stay: the worker's next one uses them)
    void drop() {
#if defined(STRATA_DUO_TLS)
        if (ssl_) {
            if (up_) SSL_shutdown(ssl_);   // (close_notify, not waited for; never after a fatal error: lost_tls)
            SSL_free(ssl_);
            ERR_clear_error();
        }
        ssl_ = nullptr, up_ = false;
#endif
        if (fd_ >= 0) ::close(fd_);
        fd_ = -1, until_ = 0;
    }
#if defined(STRATA_DUO_TLS)
    SSL_CTX* ctx_ = nullptr;
    SSL* ssl_ = nullptr;
    bool up_ = false;
    // a TLS read or write that failed for good (the error queue is left for tls_error)
    bool lost_tls(int why, int en) {
        if (why == SSL_ERROR_ZERO_RETURN) return lost(kLeft);   // (its close_notify: ours may still follow)
        up_ = false;   // (SSL_ERROR_SYSCALL / SSL_ERROR_SSL: no SSL_shutdown on this connection any more)
        if (why == SSL_ERROR_SYSCALL) return en == 0 ? lost(kLeft) : lost_errno(en);
        errno_ = EPROTO;
        return lost(kErrno);
    }
    // TLS on the connected fd_, as the worker (server) or the coordinator; on a failure the connection is dropped.
    // The whole of it - the handshake, the checks, the tag - inside one deadline of kHandshakeSeconds.
    bool handshake(bool server, std::string& why) {
        const char* peer = role_name(server ? 2 : 1);
        const auto no = [&](const std::string& w) {
            why = w;
            drop();
            return false;
        };
        const std::string late = "no answer in " + std::to_string(kHandshakeSeconds) + " s";
        deadline(kHandshakeSeconds);   // (a peer that connects and says nothing, or a byte now and then, does not hold the worker)
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
        for (;;) {
            errno = 0;
            const int r = server ? SSL_accept(ssl_) : SSL_connect(ssl_);
            if (r == 1) break;
            const int e = SSL_get_error(ssl_, r);
            if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) return no("TLS handshake: " + tls_error(ssl_));
            if (!wait(e == SSL_ERROR_WANT_READ)) return no("TLS handshake: " + late);
        }
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
        char tag[sizeof kTag] = {};
        errno = 0;
        if (server) {
            if (!put(kTag, sizeof kTag)) return no("TLS: " + (fault_ == kLate ? late : tls_error(ssl_)));
        } else {
            if (!get(tag, sizeof tag))
                return no("the worker refused this host after the TLS handshake: " + (fault_ == kLate ? late : tls_error(ssl_)));
            if (std::memcmp(tag, kTag, sizeof tag) != 0) return no("the peer is not a Strata Duo worker");
        }
        deadline(0);
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
        // a peer host that vanishes sends no FIN: keepalive finds it while this end waits in recv (kDeadSeconds), the
        // retransmission limit while it waits in send - the blocked call then fails with ETIMEDOUT
        ::setsockopt(fd_, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
        int idle = kKeepIdle, intvl = kKeepIntvl, cnt = kKeepCnt;
#if defined(TCP_KEEPALIVE)   // macOS: the idle seconds before the first probe
        ::setsockopt(fd_, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof idle);
#elif defined(TCP_KEEPIDLE)   // Linux
        ::setsockopt(fd_, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof idle);
#endif
#if defined(TCP_KEEPINTVL)
        ::setsockopt(fd_, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
#endif
#if defined(TCP_KEEPCNT)
        ::setsockopt(fd_, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof cnt);
#endif
#if defined(TCP_RXT_CONNDROPTIME)   // macOS: unacknowledged data is given up after this many seconds
        int dead = kDeadSeconds;
        ::setsockopt(fd_, IPPROTO_TCP, TCP_RXT_CONNDROPTIME, &dead, sizeof dead);
#elif defined(TCP_USER_TIMEOUT)   // Linux: the same, in milliseconds
        unsigned dead = (unsigned) kDeadSeconds * 1000;
        ::setsockopt(fd_, IPPROTO_TCP, TCP_USER_TIMEOUT, &dead, sizeof dead);
#endif
        (void) idle, (void) intvl, (void) cnt;
    }
};

}   // namespace strata::ds4::duo
