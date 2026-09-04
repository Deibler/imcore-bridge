// Prints each incoming message as it arrives, then echoes a reply in-thread.
//
// Run with: npx tsx examples/watch-conversations.ts
import { ImcoreBridge, launch } from "imcore-bridge";

const bridge: ImcoreBridge = await launch();

console.log(`connected to Messages (pid ${bridge.pid})`);
if (!bridge.can("events")) {
  console.error("this macOS build does not expose message events");
  process.exit(1);
}

for await (const event of bridge.events()) {
  switch (event.type) {
    case "message": {
      const { senderName, sender, text, chatGUID, isFromMe } = event.data;
      if (isFromMe) break;
      console.log(`${senderName ?? sender}: ${text ?? "(no text)"}`);

      // Attachments arrive with a path, so other tooling can read the file.
      for (const attachment of event.data.attachments ?? []) {
        console.log(`   ↳ ${attachment.filename} (${attachment.mimeType})`);
        if (attachment.audioTranscript) {
          console.log(`     transcript: ${attachment.audioTranscript}`);
        }
      }

      // Reply in a thread rooted at the message we just received.
      if (chatGUID && text?.toLowerCase() === "ping") {
        await bridge.send({ chat: chatGUID, text: "pong", replyTo: event.data.guid });
      }
      break;
    }

    case "typing":
      if (event.data.typing) {
        console.log(`${event.data.sender?.name ?? "someone"} is typing…`);
      }
      break;

    case "message-updated":
      if (event.data.isRead) console.log(`(read) ${event.data.guid}`);
      break;
  }
}
