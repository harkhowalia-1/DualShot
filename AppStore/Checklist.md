# Publishing DualShot 1.0

**Status:** submitted for App Review on November 2, 2026 (build 1.0 (2), $2.99, all 175 countries, releases automatically when approved).

Done and ready:

- [x] Signed App Store build, version 1.0 (1): in Xcode › Window › Organizer, and `build/DualShot-1.0-AppStore.ipa` (not in git)
- [x] Privacy manifest, export compliance, permission texts
- [x] Listing text, keywords, review notes and privacy answers: [Metadata.md](Metadata.md)
- [x] Six screenshots: [Screenshots-6.3in/](Screenshots-6.3in) (required) and [Screenshots-6.9in/](Screenshots-6.9in) (large displays)
- [x] Privacy policy, support and marketing pages (live on GitHub Pages)

Your steps (about 20 minutes):

1. **Create the app.** [App Store Connect](https://appstoreconnect.apple.com) › Apps › **+** › New App. Platform iOS, name `DualShot: Front & Back Camera`, language English (U.S.), bundle ID `com.harkhowalia.dualshot`, SKU `dualshot-ios`.
   If the name is taken, try `DualShot – Dual Camera`, then shorten the subtitle to fit.
2. **Upload the build.** Xcode › Window › Organizer › select *DualShot 1.0 (1)* › **Distribute App** › App Store Connect › Upload. It shows up under TestFlight after about 15 minutes of processing.
3. **Fill in the listing** from [Metadata.md](Metadata.md), drag in the six screenshots, and pick the build.
4. **App Privacy:** "No, we do not collect data."
5. **Pricing:** choose a price (Metadata.md has a recommendation). If you're charging, sign the Paid Apps agreement and add banking and tax details under Business first, and apply for the [Small Business Program](https://developer.apple.com/app-store/small-business-program/).
6. **Test once on TestFlight** on your iPhone: record with sound (headphones off), take a photo, check Photos.
7. **Add for Review › Submit.** Review usually takes 1–2 days.

For the next update, raise `CURRENT_PROJECT_VERSION` in `project.yml` before archiving; every upload needs a new build number.
