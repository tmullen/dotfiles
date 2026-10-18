---
title: Outbound webhooks
use_when: [webhooks, outbound webhook, webhook deliveries, signing secret, HMAC signature, SSRF, DNS rebinding, retry and disable failing endpoint, Slack integration, Campfire integration, delivery log]
sources:
  - app/models/webhook.rb, app/models/webhook/*.rb
  - app/jobs/event/webhook_dispatch_job.rb, app/jobs/webhook/delivery_job.rb
  - app/controllers/webhooks_controller.rb, app/controllers/webhooks/*.rb
  - app/views/webhooks/event.json.jbuilder, app/views/webhooks/event.html.erb
  - app/models/push/subscription.rb (shares the SSRF guard)
  - config/recurring.yml, Gemfile (surfguard)
  - test/models/webhook_test.rb, test/models/webhook/*.rb, test/test_helpers/dns_test_helper.rb
  - commits a515ea3b1, 9d717239e, 5c6cad057, dd3063b01, d7db97339, 7af93765a, 29c792630, a253c31de, d3185b5e9, f22d19eb6
snapshot: 27d0d2e6b
---

# Outbound webhooks

## Answer

A `Webhook` belongs to a board and subscribes to a list of event actions. Every
`Event` enqueues one dispatch job after commit. The job finds matching active webhooks
and calls `webhook.trigger(event)`, which just **creates a `Webhook::Delivery` row**.
The delivery enqueues itself, and `delivery.deliver` does the HTTP POST: it resolves
DNS once through an SSRF policy (the `surfguard` gem), pins the connection to that IP,
signs the body with HMAC-SHA256, streams the response with a size cap, and stores
request/response on the row. A `DelinquencyTracker` record deactivates a webhook
after sustained failure. There are no retries; deliveries are a 7-day log.

## Shape

```
app/models/
  webhook.rb                    # Triggerable; URL regexes for Slack/Campfire/Basecamp; activate/deactivate
  webhook/
    triggerable.rb              # scope :triggered_by(event); #trigger(event) → deliveries.create!
    delivery.rb                 # state enum, request/response stores, #deliver, payload formats, cleanup
    delinquency_tracker.rb      # has_one per webhook: consecutive failures over time → deactivate
app/jobs/
  event/webhook_dispatch_job.rb # ActiveJob::Continuable; find_each with cursor
  webhook/delivery_job.rb       # perform: delivery.deliver
app/controllers/
  webhooks_controller.rb                 # board-scoped CRUD, admin only; url immutable on update
  webhooks/activations_controller.rb     # create = reactivate
  webhooks/deliveries_controller.rb      # JSON index of the delivery log
app/views/webhooks/
  event.json.jbuilder           # the generic payload (cached)
  event.html.erb                # plain sentence + link, for Campfire/Basecamp chat
```

Routes:

```ruby
resources :boards do
  resources :webhooks do             # WebhooksController (top-level), loads @board via BoardScoped
    scope module: :webhooks do
      resource :activation, only: :create
      resources :deliveries, only: :index, defaults: { format: :json }
    end
  end
end

resolve "Webhook" do |webhook, options|
  route_for :board_webhook, webhook.board, webhook, options
end
```

Tables: `webhooks(board_id, name, url, signing_secret, subscribed_actions text, active)`,
`webhook_deliveries(webhook_id, event_id, state, request text, response text)`,
`webhook_delinquency_trackers(webhook_id, consecutive_failures_count, first_failure_at)`.

## Key code

Dispatch hangs off the event; triggering is a row insert:

```ruby
class Event < ApplicationRecord
  after_create_commit :dispatch_webhooks
  private
    def dispatch_webhooks = Event::WebhookDispatchJob.perform_later(self)
end

class Event::WebhookDispatchJob < ApplicationJob
  include ActiveJob::Continuable
  queue_as :webhooks
  discard_on ActiveJob::DeserializationError

  def perform(event)
    step :dispatch do |step|
      Webhook.active.triggered_by(event).find_each(start: step.cursor) do |webhook|
        webhook.trigger(event)
        step.advance! from: webhook.id
      end
    end
  end
end

module Webhook::Triggerable
  included do
    scope :triggered_by, ->(event) { where(board: event.board).triggered_by_action(event.action) }
    scope :triggered_by_action, ->(action) { where("subscribed_actions LIKE ?", "%\"#{action}\"%") }
  end

  def trigger(event)
    deliveries.create!(event: event) unless account.cancelled?
  end
end
```

The delivery is a stateful record that delivers itself:

```ruby
class Webhook::Delivery < ApplicationRecord
  ENDPOINT_TIMEOUT = 7.seconds
  MAX_RESPONSE_SIZE = 100.kilobytes

  store :request, coder: JSON
  store :response, coder: JSON
  enum :state, %w[ pending in_progress completed errored ].index_by(&:itself), default: :pending

  after_create_commit :deliver_later

  def deliver
    in_progress!
    self.request[:headers] = headers
    self.response = perform_request
    self.state = :completed
    save!
    webhook.delinquency_tracker.record_delivery_of(self)
  rescue
    errored!
    raise
  end

  private
    def perform_request
      if resolved_ip.nil?
        { error: :private_uri }
      else
        request = Net::HTTP::Post.new(uri, headers).tap { |request| request.body = payload }
        response = http.request(request) { |r| stream_body_with_limit(r) }
        { code: response.code.to_i }
      end
    rescue ResponseTooLarge
      { error: :response_too_large }
    rescue Surfguard::Unresolvable, Resolv::ResolvTimeout, Resolv::ResolvError, SocketError
      { error: :dns_lookup_failed }
    # ... connection_timeout, destination_unreachable, failed_tls the same way
    end

    def resolved_ip
      return @resolved_ip if defined?(@resolved_ip)
      @resolved_ip = Surfguard.resolve_public_ips(uri.host).first
    end

    # The nil proxy address ignores http_proxy: a proxy would look the host up again, and the connection
    # would no longer go to resolved_ip.
    def http
      Net::HTTP.new(uri.host, uri.port, nil).tap do |http|
        http.ipaddr = resolved_ip
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = ENDPOINT_TIMEOUT
        http.read_timeout = ENDPOINT_TIMEOUT
      end
    end

    def headers
      { "User-Agent" => USER_AGENT, "Content-Type" => content_type,
        "X-Webhook-Signature" => signature,                       # HMAC-SHA256(signing_secret, payload)
        "X-Webhook-Timestamp" => event.created_at.utc.iso8601 }
    end
end
```

*(Condensed: constants, three rescue clauses and `stream_body_with_limit` elided.)*

Payload format is picked by URL shape; the generic one renders a jbuilder template
through a per-account renderer:

```ruby
def payload
  @payload ||= if webhook.for_basecamp?   then { content: render_payload(formats: :html) }.to_query
               elsif webhook.for_campfire? then render_payload(formats: :html)
               elsif webhook.for_slack?    then slack_payload
               else render_payload(formats: :json)
               end
end

def render_payload(**options)
  webhook.renderer.render(layout: false, template: "webhooks/event", assigns: { event: event }, **options).strip
end

# Webhook
def renderer
  @renderer ||= ApplicationController.renderer.new(script_name: account.slug, https: !Rails.env.local?)
end
```

Delinquency is its own record, not columns on `webhooks`:

```ruby
class Webhook::DelinquencyTracker < ApplicationRecord
  DELINQUENCY_THRESHOLD = 10
  DELINQUENCY_DURATION = 1.hour

  def record_delivery_of(delivery)
    if delivery.succeeded?
      reset
    else
      mark_first_failure_time if consecutive_failures_count.zero?
      increment!(:consecutive_failures_count, touch: true)
      webhook.deactivate if delinquent?          # ≥10 in a row AND failing for >1 hour
    end
  end
end
```

Cleanup is a class method run by Solid Queue's recurring config, batched:

```ruby
def self.cleanup(batch_size: 500, pause: 0.1)
  sleep pause until stale.limit(batch_size).delete_all.zero?
end
# config/recurring.yml
cleanup_webhook_deliveries:
  command: "Webhook::Delivery.cleanup"
  schedule: every 15 minutes
```

## Why

- **Webhooks are just another event destination.** 9d717239e "Dispatch Webhooks on
  event creation"; the whole feature (PR #1083, Stanko Krtalić) adds no tracking
  code to cards or comments. *"the system creates events, and those events are
  relayed to several destinations, such as the activity timeline or webhooks."*
  (Jorge, [Fractal journeys](https://dev.37signals.com/fractal-journeys/)) See
  [[patterns/events-as-spine]].
- **Two hops, each a record.** Dispatch fans out to rows; each row is delivered by its
  own job. A slow endpoint can't block others, and the delivery log is the audit
  trail the deliveries API (21981898d "Add JSON API for webhook deliveries (#2785)")
  serves. Triggering lives in its own concern: 5c6cad057 "Extract triggering logic
  into a concern".
- **The dispatch job is resumable.** `ActiveJob::Continuable` with
  `step.advance! from: webhook.id` means an interrupted dispatch resumes from the
  cursor instead of re-delivering (inference from the API's purpose).
- **Pin the resolved IP; don't re-resolve.** 7af93765a "Security: close narrow window
  of exposure to DNS rebinding (#1903)" (Jeremy Daer) replaced a check-then-connect
  (`private_uri?` resolved, then `Net::HTTP` resolved again) with resolve-once and
  `ipaddr:`. f22d19eb6 "Don't let an http_proxy environment variable bypass the
  pinned address": *"With http_proxy or https_proxy set, Net::HTTP would instead send
  the hostname to the proxy, which looks it up again"*. The one comment in
  `Delivery` explains exactly this non-obvious `nil`.
- **Own the policy until someone else owns it better.** The SSRF ranges lived in
  `app/models/ssrf_protection.rb` (deleted since) and grew through several IPv6 fixes (0eefd67b6,
  0b6a776f2, db098dbb0), then moved to a shared 37signals gem: d3185b5e9 "SSRF: take
  the address policy from surfguard instead of keeping our own copy (#3026)". Web
  push (`Push::Subscription#resolved_endpoint_ip`) uses the same guard.
- **Bounded reads.** 29c792630 "Stream response in webhook request manually to check
  size" (PR #2033): *"This addresses a DoS vulnerability where the response might be
  massive leading to OOM errors"* and *"we only care about the status code in the end."*
- **Replay protection needs a stable timestamp.** d7db97339 "Use the same timestamp
  from the body in the header": *"Else replay attack prevention doesn't work"*. The
  header uses `event.created_at`, not `Time.now`.
- **Simple delinquency beats ratios.** dd3063b01 "Simplify delinquency tracking"
  replaced `total_count`/`failed_count`/`last_reset_at` with
  `consecutive_failures_count` + `first_failure_at`: one success resets everything.
- **No speculative machinery.** 5e4d15d80 "Remove concurrency limit": *"It won't be
  useful in practice for now, and we can always put it back in if the need arises"*.
  9d77b17b8 "Remove encryption". No retry/backoff exists; a failed delivery is logged
  and counted (inference: delinquency is the retry policy's replacement).
- **Batched cleanup.** a253c31de "Batch webhook delivery cleanup to prevent DB lock
  contention (#2555)": *"Delete in small batches with a pause between each to let
  other transactions through, following the SolidQueue pattern."*
- **Cancelled accounts go quiet** in the model, not the job: eceb6c9b4 "Add
  self-service account deletion (#2246)" added `unless account.cancelled?` and
  `discard_on ActiveJob::DeserializationError` (events can vanish with their account).
- **URL is immutable after create**: `@webhook.update(webhook_params.except(:url))`
  (inference: the signing secret is tied to the destination; change destination →
  new webhook).
- **Chat integrations by URL sniffing** (2fc9215b1 "Add support for Basecamp, Campfire
  & Slack webhooks"): no "type" column; the URL regex decides the format. This is
  Fizzy-specific product glue.

**Fizzy-specific vs reusable.** Reusable: event → dispatch job → delivery rows →
self-delivering record; HMAC + timestamp headers; pinned-IP SSRF guard; response
cap; delinquency record; batched recurring cleanup. Fizzy-specific: board scoping,
the action whitelist, Slack/Campfire/Basecamp formats, `LIKE` on a JSON text
column for subscription matching (works because it's per-board and small).

## Testing

- `test/models/webhook/delivery_test.rb` uses WebMock `stub_request(:post, url)` for
  each format and failure mode (`.to_timeout`, `.to_raise(Errno::ECONNREFUSED)`,
  `OpenSSL::SSL::SSLError`), and asserts `delivery.response[:error]` symbols.
- SSRF tests stub DNS, not HTTP: `stub_dns_resolution("169.254.169.254")` →
  `"private_uri"`; `stub_dns_failure` → `"dns_lookup_failed"`; a mocha expectation
  `Net::HTTP.expects(:new).with("example.com", 443, nil)` proves pinning; a proxy test
  asserts `TCPSocket.open` never sees the proxy host. Helpers in
  `test/test_helpers/dns_test_helper.rb` stub `Resolv.getaddresses`.
- `test/models/webhook/triggerable_test.rb`: `assert_difference -> { Webhook::Delivery.count }`,
  cancelled-account case via `@account.cancel(initiated_by:)`.
- `test/models/webhook/delinquency_tracker_test.rb`, `test/models/webhook_test.rb`
  (URL validation, `for_slack?` etc.), `test/models/surfguard_policy_test.rb`.
- Controllers: `test/controllers/webhooks_controller_test.rb`,
  `test/controllers/webhooks/activations_controller_test.rb`,
  `test/controllers/webhooks/deliveries_controller_test.rb`.

## Reuse recipe

1. Have an `Event` table first ([[components/events]]). Add `after_create_commit` →
   `Event::WebhookDispatchJob`.
2. `Webhook`: owner scope, `url`, `has_secure_token :signing_secret`,
   `subscribed_actions` normalized against a whitelist, `active` flag,
   `activate`/`deactivate`.
3. `Webhook::Triggerable#trigger(event)` creates a `Webhook::Delivery`; the delivery's
   `after_create_commit` enqueues `Webhook::DeliveryJob`, which calls `delivery.deliver`.
4. In `deliver`: resolve once through an SSRF policy, connect with `ipaddr=` and a
   `nil` proxy, set short timeouts, stream the body with a byte cap, sign with
   HMAC-SHA256 plus a timestamp header from the event, and store request/response.
   Map network errors to symbols instead of raising.
5. Add a `has_one` delinquency tracker; deactivate after N consecutive failures over T.
   Expose reactivation as `resource :activation`.
6. Recurring `Delivery.cleanup` in batches; don't build retries until you need them.
7. Render payloads with `ApplicationController.renderer` scoped to the tenant so URL
   helpers produce correct links.

## Related

[[components/events]] · [[patterns/events-as-spine]] · [[patterns/jobs-later-now]] ·
[[patterns/state-as-resource]] · [[components/notifications]] ·
[[components/accounts-tenancy]] · [[sources]]
