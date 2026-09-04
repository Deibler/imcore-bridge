/** Features the running Messages build supports, from live selector probes. */
export interface Capabilities {
  typing: boolean;
  typingData: boolean;
  send: boolean;
  reply: boolean;
  subject: boolean;
  /** Choosing whether one message goes out over iMessage or as a text. */
  sendService: boolean;
  effect: boolean;
  effectWithAttachments: boolean;
  attachments: boolean;
  tapback: boolean;
  /**
   * Reacting with an arbitrary emoji rather than one of the six classic
   * tapbacks. Reported separately because it goes through different IMCore
   * classes, so it can be missing on a build where `tapback` works.
   */
  emojiTapback: boolean;
  /** Silencing a conversation — the app's Hide Alerts. */
  mute: boolean;
  /** Emptying a conversation of its messages. */
  deleteHistory: boolean;
  /** Reporting a conversation to Apple as junk. */
  reportJunk: boolean;
  /** Listing the unread messages that mention this account. */
  mentions: boolean;
  /** Resending a failed iMessage over SMS. */
  sendAsText: boolean;
  /** Sharing this account's location with a conversation. */
  shareLocation: boolean;
  retract: boolean;
  edit: boolean;
  groupRename: boolean;
  groupPhoto: boolean;
  groupAdd: boolean;
  groupRemove: boolean;
  groupLeave: boolean;
  /** Search over the index Messages maintains. */
  search: boolean;
  /** Ranked search, which adds image classification and semantic matching. */
  searchRanked: boolean;
  /** Deep history and search-hit resolution from the message store. */
  store: boolean;
  /** Creating polls and voting in them. */
  poll: boolean;
  /** Reading contact pictures. */
  avatars: boolean;
  /** Scheduling a message for later delivery, and cancelling one. */
  sendLater: boolean;
  /** Sending a file as a sticker rather than as an ordinary attachment. */
  stickers: boolean;
  /** Sticking a sticker onto an existing bubble rather than sending it alone. */
  stickerAttach: boolean;
  /** Removing a conversation, as against emptying it. */
  deleteChat: boolean;
  /** Sending this account's own Name & Photo to someone. */
  shareNameAndPhoto: boolean;
  /**
   * Asking whether a membership change will be acted on before making it.
   * Without it both calls still work — they just fail silently, as they did
   * before, so this reports whether a refusal can be reported.
   */
  groupPreconditions: boolean;
  /** Returning a conversation to unread. */
  markUnread: boolean;
  /** Pushing one message past a recipient's mute or Focus. */
  notifyAnyway: boolean;
  /** Pinning a conversation to the top of the list. */
  pin: boolean;
  /** Reading the signed-in Apple ID, its aliases and SMS relay state. */
  account: boolean;
  /** Changing which vetted alias outgoing messages are attributed to. */
  sendingAlias: boolean;
  /** Reading the Name & Photo cards people have shared. */
  nicknames: boolean;
  /** Counts and distributions over the message store. */
  stats: boolean;
  events: boolean;
}

/** The signed-in messaging identity for one service. */
export interface AccountIdentity {
  /** Apple ID the account is signed in as. */
  appleID?: string;
  /** Name on the account. */
  name?: string;
  /** Every address that reaches this account. */
  aliases: string[];
  /** The subset Apple has verified — only these can be sent from. */
  vettedAliases: string[];
  /** Which alias outgoing messages are currently attributed to. */
  sendingAs?: string;
  /** Connection state, as Messages words it. */
  status?: string;
  registered?: boolean;
  /** Whether this Mac can relay texts from a paired iPhone. */
  smsRelayCapable?: boolean;
  smsRelayEnabled?: boolean;
}

/** Signed-in identity across services. */
export interface Account {
  imessage?: AccountIdentity;
  sms?: AccountIdentity;
}

/**
 * A Name & Photo card.
 *
 * This is what someone chose to share over iMessage, which Messages displays
 * in preference to the contact card — so it can differ from Contacts, and it
 * exists for people who have no contact card at all.
 */
export interface NameAndPhoto {
  name?: string;
  firstName?: string;
  lastName?: string;
  /** Handle the card belongs to. */
  handle?: string;
  /** Shared photo, base64-encoded. */
  photo?: string;
  photoBytes?: number;
  /** Cards waiting to be accepted or declined. Only on your own card. */
  pending?: NameAndPhoto[];
}

