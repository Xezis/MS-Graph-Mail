# Microsoft Graph Mail API limits and throttling reference

**Microsoft Graph applies multi-layered throttling for mail operations with limits enforced per app-mailbox combination, not per license tier.** The critical thresholds are **10,000 API requests per 10 minutes** and **4 concurrent requests** per app per mailbox, but Exchange Online's **30 messages per minute** sending limit often becomes the actual bottleneck for bulk mail operations. All Microsoft 365 license types—E3, E5, and Business plans—share identical Graph API throttling limits.

## Rate limits for mail operations

The Outlook service in Microsoft Graph applies throttling limits at the **app ID + mailbox combination** level, meaning exceeding limits on one mailbox doesn't affect access to others. This design allows applications to scale across many mailboxes without cumulative throttling.

| Limit type | Threshold | Scope |
|------------|-----------|-------|
| API requests | 10,000 per 10 minutes | Per app per mailbox |
| Concurrent requests | **4 simultaneous** | Per app per mailbox |
| Upload size | 150 MB per 5 minutes | Per app per mailbox |
| Download size | 5 GB per 5 minutes | Per app per mailbox |
| Global limit | 130,000 per 10 seconds | Per app across all tenants |

While the theoretical average is ~17 requests/second, Microsoft recommends designing for **4-10 requests/second per mailbox** for sustainable performance. Writes are more likely to trigger throttling than reads—you may encounter scenarios where sends fail while reads succeed.

Exchange Online imposes additional service-level limits that affect Graph Mail API operations:

| Operation | Exchange limit |
|-----------|---------------|
| Message rate | **30 messages per minute** per mailbox |
| Recipient rate | **10,000 recipients per 24 hours** per user |
| Recipients per message | Up to 1,000 (customizable) |
| Receiving limit | 3,600 messages per hour |

## Attachment and message size thresholds

Microsoft Graph uses a **3 MB threshold** to determine attachment upload method. Standard attachments require a single POST request, while larger files need an upload session.

| File size | Required method |
|-----------|-----------------|
| Under 3 MB | Single POST to `/messages/{id}/attachments` |
| 3 MB – 150 MB | Create upload session with iterative PUT requests |
| Over 150 MB | **Not supported** |

Base64 encoding increases attachment payload size by approximately **33%**, so a 2.3 MB file in Base64 would exceed the 3 MB POST limit. Upload session chunks should be under **4 MB** each for optimal performance.

Message size limits vary by client and scenario:

| Scenario | Size limit |
|----------|-----------|
| Between Microsoft datacenters | **150 MB** maximum |
| Outlook desktop/Mac | 150 MB (35 MB default, configurable) |
| Outlook Web Access | **112 MB** (encoding overhead) |
| Outlook mobile | 33 MB |
| Encrypted messages (Purview) | 100 MB |
| Encrypted messages (legacy OME) | 25 MB |
| Maximum attachments per message | **250 attachments** |
| Subject line | 255 characters |

## Batch request constraints

The `$batch` endpoint accepts a maximum of **20 individual requests per batch**, but the Outlook service processes only **4 requests concurrently** from any batch targeting mail resources.

```
POST https://graph.microsoft.com/v1.0/$batch
```

This means batches targeting the same mailbox execute in groups of 4, not all 20 simultaneously. Use the `dependsOn` property to sequence requests when order matters. Each individual request in a batch is evaluated against throttling limits independently—if one request triggers throttling, it returns status **429** while others may succeed. Dependent requests fail with status **424** (Failed Dependency).

For pagination, the List Messages endpoint defaults to **10 items** per page. You can increase this to **999** using `$top`, but large page sizes with full payloads may trigger **HTTP 504 timeouts**. Always use `$select` to limit returned properties when fetching large result sets.

## Delegated versus application permissions

Throttling limits remain **identical** regardless of permission type. The difference lies in scope and access patterns, not rate limits.

| Aspect | Delegated | Application |
|--------|-----------|-------------|
| Context | Acts as signed-in user | Acts with app's identity |
| Mailbox access | User's accessible mailboxes only | Any mailbox (with admin consent) |
| Throttling scope | Per user + per app + per tenant | Per app + per tenant |
| Quota accumulation | Separate quotas per user | Shared quota across all accessed mailboxes |

With delegated permissions, each user gets their own **10,000 requests/10 minutes** quota. With application permissions accessing multiple mailboxes, the **per app per mailbox** model still applies—accessing mailbox A and mailbox B creates two separate quota buckets of 10,000 requests each.

## Per-user and per-application quotas

User-level quotas primarily come from Exchange Online service limits rather than Graph API throttling:

- **Sending**: 30 messages/minute, 10,000 recipients/day
- **Receiving**: 3,600 messages/hour (single sender limited to 33% of this)
- **Mailbox storage**: 50-100 GB depending on license

Application-level quotas include:

| Limit type | Value |
|------------|-------|
| Global API requests | 130,000 per 10 seconds across all tenants |
| Webhook subscriptions | 500 requests per 20 seconds per app per tenant |
| Active Outlook subscriptions | 1,000 per mailbox |
| API permissions per app registration | 400 maximum |

The **Tenant External Recipient Rate Limit (TERRL)**, introduced in 2025, caps external email recipients per tenant based on license count. Trial tenants are limited to **5,000 external recipients per day**.

## License tiers do not affect API throttling

Microsoft Graph API rate limits are **not differentiated by Microsoft 365 license tier**. E3, E5, Business Basic, and Business Premium all receive identical throttling thresholds. The only license-related differences affecting mail API operations are:

- **Mailbox storage**: Business plans get 50 GB, E3/E5 get 100 GB
- **Archive mailbox**: Not available on F3/Kiosk plans
- **Advanced APIs**: eDiscovery, Defender, and Compliance APIs require E5 or add-ons

## Best practices for handling 429 throttling responses

When throttled, Microsoft Graph returns HTTP **429 Too Many Requests** with a `Retry-After` header specifying seconds to wait.

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 10
x-ms-throttle-scope: Tenant_Application/ReadWrite/{AppId}/{TenantId}
x-ms-throttle-information: WriteLimitExceeded
```

**Recommended retry strategy:**

1. Never retry immediately—all requests count against limits
2. Wait the exact duration specified in `Retry-After` header
3. Retry the failed request
4. If still throttled, continue respecting `Retry-After`
5. Without `Retry-After`, implement exponential backoff with jitter

**Proactive throttling avoidance:**

- Use **change notifications (webhooks)** instead of polling
- Leverage **delta queries** (`/messages/delta`) for incremental sync
- Apply `$select` to reduce payload size and request cost
- Increase page size with `$top` to reduce total requests
- Cache data locally when appropriate
- Design for **4-10 requests/second** per mailbox, not the theoretical maximum

The `x-ms-throttle-limit-percentage` header (values 0.8-1.8) indicates proximity to throttling—values approaching 1.0 suggest imminent throttling. Microsoft Graph SDKs include built-in retry handlers that automatically respect `Retry-After` headers.

## Conclusion

Building robust mail integrations with Microsoft Graph requires designing around the **4 concurrent request limit** per mailbox and the Exchange Online **30 messages/minute** sending cap—these often constrain throughput before the 10,000 requests/10 minutes API limit becomes relevant. Since license tiers don't affect API throttling, focus on architectural patterns: use webhooks over polling, implement proper retry logic with `Retry-After` respect, and leverage delta queries for synchronization. The per-app-per-mailbox throttling model enables horizontal scaling across many mailboxes without cumulative quota concerns.