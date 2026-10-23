# AMScreen

Companion tweak for **AnsweringMachine XS (rootless)** on iOS 16 / Dopamine.

AnsweringMachine still auto-answers, plays the greeting and records the caller.
Its call-screening screen (Listen without answering / Hang up / Talk) no longer
appears on iOS 16, because its `AMCallWindow` is created without a `UIWindowScene`.
AMScreen shows a replacement screen in SpringBoard when AM auto-answers. Its buttons
call AM's own controller (`AMCenter`):

| Button | Calls |
|---|---|
| Listen without answering | `-[AMCenter listenToCaller:]` |
| Talk | `-[AMCenter takeOverCurrentCall]` |
| Hang up | `-[AMCenter declineCurrentCall]`, falling back to `TUCallCenter disconnectCall:` |
| ⌄ (hide) | Hides the screen; tap AM's status-bar indicator to bring it back |

## Build (GitHub Actions)

1. Create a **private** GitHub repo and push this folder to it.
2. The `Build AMScreen` workflow runs on every push (or via *Actions → Run workflow*).
3. Download the `AMScreen-deb` artifact from the run, then unzip it to get the `.deb`.

## Install

Copy the `.deb` to the phone and install it with Sileo/Zebra/Filza, or over SSH:

```
sudo dpkg -i com.personal.amscreen_*.deb && sbreload
```

## Testing and logs

Call the phone from another number and let it ring until AM picks up (your
greeting delay, e.g. 12 s). The screen should appear.

Every step is logged to `/var/mobile/Library/Logs/AMScreen.log`. If something
doesn't work, send that file. It shows whether AM's hooks fired
(`-[AMCenter autoAnswerCall]`, `listenToCaller:` ...) and what the buttons did.
