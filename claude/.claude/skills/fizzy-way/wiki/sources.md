---
title: External sources — blogs, DHH writing, podcasts
use_when: [cite a source, what did Jorge say, what did DHH say, blog post, podcast, why do they do X]
verified: 2026-10-18 (every URL fetched; quotes checked verbatim)
---

# External sources

These are external primary sources on how 37signals and DHH organize Rails SaaS code, collected as reference material for a wiki based on Fizzy (github.com/basecamp/fizzy).

**How this was checked (2026-10-18).** Every URL below was fetched and returned HTTP 200. Every quote was compared word for word against the fetched page text. Some quotes contain an ellipsis (…) where words were cut; the parts on either side are verbatim. Anything that couldn't be checked is marked **UNVERIFIED** or left out.

---

## 1. dev.37signals.com posts

### The "Code I like" series (Jorge Manrubia)

- **Series index:** https://dev.37signals.com/series/code-i-like/
  - Its description: "Articles by Jorge Manrubia on Rails design techniques and patterns. They feature code examples extracted from 37signals apps."
  - The series has six posts, all listed below.

| Post | Date | URL |
|---|---|---|
| Domain driven boldness | 2022-06-13 | https://dev.37signals.com/domain-driven-boldness/ |
| Fractal journeys | 2022-09-18 | https://dev.37signals.com/fractal-journeys/ |
| Good concerns | 2022-10-10 | https://dev.37signals.com/good-concerns/ |
| Vanilla Rails is plenty | 2022-11-08 | https://dev.37signals.com/vanilla-rails-is-plenty/ |
| Active Record, nice and blended | 2022-12-16 | https://dev.37signals.com/active-record-nice-and-blended/ |
| Globals, callbacks and other sacrileges | 2023-07-31 | https://dev.37signals.com/globals-callbacks-and-other-sacrileges/ |

#### Vanilla Rails is plenty (2022-11-08)

https://dev.37signals.com/vanilla-rails-is-plenty/

- **Covers:** There's no separate application or service layer. Controllers call rich domain models directly. Concerns split the model's API into traits, and the heavy work is handed to small object systems behind them. The worked example is Basecamp's `Recording` with `Recording::Incineratable` → `Recording::Incineration` and `Recording::Copyable` → `Copy`/`Recording::Copier`.
- **Also covers:** POROs live in `app/models`. The `Signup` model is presented as an alternative to a `SigningUpService`.

Quotes:
- "In other words, we don't default to create services, actions, commands, or interactors to implement controller actions."
- "As opposed to anemic domain models, our approach encourages building rich domain models. We think of domain models as our application API"
- "rich internal object models hidden behind high-level APIs on domain models."
- "On the other, it feels more natural, like plain English. It feels more Ruby."
- "You can find many POROs in our app/models folders."

#### Good concerns (2022-10-10)

https://dev.37signals.com/good-concerns/

- **Folder conventions:** Concerns used by only one model go in `app/models/<model_name>/`. Shared concerns go in `app/models/concerns`.
- **Has-a semantics:** A concern must express a real "has a" or "acts as" trait.
- **Examples:** HEY's `User` uses an `Examiner` concern for screening. HEY's `Topic` model includes a long list of concerns. HEY account termination is a short `Account` API in front of incineration and purging classes.

Quotes:
- "the most common scenario where we use them is to organize code within a single model."
- "For model-specific concerns: we place them in a folder matching the model name: app/models/<model_name>."
- "each concern should be a cohesive unit that captures a trait of the host model."
- "You should not treat concerns as arbitrary containers of behavior and structure to split a large model into smaller parts."
- "Using concerns doesn't limit or replace the need to design systems properly."
- "There is a subsystem of three classes in charge of that, and the Account model offers just the door to use it."

#### Domain driven boldness (2022-06-13)

https://dev.37signals.com/domain-driven-boldness/

- **Covers:** Names that come from the domain and carry some personality. In Basecamp, removing a person means "erecting a tombstone" for them. HEY screening uses "clearance petitions" that a "petitioner" submits and an "examiner" reviews.
- **Practice:** Jorge writes a plain-text description of a domain model before building it.

Quotes:
- "I would have expected something like replacing a person with a placeholder when removing it, but erecting a tombstone when deceasing a person was so much better."
- "It was more eloquent, clear, and concise on the objective side. On the subjective side: it had a boldness component, like personality or soul."
- "don't be aseptic; double down on boldness."
- "This usage of concerns is a pretty pragmatic implementation of roles." (This refers to roles in DCI.)

