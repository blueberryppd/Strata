// The Duo link alone, on loopback: a worker thread answers each 36-byte call (a Head and one token id) with a 92 KB
// hand-off, as a decode step does.  Prints the round trip's time, plain (no directory) or TLS (a certificate directory).
//   link_bench PORT ROUNDS [CERTS_DIR]
#include "ds4_duo.hpp"
#include <algorithm>
#include <chrono>
#include <thread>
#include <vector>
using namespace strata::ds4;
int main(int argc, char** argv) {
    if (argc < 3) return 2;
    const std::string addr = std::string("127.0.0.1:") + argv[1], certs = argc > 3 ? argv[3] : "";
    const int rounds = std::atoi(argv[2]);
    const size_t big = 92 * 1024;
    const bool insecure = certs.empty();
    std::thread worker([&] {
        duo::Link l;
        std::string err;
        if (!l.accept_one(addr, "127.0.0.1", certs, insecure, err)) { std::fprintf(stderr, "worker: %s\n", err.c_str()); return; }
        std::vector<char> out(big, 'x');
        duo::Head h;
        int32_t tk;
        while (l.recv_head(h) && h.op == duo::kForward && l.get(&tk, 4)) l.send(duo::kHand, 1, 0, out.data(), out.size());
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    duo::Link l;
    std::string err;
    if (!l.connect_to(addr, certs, insecure, err)) { std::fprintf(stderr, "coordinator: %s\n", err.c_str()); return 1; }
    std::vector<char> in(big);
    std::vector<double> us;
    int32_t tk = 7;
    duo::Head h;
    for (int i = 0; i < rounds + 200; ++i) {
        const auto t0 = std::chrono::steady_clock::now();
        if (!l.send(duo::kForward, i, 1, &tk, 4) || !l.recv_head(h) || h.bytes != big || !l.get(in.data(), big)) return 1;
        if (i >= 200) us.push_back(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count());
    }
    l.send(duo::kBye);
    l.close();
    worker.join();
    std::sort(us.begin(), us.end());
    std::printf("%s: %d round trips (36 B out, %zu B back): median %.1f us, p90 %.1f us, p99 %.1f us, min %.1f us\n",
                insecure ? "plain" : "TLS", rounds, big + sizeof h, us[us.size() / 2], us[us.size() * 9 / 10], us[us.size() * 99 / 100], us[0]);
    return 0;
}