/** Counts and distributions over a conversation, or the whole store. */
export interface Stats {
  messages: number;
  sent: number;
  received: number;
  withAttachments: number;
  tapbacks: number;
  /** Unix seconds of the first and last message in scope. */
  firstAt: number;
  lastAt: number;
  chatGuid?: string;
  people: { handle: string | null; fromMe: number; messages: number; lastAt: number }[];
  byHour: { hour: number; messages: number }[];
  byWeekday: { weekday: number; messages: number }[];
  byMonth: { month: string; messages: number }[];
  media: { mimeType: string | null; count: number; bytes: number }[];
  services: { service: string; messages: number }[];
}

export type Capability = keyof Capabilities;

/** A participant, resolved against Contacts where possible. */
export interface Person {
  /** Phone number or email address as iMessage knows it. */
  id: string;
  /** Full name from Contacts; absent for unknown numbers. */
  name?: string;
  firstName?: string;
  nickname?: string;
}

/**
 * The outcome of a group operation, read back rather than assumed.
 *
 * The underlying IMCore calls return void, so `ok` only means nothing raised.
 * `changed` is whether the chat actually differs afterwards.
 */
export interface GroupResult {
  ok: true;
  /** Whether the membership or name actually moved. */
  changed: boolean;
  /** Handles in the conversation after the operation. */
  participants: string[];
  /** The same people, resolved against Contacts where possible. */
  people?: Person[];
  displayName?: string;
}

/** A contact picture, fetched one at a time. */
export interface ContactAvatar {
  handle: string;
  name?: string;
  mimeType: string;
  /** Base64-encoded image bytes. */
  data: string;
}

/** One of a contact's labelled entries — the label is already localised. */
export interface LabeledValue {
  /** "home", "work", "mobile" — as Contacts displays it, not `_$!<Home>!$_`. */
  label?: string;
}

export interface ContactPhone extends LabeledValue {
  number: string;
}
export interface ContactEmail extends LabeledValue {
  address: string;
}
export interface ContactUrl extends LabeledValue {
  url: string;
}
export interface ContactRelation extends LabeledValue {
  name: string;
}
export interface ContactDate extends LabeledValue {
  /** Parts that are set; a date recorded without a year has no `year`. */
  date: { year?: number; month?: number; day?: number };
}
export interface ContactAddress extends LabeledValue {
  street?: string;
  subLocality?: string;
  city?: string;
  state?: string;
  postalCode?: string;
  country?: string;
  countryCode?: string;
}
export interface ContactProfile extends LabeledValue {
  service?: string;
  username?: string;
  url?: string;
}

/**
 * Everything Contacts holds about the person behind a handle.
 *
 * A handle on its own says nothing — "+15550000000 said this" is not how anyone
 * reads a conversation. Fields absent from the card are absent here rather than
 * present and empty.
 */
export interface Contact {
  /** The handle this card was looked up by. */
  handle?: string;
  /** Contacts' own identifier for the card. */
  id?: string;
  /** The name as it would be written, e.g. `Ada Lovelace`. */
  name?: string;
  firstName?: string;
  middleName?: string;
  lastName?: string;
  prefix?: string;
  suffix?: string;
  nickname?: string;
  previousLastName?: string;
  phoneticFirstName?: string;
  phoneticMiddleName?: string;
  phoneticLastName?: string;

  organization?: string;
  department?: string;
  jobTitle?: string;
  /** The card is a company rather than a person. */
  isOrganization?: boolean;
  note?: string;

  birthday?: { year?: number; month?: number; day?: number };
  /** Anniversaries and other labelled dates. */
  dates?: ContactDate[];

  phoneNumbers?: ContactPhone[];
  emailAddresses?: ContactEmail[];
  postalAddresses?: ContactAddress[];
  urls?: ContactUrl[];
  relations?: ContactRelation[];
  socialProfiles?: ContactProfile[];
  instantMessageAddresses?: ContactProfile[];

  /** Whether a picture exists. Ask with `includePhoto` to get the bytes. */
  hasPhoto?: boolean;
  photo?: { mimeType: string; data: string };
}

