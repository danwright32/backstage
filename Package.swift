// swift-tools-version: 6.0
import PackageDescription

// Shared Google sign in and Gmail sending for Ovation, Overture and Downbeat.
//
// macOS ONLY, and that is a statement about the code rather than a preference:
// the sources import AppKit (to open the consent page in the person's browser)
// and Network (for the loopback listener that catches Google's redirect back).
// Neither exists on Linux. backstage#2.
let package = Package(
    name: "BackstageGoogle",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackstageGoogle", targets: ["BackstageGoogle"]),
    ],
    targets: [
        .target(name: "BackstageGoogle"),
        .testTarget(name: "BackstageGoogleTests", dependencies: ["BackstageGoogle"]),
    ]
)
