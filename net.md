# Lyx Network Library (std.net) Implementation Plan

## Executive Summary
This plan outlines the implementation of a cross-platform network library for the Lyx compiler, targeting POSIX (Linux/macOS), Windows, and ESP32 platforms. The solution uses a Hardware Abstraction Layer (HAL) approach with syscall wrappers, a unified event loop abstraction, and a clean Lyx API.

## Core Architecture Overview

```
Lyx Application
    ↓
std.net API (net.TCPListener, net.TCPConn, etc.)
    ↓
Event Loop Abstraction (epoll/kqueue/IOCP)
    ↓
Syscall Wrapper Layer (internal/sys)
    ↓
Platform-Specific Implementations
```

## Phase 1: Foundation & Common Interface (Week 1)

### Objectives
- Define common socket interface
- Implement basic syscall wrappers
- Create blocking I/O prototypes
- Build simple TCP echo server/client

### Files to Create/Modify

#### 1. Common Socket Definitions
`std/net/internal/types.lyx`
```lyx
unit std.net.internal.types;

pub con
  AF_INET: int64 := 2,
  SOCK_STREAM: int64 := 1,
  SOCK_DGRAM: int64 := 2,
  IPPROTO_TCP: int64 := 6,
  IPPROTO_UDP: int64 := 17,
  SOL_SOCKET: int64 := 1,
  SO_REUSEADDR: int64 := 2,
  TCP_NODELAY: int64 := 1,
  SHUT_RD: int64 := 0,
  SHUT_WR: int64 := 1,
  SHUT_RDWR: int64 := 2,
  INVALID_SOCKET: int64 := -1;

pub type NativeSocket = int64;  // Platform-agnostic socket handle
```

#### 2. Syscall Wrapper Layer
`std/net/internal/sys.lyx`
```lyx
unit std.net.internal.sys;

pub fn socket(domain: int64, type: int64, protocol: int64): NativeSocket;
pub fn bind(sockfd: NativeSocket, addr: Pointer, addrlen: int64): int64;
pub fn listen(sockfd: NativeSocket, backlog: int64): int64;
pub fn accept(sockfd: NativeSocket, addr: Pointer, addrlen: Pointer): NativeSocket;
pub fn connect(sockfd: NativeSocket, addr: Pointer, addrlen: int64): int64;
pub fn read(fd: NativeSocket, buf: Pointer, count: int64): int64;
pub fn write(fd: NativeSocket, buf: Pointer, count: int64): int64;
pub fn recvfrom(fd: NativeSocket, buf: Pointer, len: int64, flags: int64,
                src_addr: Pointer, addrlen: Pointer): int64;
pub fn sendto(fd: NativeSocket, buf: Pointer, len: int64, flags: int64,
              dest_addr: Pointer, addrlen: int64): int64;
pub fn close(fd: NativeSocket): int64;
pub fn setsockopt(fd: NativeSocket, level: int64, optname: int64,
                  optval: Pointer, optlen: int64): int64;
pub fn getsockopt(fd: NativeSocket, level: int64, optname: int64,
                  optval: Pointer, optlen: Pointer): int64;
pub fn ioctl(fd: NativeSocket, request: int64, argp: Pointer): int64;
pub fn fcntl(fd: NativeSocket, cmd: int64, arg: int64): int64;
```

#### 3. Platform-Specific Implementations
Create backend-specific files:
- `std/net/internal/sys_linux.lyx`
- `std/net/internal/sys_darwin.lyx`
- `std/net/internal/sys_windows.lyx`
- `std/net/internal/sys_esp32.lyx`

#### 4. Blocking Socket API
`std/net/socket.lyx`
```lyx
unit std.net.socket;

pub type TCPListener = struct {
  fd: NativeSocket;
};

pub type TCPConn = struct {
  fd: NativeSocket;
};

pub type UDPConn = struct {
  fd: NativeSocket;
};

pub type IPAddr = struct {
  family: int64;
  addr: array[uint8, 16];
  port: uint16;
};

pub fn TCPListenerNew(addr: IPAddr): (TCPListener, error);
pub fn (l *TCPListener) Accept(): (TCPConn, error);
pub fn (l *TCPListener) Close(): error;

pub fn TCPConnDial(addr: IPAddr): (TCPConn, error);
pub fn (c *TCPConn) Read(buf: array[uint8]): (int64, error);
pub fn (c *TCPConn) Write(buf: array[uint8]): (int64, error);
pub fn (c *TCPConn) Close(): error;
```

## Phase 2: Event Loop Abstraction (Week 2-3)

### Objectives
- Implement unified event loop abstraction
- Create async versions of socket operations
- Build HTTP client/server demo
- Add TLS support foundation

### Key Components