/** A conversation's own details, as opposed to its messages. */
export interface ChatDetails {
  chatGuid: string;
  displayName?: string;
  /**
   * The picture the group is drawn with. `localPath` is absent when the chat
   * names one the attachment table no longer holds.
   */
  groupPhoto?: Attachment;
  /**
   * A conversation background is set. Only its presence is reported: it is
   * stored as a remote asset rather than a local file.
   */
  hasBackground?: boolean;
  archived?: boolean;
  /** Filed under Unknown Senders. */
  filtered?: boolean;
  blocked?: boolean;
}

export interface Chat {
  guid: string;
  chatIdentifier?: string;
  displayName?: string;
  participants: string[];
  /** Participants with names attached, where Contacts knows them. */
  people?: Person[];
  isGroup: boolean;
  service?: string;
  unreadCount?: number;
  isPinned?: boolean;
  isMuted?: boolean;
  /**
   * When the silence ends, as a Unix time. Absent when a muted conversation is
   * muted indefinitely, which is stored as a date far enough out that
   * reporting it would read as a real deadline.
   */
  mutedUntil?: number;
  /** Seconds since the Unix epoch. */
  lastActivity?: number;
  unreadMentionGUIDs?: string[];
}

/** What sort of content a message carries. */
export type MessageKind =
  | "text"
  | "attachment"
  | "link"
  | "poll"
  | "tapback"
  | "retracted"
  | "app"
  | "photos"
  | "findmy"
  /** A group event rather than a message: see `event`. */
  | "event";

export interface Attachment {
  guid: string;
  filename?: string;
  mimeType?: string;
  /** Uniform type identifier, e.g. `public.heic`. */
  uti?: string;
  /** Path on disk. May be absent if the file has not been downloaded. */
  localPath?: string;
  sizeBytes?: number;
  /** Messages' own on-device transcription, for audio messages. */
  audioTranscript?: string;
  isAudioMessage?: boolean;
  isSticker?: boolean;
  isOutgoing?: boolean;
  /** IMCore's transfer state. 5 is a completed transfer. */
  transferState?: number;
  /** Not downloaded, or withheld — nothing is at `localPath`. */
  hidden?: boolean;
  /** Held back by Communication Safety as possibly sensitive. */
  sensitive?: boolean;
  /**
   * What the image depicts, in words — the description Messages stores for
   * accessibility. Present on Genmoji and on image glyphs generally, and the
   * difference between "an image" and knowing what was sent.
   */
  description?: string;
  /** Stable identity of an image glyph, so the same one is recognisable. */
  contentIdentifier?: string;
  /**
   * Bundle identifier of the extension a sticker came from — what separates a
   * Memoji from a third-party pack from one made out of a photo.
   */
  stickerSource?: string;
}

/** A reaction on a message. */
export interface Tapback {
  kind: TapbackKind;
  /** Handle of whoever reacted. */
  sender?: string;
  /** Their name from Contacts, when known. */
  senderName?: string;
  /** Set for custom emoji reactions. */
  emoji?: string;
  isFromMe: boolean;
}

/** An @-mention, located within the message text. */
export interface Mention {
  /** Handle of the person mentioned. */
  handle: string;
  /** The text covered by the mention, e.g. a display name. */
  text: string;
  location: number;
  length: number;
}

/** A URL found in the message body. */
export interface Link {
  url: string;
  /** The text the URL covers. */
  text: string;
  /** Whether Messages rendered it as a rich preview. */
  isRichLink: boolean;
}

/**
 * The preview Messages fetched for a link, as the bubble draws it.
 *
 * Read out of the message's balloon payload, which is where the page's
 * OpenGraph metadata ends up.
 */
export interface LinkPreview {
  url?: string;
  /** The URL as sent, when a redirect moved it. */
  originalUrl?: string;
  title?: string;
  summary?: string;
  /** Publisher name, e.g. `TikTok`. */
  siteName?: string;
  /** OpenGraph type, e.g. `website` or `article`. */
  itemType?: string;
  /**
   * Remote URL of the preview image. The downloaded bytes live in the
   * attachment table, not in the payload.
   */
  imageUrl?: string;
  /** Remote URL of the site's icon. */
  iconUrl?: string;
}

