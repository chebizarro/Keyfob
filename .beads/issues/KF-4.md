---
id: KF-4
title: "PolicyEngine singleton has no thread safety for mutable state"
priority: 0
category: reliability-gap
status: fixed
created: 2026-04-22
---

## Problem
PolicyEngine.shared is accessed from multiple threads (main, XPC, URL handlers) but all mutable state (origins, allowedCallers, sessions, buckets) has zero synchronization.

## Evidence
Dictionaries and sets mutated from XPC threads, UI threads, and URL handler threads concurrently without locks.

## Affected Files
- Sources/KeyfobPolicy/PolicyEngine.swift

## Why Not Production-Ready
Concurrent dictionary/set mutation in Swift causes crashes and data corruption.

## Fix Strategy
Add serial DispatchQueue or NSLock to synchronize all mutable state access.
