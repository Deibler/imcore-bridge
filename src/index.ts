export { ImcoreBridge } from "./client.js";
export { launch, injectMessages, quitMessages, isMessagesRunning } from "./launch.js";
export { supervise, Supervisor } from "./supervisor.js";
export { stageAttachment, stagingRoot, AttachmentSendError } from "./attachments.js";
export type { LaunchOptions, InjectOptions } from "./launch.js";
export type { SuperviseOptions } from "./supervisor.js";

export {
  defaultSocketPath,
  defaultDylibPath,
  containerDir,
  MESSAGES_BINARY,
  MESSAGES_BUNDLE_ID,
} from "./paths.js";

export {
  ImcoreBridgeError,
  BridgeUnavailableError,
  UnsupportedFeatureError,
  RpcTimeoutError,
  ChatNotFoundError,
  MessageNotFoundError,
  RpcError,
} from "./errors.js";

export type {
  Attachment,
  Tapback,
  Mention,
  Link,
  BridgeEvent,
  BridgeStatus,
  Capabilities,
  Capability,
  Chat,
  ClientOptions,
  Message,
  MessageKind,
  Person,
  SearchHit,
  SearchKind,
  SearchLabel,
  SearchOptions,
  SearchResults,
  SendOptions,
  SendStatus,
  StoreHistory,
  StoreHistoryOptions,
  StoredMessage,
  TapbackKind,
} from "./types.js";

/**
 * Expressive effect identifiers, as observed in real messages.
 *
 * Bubble effects animate the message; screen effects take over the window.
 * Pass one as `effect` to {@link ImcoreBridge.send}.
 */
export const Effects = {
  bubble: {
    impact: "com.apple.MobileSMS.expressivesend.impact",
    loud: "com.apple.MobileSMS.expressivesend.loud",
    gentle: "com.apple.MobileSMS.expressivesend.gentle",
    invisibleInk: "com.apple.MobileSMS.expressivesend.invisibleink",
  },
  screen: {
    echo: "com.apple.messages.effect.CKEchoEffect",
    confetti: "com.apple.messages.effect.CKConfettiEffect",
    happyBirthday: "com.apple.messages.effect.CKHappyBirthdayEffect",
    fireworks: "com.apple.messages.effect.CKFireworksEffect",
    lasers: "com.apple.messages.effect.CKLasersEffect",
    balloons: "com.apple.messages.effect.CKBalloonsEffect",
    spotlight: "com.apple.messages.effect.CKSpotlightEffect",
    shootingStar: "com.apple.messages.effect.CKShootingStarEffect",
    heart: "com.apple.messages.effect.CKHeartEffect",
    sparkles: "com.apple.messages.effect.CKSparklesEffect",
  },
} as const;