/** One choice in a poll. */
export interface PollOption {
  /** Stable identifier, which is also how a vote names its choice. */
  id?: string;
  text?: string;
  /** Handle of whoever added this option. */
  creator?: string;
  /** Handles of everyone who chose it, once history has tallied the votes. */
  voters?: string[];
  voteCount?: number;
}

/**
 * A poll, decoded from its balloon payload.
 *
 * Votes are not carried here: the payload holds the poll itself, and each vote
 * arrives as its own message.
 */
export interface Poll {
  question?: string;
  /** Handle of whoever created the poll. */
  creator?: string;
  options?: PollOption[];
  /**
   * Identifier tying votes to this poll. A vote must carry the poll's own or
   * it is not counted.
   */
  sessionId?: string;
  /** Votes cast, once history has folded them on. */
  votes?: PollVote[];
  /** Total votes across all options. */
  totalVotes?: number;
}

/** One vote cast in a poll. */
export interface PollVote {
  /** Handle of the voter. */
  handle?: string;
  optionId: string;
  /** When the vote was recorded, in Unix seconds. */
  time?: number;
}

/**
 * A transcript line that is not a message — the grey text a group conversation
 * is punctuated with.
 *
 * These are ordinary rows in the store, distinguished only by columns that are
 * empty on every real message, so a reader that ignores them sees a group chat
 * with unexplained gaps: people appearing without having been added, a name
 * that changes with nothing to explain it.
 */
export interface GroupEvent {
  kind:
    | "participant-added"
    | "participant-change"
    | "group-renamed"
    | "group-photo-set"
    | "group-photo-removed"
    /**
     * Something drawn the same way as a picture change but which the item
     * says is not one — a conversation background, on releases that have
     * them. Only reported from the live path, which can tell; deep history
     * has to infer a picture change from whether an image came along.
     */
    | "group-action"
    | "share"
    | "unknown";
  /** Handle of whoever performed it. */
  actor?: string;
  /** The actor's name from Contacts, when known. */
  actorName?: string;
  /** Handle of the person it was done to, for a participant change. */
  participant?: string;
  /** Their name from Contacts, when known. */
  participantName?: string;
  /** The new conversation name, on a rename. */
  name?: string;
  /**
   * The raw code, where its meaning is not established. Present on a
   * participant change that is not an addition, and on every picture change.
   */
  actionCode?: number;
  shareStatus?: number;
  shareDirection?: number;
  /** The raw `item_type`, on a kind this version does not recognise. */
  itemType?: number;
}

/** One earlier version of an edited message part. */
export interface MessageVersion {
  text?: string;
  /** When this version was written, in Unix seconds. */
  date?: number;
  mentions?: Mention[];
  links?: Link[];
}

/**
 * The version chain of one edited part, oldest first.
 *
 * The last entry is the text the message reads as now — the chain is only
 * meaningful with its endpoint in it.
 */
export interface EditHistory {
  part: number;
  versions: MessageVersion[];
}

/** Styling a person applies from the format bar. */
export type TextStyle = "bold" | "italic" | "underline" | "strikethrough";

/**
 * A range of the message text to style, animate, or turn into a mention.
 *
 * Ranges are in UTF-16 code units, the same units `location` and `length` use
 * everywhere else here. A range outside the body is ignored rather than sent,
 * since IMCore raises on one while splitting the message into parts — which is
 * a crash in Messages, not a failed send.
 */
export interface FormatRange {
  location: number;
  length: number;
  styles?: TextStyle[];
  /**
   * An animated effect, by IMCore's name for it. `status().textEffects` lists
   * what this build accepts; on macOS 26 that is `scaleRipple`, `stretch`,
   * `squish`, `bounce`, `big`, `bloom`, `somersault`, `shakeVertical`,
   * `shakeHorizontal`, `jitter`, `small`, `explode`.
   *
   * Names are case-sensitive and not always what the UI calls them — there is
   * no `shake`. An unknown name is rejected rather than sent, because IMCore
   * reads an unrecognised one as "no effect" and the message would go out
   * looking like it worked.
   */
  textEffect?: string;
  /** Makes the range a mention of this handle, which notifies them. */
  handle?: string;
}

