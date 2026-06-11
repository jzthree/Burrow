import Darwin
import Foundation

/// Probes whether the *remote service* behind a local SSH forward is actually
/// accepting connections — distinct from "ssh owns the local port."
///
/// Connecting to the local listener always succeeds (ssh accepts immediately),
/// so the reliable signal is what ssh does next: when the remote destination
/// refuses, ssh opens the forwarded channel, the remote rejects it, and ssh
/// closes the local connection — the client sees EOF within a few hundred ms.
/// If the remote accepts, the connection stays open (or the service sends a
/// banner). So: connect, then wait briefly for an early EOF.
public enum ForwardProbe {
    public enum Result: Sendable {
        case reachable
        case unreachable
        case unknown
    }

    public static func probe(host: String, port: Int, settleMilliseconds: Int = 400) -> Result {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            return .unknown
        }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        addr.sin_addr.s_addr = inet_addr(host == "localhost" ? "127.0.0.1" : host)

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            // Nothing is listening locally at all (ssh not bound) — not our job
            // to interpret; report unknown so callers fall back to other state.
            return .unknown
        }

        // Poll for an early EOF/error: ssh closes the socket when the remote
        // destination refuses the forwarded channel.
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32(settleMilliseconds))
        if ready > 0 {
            if pfd.revents & Int16(POLLHUP | POLLERR) != 0 {
                return .unreachable
            }
            if pfd.revents & Int16(POLLIN) != 0 {
                // Readable: either a banner (reachable) or EOF (closed).
                var byte: UInt8 = 0
                let n = recv(fd, &byte, 1, Int32(MSG_PEEK))
                return n == 0 ? .unreachable : .reachable
            }
        }
        // Still open with no data after the settle window → service accepted
        // the connection and is just quiet (e.g. a server awaiting a request).
        return .reachable
    }
}
