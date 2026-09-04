# Search

Messages does not keep a text index of its own. It donates every message,
attachment and conversation to a private **CoreSpotlight** domain, and its own
search field queries that. This library queries the same index.

That choice matters more than it sounds. The index already holds work the device
has done:

- **Image classification.** Searching `dog` returns photographs of dogs whose
  messages never mention one, because Apple's classifier labelled them.
- **Text recognised inside images.** A screenshot of a receipt is findable by
  the words printed in it.
- **Spoken content** in audio and video.
- **Ranking**, so the first result is usually the intended one.

Reimplementing any of that would be a poor copy of what is already on disk.

```ts
const { hits } = await bridge.search({ query: "dog", kinds: ["attachment"] });
for (const hit of hits) {
  console.log(hit.labels?.map((l) => l.label).join(", "), hit.snippet);
}
```

## Why it must run inside Messages

The domain is private to `com.apple.MobileSMS`. From any other process it does
not exist — `mdfind` returns nothing no matter the query, and
`mdutil -s ~/Library/Messages` reports an unknown indexing state. The injected
bridge runs inside Messages, which is the only place the index is readable.

## What a hit is

Hits are references, not messages. Resolve `messageGuid` against the message
store or `getHistory` to read one in context.

| `kind` | `guid` | Carries a chat? |
| --- | --- | --- |
| `message` | the message GUID | yes — `chatGuid` |
| `attachment` | `at_<part>_<message GUID>` | no |
| `chat` | the handle | n/a |

A message's domain identifier *is* the GUID of the chat holding it, so message
hits are attributed for free. Attachments are filed under a domain of their own
and carry nothing that names a conversation — their whole attribute set is five
keys, none of which is a chat.

## Scope and kind

Scope and `kinds` are independent filters and combine freely: a whole account,
one DM, or one group, crossed with any set of kinds.

Scope is applied **inside** the query rather than to its results. That is not a
detail — filtering afterwards means a scoped search can come back empty while
matches sit further down the ranking.

```ts
// Everything about invoices in one group.
await bridge.search({ query: "invoice", chat: "any;+;chat000000000000000001" });

// Only the files in a DM.
await bridge.search({ query: "receipt", chat: "+15550000000", kinds: ["attachment"] });
```

Attachments need a second step. Because they sit in their own domain, a scoped
query can never return them, and their identifier cannot be looked up in the
index — both `**== "<guid>"` and `_kMDItemExternalID == "<guid>"` match nothing.
So a scoped search that wants files lists the conversation's own items once,
then keeps the attachments whose owning message is among them. That listing is
cached briefly, since it is the expensive part of a scoped search.

When a scope forces those two queries, the limit is split between them.
Otherwise messages fill every slot and files never appear.

## Ranked and substring

`strategy` reports which engine answered:

- `ranked` — `CSUserQuery`, the natural-language path, and the only one that
  applies classification and semantic matching. It requires a configured
  `CSUserQueryContext`; passing `nil` fails with `CSSearchQueryErrorDomain`
  −2002.
- `substring` — `CSSearchQuery`, the fallback, text only.

Body text is indexed for **matching** but never returned as a fetchable
attribute. A named-attribute predicate such as `textContent == "dog*"` matches
nothing; the all-attribute operator `**==` is what reaches it.

`snippet` is worth noting on its own: most rows in the message store keep their
body in an encoded `attributedBody` blob rather than in `text`. Spotlight
returns readable text for those without decoding anything.

## Limits

- **The index can outlive the store.** Deleted messages may still be indexed, so
  a hit's `messageGuid` is not guaranteed to resolve. Treat a missing message as
  deleted rather than as an error.
- **Attachment hits carry no `chatGuid`**, only `messageGuid`. Scoped searches
  attribute them internally, but a global search cannot say which conversation a
  file came from without resolving the message.
- **`truncated`** means the query hit its deadline with results still arriving.
- Results are ordered by relevance within each kind. A scoped search returning
  both kinds ran two queries, whose rankings are not comparable — sort by `date`
  for a single timeline.
