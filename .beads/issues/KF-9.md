---
id: KF-9
title: "Callback page posts signing results with wildcard targetOrigin"
priority: 1
category: security-gap
status: fixed
created: 2026-04-22
---

## Problem
callback.html sends signing results via postMessage with wildcard "*" origin. Any page that opened this window receives signed event data.

## Evidence
window.opener.postMessage({ __keyfob_cb__: cbId, payload }, '*');

## Affected Files
- Web/demo/callback.html

## Fix Strategy
Pass requesting origin through the flow and use as targetOrigin.
