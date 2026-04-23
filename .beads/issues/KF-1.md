---
id: KF-1
title: "Hardcoded placeholder identifiers throughout codebase"
priority: 0
category: unsafe-hardcoding
status: fixed
created: 2026-04-22
---

## Problem
Every bundle identifier, access group, app group, XPC service name, and Universal Link host uses placeholder values that cannot work in production.

## Evidence
- KeyManager.swift:21 - accessGroup = "TODO_TEAMID.com.yourorg.keyfob.shared"
- PolicyEngine.swift:9 - appGroup = "group.com.yourorg.keyfob"
- URLRouter.swift:9 - ulHost = "keyfob.example.com"
- XPCClient.swift:9 - serviceName = "TODO.com.yourorg.keyfob.mac.xpc"
- SafariExtensionHandler.swift:6 - xpcServiceName = "TODO.com.yourorg.keyfob.mac.xpc"
- All Info.plist files use TODO.com.yourorg.keyfob.* bundle IDs
- content.js:4 (SafariWE) - UL_BASE = "https://keyfob.example.com/app"
- All entitlements files are empty dict

## Affected Files
- Sources/KeyfobCrypto/KeyManager.swift
- Sources/KeyfobPolicy/PolicyEngine.swift
- Sources/KeyfobBridge/URLRouter.swift
- Apps/Keyfob-macOS/XPCClient.swift
- Extensions/KeyfobSafariAE/SafariExtensionHandler.swift
- Extensions/KeyfobSafariWE/content.js
- All Info.plist files, All .entitlements files
- Build/xcodegen/project.yml

## Why Not Production-Ready
Nothing works: Keychain access fails, App Group container returns nil, XPC connections fail, Universal Links do not resolve.

## Fix Strategy
Centralize identifiers into build configuration. Replace all TODOs with real values or xcconfig-driven variables. Populate entitlements.