#### Fractal journeys (2022-09-18)

https://dev.37signals.com/fractal-journeys/

- **Argument:** Good code shows the same qualities at every scale.
- **Walkthrough:** The example is Basecamp's **event relaying** pipeline: `Event` includes `Relaying`, then `Event#relay_now`, then `relay_to_or_revoke_from_timeline`, then `Timeline::Relayer#relay` (which records and broadcasts the relay). It's useful background for the events and notifications design.

Quotes:
- "Good code is a fractal: you observe the same qualities repeated at different levels of abstraction."
- "Good code is the one that is easy to understand, and the best mechanism we have to deal with complexity is building abstractions."
- "Notice that it speaks the domain language; it does one thing from the point of view of the job that invokes it"
- "one responsibility and one level of abstraction, with names reflecting the problem we are reasoning about."

#### Active Record, nice and blended (2022-12-16)

https://dev.37signals.com/active-record-nice-and-blended/

- **Covers:** Persistence and domain logic belong in the same class.
- **Techniques:** Associations, scopes, STI, serialized attributes, and delegated types. Active Record calls are wrapped in private methods behind domain methods such as `Contact#designate_to`. POROs such as `Timeline::Aggregator` handle complex queries.

Quotes:
- "The distinctive trait of the Active Record pattern is combining domain logic and persistence in the same class, and that's how we use it here at 37signals."
- "I think associations are one of the best features of Active Record, and we use them extensively in our apps."
- "For querying, we use scopes extensively."
- "So persistence is mixed in but well organized and encapsulated."

#### Globals, callbacks and other sacrileges (2023-07-31)

https://dev.37signals.com/globals-callbacks-and-other-sacrileges/

- **Covers three sharp tools:**
  - `CurrentAttributes`, for example `belongs_to :creator, default: -> { Current.person }`.
  - Callbacks, for secondary or orthogonal concerns such as auditing and event tracking (`Bucket::Eventable`).
  - `.suppress`, for exceptional cases such as copying.
- **Factories:** Contrasts callbacks with a factory (`bucket.record`), which is used only when the extra complexity is justified.
- This is the main written source for **event tracking** in 37signals apps.

Quotes:
- "Sacrificing purity for convenience is one of the Rails pillars."
- "you don't want to orchestrate complex flows using callbacks."
- "On the tactical side, the combination of callbacks with CurrentAttributes achieves something powerful: you can create a project normally, and the operation gets seamlessly audited."
- "An auditing concern is orthogonal to creating projects."
- "The key to using .suppress is exceptionality."

### Other relevant dev.37signals posts

| Post | Author | Date | URL | Relevance |
|---|---|---|---|---|
| A vanilla Rails stack is plenty | Jorge Manrubia | 2024-12-12 | https://dev.37signals.com/a-vanilla-rails-stack-is-plenty/ | The Rails 8 stack 37signals picked for its new apps: no Redis, Solid Queue/Cache/Cable, Minitest with fixtures, importmaps and #nobuild. |
| Minding the small stuff in pull request reviews | Jorge Manrubia | 2023-08-30 | https://dev.37signals.com/minding-the-small-stuff-in-pr-reviews/ | Naming, aesthetics, and consistency enforced in PR review. Real review comments, including DHH's. |
| Compared to what? | Jorge Manrubia | 2022-12-13 | https://dev.37signals.com/compared-to-what/ | Argues that design discussions need real code. Not quoted here. |
| Pending tests | Jorge Manrubia | 2023-03-01 | https://dev.37signals.com/pending-tests/ | "I rarely write my tests first or use them to help design my code." (This is the post's meta description.) |
| The Rails Delegated Type Pattern (RECORDABLES video, transcript on page) | Jeffrey Hardy, with hosts Kimberly Rhodes and Fernando Olivares | 2025-12-19 | https://dev.37signals.com/the-rails-delegated-type-pattern/ | Basecamp's recordings/recordables, immutable recordables, and the **event** history model. See Podcasts. |
| Rails Multi-Tenancy (RECORDABLES) | Mike Dalessio | 2026-02-13 | https://dev.37signals.com/rails-multi-tenancy/ | **Fizzy-specific:** one SQLite DB per customer, the active_record-tenanted gem, and why Fizzy launched on MySQL. See Podcasts. |
| Behind the Fizzy Infrastructure (RECORDABLES) | Kevin McConnell | 2026-02-26 | https://dev.37signals.com/fizzy-infrastructure/ | **Fizzy-specific:** the SQLite replication (Beamer) experiment and the decision to unwind it days before launch. See Podcasts. |
| Introducing Action Push Native | Jacopo (dev.37signals author) | 2025-08-18 | https://dev.37signals.com/introducing-action-push-native/ | Push notification delivery gem used in Basecamp and HEY: "more than 10 million push notifications per day". |

