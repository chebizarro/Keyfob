// Minimal NIP-07 provider interface to be injected by Safari extensions
export interface NostrProvider {
  getPublicKey(): Promise<string>;
  signEvent(evt: any): Promise<any>;
}

export const KeyfobBridge = {
  // iOS: use Universal Link to handoff; macOS: use XPC messaging (implemented by the extension)
  async getPublicKey(): Promise<string> {
    // Placeholder: filled by extension runtime
    throw new Error('Not implemented in shared layer.');
  },
  async signEvent(evt: any): Promise<any> {
    throw new Error('Not implemented in shared layer.');
  }
};
