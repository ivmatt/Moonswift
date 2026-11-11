// swift-tools-version: 6.0
import PackageDescription

// Builds moonlight-common-c (GPLv3) and the mbedTLS crypto it uses from the pinned git submodules,
// with the same settings as upstream's CMake build (CMakeLists.txt, enet/CMakeLists.txt).

// Both libraries share these: mbedTLS's PSA crypto is called from several streaming threads, so it needs locking.
let mbedTLSThreading: [CSetting] = [
    .define("MBEDTLS_THREADING_C"),
    .define("MBEDTLS_THREADING_PTHREAD"),
]

let package = Package(
    name: "MoonlightCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MoonlightCore", targets: ["MoonlightCore"]),
    ],
    targets: [
        // Swift imports this: Limelight.h plus a shim for the printf-style log callback Swift can't implement.
        .target(
            name: "MoonlightCore",
            dependencies: ["MoonlightCommonC"],
            path: "Sources/MoonlightCore"
        ),
        .target(
            name: "MoonlightCommonC",
            dependencies: ["MbedCrypto"],
            path: "moonlight-common-c",
            sources: [
                "src",
                "enet/callbacks.c", "enet/compress.c", "enet/host.c", "enet/list.c",
                "enet/packet.c", "enet/peer.c", "enet/protocol.c", "enet/unix.c",
                "nanors/rs.c", "nanors/deps/obl/oblas_common.c", "nanors/deps/obl/oblas_lite.c",
            ],
            publicHeadersPath: "enet/include", // must exist; MoonlightCore is what exposes Limelight.h
            cSettings: mbedTLSThreading + [
                .headerSearchPath("nanors"),
                .headerSearchPath("nanors/deps"),
                .headerSearchPath("nanors/deps/obl"),
                .define("USE_MBEDTLS"),
                .define("__APPLE_USE_RFC_3542"), // IPV6_PKTINFO and friends, as moonlight-ios defines
                // What enet's CMake feature checks find on Apple platforms (no gethostbyname_r there).
                .define("HAS_SOCKLEN_T"), .define("HAS_FCNTL"), .define("HAS_IOCTL"), .define("HAS_POLL"),
                .define("HAS_GETADDRINFO"), .define("HAS_GETNAMEINFO"), .define("HAS_INET_PTON"),
                .define("HAS_INET_NTOP"), .define("HAS_MSGHDR_FLAGS"),
                .define("LC_DEBUG", .when(configuration: .debug)),
                .define("NDEBUG", .when(configuration: .release)),
                .unsafeFlags(["-w"]), // third-party code: don't flood the app's build with its warnings
            ]
        ),
        .target(
            name: "MbedCrypto",
            path: "mbedtls",
            sources: ["library"],
            publicHeadersPath: "include",
            cSettings: mbedTLSThreading + [
                .headerSearchPath("library"),
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)
