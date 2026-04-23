---
id: KF-2
title: "Key export encryption is a plaintext JSON stub"
priority: 0
category: fake-completion
status: fixed
created: 2026-04-22
---

## Problem
KeyManager.exportEncrypted(password:) returns plaintext JSON containing the raw private key in base64. The TODO says "Replace with Argon2id + ChaCha20-Poly1305" but no encryption exists.

## Evidence
KeyManager.swift:75-83 - payload dict with raw sk is returned as-is.

## Affected Files
- Sources/KeyfobCrypto/KeyManager.swift

## Why Not Production-Ready
Exposes raw private keys in plaintext despite function name implying encryption. Data loss / key compromise risk.

## Fix Strategy
Implement real encryption using CryptoKit (HKDF + AES-GCM minimum). Until then, throw unimplemented error.
