// ──────────────────────────────────────────────────────────────────
// nostr-provider.ts — Shared NIP-07 types and messaging constants
// ──────────────────────────────────────────────────────────────────
//
// This file is the TypeScript source-of-truth for the types and
// constants shared between the Safari Web Extension content script
// and the Safari App Extension content script. The equivalent Swift
// constants live in Placeholder.swift (KeyfobWebShared target).
//
// NOTE: This file is NOT compiled by SPM. It is a reference/resource
// for the web extension build pipeline.
// ──────────────────────────────────────────────────────────────────

// ── NIP-07 Types ─────────────────────────────────────────────────

/** A Nostr event as submitted by the web page (unsigned). */
export interface NIP07UnsignedEvent {
  kind: number;
  created_at: number;
  tags: string[][];
  content: string;
}

/** A fully-signed Nostr event returned to the web page. */
export interface NIP07SignedEvent extends NIP07UnsignedEvent {
  id: string;
  pubkey: string;
  sig: string;
}

/**
 * The `window.nostr` interface defined by NIP-07.
 *
 * @see https://github.com/nostr-protocol/nips/blob/master/07.md
 */
export interface NostrProvider {
  getPublicKey(): Promise<string>;
  signEvent(event: NIP07UnsignedEvent): Promise<NIP07SignedEvent>;
}

// ── Messaging Constants (keep in sync with Swift WebMessageName) ─

/** Message names for Safari App Extension native messaging. */
export const MessageName = {
  /** JS → Native: request the user's Nostr public key. */
  getPublicKey: "keyfob_getPublicKey",
  /** JS → Native: request a Nostr event signature. */
  signEvent: "keyfob_signEvent",
  /** Native → JS: response envelope for both methods. */
  response: "keyfob_response",
} as const;

/** Keys in the native-message userInfo dictionaries. */
export const MessageKey = {
  reqId: "reqId",
  ok: "ok",
  pubkey: "pubkey",
  id: "id",
  sig: "sig",
  msg: "msg",
  eventJSON: "eventJSON",
  origin: "origin",
  callback: "cb",
} as const;

/** Numeric status codes in the `ok` field. */
export const Status = {
  success: 1,
  failure: 0,
} as const;

// ── Response Type ────────────────────────────────────────────────

/** Native → JS response payload. */
export interface NativeResponse {
  ok: number;
  reqId: string;
  pubkey?: string;
  id?: string;
  sig?: string;
  msg?: string;
}

// ── Universal Link Handoff ───────────────────────────────────────

/** URL path segments for Universal Link handoff (Web Extension). */
export const HandoffPath = {
  pubkey: "pubkey",
  sign: "sign",
} as const;

/** Callback postMessage envelope sent back to the opener. */
export interface CallbackPayload {
  __keyfob_cb__: string;
  payload: {
    ok?: string;
    pubkey?: string;
    id?: string;
    sig?: string;
    msg?: string;
  };
}
