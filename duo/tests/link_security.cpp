// No model: transport security, bounded handshake, bad magic, killed/stopped peers and sampled fingerprints.
#include "ds4_duo.hpp"
#include <atomic>
#include <csignal>
#include <sys/wait.h>
#include <thread>
using namespace strata::ds4;

static int fails = 0;
static void check(const char* name, bool ok) {
    std::printf("%s  %s\n", ok ? "PASS" : "FAIL", name);
    std::fflush(stdout);
    if (!ok) ++fails;
}
static pid_t worker(const std::string& addr, const std::string& certs, bool two = false) {
    const pid_t p = fork();
    if (p == 0) {
        duo::Link l;
        std::string e;
        if (!l.accept_one(addr, "127.0.0.1", certs, certs.empty(), e, two)) _exit(2);
        if (two) {
            duo::Head h;
            if (l.recv_head(h) || !l.bad_head() || l.peer_left()) _exit(3);
            l.refuse();
            if (!l.accept_one(addr, "127.0.0.1", certs, certs.empty(), e, true)) _exit(4);
            l.stop_listening();
            if (!l.send(duo::kOk)) _exit(5);
            _exit(0);
        }
        char go;
        if (!l.get(&go, 1)) _exit(6);
        if (!l.put(&go, 1)) _exit(7);
        _exit(0);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    return p;
}
static void reap(pid_t p) { int st; waitpid(p, &st, 0); }
int main(int argc, char** argv) {
    if (argc != 4) { std::fprintf(stderr, "link_security PORT CERTS_DIR SCRATCH_FILE\n"); return 2; }
    std::signal(SIGPIPE, SIG_IGN);
    int port = std::atoi(argv[1]);
    const std::string certs = argv[2];
    auto addr = [&] { return "127.0.0.1:" + std::to_string(port++); };
    {
        duo::Link l;
        std::string e;
        check("insecure worker without allow refused before listening", !l.accept_one(addr(), "", "", true, e) && e.find("--duo-allow") != std::string::npos);
    }
#if defined(STRATA_DUO_TLS)
    {
        const std::string key = duo::role_file(certs, 1, ".key");
        chmod(key.c_str(), 0644);
        std::string e;
        SSL_CTX* ctx = duo::tls_context(1, certs, e);
        check("group/world-readable private key refused with chmod 600 advice", !ctx && e.find("chmod 600") != std::string::npos && e.find(key) != std::string::npos);
        if (ctx) SSL_CTX_free(ctx);
        chmod(key.c_str(), 0600);
    }
#endif
    for (const std::string c : {std::string(), certs}) {
        std::string a = addr(), e;
        pid_t p = worker(a, c);
        duo::Link l;
        bool ok = l.connect_to(a, c, c.empty(), e);
        check(c.empty() ? "plain peer connected" : "TLS peer connected", ok);
        if (!ok) { kill(p, SIGKILL); reap(p); continue; }
        kill(p, SIGKILL);
        reap(p);
        const int64_t t0 = duo::tick_ms();
        char byte;
        ok = !l.get(&byte, 1) && duo::tick_ms() - t0 < 2000;
        check(c.empty() ? "killed plain peer releases blocked read" : "killed TLS peer releases blocked read", ok);
        std::printf("link failure: %s\n", l.why().c_str());
        l.close();   // a fatal TLS read must not attempt SSL_shutdown
    }
    {
        std::string a = addr(), e;
        pid_t p = worker(a, "", true);
        duo::Link l;
        bool ok = l.connect_to(a, "", true, e);
        duo::Head h;
        h.magic = 0;
        ok = ok && l.put(&h, sizeof h);
        l.close();
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        duo::Link next;
        ok = ok && next.connect_to(a, "", true, e) && next.recv_head(h) && h.op == duo::kOk;
        check("bad header distinct from EOF; refused peer keeps listener available", ok);
        if (!ok) kill(p, SIGKILL);
        reap(p);
    }
#if defined(STRATA_DUO_TLS)
    {
        std::string a = addr(), ip, e;
        int pt;
        duo::split_addr(a, ip, pt);
        pid_t p = worker(a, certs);
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in sa{};
        sa.sin_family = AF_INET; sa.sin_port = htons((uint16_t) pt);
        inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
        const int64_t t0 = duo::tick_ms();
        bool ok = connect(fd, (sockaddr*) &sa, sizeof sa) == 0;
        // A TLS record header, then one byte every second. The entire handshake must still expire at 10 s.
        const char header[] = {0x16, 0x03, 0x01, 0x10, 0x00};
        send(fd, header, sizeof header, duo::kSendFlags);
        for (int i = 0; i < 12; ++i) {
            char b = 1;
            send(fd, &b, 1, duo::kSendFlags);
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
        char b;
        const ssize_t n = recv(fd, &b, 1, MSG_DONTWAIT);
        ok = ok && (n == 0 || (n < 0 && errno == ECONNRESET));
        close(fd);
        duo::Link l;
        ok = ok && l.connect_to(a, certs, false, e) && l.put("x", 1) && l.get(&b, 1);
        check("slow-byte TLS handshake has a whole deadline; next peer accepted", ok && duo::tick_ms() - t0 < 15000);
        if (!ok) kill(p, SIGKILL);
        reap(p);
    }
#endif
    {
        std::string a = addr(), e;
        pid_t p = worker(a, "");
        duo::Link l;
        bool ok = l.connect_to(a, "", true, e);
        kill(p, SIGSTOP);
        std::atomic<bool> done{false};
        char b = 0;
        bool got = false;
        std::thread reader([&] { got = l.get(&b, 1); done.store(true); });
        std::this_thread::sleep_for(std::chrono::seconds(duo::kDeadSeconds + 2));
        check("SIGSTOP is not a dead TCP host: read remains blocked beyond keepalive budget", ok && !done.load());
        kill(p, SIGCONT);
        l.put("r", 1);
        reader.join();
        check("resuming the stopped process completes the long read without a false timeout", got && b == 'r');
        reap(p);
    }
    {
        int fd = open(argv[3], O_RDWR | O_CREAT | O_TRUNC, 0600);
        const uint64_t size = 150ull * 1024 * 1024 * 1024;
        uint64_t a = 0, b = 0, c = 0;
        bool ok = fd >= 0 && ftruncate(fd, (off_t) size) == 0;
        const int64_t t0 = duo::tick_ms();
        ok = ok && duo::file_print(fd, size, a) && duo::file_print(fd, size, b) && a == b;
        check("150 GiB sparse-file fingerprint deterministic and under 1 s", ok && duo::tick_ms() - t0 < 1000);
        pwrite(fd, "different", 9, 0);
        ok = duo::file_print(fd, size, c);
        check("same file size, different header content gives different fingerprint", ok && a != c);
        pwrite(fd, "different", 9, (off_t) size - 9);
        ok = duo::file_print(fd, size, b);
        check("tail content included in fingerprint", ok && b != c);
        close(fd);
        unlink(argv[3]);
    }
    check("peer text bounded and printable ASCII only", duo::printable("hello\n\033[31m\xff", 9) == "hello??[3...");
    std::printf("RESULT: %d link security failures\n", fails);
    return fails ? 1 : 0;
}