Quotes from these posts:
- "If you have the luxury of starting a new Rails app today, here's our recommendation: go vanilla." ([A vanilla Rails stack is plenty](https://dev.37signals.com/a-vanilla-rails-stack-is-plenty/))
- "Your Gemfile should be almost identical to the one that Rails generates." ([A vanilla Rails stack is plenty](https://dev.37signals.com/a-vanilla-rails-stack-is-plenty/))
- "With the importance of names to make code understandable, how can anyone consider discussing those superfluous?" ([Minding the small stuff](https://dev.37signals.com/minding-the-small-stuff-in-pr-reviews/))
- "The big picture matters, for sure, but computers don't execute big pictures, they execute lines of code, so how you compose those matters too." ([Minding the small stuff](https://dev.37signals.com/minding-the-small-stuff-in-pr-reviews/))

**Not found:** I found no dev.37signals post devoted to notification design, and none that walks through Fizzy's application code in general. The Fizzy-specific dev posts are the two RECORDABLES infrastructure episodes above.

---

## 2. DHH posts and primary material

### Fizzy launch post

**Fizzy is our fun, modern take on Kanban (and we made it open source!)**, DHH, HEY World, 2025-12-03
https://world.hey.com/dhh/fizzy-is-our-fun-modern-take-on-kanban-and-we-made-it-open-source-54ac41b6

- Fizzy is released under the O'Saasy License: MIT-style, but SaaS rights are reserved for 37signals.
- The post invites readers to study the code, including its full PR history.

Quotes:
- "That means it's not technically Open Source™, but the source sure is open"
- "Fizzy allows you full introspection into that. Including the entire history of how the product was built, pull request by pull request. It's a great way to learn how modern Rails applications are put together!"

There's also a related post on the license, **The O'Saasy License**: https://world.hey.com/dhh/the-o-saasy-license-336c5c8f. It's listed on DHH's HEY World index. I didn't fetch it for quotes.

### Concerns (Signal v. Noise, 2012)

**Put chubby models on a diet with concerns**, DHH, 2012-12-18
https://signalvnoise.com/posts/3372-put-chubby-models-on-a-diet-with-concerns

- This is the original statement of the 37signals concerns style (Basecamp's Trashable, Searchable, Visible, Taggable, and so on).

Quotes:
- "These concerns encapsulate both data access and domain logic about a certain slice of responsibility."
- "I find that concerns are often just the right amount of abstraction and that they often result in a friendlier API."
- "It's true that this will lead to a proliferation of methods on some objects, but that has never bothered me. I care about how I interact with my code base through the source."

### The Rails Doctrine (DHH)

https://rubyonrails.org/doctrine

- Jorge's posts link to three of its sections: **No one paradigm**, **Exalt beautiful code**, and **Provide sharp knives**.

Quotes:
- "Aesthetically pleasing code is a value unto itself and should be pursued with vigor." (#beautiful-code)
- "In Ruby, it's often somewhere at the intersection between native Ruby idioms and the power of a custom domain-specific language." (#beautiful-code)
- "Rails concerns, the specialization of Ruby's mixins, are often used to give the individual models a very wide surface area." (#no-one-paradigm)
- "If you can't be trusted to keep the kitchen sink out of your overstuffed concerns, you're probably not going to end up with a shining beacon of elegance otherwise." (#provide-sharp-knives)

### "On Writing Software Well" (DHH video series on the real Basecamp 3 code, 2018)

- **Announcement post (Signal v. Noise, 2018-02-20):** https://signalvnoise.com/svn3/on-writing-software-well/
  - "It's less "here's how to do it" and more "here's what I was thinking when we made this choice or took this direction"."
- **Playlist:** https://www.youtube.com/playlist?list=PL3m89j0mV0pdNAg6x9oq6S8Qz_4C-yuwj
- The descriptions quoted below are DHH's own YouTube video descriptions. I verified them from the video pages. There's no transcript, so nothing from the videos themselves is quoted.

| # | Title | Uploaded | URL | Description (verbatim excerpt) |
|---|---|---|---|---|
| 1 | On Writing Software (well?) #1: Pilot Episode | 2018-02-12 | https://www.youtube.com/watch?v=H5i1gdwe1Ls | "In which I talk about a dislike of code comments, replacing them with explaining constants or extracting a concept into Rails itself." |
| 2 | Using callbacks to manage auxiliary complexity | 2018-02-13 | https://www.youtube.com/watch?v=m1jOWu7woKM | "Callbacks are a powerful technique for making that which isn't essential to a primary flow live on the side." It "pairs very well together with concerns." The example is Basecamp 3 **mentions**. |
| 3 | Using globals when the price is right | 2018-02-15 | https://www.youtube.com/watch?v=D7zUOtlpUPw | "how we use globals in Basecamp to provide access to the current user and request details" (CurrentAttributes) |
| 4 | Not every model is backed by a database | 2018-02-16 | https://www.youtube.com/watch?v=MQw9zF9IehI | "how to combine the API beauty of concerns with the encapsulation of concepts in plain-old Ruby objects." |
| 5 | Testing without test damage or excessive isolation | — | https://www.youtube.com/watch?v=Tc5z64XIwIY | (title only; video page not fetched) |
| 6 | Actually deleting data, not just pretending to | — | https://www.youtube.com/watch?v=AoxoPfilKqE | (title only; video page not fetched) |
| 7 | Move the specifics down as far as it'll go when evolving your codebase | 2018-03-06 | https://www.youtube.com/watch?v=Yd3j3ZEx6DU | "Make it work. But then you should refactor it to make it nice." |

I took the titles and IDs for #5 and #6 from the playlist page but didn't open those video pages.

### Other DHH long-form interviews

**Lex Fridman Podcast #474, "DHH: Future of Programming, AI, Ruby on Rails, Productivity & Parenting"** (2025-07-12)
- Transcript: https://lexfridman.com/dhh-david-heinemeier-hansson-transcript/
- It has a "Beautiful code" chapter and goes through the Rails Doctrine.

Quotes:
- "I didn't even have the concept that aesthetics, beautiful code was something we could optimize for."
- "we're not going to abbreviate. This is a key difference in the aesthetics between Ruby and Python as well."
- "Init is shorter to type, it's only five characters. Initialize is a lot longer, but it looks a lot better and you don't type it very often, so you should look at something pretty."

---

## 3. Podcasts and videos

Ordered with Fizzy-specific episodes first.

### RECORDABLES (37signals' own video and podcast series; transcripts are on the dev.37signals pages)

- **Hosts:** Kimberly Rhodes (host of REWORK) and Fernando Olivares (Lead Programmer, mobile).

**1. "Rails Multi-Tenancy"** (2026-02-13)
- **Guest:** Mike Dalessio
- **Page:** https://dev.37signals.com/rails-multi-tenancy/
- **Video:** https://www.youtube.com/embed/J1I3puqWDEw
- **Covers:** Fizzy's original plan of one SQLite database per customer, the Active Record Tenanted gem, safeguards against cross-tenant leaks, and a live demo converting Writebook to multi-tenant. Fizzy launched on MySQL instead.
- **Transcript quotes:**
  - "So when we were building Fizzy here at 37signals, we wanted it to be multi-tenant and we wanted one application to work for all the customers similar to what Basecamp does."
  - "And we launched Fizzy with MySQL instead of with SQLite."

**2. "Behind the Fizzy Infrastructure"** (2026-02-26)
- **Guest:** Kevin McConnell
- **Page:** https://dev.37signals.com/fizzy-infrastructure/
- **Video:** https://www.youtube-nocookie.com/embed/QeGFqx4i_AU
- **Covers:** Why the team explored per-customer SQLite plus replication: the ONCE/self-hosted packaging, and putting data close to users to cut latency. Also the decision, days before launch, to revert to a conventional setup.
- **Code covered:** Infrastructure only, not the domain model.

**3. "The Rails Delegated Type Pattern"** (2025-12-19)
- **Guest:** Jeffrey Hardy (Principal Programmer)
- **Page:** https://dev.37signals.com/the-rails-delegated-type-pattern/
- **Video:** https://www.youtube-nocookie.com/embed/m90sl-Uvu0Y
- **Covers:** Basecamp's recordings/recordables, the tree of recordings, immutable recordables, the **event** model that records history, timelines, copying, and capabilities defined per recordable type.
- **Code covered:** Basecamp, not Fizzy, but it's the clearest primary explanation of the event and history design.
- **Transcript quotes:**
  - "You got to think of the recordables as being pretty dumb. They're just like, in the case of a message, it's literally just a title and content."
  - "if you want to have a history of what are all the recordables that it ever pointed to, we track that in an event model."

**4. "Moving Mountains of Data off S3"**
- **Guest:** Jeremy Daer
- **Page:** https://dev.37signals.com/moving-mountains-of-data-off-s3/
- **Covers:** Infrastructure only. Relevant to the AGENTS.md rule that big data transfers must stream rather than buffer.

### On Rails (Rails Foundation, host Robby Russell)

- **Show:** https://podcast.rubyonrails.org/2462975
- The RSS feed lists **two** episodes with 37signals guests.

**1. "DHH: Basecamp 5, Vibe Coding, and the Future of Rails"** (2026-06-12)
- **URL:** https://podcast.rubyonrails.org/2462975/episodes/19335416-dhh-basecamp-5-vibe-coding-and-the-future-of-rails (full transcript on page)
- **Fizzy segment:** 16:50, "The Basecamp 3 “chassis,” Fizzy, and carbon-dating an app". DHH compares Fizzy's code with Basecamp 5's, which runs on the Basecamp 3 codebase from 2013.
- **Architecture segment:** 33:56, "Make the change easy, then make the easy change". DHH discusses architecture, agents, and refactoring.
- **Transcript quotes:**
  - "we also just released Fizzy, for example, a greenfield application that was built to the best standards we knew how with all of our best ideas and all our best talents of today."
  - "But I can open today models in the Basecamp codebase that would look absolutely right at home in Fizzy, even though Fizzy was just written 5 minutes ago."
  - "it's perfectly happy writing 1,200 lines of code on something when an architectural twist Rails could have reduced that to 20 lines of code."
  - "hesitations about software development without care towards architecture, without care towards style, and beauty"

**2. "Rosa Gutiérrez & Solid Queue"** (2025-06-24)
- **URL:** https://podcast.rubyonrails.org/2462975/episodes/17305252-rosa-gutierrez-solid-queue
- **Guest:** Rosa Gutiérrez, Principal Programmer.
- **Covers:** Why 37signals replaced Resque, building Solid Queue on Active Job and MySQL, recurring and long-running jobs, and testing.
- **Code covered:** Infrastructure and jobs, not app code.
- I verified this from the show-notes description only and pulled no transcript quotes.

### REWORK (37signals podcast: Jason Fried, DHH, host Kimberly Rhodes)

These episodes are product- and business-level, not code walkthroughs.

**"Open source outside the box"** (2025-12-17)
- **URL:** https://37signals.com/podcast/open-source-outside-the-box/ (transcript on page)
- **Covers:** Why Fizzy's source is open, outside PRs, and who reviews them (JZ, Mike, Jorge).
- **Quote:** "one of the things people were shocked about how Vanilla it is actually. No build and a lot of Vanilla Rails, not a bunch of different extra frameworks and extra libraries and stuff." (Jason Fried, 08:43)

**Other REWORK episodes:**
- "Fizzy Q's and A's" (2025-10-29): https://37signals.com/podcast/fizzy-qs-and-as/. Product questions before launch.
- "Launch day": https://37signals.com/podcast/launch-day/. Launch logistics. The date isn't verified from the page.
- "Software as art" (2025-08-06): https://37signals.com/podcast/software-as-art/. A product point of view, not code.

### Code with Jason (host Jason Swett)

- **#167 "Vanilla Rails is Plenty" with Jorge Manrubia:** https://www.codewithjason.com/podcast/11859880-167-vanilla-rails-is-plenty-with-jorge-manrubia-of-37signals/
  - Show notes: "In this episode I talk with Jorge Manrubia about his recent blog post, "Vanilla Rails is Plenty"."
  - Linked resources: Domain-Driven Boldness, *Smalltalk Best Practice Patterns*, CurrentAttributes.
- **#169 "Rails Concerns with Jorge Manrubia of 37signals":** https://www.codewithjason.com/podcast/11919362-169-rails-concerns-with-jorge-manrubia-of-37signals/
  - Show notes: "In today's episode, Jorge Manrubia returns for a discussion of Rails concerns."
- **Caveats for both:** The pages carry no transcript and no date, and I couldn't check what was said in either episode.

### Remote Ruby (Chris Oliver, Andrew Mason, David Hill)

- **"Turbo Morph & ActiveRecord Encryption with Jorge Manrubia"** (2023-11-10): https://www.buzzsprout.com/2260490/episodes/13902138-turbo-morph-activerecord-encryption-with-jorge-manrubia
  - **Covers:** Active Record Encryption, Console1984, and Turbo 8 morphing.
  - **Code covered:** HEY and Basecamp internals at the framework level.
- **"Joined by David Hill"** (2025-12-12): https://www.buzzsprout.com/2260490/episodes/18337037
  - Show notes say it "touches on the new open-source release of Basecamp's Kanban board, Fizzy, and some innovative CSS techniques used in the project."
  - **Caveat:** A short segment only. Depth is unverified.
- **"Tool Standardization"** (2026-01-23): https://www.buzzsprout.com/2260490/episodes/18533221
  - Show notes mention Fizzy's SSRF protection (spelled "SSFR" in the notes) and link to `app/models/ssrf_protection.rb` (since moved to the `surfguard` gem in d3185b5e9; the path no longer exists at the snapshot).
  - **Caveat:** Depth is unverified.

### Drifting Ruby (screencast, not a podcast)

**#539 "Cool Things in Fizzy"** (David Kimura, 2025-12-07, 20:23)
- **URL:** https://www.driftingruby.com/episodes/cool-things-in-fizzy
- **Description:** "In this episode, we look deploying Fizzy to a server and look at some of the notable practices found in the code."
- **Chapters:** Multitenancy, Entropy, ActiveJob and Multitenancy, CRUD Styling, Rich Domain Model, Modifying ActionText and ActiveStorage.
- It's a Pro (paid) episode, and I found no transcript.

### Ruby Rogues

**RUBY 520 "Encryption and Security in Ruby and Rails ft. Jorge Manrubia"** (2021-10-27)
- **URL:** https://topenddevs.com/podcasts/ruby-rogues/encryption-and-security-in-ruby-and-rails-ft-jorge-manrubia-ruby-520
- **Covers:** Rails encryption as used in HEY. It isn't about code organization.

### The Rails Changelog (host Emmanuel Hayford)

**UNVERIFIED.** Search results point to episode 023, a Rosa Gutierrez interview about Solid Queue (around 2024-06-20). Problems with checking it:
- The show's feed (feeds.transistor.fm/the-rails-changelog) returns 404.
- Metacast returned 403.
- I couldn't confirm an episode URL.

I found no Rails Changelog episode on Fizzy.

### Third-party Fizzy code write-ups (not 37signals; useful leads)

Rob Zolkos (zolkos.com) wrote several posts on Fizzy. All URLs returned 200.

| Title | Date | URL |
|---|---|---|
| The Making of Fizzy, Told by Git | 2025-12-02 | https://www.zolkos.com/2025/12/02/the-making-of-fizzy-told-by-git |
| Fizzy Webhooks: What You Need to Know | 2025-12-02 | https://www.zolkos.com/2025/12/02/fizzy-webhooks-what-you-need-to-know |
| Vanilla CSS is all you need | 2025-12-03 | https://www.zolkos.com/2025/12/03/vanilla-css-is-all-you-need |
| Fizzy's Pull Requests: Who Built What and How | 2025-12-10 | https://www.zolkos.com/2025/12/10/fizzys-pull-requests |
| A Month Exploring Fizzy | 2026-01-02 | https://www.zolkos.com/2026/01/02/a-month-exploring-fizzy |

These aren't primary sources, and none were quoted.

---

## 4. Quotes by topic

Every quote below was checked word for word against the fetched page.

### (a) Concerns as the way to organize rich models

1. "each concern should be a cohesive unit that captures a trait of the host model." Jorge Manrubia, [Good concerns](https://dev.37signals.com/good-concerns/)
2. "They need to feature a genuine has trait or acts as semantics to work, just like class inheritance needs the is a relationship." Jorge Manrubia, [Good concerns](https://dev.37signals.com/good-concerns/)
3. "I care about how I interact with my code base through the source. That concerns happen to mix it all together into a big model under the hood is irrelevant to the understanding of the domain model." DHH, [Put chubby models on a diet with concerns](https://signalvnoise.com/posts/3372-put-chubby-models-on-a-diet-with-concerns)
   - This one runs slightly over 40 words. Trim it at "source." if needed.
4. "rich internal object models hidden behind high-level APIs on domain models." Jorge Manrubia, [Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/)

### (b) Notifications and events design in 37signals apps

**Caveat:** I found no 37signals post or episode devoted to *notification* design, in Fizzy or elsewhere. The closest primary sources cover **events**: recording them, relaying them, and auditing through callbacks. Notifications in Fizzy build on those events. For the notification code itself, read `app/models` in the repo.

1. "the system creates events, and those events are relayed to several destinations, such as the activity timeline or webhooks." Jorge Manrubia, [Fractal journeys](https://dev.37signals.com/fractal-journeys/)
2. "On the tactical side, the combination of callbacks with CurrentAttributes achieves something powerful: you can create a project normally, and the operation gets seamlessly audited." Jorge Manrubia, [Globals, callbacks and other sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/)
3. "The event has a reference to the recording and it has a reference to a recordable. This means we can look at the history of a recording and see all of its changes" Jeffrey Hardy, [RECORDABLES: The Rails Delegated Type Pattern](https://dev.37signals.com/the-rails-delegated-type-pattern/)
4. "Callbacks are a powerful technique for making that which isn't essential to a primary flow live on the side." DHH, [On Writing Software Well #2](https://www.youtube.com/watch?v=m1jOWu7woKM) (video description; the example is Basecamp mentions)

### (c) Naming, refactoring, and what makes code beautiful

1. "Aesthetically pleasing code is a value unto itself and should be pursued with vigor." DHH, [Rails Doctrine: Exalt beautiful code](https://rubyonrails.org/doctrine#beautiful-code)
2. "With the importance of names to make code understandable, how can anyone consider discussing those superfluous?" Jorge Manrubia, [Minding the small stuff in pull request reviews](https://dev.37signals.com/minding-the-small-stuff-in-pr-reviews/)
3. "one responsibility and one level of abstraction, with names reflecting the problem we are reasoning about." Jorge Manrubia, [Fractal journeys](https://dev.37signals.com/fractal-journeys/)
4. "I would have expected something like replacing a person with a placeholder when removing it, but erecting a tombstone when deceasing a person was so much better." Jorge Manrubia, [Domain driven boldness](https://dev.37signals.com/domain-driven-boldness/)
5. "Make it work. But then you should refactor it to make it nice." DHH, [On Writing Software Well #7](https://www.youtube.com/watch?v=Yd3j3ZEx6DU) (video description)
6. "an architectural twist Rails could have reduced that to 20 lines of code. And I think that's foundational to the longevity of good code bases" DHH, [On Rails, 2026-06-12](https://podcast.rubyonrails.org/2462975/episodes/19335416-dhh-basecamp-5-vibe-coding-and-the-future-of-rails)

---

## Additions

### Testing (added by the testing cluster; each page fetched 2026-10-18 and quotes checked verbatim against the raw HTML)

- **A vanilla Rails stack is plenty**, Jorge Manrubia, https://dev.37signals.com/a-vanilla-rails-stack-is-plenty/
  - "Test your apps with Minitest. Use fixtures and build a realistic set of those as you cook your app."
- **TDD is dead. Long live testing.**, DHH, 2014, https://dhh.dk/2014/tdd-is-dead-long-live-testing.html
  - "I rarely unit test in the traditional sense of the word, where all dependencies are mocked out, and thousands of tests can close in seconds. It just hasn't been a useful way of dealing with the testing of Rails applications. I test active record models directly, letting them hit the database, and through the use of fixtures."
  - "A dense jungle of service objects, command patterns, and worse."
- **Testing like the TSA**, DHH, Signal v. Noise, 2012-04-11, https://signalvnoise.com/posts/3159-testing-like-the-tsa
  - "Knowing what not to test is the harder part of the lesson."
  - "Don’t test standard Active Record associations, validations, or scopes."
- **System tests have failed**, DHH, HEY World, 2024-05-17, https://world.hey.com/dhh/system-tests-have-failed-d90af718
  - "System tests remain as slow, brittle, and full of false negatives as they did a decade ago."
  - "System tests work well for the top-level smoke test."
  - "not testing business logic, which model and controller tests do better and cheaper"