#### 1. Event Loop Interface
`std/net/internal/poller.lyx`
```lyx
unit std.net.internal.poller;

pub type Event = struct {
  fd: NativeSocket;
  events: int64;  // READ, WRITE, ERROR
  data: Pointer;  // User data
};

pub const
  EVENT_READ: int64 := 1,
  EVENT_WRITE: int64 := 2,
  EVENT_ERROR: int64 := 4;

pub type Poller = struct {
  _impl: Pointer;  // Opaque
};

pub fn PollerNew(): (Poller, error);
pub fn (p *Poller) Add(fd: NativeSocket, events: int64, data: Pointer): error;
pub fn (p *Poller) Wait(timeout_ms: int64): ([]Event, error);
pub fn (p *Poller) Close(): error;
```

#### 2. Platform-Specific Pollers
- `std/net/internal/poller_epoll.lyx` (Linux)
- `std/net/internal/poller_kqueue.lyx` (macOS)
- `std/net/internal/poller_iocp.lyx` (Windows)
- `std/net/internal/poller_esp32.lyx` (ESP32 - simplified)

## Phase 3: Advanced Features (Week 4)

### Objectives
- Add DNS resolution
- Implement TLS support
- Add connection pooling
- Implement HTTP client

### Key Components
- DNS Resolution (`std/net/dns.lyx`)
- TLS Support via mbedTLS (`std/net/tls.lyx`)
- Connection Pooling (`std/net/pool.lyx`)
- HTTP Client (`std/net/http/client.lyx`)

## Phase 4: ESP32 Specialization (Week 5)

### Objectives
- Adapt memory management for ESP32
- Implement LwIP-specific optimizations
- Add WiFi provisioning
- Over-the-air (OTA) updates

## Dependencies & External Libraries

1. **c-ares** - Async DNS resolution (permissive license)
2. **mbedTLS** - TLS support (Apache 2.0)
3. **http-parser** - HTTP parsing (MIT)
4. **LwIP** - Available for ESP32 target

## Risk Mitigation

### Technical Risks
1. ESP32 Memory Constraints → Strict connection limits
2. Windows IOCP Complexity → Select/poll fallback
3. TLS Implementation → Start with mbedTLS
4. Cross-Platform Differences → Unit tests per platform

### Mitigation Strategies
1. Platform-specific unit tests
2. Feature detection over version detection
3. CI/CD with matrix testing (Linux, Windows, macOS, ESP32)

## Success Criteria

### Phase 1 MVP
- TCP echo server/client works on Linux
- Basic UDP functionality
- IP address parsing

### Phase 2 Beta
- Full async API on Linux/Windows
- HTTP 1.1 server/client demo
- Basic TLS support

### Phase 3 RC
- All platforms passing connectivity tests
- DNS resolution working
- Comprehensive test suite

### Phase 4 Release
- ESP32 optimized for memory
- WiFi provisioning
- OTA updates foundation

---

## Current Implementation Status

### ✅ Completed Features

| File | Description |
|------|-------------|
| `std/net/types.lyx` | Constants (AF_INET, SOCK_STREAM, etc.), Types (IPAddr, SockAddrIn, MacAddr, EthernetHeader, ARPPacket), Helpers (Htons, Ntohs, IPPack, IPUnpack), TCP/Socket Options |
| `std/net/socket.lyx` | TCPListener, TCPConn, UDPSocket, RawSocket, ICMP-Ping, ARP packets, Socket Options (Nodelay, KeepAlive, Buffers) |
| `std/net/dns.lyx` | DNS resolver (A records), DNSResolveGoogle, DNSResolveCloudflare |
| `std/net/syscalls.lyx` | Low-level syscall declarations |
| `std/net/internal/types.lyx` | Extended constants + IPv6 structures (SockAddrIn6) |

---

## TODO / Open Items

### High Priority

- [ ] **IPv6 Support** – `SockAddrIn6` struct exists but no implementation uses it
- [x] **TCP Options** – Missing `setsockopt(TCP_NODELAY)`, `SO_KEEPALIVE` ✅
- [x] **getsockopt** – Declared in syscalls but never used (socket state queries) ✅
- [x] **ParseIPAddr** – Only 3 hardcoded cases, needs proper string parsing ✅

### Medium Priority

- [ ] **Non-blocking I/O** – Only basic `MSG_DONTWAIT` support
- [ ] **select/poll** – No multiplexing functions
- [ ] **Unix Domain Sockets** – `AF_UNIX` constant exists but no implementation
- [ ] **Async connect** – No `EINPROGRESS` handling

### Low Priority

- [x] **Full DNS** – Only A records, missing AAAA, MX, CNAME resolution ✅
- [ ] **Stack Allocation** – All functions use `mmap` for temporary structures (performance)
- [ ] **Hostname Resolution** – No `gethostbyname`, only IP-based operations
- [ ] **Connection Pooling** – Not implemented yet
- [ ] **HTTP Client** – Not implemented yet
- [ ] **TLS Support** – Not implemented yet
