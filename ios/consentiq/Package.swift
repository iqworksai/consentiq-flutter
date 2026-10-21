// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "consentiq",
  platforms: [
    .iOS("12.0")
  ],
  products: [
    .library(name: "consentiq", targets: ["consentiq"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "consentiq",
      dependencies: [],
      resources: [
        .process("PrivacyInfo.xcprivacy")
      ]
    )
  ]
)