/** One run of a decoded message body. */
export interface BodyPart {
  /** What the run is: plain text, an attachment, a mention, or a link. */
  kind: "text" | "attachment" | "mention" | "link";
  text: string;
  location: number;
  length: number;
  /** Styling on this run, as the bubble draws it. */
  styles?: TextStyle[];
  /** An animated text effect, by IMCore's name for it. */
  textEffect?: string;
  /** Messages recognised this run as a one-time passcode. */
  isOneTimeCode?: boolean;
  /** A data detector matched here — a flight, parcel, address or amount. */
  isDataDetected?: boolean;
  /** Which message part this run belongs to. */
  partIndex?: number;
  /** Transfer GUID, on an attachment run. */
  attachmentGuid?: string;
  /** Handle of the person mentioned, on a mention run. */
  handle?: string;
  /** URL, on a link run. */
  url?: string;
  /** Any other attributes IMCore tagged the run with. */
  attributes?: Record<string, string | number>;
}

export interface Message {
  guid: string;
  /**
   * The message store's rowid, for recording where a consumer got to.
   *
   * Absent until Messages has written the message to the store, which for one
   * just received can be a moment after this event. That is the safe way
   * round: a consumer that cannot advance its cursor asks for the message
   * again after a restart and sees it twice, where a guessed rowid would move
   * the cursor past messages that were never delivered.
   *
   * Pass the highest one seen as {@link StoreHistoryOptions.sinceRowID} to
   * collect whatever arrived while nothing was listening.
   */
  rowid?: number;
  text?: string;
  /** Sender handle; absent on your own messages in some shapes. */
  sender?: string;
  /** Sender's name from Contacts, when known. */
  senderName?: string;
  isFromMe: boolean;
  /** Seconds since the Unix epoch. */
  time?: number;
  kind?: MessageKind;
  subject?: string;

  isDelivered?: boolean;
  isRead?: boolean;
  isSent?: boolean;
  isPlayed?: boolean;
  hasMention?: boolean;
  timeDelivered?: number;
  timeRead?: number;
  timePlayed?: number;

  /** GUID of the message this one replies to. */
  replyToGUID?: string;
  threadIdentifier?: string;

  /**
   * Reactions on this message, as the UI draws them.
   *
   * Tapbacks are folded onto the message they react to rather than appearing
   * as separate entries, so `tapbacks.length` is the count on the bubble.
   */
  tapbacks?: Tapback[];

  /** @-mentions in the body, with the text they cover. */
  mentions?: Mention[];

  /** URLs in the body. Preview title and image are not available. */
  links?: Link[];

  /** Set on tapbacks: which message they react to, and how. */
  associatedMessageGUID?: string;
  associatedMessageType?: number;
  associatedMessageEmoji?: string;

  dateEdited?: number;
  dateRetracted?: number;
  /** Earlier versions of an edited message, per part, oldest first. */
  editHistory?: EditHistory[];
  /** Every part was unsent — the bubble is gone from this side. */
  unsent?: boolean;
  /** Which parts were unsent, for a message unsent one part at a time. */
  unsentParts?: number[];
  /**
   * The unsend never reached the other party: the state the app draws as
   * "Not Unsent". They still see the message and it cannot be taken back.
   */
  unsendFailed?: boolean;

  /**
   * Set instead of a body when this is a group event rather than a message —
   * someone added, a rename, the picture changing. IMCore models these as
   * their own item type, so they arrive with no text at all.
   */
  event?: GroupEvent;

  /** Non-zero on a message being held by Send Later. */
  scheduleType?: number;
  /** When a held message is due to go out, in Unix seconds. */
  scheduledFor?: number;
  /** When it was scheduled, as opposed to when it goes out. */
  scheduledAt?: number;

  /** Expressive effect identifier, e.g. `com.apple.messages.effect.CKConfettiEffect`. */
  effect?: string;

  attachments?: Attachment[];
  /** Plugin identifier for rich balloons (links, polls, apps). */
  balloonBundleID?: string;
  /** Human-readable summary Messages computed for a rich balloon. */
  summary?: string;
  /** Base64 plugin payload, for callers that decode it themselves. */
  payloadData?: string;

  chatGUID?: string;
  chatIdentifier?: string;
  error?: number;
}

