// Strata Duo: one DeepSeek V4.1 model over two hosts, split by layers at a cut K.
//
// The prefix host (the worker) holds layers [0, K) and the Engram rows; the suffix host (the coordinator) holds
// layers [K, nl), the head and the sampler, and is the one a server talks to.  Both processes are this same engine
// with the same pack: the coordinator repeats every call that changes the conversation's state (a window's tokens,
// reset, checkpoint, mark, pin, restore) to the worker, which runs it on its own layers, and a window's hand-off
// (h | pre | topk | cand, what a device change moves in forward_serial) comes back over the link.
//
// The link here is a plain TCP stream between two addresses of a private point-to-point network (the worker binds
// one address and admits one peer address).  It carries token ids and activations unencrypted: use it on a direct
// cable only.  (A TLS transport replaces it before this leaves the bench.)
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
#include <unistd.h>

namespace strata::ds4::duo {

enum Op : uint32_t { kHello = 1, kOk = 2, kErr = 3, kForward = 4, kHand = 5, kReset = 6, kCheckpoint = 7, kMark = 8, kPin = 9,
                     kRestore = 10, kBye = 11 };

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

class Link {
public:
    ~Link() { close(); }
    bool open() const { return fd_ >= 0; }
    void close() {
        if (fd_ >= 0) ::close(fd_);
        fd_ = -1;
    }
    // the worker: bind `addr` (ip:port), take one connection, from `allow` only (an ip; empty: any)
    bool accept_one(const std::string& addr, const std::string& allow, std::string& err) {
        std::string ip;
        int port = 0;
        if (!split_addr(addr, ip, port)) return fail(err, "--duo-listen wants ip:port");
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
                std::fprintf(stderr, "ds4 duo: refused a connection from %s\n", pip);
                ::close(fd);
                continue;
            }
            fd_ = fd;
            break;
        }
        ::close(ls);
        tune();
        return true;
    }
    bool connect_to(const std::string& addr, std::string& err) {
        std::string ip;
        int port = 0;
        if (!split_addr(addr, ip, port)) return fail(err, "--duo-connect wants ip:port");
        fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd_ < 0) return fail(err, "socket");
        sockaddr_in sa{};
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t) port);
        if (::inet_pton(AF_INET, ip.c_str(), &sa.sin_addr) != 1) return fail(err, "--duo-connect: not an IPv4 address");
        if (::connect(fd_, (sockaddr*) &sa, sizeof sa) != 0) return fail(err, "connect " + addr + ": " + std::strerror(errno));
        tune();
        return true;
    }
    bool put(const void* p, size_t n) {
        const char* q = (const char*) p;
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
