# Sitemap URL Health Check

A GitHub Action that checks every URL listed in your XML sitemap and fails the job when it finds broken ones: 404/410s, other 4xx errors and 5xx server errors. It also reports redirects, redirect chains, https-to-http downgrades and `X-Robots-Tag: noindex` headers, so you can catch them before search engines do.

It runs the Apify Actor [`lineagersiui/sitemap-url-health-checker`](https://apify.com/lineagersiui/sitemap-url-health-checker) on **your own Apify account**, using your API token. The Action itself has no dependencies or build step: it's a composite action that uses bash, curl and jq, which are preinstalled on GitHub-hosted Ubuntu runners.

## Usage

1. Create an Apify account and copy your API token from the integrations settings in Apify Console.
2. In your site's repository, add the token as a secret named `APIFY_TOKEN` (Settings > Secrets and variables > Actions).
3. Add a workflow, for example `.github/workflows/sitemap-health.yml`:

```yaml
name: Sitemap health
on:
  schedule:
    - cron: '0 6 * * 1'   # every Monday 06:00 UTC
  workflow_dispatch:

jobs:
  sitemap:
    runs-on: ubuntu-latest
    steps:
      - uses: lineagersiui-boop/sitemap-url-health-check@v1
        with:
          apify-token: ${{ secrets.APIFY_TOKEN }}
          site-url: example.com
```

You can also run it after each deploy: use `on: deployment_status`, or add the step at the end of your deploy job. A full example is in [`examples/sitemap-health.yml`](examples/sitemap-health.yml).

## Permission

The Actor checks only sites that you own or have permission to check. It refuses non-demo runs unless `confirmPermission` is `true`. **This Action always sends `confirmPermission: true`.** By adding the Action to your site's CI and giving it a site or sitemap URL, you confirm that you own that site or have permission to check it. Don't point it at sites you don't control. The checker respects robots.txt: disallowed URLs are skipped and not billed.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `apify-token` | yes | | Your Apify API token. Pass it from a secret. Runs are billed to this account. |
| `site-url` | one of these two | | Site address(es), for example `example.com`. The sitemap is found from robots.txt or `/sitemap.xml`. Comma- or newline-separated, up to 10. |
| `sitemap-url` | one of these two | | Direct sitemap, sitemap-index, `.xml.gz` or plain-text list URL(s). Comma- or newline-separated, up to 10. |
| `max-urls` | no | `500` | Maximum URLs checked per run, from 1 to 5,000. This is the hard cap on billed checks. |
| `fail-on` | no | `not_found,server_error,client_error` | Comma-separated flags that fail the job. Leave it empty to report only and never fail. |
| `only-problems` | no | `true` | Return only URLs with problems. Healthy URLs are still checked and billed either way. |

### Flags

| Flag | Meaning |
|---|---|
| `not_found` | 404 or 410 |
| `client_error` | Another 4xx |
| `server_error` | 5xx |
| `redirected` / `redirect_chain` / `too_many_redirects` | Redirects once, more than once, or more than 5 times |
| `https_downgrade` | An https URL redirects to http |
| `noindex_header` | Sends `X-Robots-Tag: noindex` |
| `blocked_by_robots` | robots.txt disallows the URL for this checker. It's skipped and not billed |
| `timeout` / `network_error` / `blocked_private_address` | The URL couldn't be checked. It's not billed |
| `ok` | 2xx with no redirect |

For example, add `redirect_chain,https_downgrade,noindex_header` to `fail-on` to also fail on those.

## Outputs

| Output | Description |
|---|---|
| `problems` | Number of checked URLs with any problem flag |
| `failing` | Number of returned URLs with at least one `fail-on` flag |
| `checked` | Number of URLs checked |
| `run-id` | Apify run ID. Open it in Apify Console for the full dataset |

The Action also writes a job summary with the counts and a table of problem URLs (up to 100 rows, failing URLs first). It adds an error annotation for each of the first 20 failing URLs.

## Cost

The Action is free and MIT-licensed. The Actor runs on your Apify account and is billed there:

- **$0.0005 per URL checked**, which is $0.25 for 500 URLs. URLs skipped by robots.txt, time-outs and network errors aren't billed.
- **Apify platform usage** for the run, which is also billed to your account.

`max-urls` caps the number of billed checks per run. To see the output format at no cost, run the Actor in Apify Console with empty input. That's a free demo that checks 20 URLs of apify.com and isn't billed. This Action always needs a site or sitemap, so it never runs the demo.

## Security

- Your token is sent only to `api.apify.com`, in an `Authorization` header. The Action never prints it, writes it to disk or puts it on a command line.
- Use a repository or environment secret. Never paste the token into the workflow file.
- The Action makes no other network calls and stores nothing. The site and sitemap URLs you give it are sent to Apify to run the check, and Apify's privacy policy applies to that run.

## Disclosure

The author of this Action also built the Apify Actor it calls (`lineagersiui/sitemap-url-health-checker`), and earns that Actor's pay-per-event fees when you use it. There are no affiliate or referral parameters. This project isn't affiliated with or endorsed by Apify or GitHub. It was built with AI assistance under the author's direction.

## License

[MIT](LICENSE)
