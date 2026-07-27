# SMS Integration (TN Messages fork)

This fork adds local **SMS** alongside BlueBubbles' iMessage. The app becomes
Android's **default SMS app**, handling SMS natively, and syncs SMS to a
self-hosted **SMS Sync Server** (Node) so the Mac and other devices stay in
sync. iMessage is unchanged (Apple via the BlueBubbles Server). SMS renders as
green bubbles via the existing `ChatServiceType.sms`; iMessage stays blue.

- **Source of truth:** SMS → our SMS Sync Server; iMessage → Apple/BlueBubbles Server. The two never mix on the wire; they merge only in the UI (by phone number).
- **Native layer** (`android/.../services/sms/`) owns the OS SMS store + radio.
- **Dart layer** (`lib/services/.../sms`) owns server sync + ObjectBox mapping + UI. (Being built next.)

## Native ↔ Dart method-channel contract

Channel: `com.bluebubbles.messaging` (existing). Message maps use:
`{ providerId:int, address:String, body:String, date:int(ms), read:bool, isFromMe:bool, type:"sms" }`

### Dart → native (invoke on the method channel)
| Method | Args | Returns |
|---|---|---|
| `sms-is-default` | — | `bool` — is this app the default SMS app |
| `sms-request-default` | — | `bool` — launched the OS role prompt |
| `sms-query` | `since:int(ms)` | `List<message map>` (backfill/history) |
| `sms-count` | — | `int` — total SMS rows |
| `sms-send` | `address:String, body:String, messageId:String` | `{messageId}` |
| `sms-mark-read` | `address:String` | `int` rows updated |
| `sms-delete` | `ids:List<int>` (provider _ids) | `int` rows deleted |
| `sms-sim-info` | — | `{present:bool, simKey:String?}` |

### native → Dart (`MethodCallHandler.invokeMethod`)
| Method | Payload |
|---|---|
| `sms-received` | message map (from `SMS_DELIVER`, already persisted) |
| `sms-sent-status` | `{messageId:String, status:"sent"\|"failed"}` |

Native emits best-effort only when the Dart engine is alive; the Dart service
reconciles anything missed via `sms-query` on startup.

## Default-SMS-app components (manifest)
- `SmsDeliverReceiver` (`SMS_DELIVER`, `BROADCAST_SMS`) — persists inbound + notifies Dart.
- `MmsDeliverReceiver` (`WAP_PUSH_DELIVER`) — MMS deferred.
- `HeadlessSmsSendService` (`RESPOND_VIA_MESSAGE`) — quick-reply.
- `MainActivity` `SENDTO` filter (`sms/smsto/mms/mmsto`) — compose entry.
- `SmsSentReceiver` — send-result → Sent box + status to Dart.

## Status
- [x] Native engine + default-app plumbing + method channel.
- [x] Dart `SmsService`: native-event listener, maps SMS into `SMS;-;` chats via the existing pipeline (green bubbles, merged with iMessage by number).
- [x] Outbound: SMS-service chats send via the local SIM (`OutgoingMessageHandler._sendLocalSms`), not the BlueBubbles server.
- [x] Server backup/sync (`SmsServerClient`): register / ingest (backup) / delta (restore on viewer devices) / heartbeat (SIM primary). Reuses the v3 Node server.
- [x] Settings → "SMS Agent" page (`sms_agent_panel.dart`): default-app status + button, SIM, server config, sync now.
- [ ] Realtime cross-device (WebSocket `/stream`): Mac→phone send-commands, live read/delete propagation. (Currently backup + restore via REST; Mac already reads SMS from the server.)
- [ ] MMS (media/group).
- [ ] Outbound in brand-new SMS conversations started from the compose screen (replies within threads work).
