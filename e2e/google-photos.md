# Google Photos import: setup and device test

Halo can import photos you pick in Google's own Photos Picker. Only the photos you pick are
downloaded, straight to your iPhone. Faces are found and embedded on the device, exactly like the
Apple Photos scan, and nothing is ever uploaded. Imported faces are suggestions until you confirm
them in **People > Who is this?**.

The import needs an OAuth client ID from your own Google Cloud project. It is not a secret, but it
is personal: it lives in the gitignored `App/Local.xcconfig`, never in the repo. Without it the
People tab hides "Add from Google Photos" and Settings says Google Photos isn't set up.

## 1. Google Cloud Console

1. Go to <https://console.cloud.google.com/> and create a project (any name, e.g. "Halo personal").
2. **APIs & Services > Library**: search for **Photos Picker API** and click **Enable**. (Not the
   Photos Library API; Halo uses only the Picker.)
3. **APIs & Services > OAuth consent screen** (Google Auth Platform):
   - User type: **External**.
   - Publishing status: leave it in **Testing**.
   - App name and support email: anything; your own email is fine.
   - Data access / scopes: add `https://www.googleapis.com/auth/photospicker.mediaitems.readonly`
     (the only scope Halo asks for).
   - **Test users / Audience**: add the Google account whose photos you will pick. Only test users
     can sign in while the app is in Testing.
4. **APIs & Services > Credentials > Create credentials > OAuth client ID**:
   - Application type: **iOS**.
   - Bundle ID: `study.paradigm.halo` (or your own if you changed `PRODUCT_BUNDLE_IDENTIFIER`).
   - Create, then copy the **Client ID** (`1234567890-abc….apps.googleusercontent.com`). An iOS
     client has no client secret.

Note: in Testing mode Google expires the sign-in after **7 days**. The next import then shows
"Google sign-in expired. Import again to sign in." and signs you in again. That is expected.

## 2. Put the client ID in the build

```sh
cp App/Local.xcconfig.example App/Local.xcconfig   # once; App/Local.xcconfig is gitignored
```

Edit `App/Local.xcconfig`:

```
HALO_GOOGLE_CLIENT_ID = 1234567890-abc….apps.googleusercontent.com
```

Then regenerate the project so the Info.plist key `HaloGoogleClientID` picks it up:

```sh
xcodegen generate --spec App/project.yml
```

Build and run on your iPhone. Never commit `App/Local.xcconfig` (the repo is public).

## 3. Walkthrough on a device

Use your own photos, or photos of friends **who agreed to it**.

1. **Entry points.** People tab: an "Add from Google Photos" bar sits under the list. Settings >
   Google Photos: "Google account: Not signed in", "Add from Google Photos", and the line "Only
   photos you pick are downloaded. Faces are found on this device and never uploaded."
2. **Sign in.** Tap "Add from Google Photos". The status reads "Signing in to Google…" and Google's
   sign-in sheet opens. Sign in with the test user and allow access.
3. **Pick.** The status reads "Pick photos in Google Photos, then come back to Halo." Google Photos
   (the app, or the browser) opens. Pick 5–20 photos with the same few people, tap Done, then
   switch back to Halo.
4. **Download and scan.** The status shows "Downloading n of m photos…" then "Finding faces on this
   device…". If an Apple Photos scan was running, Settings shows it as "Paused" meanwhile; it
   picks up again by itself afterwards.
5. **Result.** "Picked m photos, found k faces. Review new faces in Who is this?". People tab >
   Needs review > **Who is this?** shows the new groups, with face thumbnails cropped from the
   downloaded copies.
6. **Confirm before recognize.** Before confirming, point the Live Lens at one of those people: no
   name appears. Confirm a group as that person, then point the lens again: the name appears.
7. **Cancel.** Start another import and tap Cancel while it waits for the picker: the bar goes back
   to "Add from Google Photos" with no error. Photos already imported stay.
8. **Busy.** Tap "Add from Google Photos" twice quickly: only one import runs.
9. **Sign out.** Settings > Google Photos > "Sign out of Google": it now reads "Not signed in".
   Imported faces stay. The next import asks you to sign in again.
10. **Kill switch.** Start an import and, while it waits for the picker, go to Settings > Erase all
    Halo data. Afterwards: People is empty, "Who is this?" has nothing, Settings shows
    "Not signed in", and the next import asks you to sign in again (tokens and downloaded photos
    were deleted). Nothing reappears later.
11. **Expired sign-in (optional).** After 7 days in Testing mode, import again: the message
    "Google sign-in expired. Import again to sign in." appears; importing again signs in.

What you should never see anywhere in the app: a Google URL, a token, a media item id or a file
name from Google.
