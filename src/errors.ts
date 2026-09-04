/**
 * Base class for every error this library raises.
 *
 * `code` is the identifier the bridge sent, carried on every error rather than
 * only the unrecognised ones, so a caller can branch on it without having to
 * know which errors got a class of their own.
 */
export class ImcoreBridgeError extends Error {
  constructor(message: string, readonly code?: string) {
    super(message);
    this.name = new.target.name;
  }
}

/** No injected bridge is connected: not installed, not launched, or Messages is not running. */
export class BridgeUnavailableError extends ImcoreBridgeError {}

/**
 * The running Messages build does not offer this capability.
 *
 * Distinct from a bug: private selectors move between macOS releases, and the
 * bridge reports per-feature availability rather than failing wholesale.
 */
export class UnsupportedFeatureError extends ImcoreBridgeError {
  constructor(readonly feature: string, message?: string) {
    super(
      message ?? `feature '${feature}' is unavailable on this macOS build`,
      "unsupported_feature",
    );
  }
}

/** Messages accepted the request but did not answer within the timeout. */
export class RpcTimeoutError extends ImcoreBridgeError {
  constructor(readonly method: string, readonly timeoutMs: number) {
    super(`'${method}' did not respond within ${timeoutMs}ms`, "timeout");
  }
}

/** No conversation matched the given GUID, chat identifier, or handle. */
export class ChatNotFoundError extends ImcoreBridgeError {
  constructor(message: string) {
    super(message, "chat_not_found");
  }
}

/**
 * No such message.
 *
 * Ordinary rather than exceptional when resolving a search hit: the search
 * index is not pruned when a message is deleted, so an old hit can name a
 * message the store no longer has.
 */
export class MessageNotFoundError extends ImcoreBridgeError {
  constructor(message: string) {
    super(message, "message_not_found");
  }
}

/** The bridge rejected the request, or IMCore refused the operation. */
export class RpcError extends ImcoreBridgeError {
  declare readonly code: string;
  constructor(code: string, message: string) {
    super(message, code);
  }
}

/** Maps a wire error onto the most specific class available. */
export function errorFromWire(code: string, message: string, method: string): ImcoreBridgeError {
  switch (code) {
    case "chat_not_found":
      return new ChatNotFoundError(message);
    case "message_not_found":
      return new MessageNotFoundError(message);
    case "unsupported_feature":
    case "unsupported_combination":
      return new UnsupportedFeatureError(method, message);
    case "timeout":
      return new RpcTimeoutError(method, 0);
    case "not_ready":
      return new BridgeUnavailableError(message);
    case "chat_poisoned":
    case "self_send_blocked":
    case "chat_mismatch":
    case "service_mismatch":
      // Permanent for this payload: the same message to the same chat will be
      // refused the same way until the operator acts, so callers must not
      // treat it as a transient send failure and retry. chat_mismatch is the
      // resolution invariant (the chat a spec resolved to is not the
      // conversation it addressed); service_mismatch is a caller naming a
      // service the chat is not on — account forcing was removed because it
      // is what poisoned imagent's chat registration.
      return new RpcError(code, message);
    default:
      return new RpcError(code, message);
  }
}