export interface SendOptions {
  chat: string;
  text?: string;
  subject?: string;
  /** Expressive effect identifier. */
  effect?: string;
  /** GUID of the message being replied to. */
  replyTo?: string;
  /**
   * Local file paths to send.
   *
   * They travel with `text` as one message, so the text reads as a caption
   * rather than arriving separately, and they can be sent to any conversation
   * `chat` resolves to, group chats included.
   */
  files?: string[];

  /**
   * Sends `files` as stickers rather than as ordinary attachments.
   *
   * A sticker is size- and dimension-limited; a file that exceeds either is
   * refused rather than quietly delivered as a plain image.
   *
   * `attachTo` sticks it onto an existing message instead of sending it on its
   * own, the way peel-and-stick does in the app. A stuck sticker carries no
   * text, so `text` alongside it is refused rather than dropped.
   */
  sticker?: boolean | { label?: string; attachTo?: string };

  /**
   * A key of the caller's choosing that makes this send safe to repeat.
   *
   * A send that reaches Messages and then loses its reply — a timeout, a
   * dropped socket, a client that died in between — leaves you unable to tell
   * whether it went out. Retrying sends it twice; not retrying drops it, and
   * neither is fixable afterwards, because nothing in the message store ties an
   * attempt to your intent.
   *
   * Repeating a send with the same key inside the window returns the original
   * result with `duplicate: true` and sends nothing. Use one key per message
   * you mean to send, reused across every retry of that message.
   *
   * The record lives in the injected process and is dropped when Messages
   * restarts, which is deliberate: it covers a retry cycle, not a decision to
   * send the same thing again hours later.
   */
  idempotencyKey?: string;

  /** GUIDs of transfers already registered by the caller. */
  attachments?: string[];

  /**
   * Styling, animated effects and mentions, applied over ranges of `text`.
   *
   * A mention is a range naming a handle: that is what makes it notify the
   * person rather than merely read as their name.
   */
  formatting?: FormatRange[];

  /**
   * Which service carries this one message.
   *
   * Omitted, it goes the way the conversation already sends. Named, it is
   * routed over that account for this message only — the conversation's own
   * service is deliberately left alone, since rewriting it would change where
   * every later message goes, including ones sent from the app by hand.
   *
   * `SMS` needs an active text-message relay on this Mac; without one the send
   * is refused rather than quietly going out as an iMessage.
   */
  service?: "iMessage" | "SMS";
}

/**
 * A reaction. The six classic tapbacks are named; `emoji` is the custom-emoji
 * reaction, which carries the character alongside it.
 */
export type TapbackKind =
  | "love"
  | "like"
  | "dislike"
  | "laugh"
  | "emphasize"
  | "question"
  | "emoji";

/** What a search hit refers to. */
export type SearchKind = "message" | "attachment" | "chat";

/** A scene label Apple's classifier assigned to an image or video. */
export interface SearchLabel {
  /** Human-readable class, such as "Dog" or "Document". */
  label: string;
  /** Classifier confidence between 0 and 1, when reported. */
  confidence?: number;
}

export interface SearchHit {
  kind: SearchKind;
  /** Message GUID, attachment GUID, or handle, depending on `kind`. */
  guid: string;
  /** The message this hit belongs to; equals `guid` for message hits. */
  messageGuid?: string;
  /**
   * Conversation the hit belongs to. Absent for attachment hits, which the
   * index files under their own domain rather than under a chat — pass
   * `messageGuid` to `getHistory` or the message store to place one.
   */
  chatGuid?: string;
  /** Which attachment of the message this is, for attachment hits. */
  partIndex?: number;
  /** Handle for chat hits. */
  handle?: string;
  /**
   * Indexed text for the hit. For a message this is its body; for a picture it
   * is text recognised inside the image; for audio or video, spoken content.
   */
  snippet?: string;
  /** Conversation name for a message hit, contact name for a chat hit. */
  title?: string;
  /** Uniform type identifier, such as `public.png`. */
  contentType?: string;
  /** Seconds since the Unix epoch. */
  date?: number;
  /** Scene labels, which is how a query matches pictures by what is in them. */
  labels?: SearchLabel[];
  /** Attributes the hit matched on, such as `textContent`. */
  matchedOn?: string[];
  /** Media classes the index assigned, such as `Photo` or `Screenshot`. */
  mediaTypes?: string[];
}

