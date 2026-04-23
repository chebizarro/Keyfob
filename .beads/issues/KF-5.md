---
id: KF-5
title: "Dual NIP-01 serialization paths disagree on format"
priority: 1
category: correctness
status: fixed
created: 2026-04-22
---

## Problem
Two independent NIP-01 serialization implementations:
1. CanonicalJSON.serializeEvent() produces {object with sorted keys}
2. Signer.computeNIP01Id() produces [0,pubkey,created_at,kind,tags,content] (correct NIP-01 array)
CanonicalJSON is used for display only, but its name implies authority.

## Affected Files
- Sources/KeyfobCore/CanonicalJSON.swift
- Sources/KeyfobCrypto/Signer.swift
- Sources/KeyfobCore/Orchestrator.swift

## Fix Strategy
Consolidate to single authoritative NIP-01 serialization. Rename CanonicalJSON to EventDisplayJSON or merge.
