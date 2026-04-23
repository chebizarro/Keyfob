---
id: KF-8
title: "KeyfobHostDemo references undefined DemoAppDelegate"
priority: 1
category: missing-implementation
status: fixed
created: 2026-04-22
---

## Problem
Apps/KeyfobHostDemo/Main.swift references DemoAppDelegate via UIApplicationDelegateAdaptor but the class is never defined.

## Affected Files
- Apps/KeyfobHostDemo/Main.swift

## Fix Strategy
Create DemoAppDelegate class or remove the adaptor.