export interface SearchResults {
  hits: SearchHit[];
  /**
   * `ranked` used Apple's ranked engine, which applies classification and
   * semantic matching. `substring` is the fallback and matches text only.
   */
  strategy: "ranked" | "substring";
  /** True when the query hit its deadline and results are incomplete. */
  truncated?: boolean;
}

export interface SearchOptions {
  /** What to search for, as a person would type it. */
  query: string;
  /** Maximum hits to return. Defaults to 50. */
  limit?: number;
  /** Restrict to one conversation, by GUID, handle, or display name. */
  chat?: string;
  /** Restrict to certain kinds of hit. */
  kinds?: SearchKind[];
}

/**
 * One row from the message store.
 *
 * Store columns pass through by their own names, with times converted to Unix
 * seconds. Everything the store keeps encoded — the body, the plugin payload,
 * the summary plist — is decoded here into the typed fields below rather than
 * handed over as base64; the raw bytes appear only where no decoder covers
 * them, so nothing is ever silently lost.
 */
export interface StoredMessage {
  rowid: number;
  guid: string;
  /** The body text, decoded from `attributedBody` when the column is empty. */
  text?: string | null;
  /** Base64 NSAttributedString archive, present only if it could not be read. */
  attributedBody?: string | null;
  /** Handle of the sender; absent on messages you sent. */
  sender?: string | null;
  /** The sender's name from Contacts, resolved from the handle. */
  senderName?: string;
  subject?: string | null;
  service?: string;
  account?: string;
  error?: number;
  date?: number;
  date_read?: number;
  date_delivered?: number;
  date_played?: number;
  is_delivered?: number;
  is_finished?: number;
  is_from_me?: number;
  is_read?: number;
  is_sent?: number;
  is_played?: number;
  is_audio_message?: number;
  is_empty?: number;
  /** Classified as junk and filed under Unknown Senders. */
  is_spam?: number;
  /** Sent as SMS after iMessage delivery failed. */
  was_downgraded?: number;
  /** The sender's identity is verified by Contact Key Verification. */
  is_kt_verified?: number;
  is_time_sensitive?: number;
  /** Delivered without a notification, e.g. from an unknown sender. */
  was_delivered_quietly?: number;
  /** An expiring audio message, and how far through expiry it is. */
  is_expirable?: number;
  expire_state?: number;
  item_type?: number;
  cache_has_attachments?: number;
  associated_message_guid?: string | null;
  associated_message_type?: number;
  associated_message_emoji?: string | null;
  balloon_bundle_id?: string | null;
  /**
   * Raw base64 plugin payload, present only when no decoder covers the plugin.
   * Link and poll messages arrive decoded as `link` and `poll` instead.
   */
  payload_data?: string | null;
  expressive_send_style_id?: string | null;
  reply_to_guid?: string | null;
  thread_originator_guid?: string | null;
  date_edited?: number;
  date_retracted?: number;
  part_count?: number;
  /** Non-zero on a message that was scheduled with Send Later. */
  schedule_type?: number;
  schedule_state?: number;
  /**
   * The conversation holding this message. Present on a single-message read,
   * and on a history read that spanned every conversation — where it is the
   * only thing saying which one a message came from.
   */
  chatGuid?: string;

  /** Runs of the decoded body: text, attachments, mentions and links in order. */
  parts?: BodyPart[];
  /** @-mentions in the body. */
  mentions?: Mention[];
  /** URLs in the body. */
  links?: Link[];
  /** Decoded link preview, on a link message. */
  link?: LinkPreview;
  /** Decoded poll, on a poll message. */
  poll?: Poll;
  /** Files carried by the message, including stickers and image glyphs. */
  attachments?: Attachment[];
  /** Reactions folded onto this message, as the UI draws them. */
  tapbacks?: Tapback[];
  /** Stickers stuck onto this message. */
  stickers?: StuckSticker[];
  /** Set instead of a body when the row is a group event rather than a message. */
  event?: GroupEvent;

