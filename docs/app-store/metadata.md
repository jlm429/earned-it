# App Store Metadata Draft

Confirm every value in App Store Connect before submission. This file does not change the live listing.

## Listing

**Name:** Earned It

**Subtitle:** Shared chores for families

**Promotional text:** A simple shared chore app for families. Free, with no ads and no tracking.

**Description**

Earned It gives families one clear place to share chores and follow progress together.

Parents can create recurring weekday chores or make a chore available only when it is needed. Assign work to every child, one child, or a group of children who alternate turns. Children see their own work and can mark it complete from their invited profile.

Weekly views help families review progress, streaks, and missing items. Parents can optionally set an allowance amount and see whether all required work was completed. Earned It tracks eligibility only. It does not move money or record payments.

Family data is saved locally first and can synchronize through private/shared iCloud storage across invited iPhones. Offline changes are retained and synchronize when the app can connect again.

Free. No ads. No tracking.

Earned It contains no advertising, behavioral analytics, or third-party tracking SDKs.

**Keywords:** chores,family,kids,parents,allowance,habits,household,streaks,responsibility

**Primary category:** Lifestyle

**Secondary category:** Productivity

**Price:** Free

## URLs

These URLs work after the release-readiness branch is merged to the public `main` branch:

- Privacy Policy URL: `https://github.com/jlm429/earned-it/blob/main/docs/app-store/privacy-policy.md`
- Support URL: `https://github.com/jlm429/earned-it/issues`
- Marketing URL: `https://github.com/jlm429/earned-it` (optional)

If the repository will not remain public, host the policy and support material elsewhere before submission and update the app links.

## Age rating

Complete the current App Store Connect questionnaire honestly. Based on the inspected content, the app has no violence, sexual content, profanity, gambling, contests, unrestricted web browsing, advertising, or user-generated public content. A low rating is likely, but App Store Connect determines the result.

Do not select **Made for Kids** merely because children can use family profiles. That choice is a long-term App Store category commitment with additional requirements. Make it only after a deliberate legal and product review.

## Review notes draft

Earned It is a shared family chore app built with SwiftUI, SwiftData, and CloudKit. It has no developer account system, ads, analytics, tracking, subscriptions, or in-app purchases.

To review the core experience:

1. Choose **Create a New Family**.
2. Enter fictional family and parent names.
3. Add at least one fictional child and finish setup.
4. Add a chore, mark work complete, and review weekly progress.

Creating an invitation enables the owner's private CloudKit zone and requires an available iCloud account. Parent and child invitations are bound to a role and profile. Camera access is optional and is used only to scan an Earned It invitation QR code. Reviewers can enter the code or link instead.

No demo account is required because the app does not operate its own account service. If App Review needs a two-account invitation test, provide a current one-time invitation through the private Review Notes or attachment channel at submission time. Do not place a live invitation in this repository or permanent metadata.

## Copyright and content rights

- Enter the rights holder's current legal name and year in App Store Connect. No legal entity is inferred in this repository.
- Confirm commercial rights for the app icon and every screenshot overlay or font not supplied by Apple.
- The daily thought uses unattributed product microcopy. See [quotes-and-attribution.md](quotes-and-attribution.md) for the content review.
- App screenshots must use fictional family information.

## Required manual fields

- app record, SKU, primary language, and bundle ID selection;
- copyright;
- age-rating questionnaire;
- content-rights declaration;
- privacy responses and Privacy Policy URL;
- Support URL and optional Marketing URL;
- pricing and availability;
- export-compliance answers;
- review contact details;
- build selection and release method;
- Digital Services Act trader status and any territory-specific requirements that apply to the account.
