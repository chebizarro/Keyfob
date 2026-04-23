---
id: KF-3
title: "PolicyEngine consent fallback checks biometric availability but never authenticates"
priority: 0
category: fake-completion
status: fixed
created: 2026-04-22
---

## Problem
When no consentProvider is set, PolicyEngine.requestConsent() calls canEvaluatePolicy() but never evaluatePolicy(). It checks if biometrics exist, not whether user authenticates. Signing proceeds without user interaction.

## Evidence
PolicyEngine.swift:66-76 - Falls through after canEvaluatePolicy with no evaluatePolicy call.

## Affected Files
- Sources/KeyfobPolicy/PolicyEngine.swift

## Why Not Production-Ready
Security bypass: on any biometric-capable device, signing proceeds without consent.

## Fix Strategy
Either always require a real consentProvider (throw if nil), or call evaluatePolicy() in the fallback.