  /** Earlier versions of an edited message, per part. */
  editHistory?: EditHistory[];
  /** The message was unsent — every part removed from this side. */
  unsent?: boolean;
  /**
   * Which parts were unsent. A message can be unsent a part at a time, in
   * which case the rest of it is still in the conversation.
   */
  unsentParts?: number[];
  /**
   * The unsend never reached the other party: the state the app draws as
   * "Not Unsent". They still see the message and it can no longer be taken
   * back. Nothing else in the row says so.
   */
  unsendFailed?: boolean;
  /**
   * When a scheduled message will be delivered, in Unix seconds. This is the
   * message's own timestamp — IMCore dates it into the future and holds it.
   */
  scheduledFor?: number;
  /** When it was scheduled, as opposed to when it goes out. */
  scheduledAt?: number;
}

/** A sticker placed on a message rather than sent as one. */
export interface StuckSticker {
  guid: string;
  isFromMe: boolean;
  sender?: string;
  /** Their name from Contacts, when known. */
  senderName?: string;
  date?: number;
  /** The sticker image itself. */
  attachments?: Attachment[];
}

export interface StoreHistoryOptions {
  /**
   * Conversation, by GUID, handle, or display name.
   *
   * Optional, and only worth leaving out when paging forwards: a consumer
   * catching up after downtime does not know which conversations have news, so
   * restricting the scan to one would mean asking every chat in turn. Each
   * message then carries the `chatGuid` it belongs to.
   */
  chat?: string;
  /** Page size. Defaults to 200, max 1000. */
  limit?: number;
  /** Page backwards: pass the previous page's `nextBeforeRowID`. */
  beforeRowID?: number;
  /**
   * Page forwards: everything written after a rowid recorded earlier.
   *
   * This is how a consumer that was not running finds out what it missed —
   * reading the same thing with `beforeRowID` would mean walking the archive
   * backwards until the cursor came into view. Starting with no cursor at all,
   * ask without one: the newest page comes back, and its `nextSinceRowID` is
   * the position to resume from.
   *
   * Rejected alongside `beforeRowID`, since a window bounded at both ends has
   * no single cursor to continue from.
   */
  sinceRowID?: number;
}

export interface StoreHistory {
  messages: StoredMessage[];
  /** Present when the read was restricted to one conversation. */
  chatGuid?: string;
  /** Pass as `beforeRowID` for the next older page. */
  nextBeforeRowID: number;
  /**
   * Pass as `sinceRowID` for whatever arrives next.
   *
   * Held where it was when nothing new came back, so an idle poll asks the
   * same question again rather than resetting and replaying the archive.
   */
  nextSinceRowID: number;
  hasMore: boolean;
}

/**
 * What became of a send.
 *
 * `unknown` is a real answer rather than a failure: a message Messages has not
 * written to the store yet reads as unknown for a moment after a successful
 * send, and so does a GUID that was never sent. The two cannot be told apart
 * from here, so they are not guessed between — ask again shortly.
 */
export interface SendStatus {
  guid: string;
  state: "unknown" | "pending" | "sent" | "delivered" | "read" | "failed";
  /** The store rowid, once there is one. */
  rowid?: number;
  /** IMCore's error code, on `failed`. */
  error?: number;
  /** Seconds since the Unix epoch. */
  date?: number;
  date_delivered?: number;
  date_read?: number;
  chatGuid?: string;
}

export interface BridgeStatus {
  ready: boolean;
  pid: number;
  protocol: number;
  capabilities: Capabilities;
  /** Animated text effect names this build accepts, asked of IMCore. */
  textEffects?: string[];
}

/** Events pushed from Messages as they happen. */
export type BridgeEvent =
  | { type: "message"; data: Message }
  | { type: "message-sent"; data: Message }
  | { type: "message-updated"; data: Message }
  | { type: "chat-item"; data: Message & { itemClass?: string } }
  | { type: "typing"; data: { chatGUID: string; sender?: Person | null; typing: boolean } }
  | { type: "read-receipt"; data: { chatGUID: string } }
  | { type: "unread-changed"; data: Chat }
  | { type: "hello"; data: BridgeStatus }
  | { type: string; data: unknown };

export interface ClientOptions {
  /** Socket path. Defaults to the one inside the Messages container. */
  socketPath?: string;
  /** Per-request timeout in milliseconds. Defaults to 35000. */
  timeoutMs?: number;
}
