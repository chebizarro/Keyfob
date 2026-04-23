---
id: KF-7
title: "KeyfobActionExt has no Swift implementation"
priority: 1
category: missing-implementation
status: fixed
created: 2026-04-22
---

## Problem
Info.plist references ActionExtension as principal class but no Swift file exists in Extensions/KeyfobActionExt/.

## Affected Files
- Extensions/KeyfobActionExt/

## Fix Strategy
Implement ActionExtension class or remove the target.
